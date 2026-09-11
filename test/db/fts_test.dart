import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/data/db/database.dart';
import 'package:yapapp/data/models/enums.dart';
import 'package:yapapp/data/repositories/note_repository.dart';

import 'test_db.dart';

void main() {
  late AppDatabase db;
  late NoteRepository notes;

  setUp(() {
    db = openTestDatabase();
    notes = NoteRepository(db);
  });

  tearDown(() => db.close());

  Future<int> ftsRowCount() async {
    final rows =
        await db.customSelect('SELECT COUNT(*) AS c FROM notes_fts').get();
    return rows.single.read<int>('c');
  }

  test('insert trigger indexes a new note', () async {
    await notes.createNote(
      type: NoteType.person,
      title: 'Ritu Sharma',
      body: 'Video editor, met at a Goa wedding shoot.',
      tags: ['video', 'editing'],
    );

    expect(await ftsRowCount(), 1);
    final hits = await notes.searchFts('video editor');
    expect(hits, hasLength(1));
  });

  test('search matches on body text', () async {
    final note = await notes.createNote(
      type: NoteType.idea,
      title: 'Unrelated title',
      body: 'A documentary about Konkani fishermen.',
      tags: const [],
    );
    final hits = await notes.searchFts('fishermen');
    expect(hits.single.noteId, note.id);
  });

  test('search matches on tags', () async {
    final note = await notes.createNote(
      type: NoteType.idea,
      title: 'Something',
      body: 'Body without the word.',
      tags: ['screenwriting'],
    );
    final hits = await notes.searchFts('screenwriting');
    expect(hits.single.noteId, note.id);
  });

  test('update trigger re-indexes, dropping the old terms', () async {
    final note = await notes.createNote(
      type: NoteType.idea,
      title: 'Kabaddi documentary',
      body: 'Follow one village team for a season.',
      tags: const [],
    );

    expect(await notes.searchFts('kabaddi'), hasLength(1));

    await notes.updateNote(
      id: note.id,
      changeSource: ChangeSource.manualEdit,
      title: 'Chess documentary',
      body: 'Follow one village team for a season.',
    );

    expect(await notes.searchFts('kabaddi'), isEmpty,
        reason: 'stale terms must not survive an edit');
    expect(await notes.searchFts('chess'), hasLength(1));
    expect(await ftsRowCount(), 1, reason: 'update must not duplicate the row');
  });

  test('delete trigger removes the note from the index', () async {
    final note = await notes.createNote(
      type: NoteType.note,
      title: 'Ephemeral',
      body: 'Gone soon.',
      tags: const [],
    );
    expect(await ftsRowCount(), 1);

    await notes.deleteNote(note.id);

    expect(await ftsRowCount(), 0);
    expect(await notes.searchFts('ephemeral'), isEmpty);
  });

  test('prefix matching finds partial words as you type', () async {
    await notes.createNote(
      type: NoteType.idea,
      title: 'Cinematography notes',
      body: 'Anamorphic lenses on a budget.',
      tags: const [],
    );
    expect(await notes.searchFts('cinema'), hasLength(1));
    expect(await notes.searchFts('anamor'), hasLength(1));
  });

  test('bm25 ranks the closer match first', () async {
    await notes.createNote(
      type: NoteType.idea,
      title: 'Editing',
      body: 'editing editing editing video',
      tags: const [],
    );
    final weak = await notes.createNote(
      type: NoteType.idea,
      title: 'Something else entirely about many other unrelated subjects',
      body: 'Mentions editing once in passing among many other words here.',
      tags: const [],
    );

    final hits = await notes.searchFts('editing');
    expect(hits, hasLength(2));
    expect(hits.last.noteId, weak.id);
    expect(hits.first.score, lessThan(hits.last.score),
        reason: 'bm25 is lower-is-better');
  });

  test('punctuation in a query cannot break the MATCH expression', () async {
    await notes.createNote(
      type: NoteType.person,
      title: "O'Brien",
      body: 'Sound designer.',
      tags: const [],
    );

    // Each of these would be an FTS5 syntax error if passed through raw.
    for (final query in ['O\'Brien', 'sound "designer', 'a AND', '*', '(((']) {
      expect(() => notes.searchFts(query), returnsNormally);
      await notes.searchFts(query);
    }
    expect(await notes.searchFts("O'Brien"), hasLength(1));
  });

  test('an empty or symbol-only query returns nothing', () async {
    await notes.createNote(
        type: NoteType.note, title: 'x', body: 'y', tags: const []);
    expect(await notes.searchFts(''), isEmpty);
    expect(await notes.searchFts('   '), isEmpty);
    expect(await notes.searchFts('!!!'), isEmpty);
  });
}
