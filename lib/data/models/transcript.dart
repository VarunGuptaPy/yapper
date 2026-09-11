/// The result of a [TranscriptionService] call.
class Transcript {
  const Transcript({
    required this.text,
    this.languageCode,
    this.requestId,
  });

  final String text;

  /// BCP-47 of the predominant language Sarvam detected, e.g. `hi-IN`.
  /// Null when Sarvam could not determine one.
  final String? languageCode;

  final String? requestId;
}
