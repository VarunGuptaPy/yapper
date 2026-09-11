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
    ChatMessages,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 2;

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
          // v2 added chat history. Everything else is untouched, so this is
          // purely additive — no data is rewritten or lost.
          if (from < 2) {
            await m.createTable(chatMessages);
          }
          await _createFtsObjects();
        },
        beforeOpen: (details) async {
          // Foreign keys are off by default in SQLite and must be re-enabled on
          // every connection, not just at creation.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  Future<void> _createFtsObjects() async {
    await customStatement(_createFts);
    await customStatement(_createFtsInsertTrigger);
    await customStatement(_createFtsDeleteTrigger);
    await customStatement(_createFtsUpdateTrigger);
  }
}
