import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/data/db/database.dart';
import 'package:yapapp/data/models/enums.dart';
import 'package:yapapp/data/repositories/chat_repository.dart';
import 'package:yapapp/services/chat/note_proposal.dart';

import 'test_db.dart';

void main() {
  late AppDatabase db;
  late ChatRepository chats;

  setUp(() {
    db = openTestDatabase();
    chats = ChatRepository(db);
  });

  tearDown(() => db.close());

  group('conversations', () {
    test('a new conversation starts untitled and empty', () async {
      final id = await chats.createConversation();

      final rows = await chats.watchConversations().first;
      expect(rows.single.conversation.id, id);
      expect(rows.single.conversation.title, isNull);
      expect(rows.single.displayTitle, 'New chat');
      expect(rows.single.messageCount, 0);
    });

    test('takes its name from the first question', () async {
      final id = await chats.createConversation();
      await chats.addUserMessage(id, 'which of my connections edits video?');

      final rows = await chats.watchConversations().first;
      expect(rows.single.displayTitle, 'which of my connections edits video?');
    });

    test('a long opening question is truncated', () async {
      final id = await chats.createConversation();
      await chats.addUserMessage(id, 'a' * 200);

      final title = (await chats.watchConversations().first).single.displayTitle;
      expect(title.length, lessThan(60));
      expect(title, endsWith('…'));
    });

    test('collapses newlines in the title', () async {
      final id = await chats.createConversation();
      await chats.addUserMessage(id, 'first line\n\nsecond line');

      expect(
        (await chats.watchConversations().first).single.displayTitle,
        'first line second line',
      );
    });

    test('the title is not rewritten by later messages', () async {
      final id = await chats.createConversation();
      await chats.addUserMessage(id, 'the original question');
      await chats.addAssistantMessage(conversationId: id, content: 'an answer');
      await chats.addUserMessage(id, 'a follow up');

      expect(
        (await chats.watchConversations().first).single.displayTitle,
        'the original question',
      );
    });

    test('lists the most recently used first', () async {
      final first = await chats.createConversation();
      await chats.addUserMessage(first, 'older');
      await Future<void>.delayed(const Duration(milliseconds: 3));
      final second = await chats.createConversation();
      await chats.addUserMessage(second, 'newer');

      var rows = await chats.watchConversations().first;
      expect(rows.first.conversation.id, second);

      // Replying in the older thread brings it back to the top.
      await Future<void>.delayed(const Duration(milliseconds: 3));
      await chats.addUserMessage(first, 'revived');
      rows = await chats.watchConversations().first;
      expect(rows.first.conversation.id, first);
    });

    test('reports message count and the last message', () async {
      final id = await chats.createConversation();
      await chats.addUserMessage(id, 'question');
      await chats.addAssistantMessage(
        conversationId: id,
        content: 'the answer',
      );

      final summary = (await chats.watchConversations().first).single;
      expect(summary.messageCount, 2);
      expect(summary.lastMessage, 'the answer');
    });

    test('latestConversationId tracks activity', () async {
      expect(await chats.latestConversationId(), isNull);

      final first = await chats.createConversation();
      await chats.addUserMessage(first, 'one');
      await Future<void>.delayed(const Duration(milliseconds: 3));
      final second = await chats.createConversation();
      await chats.addUserMessage(second, 'two');

      expect(await chats.latestConversationId(), second);
    });
  });

  group('isolation', () {
    test('messages belong to their own thread', () async {
      final a = await chats.createConversation();
      final b = await chats.createConversation();

      await chats.addUserMessage(a, 'in thread A');
      await chats.addUserMessage(b, 'in thread B');

      final inA = await chats.watchMessages(a).first;
      final inB = await chats.watchMessages(b).first;

      expect(inA.single.content, 'in thread A');
      expect(inB.single.content, 'in thread B');
    });

    test('history replayed to the model is scoped to the thread', () async {
      final a = await chats.createConversation();
      final b = await chats.createConversation();
      await chats.addUserMessage(a, 'about movies');
      await chats.addUserMessage(b, 'about people');

      final history = await chats.recentHistory(b);
      expect(history.single.content, 'about people',
          reason: 'a fresh chat must not inherit the previous one');
    });

    test('history is capped and oldest-first', () async {
      final id = await chats.createConversation();
      for (var i = 0; i < 30; i++) {
        await chats.addUserMessage(id, 'message $i');
      }

      final history = await chats.recentHistory(id, limit: 5);
      expect(history, hasLength(5));
      expect(history.first.content, 'message 25');
      expect(history.last.content, 'message 29');
    });
  });

  group('deleting', () {
    test('removes the thread and its messages', () async {
      final id = await chats.createConversation();
      await chats.addUserMessage(id, 'question');
      await chats.addAssistantMessage(conversationId: id, content: 'answer');

      await chats.deleteConversation(id);

      expect(await chats.watchConversations().first, isEmpty);
      expect(await chats.watchMessages(id).first, isEmpty);
    });

    test('leaves other threads alone', () async {
      final keep = await chats.createConversation();
      final drop = await chats.createConversation();
      await chats.addUserMessage(keep, 'keep me');
      await chats.addUserMessage(drop, 'drop me');

      await chats.deleteConversation(drop);

      final rows = await chats.watchConversations().first;
      expect(rows.single.conversation.id, keep);
      expect((await chats.watchMessages(keep).first).single.content, 'keep me');
    });
  });

  test('a proposal survives on its message', () async {
    final id = await chats.createConversation();
    final message = await chats.addAssistantMessage(
      conversationId: id,
      content: 'here is a suggestion',
      citations: const ['n1'],
      proposal: const NoteProposal(
        kind: ProposalKind.create,
        type: NoteType.rule,
        title: 'Never eat prawns',
        body: 'b',
      ),
    );

    final stored = (await chats.watchMessages(id).first).single;
    expect(stored.citations, ['n1']);
    expect(stored.proposalStatus, 'pending');

    await chats.setProposalStatus(message.id, ProposalStatus.confirmed);
    expect(
      (await chats.watchMessages(id).first).single.proposalStatus,
      'confirmed',
    );
  });
}
