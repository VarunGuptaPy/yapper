import 'package:drift/drift.dart';

import '../../core/ids.dart';
import '../../services/chat/note_proposal.dart';
import '../db/database.dart';

class ChatRepository {
  ChatRepository(this._db);

  final AppDatabase _db;

  Stream<List<ChatMessageRow>> watchMessages() =>
      (_db.select(_db.chatMessages)
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .watch();

  /// The recent turns replayed to the model. Capped because the full history
  /// of a personal notebook would eventually blow past the context window,
  /// and older turns rarely matter once the notes themselves are searchable.
  Future<List<ChatMessageRow>> recentHistory({int limit = 20}) async {
    final rows = await (_db.select(_db.chatMessages)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .get();
    return rows.reversed.toList();
  }

  Future<ChatMessageRow> addUserMessage(String content) =>
      _insert(role: 'user', content: content);

  Future<ChatMessageRow> addAssistantMessage({
    required String content,
    List<String> citations = const [],
    NoteProposal? proposal,
  }) =>
      _insert(
        role: 'assistant',
        content: content,
        citations: citations,
        proposal: proposal,
      );

  Future<ChatMessageRow> _insert({
    required String role,
    required String content,
    List<String> citations = const [],
    NoteProposal? proposal,
  }) async {
    final row = ChatMessageRow(
      id: newId(),
      role: role,
      content: content,
      citations: citations,
      proposal: proposal?.encode(),
      proposalStatus: proposal == null ? null : ProposalStatus.pending.name,
      createdAt: DateTime.now(),
    );
    await _db.into(_db.chatMessages).insert(row);
    return row;
  }

  Future<void> setProposalStatus(String messageId, ProposalStatus status) async {
    await (_db.update(_db.chatMessages)..where((t) => t.id.equals(messageId)))
        .write(ChatMessagesCompanion(proposalStatus: Value(status.name)));
  }

  Future<void> clear() => _db.delete(_db.chatMessages).go();
}
