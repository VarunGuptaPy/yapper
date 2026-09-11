import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors.dart';
import '../core/log.dart';
import '../services/chat/note_proposal.dart';
import 'providers.dart';

class ChatUiState {
  const ChatUiState({this.sending = false, this.error});

  final bool sending;
  final String? error;
}

class ChatController extends Notifier<ChatUiState> {
  @override
  ChatUiState build() => const ChatUiState();

  Future<void> send(String text) async {
    final question = text.trim();
    if (question.isEmpty || state.sending) return;

    final chats = ref.read(chatRepositoryProvider);
    state = const ChatUiState(sending: true);

    // The history is read before the new turn is stored so the question is not
    // duplicated as both history and prompt.
    final history = await chats.recentHistory();
    await chats.addUserMessage(question);

    try {
      final answer =
          await ref.read(chatAgentProvider).ask(question, history: history);
      await chats.addAssistantMessage(
        content: answer.content,
        citations: answer.citedNoteIds,
        proposal: answer.proposal,
      );
      state = const ChatUiState();
    } on AppException catch (e) {
      logE('Chat', 'ask failed: ${e.message}');
      state = ChatUiState(error: e.message);
    } catch (e) {
      logE('Chat', 'ask failed unexpectedly', e);
      state = const ChatUiState(error: 'Something went wrong. Try again.');
    }
  }

  /// Applies a proposal only once the user taps Confirm (SPEC.md §9).
  Future<void> confirmProposal(String messageId, NoteProposal proposal) async {
    try {
      await ref.read(noteWriterProvider).applyChatProposal(proposal);
      await ref
          .read(chatRepositoryProvider)
          .setProposalStatus(messageId, ProposalStatus.confirmed);
    } on AppException catch (e) {
      state = ChatUiState(error: e.message);
    } catch (e) {
      logE('Chat', 'could not apply proposal', e);
      state = const ChatUiState(error: 'Could not apply that change.');
    }
  }

  Future<void> dismissProposal(String messageId) => ref
      .read(chatRepositoryProvider)
      .setProposalStatus(messageId, ProposalStatus.dismissed);

  Future<void> clearHistory() => ref.read(chatRepositoryProvider).clear();

  void dismissError() => state = ChatUiState(sending: state.sending);
}

final chatControllerProvider =
    NotifierProvider<ChatController, ChatUiState>(ChatController.new);
