import 'dart:io';

import '../core/errors.dart';
import '../data/models/transcript.dart';
import 'llm/llm_models.dart';
import 'llm/llm_service.dart';
import 'transcription/transcription_service.dart';

/// Stand-ins used when Settings is incomplete.
///
/// Recording must never be blocked — the thought matters more than the config —
/// so an unconfigured app still captures audio, and the pipeline fails the
/// capture with a message that says exactly what to add. Tapping Retry after
/// filling in Settings picks it straight back up.
class UnconfiguredTranscriptionService implements TranscriptionService {
  const UnconfiguredTranscriptionService(this.message);

  final String message;

  @override
  Future<Transcript> transcribe(
    File audio, {
    List<String> keyterms = const [],
    Duration? duration,
  }) async =>
      throw AuthException(message);
}

class UnconfiguredLlmService implements LlmService {
  const UnconfiguredLlmService(this.message);

  final String message;

  @override
  Future<LlmResponse> complete(
    List<ChatMessage> messages, {
    bool jsonMode = false,
    List<ToolDefinition> tools = const [],
    double temperature = 0.2,
  }) async =>
      throw AuthException(message);
}
