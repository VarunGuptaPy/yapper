import 'package:dio/dio.dart';

import '../../core/errors.dart';

/// Sarvam authenticates every endpoint with this header (SPEC.md §14.2).
const sarvamAuthHeader = 'api-subscription-key';

const sarvamBaseUrl = 'https://api.sarvam.ai';

/// The two HTTP clients every Sarvam call needs.
///
/// They are separate on purpose: [api] carries the subscription key, [storage]
/// must not. Presigned blob URLs are signed already, and forwarding an API key
/// to a third-party storage host would leak it.
class SarvamHttp {
  SarvamHttp({required this.api, required this.storage});

  /// Preconfigured for `api.sarvam.ai` with the auth header.
  factory SarvamHttp.forKey(String apiKey) => SarvamHttp(
        api: Dio(BaseOptions(
          baseUrl: sarvamBaseUrl,
          headers: {sarvamAuthHeader: apiKey},
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(minutes: 2),
          sendTimeout: const Duration(minutes: 5),
        )),
        storage: Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(minutes: 5),
          sendTimeout: const Duration(minutes: 10),
        )),
      );

  final Dio api;
  final Dio storage;

  void close() {
    api.close();
    storage.close();
  }
}

/// Sarvam's keyterm rules: at most 50 distinct terms, at most 64 characters
/// each, and **no commas or semicolons inside a term** — it reads those as an
/// attempt to pack several keyterms into one string and rejects the whole
/// request with a 400.
///
/// Keyterms are person-note titles, which are user-authored, so none of that
/// can be assumed. A title like "Archit Sethia, Unirely" really is two names,
/// so it is split into two keyterms rather than having the comma stripped.
List<String> sanitizeKeyterms(List<String> raw) {
  final seen = <String>{};
  final out = <String>[];

  for (final term in raw) {
    for (final piece in term.split(_keytermSeparators)) {
      // Collapse any newline or run of spaces a title might carry.
      final trimmed = piece.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (trimmed.isEmpty) continue;

      final clamped =
          (trimmed.length > 64 ? trimmed.substring(0, 64) : trimmed).trim();
      if (clamped.isEmpty) continue;

      if (seen.add(clamped.toLowerCase())) out.add(clamped);
      if (out.length == 50) return out;
    }
  }
  return out;
}

final _keytermSeparators = RegExp(r'[,;]');

/// Maps a Dio failure onto the app's error vocabulary, keeping retryable
/// problems (timeouts, connection drops) distinct from permanent ones.
AppException mapSarvamError(DioException e, String what) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.transformTimeout:
      return NetworkException('$what timed out. Check your connection.', cause: e);
    case DioExceptionType.connectionError:
      return NetworkException('Could not reach Sarvam. Check your connection.',
          cause: e);
    case DioExceptionType.cancel:
      return NetworkException('$what was cancelled.', cause: e);
    case DioExceptionType.badCertificate:
      return NetworkException('Could not verify Sarvam\'s certificate.', cause: e);
    case DioExceptionType.badResponse:
    case DioExceptionType.unknown:
      break;
  }

  final status = e.response?.statusCode;
  if (status == 401 || status == 403) {
    return AuthException(
      'Sarvam rejected your API key. Check it in Settings.',
      cause: e,
    );
  }
  if (status == 429) {
    return NetworkException('Sarvam is rate limiting. Try again shortly.',
        cause: e);
  }
  if (status != null && status >= 500) {
    return NetworkException('Sarvam had a server error ($status). Try again.',
        cause: e);
  }
  return ApiException(
    '$what failed${status == null ? '' : ' ($status)'}. ${_detail(e)}'.trim(),
    statusCode: status,
    cause: e,
  );
}

/// Pulls a human-readable reason out of a Sarvam error body without dumping
/// the whole payload into the UI.
String _detail(DioException e) {
  final data = e.response?.data;
  if (data is Map) {
    final error = data['error'];
    if (error is Map && error['message'] is String) return error['message'] as String;
    if (data['message'] is String) return data['message'] as String;
    if (data['detail'] is String) return data['detail'] as String;
  }
  return '';
}
