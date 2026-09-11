/// Base for every error Yap surfaces to the user.
///
/// [message] is safe to display. It must never contain note bodies or
/// transcripts — see [redact] in `log.dart` for why.
sealed class AppException implements Exception {
  const AppException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => '$runtimeType: $message';
}

/// No connectivity, DNS failure, timeout — anything worth retrying later.
class NetworkException extends AppException {
  const NetworkException(super.message, {super.cause});
}

/// The device believes it is offline. The pipeline queues instead of failing.
class OfflineException extends NetworkException {
  const OfflineException() : super('No internet connection.');
}

/// Missing or rejected API key (HTTP 401/403), or a key not yet set in Settings.
class AuthException extends AppException {
  const AuthException(super.message, {super.cause});
}

/// The remote API answered, but with an error we cannot fix by retrying.
class ApiException extends AppException {
  const ApiException(super.message, {this.statusCode, super.cause});

  final int? statusCode;
}

/// A response did not match the schema we require.
class ValidationException extends AppException {
  const ValidationException(super.message, {super.cause});
}

/// Microphone permission denied, or the recorder failed to start.
class RecordingException extends AppException {
  const RecordingException(super.message, {super.cause});
}
