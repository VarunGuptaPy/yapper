import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:yapapp/data/db/database.dart';
import 'package:yapapp/data/models/enums.dart';
import 'package:yapapp/data/repositories/chat_repository.dart';
import 'package:yapapp/data/repositories/note_repository.dart';

/// v3 split one flat chat log into separate conversations. Anyone upgrading
/// has real history in that log, so the migration has to carry it across
/// rather than start clean.
void main() {
  late Directory dir;
  late File dbFile;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('yap_migration');
    dbFile = File('${dir.path}/yap.sqlite');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  /// Builds a database shaped like schema v2: the current schema with the
  /// conversation column and table removed, and `user_version` wound back.
  Future<void> buildV2Database({required List<String> messages}) async {
    final db = AppDatabase(NativeDatabase(dbFile));
    // Something unrelated, to prove the migration leaves the rest alone.
    await NoteRepository(db).createNote(
      type: NoteType.idea,
      title: 'A note from before the upgrade',
      body: 'Still here afterwards.',
      tags: const ['keep'],
    );
    await db.close();

    final raw = sqlite3.open(dbFile.path);
    raw
      ..execute('PRAGMA foreign_keys = OFF')
      ..execute('''
        CREATE TABLE chat_messages_old (
          id TEXT NOT NULL PRIMARY KEY,
          role TEXT NOT NULL,
          content TEXT NOT NULL,
          citations TEXT NOT NULL,
          proposal TEXT,
          proposal_status TEXT,
          created_at TEXT NOT NULL
        )
      ''')
      ..execute('DROP TABLE chat_messages')
      ..execute('ALTER TABLE chat_messages_old RENAME TO chat_messages')
      ..execute('DROP TABLE chat_conversations');

    for (var i = 0; i < messages.length; i++) {
      raw.execute(
        'INSERT INTO chat_messages '
        '(id, role, content, citations, created_at) VALUES (?, ?, ?, ?, ?)',
        [
          'm$i',
          i.isEven ? 'user' : 'assistant',
          messages[i],
          '[]',
          DateTime(2026, 9, 1).add(Duration(minutes: i)).toIso8601String(),
        ],
      );
    }

    raw.userVersion = 2;
    raw.close();
  }

  test('carries existing chat history into one conversation', () async {
    await buildV2Database(messages: [
      'which of my connections edits video?',
      'Ritu Sharma does [1].',
      'and who can help with a job?',
    ]);

    final db = AppDatabase(NativeDatabase(dbFile));
    final chats = ChatRepository(db);

    final conversations = await chats.watchConversations().first;
    expect(conversations, hasLength(1),
        reason: 'old messages become exactly one thread');
    expect(conversations.single.messageCount, 3);
    expect(conversations.single.displayTitle, 'Earlier conversation');

    final messages =
        await chats.watchMessages(conversations.single.conversation.id).first;
    expect(messages.map((m) => m.content), [
      'which of my connections edits video?',
      'Ritu Sharma does [1].',
      'and who can help with a job?',
    ]);
    expect(messages.first.role, 'user');

    await db.close();
  });

  test('does not invent a conversation when there was no history', () async {
    await buildV2Database(messages: const []);

    final db = AppDatabase(NativeDatabase(dbFile));
    expect(await ChatRepository(db).watchConversations().first, isEmpty,
        reason: 'a user who never chatted should not open onto an empty thread');
    await db.close();
  });

  test('leaves notes untouched', () async {
    await buildV2Database(messages: ['a question']);

    final db = AppDatabase(NativeDatabase(dbFile));
    final notes = await NoteRepository(db).allNotes();

    expect(notes.single.title, 'A note from before the upgrade');
    expect(notes.single.tags, ['keep']);
    await db.close();
  });

  test('full-text search still works after the upgrade', () async {
    await buildV2Database(messages: ['a question']);

    final db = AppDatabase(NativeDatabase(dbFile));
    final hits = await NoteRepository(db).searchFts('upgrade');
    expect(hits, hasLength(1));
    await db.close();
  });

  test('the upgraded database accepts new conversations', () async {
    await buildV2Database(messages: ['an old question']);

    final db = AppDatabase(NativeDatabase(dbFile));
    final chats = ChatRepository(db);

    final fresh = await chats.createConversation();
    await chats.addUserMessage(fresh, 'a brand new question');

    final conversations = await chats.watchConversations().first;
    expect(conversations, hasLength(2));
    expect(conversations.first.displayTitle, 'a brand new question');
    expect(
      await chats.recentHistory(fresh),
      hasLength(1),
      reason: 'the new thread must not inherit the adopted one',
    );

    await db.close();
  });

  test('foreign keys are enforced again once the migration is done', () async {
    await buildV2Database(messages: ['a question']);

    final db = AppDatabase(NativeDatabase(dbFile));
    final enabled =
        await db.customSelect('PRAGMA foreign_keys').getSingle();
    expect(enabled.data.values.first, 1);
    await db.close();
  });
}
