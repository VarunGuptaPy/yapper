import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/core/errors.dart';
import 'package:yapapp/data/db/database.dart';
import 'package:yapapp/data/models/enums.dart';
import 'package:yapapp/data/models/structured_note.dart';
import 'package:yapapp/data/repositories/embedding_repository.dart';
import 'package:yapapp/data/repositories/note_repository.dart';
import 'package:yapapp/search/embedding_indexer.dart';
import 'package:yapapp/services/chat/note_proposal.dart';
import 'package:yapapp/services/merge/merge_service.dart';
import 'package:yapapp/services/notes/note_writer.dart';

import '../db/test_db.dart';
import '../fakes.dart';

StructuredNote proposal({
  NoteType type = NoteType.idea,
  String title = 'Time-loop movie',
  String body = 'A courier reliving one Mumbai delivery run.',
  List<String> tags = const ['movie'],
  List<String> people = const [],
  String? mergeTargetId,
}) =>
    StructuredNote(
      type: type,
      title: title,
      body: body,
      tags: tags,
      people: people,
      mergeTargetId: mergeTargetId,
    );

void main() {
  late AppDatabase db;
  late NoteRepository notes;
  late EmbeddingRepository embeddings;
  late FakeEmbeddingService embedder;
  late ScriptedLlmService llm;
  late NoteWriter writer;

  NoteWriter build(List<Object> mergeResponses) {
    llm = ScriptedLlmService(mergeResponses);
    return NoteWriter(
      notes: notes,
      embeddings: embeddings,
      indexer: EmbeddingIndexer(
        notes: notes,
        embeddings: embeddings,
        service: embedder,
      ),
      merger: MergeService(llm),
    );
  }

  setUp(() {
    db = openTestDatabase();
    notes = NoteRepository(db);
    embeddings = EmbeddingRepository(db);
    embedder = FakeEmbeddingService();
    writer = build([]);
  });

  tearDown(() => db.close());

  group('create', () {
    test('saves and indexes a proposal', () async {
      final note = await writer.createFromProposal(proposal());

      expect(note.title, 'Time-loop movie');
      expect(await embeddings.countForModel(embedder.modelId), 1);
    });

    test('links the capture that produced it', () async {
      await CaptureRepositoryStub(db).create('cap-1');
      final note =
          await writer.createFromProposal(proposal(), captureId: 'cap-1');

      final linked = await notes.capturesFor(note.id);
      expect(linked.single.id, 'cap-1');
    });

    test('links people that already have a person note', () async {
      final person = await notes.createNote(
        type: NoteType.person,
        title: 'Ritu Sharma',
        body: 'Video editor.',
        tags: const [],
      );

      final note = await writer.createFromProposal(
        proposal(people: ['Ritu Sharma']),
      );

      final people = await notes.peopleFor(note.id);
      expect(people.single.id, person.id);
    });

    test('matches a person name case-insensitively', () async {
      await notes.createNote(
        type: NoteType.person,
        title: 'Ritu Sharma',
        body: 'b',
        tags: const [],
      );
      final note =
          await writer.createFromProposal(proposal(people: ['ritu sharma']));

      expect(await notes.peopleFor(note.id), hasLength(1));
    });

    test('matches a lone first name', () async {
      await notes.createNote(
        type: NoteType.person,
        title: 'Ritu Sharma',
        body: 'b',
        tags: const [],
      );
      final note = await writer.createFromProposal(proposal(people: ['Ritu']));

      expect(await notes.peopleFor(note.id), hasLength(1));
    });

    test('refuses an ambiguous first name rather than guessing', () async {
      await notes.createNote(
          type: NoteType.person, title: 'Ritu Sharma', body: 'b', tags: const []);
      await notes.createNote(
          type: NoteType.person, title: 'Ritu Desai', body: 'b', tags: const []);

      final note = await writer.createFromProposal(proposal(people: ['Ritu']));
      expect(await notes.peopleFor(note.id), isEmpty);
    });

    test('skips a name with no person note', () async {
      final note =
          await writer.createFromProposal(proposal(people: ['Nobody At All']));
      expect(await notes.peopleFor(note.id), isEmpty);
    });

    test('a new person note back-links notes that already mention them',
        () async {
      // Recorded before the person note existed.
      final earlier = await writer.createFromProposal(proposal(
        title: 'Short film',
        body: 'Need an editor. Ritu Sharma was recommended.',
        people: ['Ritu Sharma'],
      ));
      expect(await notes.peopleFor(earlier.id), isEmpty);

      final person = await writer.createFromProposal(proposal(
        type: NoteType.person,
        title: 'Ritu Sharma',
        body: 'Freelance video editor.',
        tags: const [],
      ));

      final mentioning = await notes.notesMentioning(person.id);
      expect(mentioning.map((n) => n.id), contains(earlier.id));
    });

    test('a person note does not link to itself', () async {
      final person = await writer.createFromProposal(proposal(
        type: NoteType.person,
        title: 'Ritu Sharma',
        body: 'Ritu Sharma is a video editor.',
      ));
      expect(await notes.notesMentioning(person.id), isEmpty);
    });
  });

  group('merge', () {
    const mergedJson = '''
{"title":"Time-loop movie","body":"A courier reliving one Mumbai delivery run. Now also set during the monsoon.","tags":["movie","monsoon"]}
''';

    test('keeps a version of the old state and writes the merged body',
        () async {
      writer = build([mergedJson]);
      final existing = await writer.createFromProposal(proposal());

      final merged = await writer.mergeIntoExisting(
        existing: existing,
        incoming: proposal(
          title: 'Monsoon angle',
          body: 'Set it during the monsoon.',
          tags: const ['monsoon'],
        ),
      );

      expect(merged.body, contains('monsoon'));
      expect(merged.body, contains('courier'),
          reason: 'the original detail must survive');
      expect(merged.tags, containsAll(['movie', 'monsoon']));

      final versions = await notes.versionsFor(existing.id);
      expect(versions.single.body, 'A courier reliving one Mumbai delivery run.');
      expect(versions.single.changeSource, ChangeSource.voiceMerge);
    });

    test('re-embeds the merged note', () async {
      writer = build([mergedJson]);
      final existing = await writer.createFromProposal(proposal());
      final before = embedder.calls;

      await writer.mergeIntoExisting(
        existing: existing,
        incoming: proposal(body: 'Set it during the monsoon.'),
      );

      expect(embedder.calls, greaterThan(before));
    });

    test('links the merging capture to the target note', () async {
      writer = build([mergedJson]);
      await CaptureRepositoryStub(db).create('cap-2');
      final existing = await writer.createFromProposal(proposal());

      await writer.mergeIntoExisting(
        existing: existing,
        incoming: proposal(),
        captureId: 'cap-2',
      );

      final linked = await notes.capturesFor(existing.id);
      expect(linked.map((c) => c.id), contains('cap-2'));
    });

    test('keeps every original tag even if the model drops one', () async {
      writer = build(['{"title":"T","body":"merged body","tags":[]}']);
      final existing = await writer.createFromProposal(
        proposal(tags: const ['movie', 'scifi']),
      );

      final merged = await writer.mergeIntoExisting(
        existing: existing,
        incoming: proposal(tags: const ['monsoon']),
      );

      expect(merged.tags, containsAll(['movie', 'scifi', 'monsoon']));
    });

    test('rejects a merged body in Devanagari', () async {
      writer = build(['{"title":"T","body":"मेरा phone number"}']);
      final existing = await writer.createFromProposal(proposal());

      await expectLater(
        writer.mergeIntoExisting(existing: existing, incoming: proposal()),
        throwsA(isA<ValidationException>()),
      );
    });

    test('rejects an empty merged body rather than destroying the note',
        () async {
      writer = build(['{"title":"T","body":"   "}']);
      final existing = await writer.createFromProposal(proposal());

      await expectLater(
        writer.mergeIntoExisting(existing: existing, incoming: proposal()),
        throwsA(isA<ValidationException>()),
      );
      expect((await notes.getNote(existing.id))!.body, contains('courier'));
    });

    test('falls back to the existing title when the model omits one', () async {
      writer = build(['{"body":"merged body"}']);
      final existing = await writer.createFromProposal(proposal());

      final merged = await writer.mergeIntoExisting(
        existing: existing,
        incoming: proposal(title: 'Ignored'),
      );
      expect(merged.title, 'Time-loop movie');
    });
  });

  group('chat proposals', () {
    test('create writes a new note and indexes it', () async {
      final note = await writer.applyChatProposal(const NoteProposal(
        kind: ProposalKind.create,
        type: NoteType.rule,
        title: 'Never eat prawns',
        body: 'Allergic reaction in Goa.',
        tags: ['food'],
      ));

      expect(note.type, NoteType.rule);
      expect(await embeddings.countForModel(embedder.modelId), 1);
    });

    test('update versions the old state as a chat edit', () async {
      final existing = await writer.createFromProposal(proposal());

      await writer.applyChatProposal(NoteProposal(
        kind: ProposalKind.update,
        noteId: existing.id,
        body: 'Rewritten body.',
      ));

      final versions = await notes.versionsFor(existing.id);
      expect(versions.single.changeSource, ChangeSource.chatEdit);
      expect((await notes.getNote(existing.id))!.body, 'Rewritten body.');
    });

    test('update leaves tags alone when the proposal omits them', () async {
      final existing =
          await writer.createFromProposal(proposal(tags: const ['keep']));

      await writer.applyChatProposal(NoteProposal(
        kind: ProposalKind.update,
        noteId: existing.id,
        body: 'New body.',
      ));

      expect((await notes.getNote(existing.id))!.tags, ['keep']);
    });

    test('an update with no note id is rejected', () async {
      await expectLater(
        writer.applyChatProposal(
          const NoteProposal(kind: ProposalKind.update, body: 'x'),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('edit and delete', () {
    test('a manual edit versions and re-indexes', () async {
      final note = await writer.createFromProposal(proposal());
      final before = embedder.calls;

      await writer.applyManualEdit(id: note.id, title: 'Renamed');

      final versions = await notes.versionsFor(note.id);
      expect(versions.single.changeSource, ChangeSource.manualEdit);
      expect(embedder.calls, greaterThan(before));
    });

    test('delete removes the note and its vector', () async {
      final note = await writer.createFromProposal(proposal());
      expect(await embeddings.countForModel(embedder.modelId), 1);

      await writer.delete(note.id);

      expect(await notes.getNote(note.id), isNull);
      expect(await embeddings.countForModel(embedder.modelId), 0);
    });
  });
}

/// Minimal capture insert so note-capture links can be exercised without
/// standing up the whole pipeline.
class CaptureRepositoryStub {
  CaptureRepositoryStub(this.db);

  final AppDatabase db;

  Future<void> create(String id) => db.into(db.captures).insert(
        CaptureRow(
          id: id,
          audioPath: '/audio/$id.m4a',
          durationMs: 1000,
          status: CaptureStatus.saved,
          createdAt: DateTime.now(),
        ),
      );
}
