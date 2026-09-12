import 'package:drift/drift.dart';

import '../models/enums.dart';
import 'converters.dart';
import 'tables.dart';

part 'database.g.dart';

/// The FTS5 index over notes, plus the triggers that keep it in sync.
///
/// `note_id` is UNINDEXED so it is stored and returned but not searchable —
/// we only ever match on the text columns and join back on the id.
const _createFts = '''
CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
  note_id UNINDEXED,
  title,
  body,
  tags
);
''';

const _createFtsInsertTrigger = '''
CREATE TRIGGER IF NOT EXISTS notes_fts_after_insert
AFTER INSERT ON notes BEGIN
  INSERT INTO notes_fts(note_id, title, body, tags)
  VALUES (new.id, new.title, new.body, new.tags);
END;
''';

const _createFtsDeleteTrigger = '''
CREATE TRIGGER IF NOT EXISTS notes_fts_after_delete
AFTER DELETE ON notes BEGIN
  DELETE FROM notes_fts WHERE note_id = old.id;
END;
''';

const _createFtsUpdateTrigger = '''
CREATE TRIGGER IF NOT EXISTS notes_fts_after_update
AFTER UPDATE ON notes BEGIN
  UPDATE notes_fts
     SET title = new.title, body = new.body, tags = new.tags
   WHERE note_id = old.id;
END;
''';

@DriftDatabase(
  tables: [
    Captures,
    Notes,
    NoteVersions,
    NoteCaptures,
    NotePeople,
    Embeddings,
    ChatConversations,
    ChatMessages,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 3;

  /// Store timestamps as ISO-8601 text rather than unix seconds.
  ///
  /// Second resolution is not enough: two edits to the same note inside one
  /// second would tie, and version history would list them in arbitrary order.
  @override
  DriftDatabaseOptions get options =>
      const DriftDatabaseOptions(storeDateTimeAsText: true);

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createFtsObjects();
        },
        onUpgrade: (m, from, to) async {
          // Recreating a table with a new column requires foreign keys to be
          // off; `beforeOpen` switches them back on for normal use.
          await customStatement('PRAGMA foreign_keys = OFF');

          // v2 added chat history. Purely additive.
          if (from < 2) {
            await m.createTable(chatMessages);
          }

          // v3 split chat history into separate conversations. Existing
          // messages are gathered into one thread rather than dropped.
          if (from < 3) {
            await m.createTable(chatConversations);
            final legacyId = await _adoptLegacyChat(m);
            await m.alterTable(
              TableMigration(
                chatMessages,
                newColumns: [chatMessages.conversationId],
                columnTransformer: {
                  chatMessages.conversationId: Constant<String>(legacyId),
                },
              ),
            );
          }

          await _createFtsObjects();
        },
        beforeOpen: (details) async {
          // Foreign keys are off by default in SQLite and must be re-enabled on
          // every connection, not just at creation.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  /// Creates the thread that pre-v3 messages belong to, and returns its id.
  ///
  /// Only written when there is history to adopt — otherwise a brand-new
  /// install would open onto an empty conversation it never started.
  Future<String> _adoptLegacyChat(Migrator m) async {
    const legacyId = 'legacy-conversation';

    final existing =
        await customSelect('SELECT COUNT(*) AS c FROM chat_messages').getSingle();
    if (existing.read<int>('c') == 0) return legacyId;

    final now = DateTime.now();
    await into(chatConversations).insert(
      ChatConversationRow(
        id: legacyId,
        title: 'Earlier conversation',
        createdAt: now,
        updatedAt: now,
      ),
      mode: InsertMode.insertOrIgnore,
    );
    return legacyId;
  }

  Future<void> _createFtsObjects() async {
    await customStatement(_createFts);
    await customStatement(_createFtsInsertTrigger);
    await customStatement(_createFtsDeleteTrigger);
    await customStatement(_createFtsUpdateTrigger);
  }
}
