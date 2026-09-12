import 'package:drift/drift.dart';

import '../../core/ids.dart';
import '../db/database.dart';
import '../models/enums.dart';
import '../models/person_name.dart';

/// A note plus its FTS relevance score, returned by [NoteRepository.searchFts].
class ScoredNoteId {
  const ScoredNoteId(this.noteId, this.score);

  final String noteId;

  /// SQLite's bm25() score: lower is a better match.
  final double score;
}

class NoteRepository {
  NoteRepository(this._db);

  final AppDatabase _db;

  Stream<List<NoteRow>> watchNotes({NoteType? type}) {
    final query = _db.select(_db.notes)
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]);
    if (type != null) {
      query.where((t) => t.type.equalsValue(type));
    }
    return query.watch();
  }

  Future<List<NoteRow>> allNotes() => _db.select(_db.notes).get();

  Future<NoteRow?> getNote(String id) =>
      (_db.select(_db.notes)..where((t) => t.id.equals(id))).getSingleOrNull();

  Stream<NoteRow?> watchNote(String id) =>
      (_db.select(_db.notes)..where((t) => t.id.equals(id))).watchSingleOrNull();

  Future<List<NoteRow>> notesByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    return (_db.select(_db.notes)..where((t) => t.id.isIn(ids))).get();
  }

  /// The names of everyone you have a `person` note about, most recent first,
  /// used as Sarvam keyterms so known names come back spelled consistently
  /// (SPEC.md §5).
  ///
  /// Only the name, never the whole title — see [extractPersonName].
  Future<List<String>> personNames() async {
    final rows = await (_db.select(_db.notes)
          ..where((t) => t.type.equalsValue(NoteType.person))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();

    final names = <String>[];
    final seen = <String>{};
    for (final row in rows) {
      final name = extractPersonName(row.title);
      if (name == null) continue;
      if (seen.add(name.toLowerCase())) names.add(name);
    }
    return names;
  }

  /// Creates a note and links the captures that produced it.
  Future<NoteRow> createNote({
    required NoteType type,
    required String title,
    required String body,
    required List<String> tags,
    List<String> captureIds = const [],
  }) async {
    final now = DateTime.now();
    final row = NoteRow(
      id: newId(),
      type: type,
      title: title,
      body: body,
      tags: tags,
      createdAt: now,
      updatedAt: now,
    );

    await _db.transaction(() async {
      await _db.into(_db.notes).insert(row);
      for (final captureId in captureIds) {
        await _db.into(_db.noteCaptures).insert(
              NoteCaptureRow(noteId: row.id, captureId: captureId),
              mode: InsertMode.insertOrIgnore,
            );
      }
    });

    return row;
  }

  /// Applies an edit, snapshotting the previous state into `note_versions`
  /// first so nothing is ever silently overwritten (SPEC.md §7.5).
  Future<NoteRow> updateNote({
    required String id,
    required ChangeSource changeSource,
    NoteType? type,
    String? title,
    String? body,
    List<String>? tags,
  }) async {
    return _db.transaction(() async {
      final current = await (_db.select(_db.notes)..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (current == null) {
        throw StateError('Cannot update note $id: it does not exist.');
      }

      await _db.into(_db.noteVersions).insert(
            NoteVersionRow(
              id: newId(),
              noteId: current.id,
              title: current.title,
              body: current.body,
              tags: current.tags,
              changedAt: DateTime.now(),
              changeSource: changeSource,
            ),
          );

      final updated = current.copyWith(
        type: type ?? current.type,
        title: title ?? current.title,
        body: body ?? current.body,
        tags: tags ?? current.tags,
        updatedAt: DateTime.now(),
      );
      await _db.update(_db.notes).replace(updated);
      return updated;
    });
  }

  Future<void> deleteNote(String id) =>
      (_db.delete(_db.notes)..where((t) => t.id.equals(id))).go();

  /// Version history, newest first.
  Future<List<NoteVersionRow>> versionsFor(String noteId) =>
      (_db.select(_db.noteVersions)
            ..where((t) => t.noteId.equals(noteId))
            ..orderBy([(t) => OrderingTerm.desc(t.changedAt)]))
          .get();

  /// The recordings a note came from, oldest first.
  Future<List<CaptureRow>> capturesFor(String noteId) async {
    final query = _db.select(_db.captures).join([
      innerJoin(
        _db.noteCaptures,
        _db.noteCaptures.captureId.equalsExp(_db.captures.id),
      ),
    ])
      ..where(_db.noteCaptures.noteId.equals(noteId))
      ..orderBy([OrderingTerm.asc(_db.captures.createdAt)]);

    final rows = await query.get();
    return [for (final r in rows) r.readTable(_db.captures)];
  }

  Future<void> linkCapture(String noteId, String captureId) =>
      _db.into(_db.noteCaptures).insert(
            NoteCaptureRow(noteId: noteId, captureId: captureId),
            mode: InsertMode.insertOrIgnore,
          );

  // -------------------------------------------------------------- people

  /// The `person` notes this note mentions.
  Future<List<NoteRow>> peopleFor(String noteId) async {
    final query = _db.select(_db.notes).join([
      innerJoin(
        _db.notePeople,
        _db.notePeople.personNoteId.equalsExp(_db.notes.id),
      ),
    ])
      ..where(_db.notePeople.noteId.equals(noteId))
      ..orderBy([OrderingTerm.asc(_db.notes.title)]);

    final rows = await query.get();
    return [for (final r in rows) r.readTable(_db.notes)];
  }

  /// The notes that mention this person — the other direction of the link,
  /// which is what makes a person note worth opening.
  Future<List<NoteRow>> notesMentioning(String personNoteId) async {
    final query = _db.select(_db.notes).join([
      innerJoin(
        _db.notePeople,
        _db.notePeople.noteId.equalsExp(_db.notes.id),
      ),
    ])
      ..where(_db.notePeople.personNoteId.equals(personNoteId))
      ..orderBy([OrderingTerm.desc(_db.notes.updatedAt)]);

    final rows = await query.get();
    return [for (final r in rows) r.readTable(_db.notes)];
  }

  Future<void> linkPerson(String noteId, String personNoteId) async {
    // A note mentioning itself is meaningless and would render as a
    // self-referential chip.
    if (noteId == personNoteId) return;
    await _db.into(_db.notePeople).insert(
          NotePersonRow(noteId: noteId, personNoteId: personNoteId),
          mode: InsertMode.insertOrIgnore,
        );
  }

  Future<void> clearPeopleLinks(String noteId) =>
      (_db.delete(_db.notePeople)..where((t) => t.noteId.equals(noteId))).go();

  /// Finds a `person` note by name, case-insensitively.
  ///
  /// Names come back from the LLM as they were spoken, so "ritu sharma" must
  /// match the note titled "Ritu Sharma".
  Future<NoteRow?> findPersonByName(String name) async {
    final target = name.trim().toLowerCase();
    if (target.isEmpty) return null;

    final people = await (_db.select(_db.notes)
          ..where((t) => t.type.equalsValue(NoteType.person)))
        .get();

    for (final person in people) {
      if (person.title.trim().toLowerCase() == target) return person;
    }
    // Fall back to a first-name match, so "Ritu" finds "Ritu Sharma" — but
    // only when exactly one person note could be meant.
    final partial = [
      for (final person in people)
        if (_firstWord(person.title) == _firstWord(target)) person,
    ];
    return partial.length == 1 ? partial.single : null;
  }

  static String _firstWord(String value) {
    final trimmed = value.trim().toLowerCase();
    final space = trimmed.indexOf(' ');
    return space == -1 ? trimmed : trimmed.substring(0, space);
  }

  /// BM25 full-text search over title, body and tags.
  ///
  /// Used by the Notes search bar and, from Phase 2, as one half of the hybrid
  /// ranking described in SPEC.md §8.
  Future<List<ScoredNoteId>> searchFts(String query, {int limit = 20}) async {
    final match = _toMatchQuery(query);
    if (match == null) return const [];

    final rows = await _db.customSelect(
      'SELECT note_id, bm25(notes_fts) AS score FROM notes_fts '
      'WHERE notes_fts MATCH ? ORDER BY score LIMIT ?',
      variables: [Variable<String>(match), Variable<int>(limit)],
      readsFrom: {_db.notes},
    ).get();

    return [
      for (final row in rows)
        ScoredNoteId(
          row.read<String>('note_id'),
          row.read<double>('score'),
        ),
    ];
  }

  /// Turns free text into a safe FTS5 MATCH expression.
  ///
  /// Every term is quoted so punctuation in a query (an apostrophe, a hyphen,
  /// a stray `"`) can never be read as FTS5 syntax, and a `*` is appended for
  /// prefix matching as you type.
  String? _toMatchQuery(String raw) {
    final terms = raw
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((t) => t.isNotEmpty)
        .toList();
    if (terms.isEmpty) return null;
    return terms.map((t) => '"$t"*').join(' OR ');
  }
}
