import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/data/db/database.dart';
import 'package:yapapp/data/models/enums.dart';
import 'package:yapapp/data/repositories/capture_repository.dart';
import 'package:yapapp/data/repositories/note_repository.dart';

import 'test_db.dart';

void main() {
  late AppDatabase db;
  late NoteRepository notes;
  late CaptureRepository captures;

  setUp(() {
    db = openTestDatabase();
    notes = NoteRepository(db);
    captures = CaptureRepository(db);
  });

  tearDown(() => db.close());

  group('CRUD', () {
    test('creates and reads a note', () async {
      final created = await notes.createNote(
        type: NoteType.idea,
        title: 'Time-loop movie',
        body: 'A courier stuck reliving one Mumbai delivery run.',
        tags: ['movie', 'scifi'],
      );

      final fetched = await notes.getNote(created.id);
      expect(fetched, isNotNull);
      expect(fetched!.title, 'Time-loop movie');
      expect(fetched.type, NoteType.idea);
      expect(fetched.tags, ['movie', 'scifi']);
    });

    test('round-trips tags through the JSON converter', () async {
      final created = await notes.createNote(
        type: NoteType.note,
        title: 'Tagged',
        body: 'body',
        tags: ['a', 'b c', "d's"],
      );
      final fetched = await notes.getNote(created.id);
      expect(fetched!.tags, ['a', 'b c', "d's"]);
    });

    test('empty tag list survives the round trip', () async {
      final created = await notes.createNote(
        type: NoteType.note,
        title: 'No tags',
        body: 'body',
        tags: const [],
      );
      expect((await notes.getNote(created.id))!.tags, isEmpty);
    });

    test('filters notes by type', () async {
      await notes.createNote(
          type: NoteType.idea, title: 'i', body: 'b', tags: const []);
      await notes.createNote(
          type: NoteType.person, title: 'p', body: 'b', tags: const []);

      final people = await notes.watchNotes(type: NoteType.person).first;
      expect(people, hasLength(1));
      expect(people.single.title, 'p');
    });

    test('personNames returns only person-note titles', () async {
      await notes.createNote(
          type: NoteType.person, title: 'Ritu Sharma', body: 'b', tags: const []);
      await notes.createNote(
          type: NoteType.person, title: 'Aakash', body: 'b', tags: const []);
      await notes.createNote(
          type: NoteType.idea, title: 'Not a person', body: 'b', tags: const []);

      expect(await notes.personNames(), containsAll(['Ritu Sharma', 'Aakash']));
      expect(await notes.personNames(), hasLength(2));
    });

    test('deleting a note cascades to its versions', () async {
      final note = await notes.createNote(
          type: NoteType.note, title: 'a', body: 'b', tags: const []);
      await notes.updateNote(
        id: note.id,
        changeSource: ChangeSource.manualEdit,
        title: 'a2',
      );
      expect(await notes.versionsFor(note.id), hasLength(1));

      await notes.deleteNote(note.id);
      expect(await notes.versionsFor(note.id), isEmpty);
    });
  });

  group('versioning', () {
    test('update snapshots the previous state before overwriting', () async {
      final note = await notes.createNote(
        type: NoteType.idea,
        title: 'Original title',
        body: 'Original body',
        tags: ['one'],
      );

      final updated = await notes.updateNote(
        id: note.id,
        changeSource: ChangeSource.manualEdit,
        title: 'New title',
        body: 'New body',
        tags: ['one', 'two'],
      );

      expect(updated.title, 'New title');
      expect(updated.body, 'New body');
      expect(updated.tags, ['one', 'two']);

      final versions = await notes.versionsFor(note.id);
      expect(versions, hasLength(1));
      // The version holds the OLD state, not the new one.
      expect(versions.single.title, 'Original title');
      expect(versions.single.body, 'Original body');
      expect(versions.single.tags, ['one']);
      expect(versions.single.changeSource, ChangeSource.manualEdit);
    });

    test('records the change source it was given', () async {
      final note = await notes.createNote(
          type: NoteType.note, title: 't', body: 'b', tags: const []);
      await notes.updateNote(
          id: note.id, changeSource: ChangeSource.voiceMerge, body: 'b2');

      final versions = await notes.versionsFor(note.id);
      expect(versions.single.changeSource, ChangeSource.voiceMerge);
    });

    test('a partial update leaves untouched fields alone', () async {
      final note = await notes.createNote(
        type: NoteType.idea,
        title: 'Keep me',
        body: 'Old body',
        tags: ['keep'],
      );

      final updated = await notes.updateNote(
        id: note.id,
        changeSource: ChangeSource.manualEdit,
        body: 'Only the body changed',
      );

      expect(updated.title, 'Keep me');
      expect(updated.tags, ['keep']);
      expect(updated.body, 'Only the body changed');
    });

    test('successive edits stack up, newest version first', () async {
      final note = await notes.createNote(
          type: NoteType.note, title: 'v1', body: 'b', tags: const []);
      await notes.updateNote(
          id: note.id, changeSource: ChangeSource.manualEdit, title: 'v2');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await notes.updateNote(
          id: note.id, changeSource: ChangeSource.chatEdit, title: 'v3');

      final versions = await notes.versionsFor(note.id);
      expect(versions, hasLength(2));
      expect(versions.first.title, 'v2', reason: 'newest snapshot first');
      expect(versions.last.title, 'v1');
    });

    test('updating a missing note throws instead of creating one', () async {
      expect(
        () => notes.updateNote(
            id: 'nope', changeSource: ChangeSource.manualEdit, title: 'x'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('capture links', () {
    test('createNote links the captures that produced it', () async {
      final capture = await captures.createCapture(
          id: 'cap-1', audioPath: '/tmp/a.m4a', durationMs: 4200);

      final note = await notes.createNote(
        type: NoteType.idea,
        title: 'From a ramble',
        body: 'body',
        tags: const [],
        captureIds: [capture.id],
      );

      final linked = await notes.capturesFor(note.id);
      expect(linked, hasLength(1));
      expect(linked.single.id, 'cap-1');
      expect(linked.single.durationMs, 4200);
    });

    test('linking the same capture twice is a no-op', () async {
      await captures.createCapture(
          id: 'cap-1', audioPath: '/tmp/a.m4a', durationMs: 1);
      final note = await notes.createNote(
          type: NoteType.note, title: 't', body: 'b', tags: const []);

      await notes.linkCapture(note.id, 'cap-1');
      await notes.linkCapture(note.id, 'cap-1');

      expect(await notes.capturesFor(note.id), hasLength(1));
    });
  });
}
