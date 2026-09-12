import 'package:drift/drift.dart';

import '../../core/ids.dart';
import '../../services/chat/note_proposal.dart';
import '../db/database.dart';

/// A conversation with enough detail to render a row in the chat list.
class ConversationSummary {
  const ConversationSummary({
    required this.conversation,
    required this.messageCount,
    this.lastMessage,
  });

  final ChatConversationRow conversation;
  final int messageCount;
  final String? lastMessage;

  String get displayTitle {
    final title = conversation.title?.trim();
    if (title != null && title.isNotEmpty) return title;
    return 'New chat';
  }
}

class ChatRepository {
  ChatRepository(this._db);

  final AppDatabase _db;

  /// How much of the opening question becomes the thread's name.
  static const _titleLength = 48;

  // ------------------------------------------------------------ conversations

  /// Threads with recent activity first.
  Stream<List<ConversationSummary>> watchConversations() {
    final count = _db.chatMessages.id.count();
    final query = _db.select(_db.chatConversations).join([
      leftOuterJoin(
        _db.chatMessages,
        _db.chatMessages.conversationId.equalsExp(_db.chatConversations.id),
      ),
    ])
      ..addColumns([count])
      ..groupBy([_db.chatConversations.id])
      ..orderBy([OrderingTerm.desc(_db.chatConversations.updatedAt)]);

    return query.watch().asyncMap((rows) async {
      return Future.wait([
        for (final row in rows)
          _summarise(row.readTable(_db.chatConversations), row.read(count) ?? 0),
      ]);
    });
  }

  Future<ConversationSummary> _summarise(
    ChatConversationRow conversation,
    int messageCount,
  ) async {
    final last = await (_db.select(_db.chatMessages)
          ..where((t) => t.conversationId.equals(conversation.id))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(1))
        .getSingleOrNull();

    return ConversationSummary(
      conversation: conversation,
      messageCount: messageCount,
      lastMessage: last?.content,
    );
  }

  /// Opens a thread. Called on the first message rather than when the user
  /// taps "New chat", so an abandoned empty chat never clutters the list.
  Future<String> createConversation() async {
    final now = DateTime.now();
    final id = newId();
    await _db.into(_db.chatConversations).insert(
          ChatConversationRow(id: id, createdAt: now, updatedAt: now),
        );
    return id;
  }

  Future<void> deleteConversation(String id) =>
      (_db.delete(_db.chatConversations)..where((t) => t.id.equals(id))).go();

  Future<void> deleteAllConversations() => _db.delete(_db.chatConversations).go();

  /// The newest thread, or null if there has never been one.
  Future<String?> latestConversationId() async {
    final row = await (_db.select(_db.chatConversations)
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
          ..limit(1))
        .getSingleOrNull();
    return row?.id;
  }

  // ---------------------------------------------------------------- messages

  Stream<List<ChatMessageRow>> watchMessages(String conversationId) =>
      (_db.select(_db.chatMessages)
            ..where((t) => t.conversationId.equals(conversationId))
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .watch();

  /// The recent turns of one thread, replayed to the model.
  ///
  /// Capped because a long thread would eventually outgrow the context window,
  /// and older turns rarely matter once the notes themselves are searchable.
  Future<List<ChatMessageRow>> recentHistory(
    String conversationId, {
    int limit = 20,
  }) async {
    final rows = await (_db.select(_db.chatMessages)
          ..where((t) => t.conversationId.equals(conversationId))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .get();
    return rows.reversed.toList();
  }

  Future<ChatMessageRow> addUserMessage(
    String conversationId,
    String content,
  ) async {
    final row = await _insert(
      conversationId: conversationId,
      role: 'user',
      content: content,
    );
    await _nameFromFirstQuestion(conversationId, content);
    return row;
  }

  Future<ChatMessageRow> addAssistantMessage({
    required String conversationId,
    required String content,
    List<String> citations = const [],
    NoteProposal? proposal,
  }) =>
      _insert(
        conversationId: conversationId,
        role: 'assistant',
        content: content,
        citations: citations,
        proposal: proposal,
      );

  Future<ChatMessageRow> _insert({
    required String conversationId,
    required String role,
    required String content,
    List<String> citations = const [],
    NoteProposal? proposal,
  }) async {
    final now = DateTime.now();
    final row = ChatMessageRow(
      id: newId(),
      conversationId: conversationId,
      role: role,
      content: content,
      citations: citations,
      proposal: proposal?.encode(),
      proposalStatus: proposal == null ? null : ProposalStatus.pending.name,
      createdAt: now,
    );

    await _db.transaction(() async {
      await _db.into(_db.chatMessages).insert(row);
      await (_db.update(_db.chatConversations)
            ..where((t) => t.id.equals(conversationId)))
          .write(ChatConversationsCompanion(updatedAt: Value(now)));
    });
    return row;
  }

  /// Names a thread after its opening question, so the list is scannable
  /// without paying for an LLM call just to write a title.
  Future<void> _nameFromFirstQuestion(
    String conversationId,
    String content,
  ) async {
    final conversation = await (_db.select(_db.chatConversations)
          ..where((t) => t.id.equals(conversationId)))
        .getSingleOrNull();
    if (conversation == null) return;
    final existing = conversation.title?.trim();
    if (existing != null && existing.isNotEmpty) return;

    final flat = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return;
    final title = flat.length > _titleLength
        ? '${flat.substring(0, _titleLength).trimRight()}…'
        : flat;

    await (_db.update(_db.chatConversations)
          ..where((t) => t.id.equals(conversationId)))
        .write(ChatConversationsCompanion(title: Value(title)));
  }

  Future<void> setProposalStatus(String messageId, ProposalStatus status) async {
    await (_db.update(_db.chatMessages)..where((t) => t.id.equals(messageId)))
        .write(ChatMessagesCompanion(proposalStatus: Value(status.name)));
  }
}
