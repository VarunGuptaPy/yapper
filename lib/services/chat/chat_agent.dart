import '../../core/errors.dart';
import '../../core/log.dart';
import '../../data/db/database.dart';
import '../llm/llm_models.dart';
import '../llm/llm_service.dart';
import 'chat_prompt.dart';
import 'chat_tools.dart';
import 'note_proposal.dart';

/// One finished answer.
class ChatAnswer {
  const ChatAnswer({
    required this.content,
    this.citedNoteIds = const [],
    this.proposal,
  });

  final String content;
  final List<String> citedNoteIds;
  final NoteProposal? proposal;
}

/// The tool-calling loop from SPEC.md §9.
class ChatAgent {
  ChatAgent({required this.llm, required this.runner});

  /// The spec's ceiling. Without it a confused model can ping-pong between
  /// searches until the context window runs out.
  static const maxToolRounds = 5;

  final LlmService llm;
  final ChatToolRunner runner;

  Future<ChatAnswer> ask(
    String question, {
    List<ChatMessageRow> history = const [],
  }) async {
    final messages = <ChatMessage>[
      const ChatMessage.system(chatSystemPrompt),
      for (final turn in history)
        if (turn.role == 'user')
          ChatMessage.user(turn.content)
        else
          ChatMessage.assistant(turn.content),
      ChatMessage.user(question),
    ];

    NoteProposal? proposal;

    for (var round = 0; round < maxToolRounds; round++) {
      final response = await llm.complete(
        messages,
        tools: ChatToolRunner.definitions(),
      );

      if (!response.hasToolCalls) {
        return _finish(response.content, proposal);
      }

      messages.add(ChatMessage(
        role: ChatRole.assistant,
        content: response.content,
        toolCalls: response.toolCalls,
      ));

      for (final call in response.toolCalls) {
        logD('Chat', 'tool ${call.name}');
        final outcome = await runner.run(call);
        // The last proposal wins: a model that re-proposes has changed its
        // mind, and only one card is shown per answer.
        if (outcome.proposal != null) proposal = outcome.proposal;

        messages.add(ChatMessage(
          role: ChatRole.tool,
          content: outcome.resultJson,
          toolCallId: call.id,
        ));
      }
    }

    // Out of rounds. Ask once more with no tools so the model must answer from
    // what it has already gathered rather than leaving the turn empty.
    logD('Chat', 'tool rounds exhausted, forcing an answer');
    final forced = await llm.complete(
      [
        ...messages,
        const ChatMessage.user(
          'Answer now using only what the tools already returned. Do not call '
          'any more tools, and do not add anything the notes did not say. If '
          'what they returned does not answer the question, say so and stop.',
        ),
      ],
    );
    return _finish(forced.content, proposal);
  }

  ChatAnswer _finish(String? content, NoteProposal? proposal) {
    final text = content?.trim() ?? '';
    if (text.isEmpty && proposal == null) {
      throw const ApiException('The model returned an empty answer.');
    }

    final cited = runner.normalizeCitations(text);
    return ChatAnswer(
      content: cited.text.isEmpty ? 'Here is the change I suggest.' : cited.text,
      citedNoteIds: cited.noteIds,
      proposal: proposal,
    );
  }
}
