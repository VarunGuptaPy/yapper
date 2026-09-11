import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_adapter.dart';

/// Pins the behaviour the batch-download bug came from: Dio decodes JSON only
/// when the content type says so.
void main() {
  Future<Object?> fetchWith(String? contentType) async {
    final dio = Dio()
      ..httpClientAdapter = FakeAdapter(
        (_) => rawResponse('{"transcript":"hello"}', contentType: contentType),
      );
    final res = await dio.get<dynamic>('https://blob.example.com/0.json');
    return res.data;
  }

  test('application/json is decoded to a Map', () async {
    expect(await fetchWith('application/json'), isA<Map<String, dynamic>>());
  });

  test('application/octet-stream is NOT decoded — it arrives as a String',
      () async {
    expect(await fetchWith('application/octet-stream'), isA<String>());
  });

  test('no content type is NOT decoded either', () async {
    expect(await fetchWith(null), isA<String>());
  });
}
