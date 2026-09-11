import '../../core/errors.dart';
import '../../core/log.dart';
import '../../data/db/database.dart';
import '../../data/models/structured_note.dart';
import '../llm/llm_models.dart';
import '../llm/llm_service.dart';
import 'structuring_prompt.dart';

/// Turns a raw transcript into validated [StructuredNote]s.
///
/// Invalid model output gets exactly one corrective retry, carrying the precise
/// validation error; a second failure is permanent and fails the capture
/// (SPEC.md §7.1).
class StructuringService {
  StructuringService(this._llm);

  final LlmService _llm;

  /// Pure, deterministic validation — no reason to make it swappable.
  static const _parser = StructuredNoteParser();

  Future<List<StructuredNote>> structure({
    required String transcript,
    List<NoteRow> candidates = const [],
  }) async {
    if (transcript.trim().isEmpty) {
      throw const ValidationException(
        'The transcript was empty — nothing was said, or nothing was heard.',
      );
    }

    final messages = <ChatMessage>[
      const ChatMessage.system(structuringSystemPrompt),
      ChatMessage.user(buildStructuringUserPrompt(
        transcript: transcript,
        candidates: candidates,
      )),
    ];

    final first = await _llm.complete(messages, jsonMode: true);
    try {
      return _parser.parse(first.content ?? '');
    } on ValidationException catch (e) {
      logD('Structuring', 'first attempt invalid: ${e.message}');

      final retryMessages = [
        ...messages,
        ChatMessage.assistant(first.content ?? ''),
        ChatMessage.user(buildRetryPrompt(e.message)),
      ];

      final second = await _llm.complete(retryMessages, jsonMode: true);
      try {
        return _parser.parse(second.content ?? '');
      } on ValidationException catch (e2) {
        logD('Structuring', 'retry also invalid: ${e2.message}');
        throw ValidationException(
          'The model returned invalid notes twice. ${e2.message}',
          cause: e2,
        );
      }
    }
  }
}
