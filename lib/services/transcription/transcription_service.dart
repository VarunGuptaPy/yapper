import 'dart:io';

import '../../data/models/transcript.dart';

/// Turns a recording into text. Swappable per SPEC.md §5.
abstract class TranscriptionService {
  /// [keyterms] biases recognition toward names the user already has notes
  /// about, so "Aakash" doesn't come back spelled three different ways.
  ///
  /// [duration] is optional but strongly preferred: Sarvam's synchronous REST
  /// endpoint rejects anything over 30 s, so knowing the length up front is
  /// what lets the implementation pick REST over the much slower Batch job.
  /// Implementations must still behave correctly when it is null.
  Future<Transcript> transcribe(
    File audio, {
    List<String> keyterms,
    Duration? duration,
  });
}
