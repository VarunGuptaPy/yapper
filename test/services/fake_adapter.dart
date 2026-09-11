import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

class RecordedRequest {
  RecordedRequest({
    required this.method,
    required this.uri,
    required this.headers,
    required this.body,
  });

  final String method;
  final Uri uri;
  final Map<String, dynamic> headers;
  final String body;

  String get path => uri.path;

  Map<String, dynamic> get json => jsonDecode(body) as Map<String, dynamic>;

  /// The value of a multipart field, or null if the body has no such field.
  String? formField(String field) {
    final marker = 'name="$field"';
    final idx = body.indexOf(marker);
    if (idx == -1) return null;
    final rest = body.substring(idx + marker.length);
    // Skip the blank line separating the part's headers from its value.
    final start = rest.indexOf('\r\n\r\n');
    if (start == -1) return null;
    final value = rest.substring(start + 4);
    final end = value.indexOf('\r\n');
    return end == -1 ? value : value.substring(0, end);
  }
}

/// A Dio adapter that records every request and answers from a router the test
/// supplies. Keeps the Sarvam client tests free of real network calls — and of
/// a mocking dependency.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  final ResponseBody Function(RecordedRequest request) handler;
  final List<RecordedRequest> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var body = '';
    if (requestStream != null) {
      final chunks = await requestStream.toList();
      body = utf8.decode(
        chunks.expand((c) => c).toList(),
        allowMalformed: true,
      );
    } else if (options.data is String) {
      body = options.data as String;
    }

    final recorded = RecordedRequest(
      method: options.method,
      uri: options.uri,
      headers: Map<String, dynamic>.from(options.headers),
      body: body,
    );
    requests.add(recorded);
    return handler(recorded);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonResponse(Object data, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

ResponseBody emptyResponse({int status = 200}) =>
    ResponseBody.fromString('', status);
