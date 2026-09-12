import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/core/errors.dart';
import 'package:yapapp/data/db/database.dart';
import 'package:yapapp/data/models/enums.dart';
import 'package:yapapp/data/repositories/capture_repository.dart';
import 'package:yapapp/data/repositories/note_repository.dart';
import 'package:yapapp/data/models/structured_note.dart';
import 'package:yapapp/data/repositories/embedding_repository.dart';
import 'package:yapapp/pipeline/capture_pipeline.dart';
import 'package:yapapp/pipeline/pipeline_resumer.dart';
import 'package:yapapp/search/embedding_indexer.dart';
import 'package:yapapp/search/hybrid_search.dart';
import 'package:yapapp/services/merge/merge_service.dart';
import 'package:yapapp/services/notes/note_writer.dart';
import 'package:yapapp/services/embedding/embedding_service.dart';
import 'package:yapapp/services/embedding/openai_compatible_embedding_service.dart';
import 'package:yapapp/services/structuring/structuring_service.dart';

import '../db/test_db.dart';
import '../fakes.dart';

const _valid = '''
{"notes":[{"type":"idea","title":"Time-loop movie","body":"A courier.",
"tags":["movie"],"people":[],"merge_target_id":null,"merge_reason":null}]}
''';

void main() {
  late AppDatabase db;
  late CaptureRepository captures;
  late NoteRepository notes;
  late FakeTranscriptionService transcription;
  late FakeConnectivity connectivity;
  late Directory tempDir;

  setUp(() async {
    db = openTestDatabase();
    captures = CaptureRepository(db);
    notes = NoteRepository(db);
    transcription = FakeTranscriptionService(text: 'mera ek idea hai');
    connectivity = FakeConnectivity();
    tempDir = await Directory.systemTemp.createTemp('yap_pipeline_test');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  /// A capture whose audio file really exists, so AudioPaths.resolve short
  /// circuits before it would need path_provider's platform channel.
  Future<CaptureRow> givenRecording({
    String id = 'cap-1',
    int durationMs = 12000,
  }) async {
    final file = File('${tempDir.path}/$id.m4a');
    await file.writeAsBytes([0, 1, 2, 3]);
    return captures.createCapture(
      id: id,
      audioPath: file.path,
      durationMs: durationMs,
    );
  }

  CapturePipeline buildPipeline(
    List<Object> llmResponses, {
    EmbeddingService? embeddingService,
    bool keyterms = true,
  }) {
    final llm = ScriptedLlmService(llmResponses);
    final embedService =
        embeddingService ?? const UnconfiguredEmbeddingService('no embeddings');
    final embeddingRepo = EmbeddingRepository(db);
    final indexer = EmbeddingIndexer(
      notes: notes,
      embeddings: embeddingRepo,
      service: embedService,
    );

    return CapturePipeline(
      captures: captures,
      notes: notes,
      transcription: transcription,
      structuring: StructuringService(llm),
      connectivity: connectivity,
      search: HybridSearch(
        notes: notes,
        embeddings: embeddingRepo,
        embeddingService: embedService,
      ),
      writer: NoteWriter(
        notes: notes,
        embeddings: embeddingRepo,
        indexer: indexer,
        merger: MergeService(llm),
      ),
      keytermsEnabled: () => keyterms,
    );
  }

  Future<CaptureStatus> statusOf(String id) async =>
      (await captures.getCapture(id))!.status;

  group('happy path', () {
    test('recorded -> awaiting_review, storing the transcript', () async {
      final capture = await givenRecording();
      final pipeline = buildPipeline([_valid]);

      await pipeline.process(capture.id);

      expect(await statusOf(capture.id), CaptureStatus.awaitingReview);
      final row = await captures.getCapture(capture.id);
      expect(row!.rawTranscript, 'mera ek idea hai');
      expect(row.error, isNull);

      final proposals = pipeline.proposalsFor(capture.id);
      expect(proposals, hasLength(1));
      expect(proposals!.single.title, 'Time-loop movie');
    });

    test('passes the recorded duration so REST vs Batch can be chosen',
        () async {
      final capture = await givenRecording(durationMs: 42000);
      await buildPipeline([_valid]).process(capture.id);

      expect(transcription.lastDuration, const Duration(milliseconds: 42000));
    });

    test('passes person names as keyterms', () async {
      await notes.createNote(
          type: NoteType.person, title: 'Ritu Sharma', body: 'b', tags: const []);
      await notes.createNote(
          type: NoteType.idea, title: 'Not a person', body: 'b', tags: const []);

      final capture = await givenRecording();
      await buildPipeline([_valid]).process(capture.id);

      expect(transcription.lastKeyterms, ['Ritu Sharma']);
    });

    test('sends only the name, never the descriptive title', () async {
      // The shape that poisoned real transcripts: Sarvam emitted the whole
      // title verbatim because it was handed one as a keyterm.
      await notes.createNote(
        type: NoteType.person,
        title: 'Parvesh Rawal - AI expert, potential co-founder/CTO',
        body: 'b',
        tags: const [],
      );

      final capture = await givenRecording();
      await buildPipeline([_valid]).process(capture.id);

      expect(transcription.lastKeyterms, ['Parvesh Rawal']);
    });

    test('sends no keyterms when the setting is off', () async {
      await notes.createNote(
          type: NoteType.person, title: 'Ritu Sharma', body: 'b', tags: const []);

      final capture = await givenRecording();
      await buildPipeline([_valid], keyterms: false).process(capture.id);

      expect(transcription.lastKeyterms, isEmpty);
    });

    test('saving a proposal creates a note linked to the recording', () async {
      final capture = await givenRecording();
      final pipeline = buildPipeline([_valid]);
      await pipeline.process(capture.id);

      final proposal = pipeline.proposalsFor(capture.id)!.single;
      final note = await pipeline.saveProposal(capture.id, proposal);

      expect(note.title, 'Time-loop movie');
      expect(note.type, NoteType.idea);
      final linked = await notes.capturesFor(note.id);
      expect(linked.single.id, capture.id);
    });

    test('completing the review moves the capture to saved', () async {
      final capture = await givenRecording();
      final pipeline = buildPipeline([_valid]);
      await pipeline.process(capture.id);

      await pipeline.completeReview(capture.id);

      expect(await statusOf(capture.id), CaptureStatus.saved);
      expect(pipeline.proposalsFor(capture.id), isNull);
    });

    test('an already-saved capture is not reprocessed', () async {
      final capture = await givenRecording();
      final pipeline = buildPipeline([_valid]);
      await pipeline.process(capture.id);
      await pipeline.completeReview(capture.id);

      await pipeline.process(capture.id);

      expect(transcription.calls, 1);
      expect(await statusOf(capture.id), CaptureStatus.saved);
    });
  });

  group('resume', () {
    test('a capture that already has a transcript is not re-transcribed',
        () async {
      final capture = await givenRecording();
      await captures.setTranscript(capture.id, 'already transcribed');
      await captures.setStatus(capture.id, CaptureStatus.structuring);

      final pipeline = buildPipeline([_valid]);
      await pipeline.process(capture.id);

      expect(transcription.calls, 0, reason: 'transcription must not repeat');
      expect(await statusOf(capture.id), CaptureStatus.awaitingReview);
    });

    test('a capture interrupted mid-transcription starts over from audio',
        () async {
      final capture = await givenRecording();
      await captures.setStatus(capture.id, CaptureStatus.transcribing);

      await buildPipeline([_valid]).process(capture.id);

      expect(transcription.calls, 1);
      expect(await statusOf(capture.id), CaptureStatus.awaitingReview);
    });

    test('proposals are rebuilt after a restart without re-transcribing',
        () async {
      final capture = await givenRecording();
      await buildPipeline([_valid]).process(capture.id);

      // A new pipeline stands in for a fresh app launch: same database,
      // empty in-memory proposal cache.
      final afterRestart = buildPipeline([_valid]);
      expect(afterRestart.proposalsFor(capture.id), isNull);

      final proposals = await afterRestart.ensureProposals(capture.id);

      expect(proposals, hasLength(1));
      expect(transcription.calls, 1, reason: 'audio is transcribed only once');
    });

    test('ensureProposals returns the cached list without a second LLM call',
        () async {
      final capture = await givenRecording();
      // Only one scripted response: a second structuring call would throw.
      final pipeline = buildPipeline([_valid]);
      await pipeline.process(capture.id);

      final proposals = await pipeline.ensureProposals(capture.id);
      expect(proposals, hasLength(1));
    });

    test('the resumer sweeps every in-progress capture, oldest first', () async {
      final first = await givenRecording(id: 'cap-1');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final second = await givenRecording(id: 'cap-2');
      await captures.setStatus(second.id, CaptureStatus.transcribing);

      final pipeline = buildPipeline([_valid, _valid]);
      await PipelineResumer(
        pipeline: pipeline,
        captures: captures,
        connectivity: connectivity,
      ).start();

      expect(await statusOf(first.id), CaptureStatus.awaitingReview);
      expect(await statusOf(second.id), CaptureStatus.awaitingReview);
    });

    test('the resumer ignores captures that are already done', () async {
      final capture = await givenRecording();
      await captures.setStatus(capture.id, CaptureStatus.saved);

      await PipelineResumer(
        pipeline: buildPipeline([]),
        captures: captures,
        connectivity: connectivity,
      ).start();

      expect(transcription.calls, 0);
    });
  });

  group('offline', () {
    test('queues instead of failing, and does not call transcription', () async {
      connectivity.online = false;
      final capture = await givenRecording();

      await buildPipeline([_valid]).process(capture.id);

      final row = await captures.getCapture(capture.id);
      expect(row!.status, CaptureStatus.recorded);
      expect(row.status.isInProgress, isTrue,
          reason: 'must stay resumable, not terminal');
      expect(row.error, CapturePipeline.queuedMessage);
      expect(transcription.calls, 0);
    });

    test('a queued capture completes once connectivity returns', () async {
      connectivity.online = false;
      final capture = await givenRecording();
      final pipeline = buildPipeline([_valid]);
      await pipeline.process(capture.id);

      connectivity.online = true;
      await pipeline.process(capture.id);

      expect(await statusOf(capture.id), CaptureStatus.awaitingReview);
      expect((await captures.getCapture(capture.id))!.error, isNull);
    });

    test('going offline between transcription and structuring re-queues',
        () async {
      final capture = await givenRecording();
      await captures.setTranscript(capture.id, 'already transcribed');
      connectivity.online = false;

      await buildPipeline([_valid]).process(capture.id);

      final row = await captures.getCapture(capture.id);
      expect(row!.status, CaptureStatus.recorded);
      expect(row.rawTranscript, 'already transcribed',
          reason: 'work already done must survive');
    });
  });

  group('failure', () {
    test('a transcription error fails the capture with its message', () async {
      transcription.error = const ApiException('Sarvam said no');
      final capture = await givenRecording();

      await buildPipeline([_valid]).process(capture.id);

      final row = await captures.getCapture(capture.id);
      expect(row!.status, CaptureStatus.failed);
      expect(row.error, 'Sarvam said no');
    });

    test('an auth error fails rather than queueing', () async {
      transcription.error = const AuthException('Bad key');
      final capture = await givenRecording();

      await buildPipeline([_valid]).process(capture.id);

      expect(await statusOf(capture.id), CaptureStatus.failed);
    });

    test('an empty transcript fails with a useful message', () async {
      transcription.text = '   ';
      final capture = await givenRecording();

      await buildPipeline([_valid]).process(capture.id);

      final row = await captures.getCapture(capture.id);
      expect(row!.status, CaptureStatus.failed);
      expect(row.error, contains('silent'));
    });

    test('invalid structuring output twice fails the capture', () async {
      final capture = await givenRecording();

      await buildPipeline(['garbage', 'still garbage']).process(capture.id);

      final row = await captures.getCapture(capture.id);
      expect(row!.status, CaptureStatus.failed);
      expect(row.error, contains('invalid notes twice'));
      expect(row.rawTranscript, 'mera ek idea hai',
          reason: 'the transcript is kept even when structuring fails');
    });

    test('an unexpected error still fails safely', () async {
      transcription.error = ArgumentError('boom');
      final capture = await givenRecording();

      await buildPipeline([_valid]).process(capture.id);

      final row = await captures.getCapture(capture.id);
      expect(row!.status, CaptureStatus.failed);
      expect(row.error, contains('Something went wrong'));
    });

    test('retry clears the error and re-runs from the stored transcript',
        () async {
      final capture = await givenRecording();
      await buildPipeline(['garbage', 'still garbage']).process(capture.id);
      expect(await statusOf(capture.id), CaptureStatus.failed);

      final retryPipeline = buildPipeline([_valid]);
      await retryPipeline.retry(capture.id);

      final row = await captures.getCapture(capture.id);
      expect(row!.status, CaptureStatus.awaitingReview);
      expect(row.error, isNull);
      expect(transcription.calls, 1,
          reason: 'retry reuses the transcript it already paid for');
    });
  });

  group('merge candidates', () {
    test('offers semantically similar notes to the structuring model',
        () async {
      final embedder = FakeEmbeddingService();
      final indexer = EmbeddingIndexer(
        notes: notes,
        embeddings: EmbeddingRepository(db),
        service: embedder,
      );
      final existing = await notes.createNote(
        type: NoteType.idea,
        title: 'Movie idea',
        body: 'A movie about video editing.',
        tags: const [],
      );
      await indexer.indexNote(existing.id);

      transcription.text = 'another movie idea about editing';
      final llm = ScriptedLlmService([_valid]);
      final capture = await givenRecording();

      await CapturePipeline(
        captures: captures,
        notes: notes,
        transcription: transcription,
        structuring: StructuringService(llm),
        connectivity: connectivity,
        search: HybridSearch(
          notes: notes,
          embeddings: EmbeddingRepository(db),
          embeddingService: embedder,
        ),
        writer: NoteWriter(
          notes: notes,
          embeddings: EmbeddingRepository(db),
          indexer: indexer,
          merger: MergeService(llm),
        ),
        keytermsEnabled: () => true,
      ).process(capture.id);

      final userTurn = llm.received.single.last.content!;
      expect(userTurn, contains('Movie idea'),
          reason: 'the candidate must reach the structuring prompt');
      expect(userTurn, contains(existing.id),
          reason: 'the model needs the id to set merge_target_id');
    });

    test('structuring still runs when embeddings are unconfigured', () async {
      final capture = await givenRecording();
      await buildPipeline([_valid]).process(capture.id);

      expect(await statusOf(capture.id), CaptureStatus.awaitingReview);
    });
  });

  group('merge', () {
    const mergedJson =
        '{"title":"Movie idea","body":"Merged body keeping both details.","tags":[]}';

    test('mergeTargetFor resolves the note the model pointed at', () async {
      final target = await notes.createNote(
        type: NoteType.idea,
        title: 'Movie idea',
        body: 'body',
        tags: const [],
      );
      final pipeline = buildPipeline([]);

      final resolved = await pipeline.mergeTargetFor(StructuredNote(
        type: NoteType.idea,
        title: 't',
        body: 'b',
        tags: const [],
        people: const [],
        mergeTargetId: target.id,
      ));

      expect(resolved!.id, target.id);
    });

    test('mergeTargetFor returns null for a deleted target', () async {
      final pipeline = buildPipeline([]);
      final resolved = await pipeline.mergeTargetFor(const StructuredNote(
        type: NoteType.idea,
        title: 't',
        body: 'b',
        tags: [],
        people: [],
        mergeTargetId: 'gone',
      ));
      expect(resolved, isNull);
    });

    test('mergeTargetFor returns null when none was suggested', () async {
      final pipeline = buildPipeline([]);
      final resolved = await pipeline.mergeTargetFor(const StructuredNote(
        type: NoteType.idea,
        title: 't',
        body: 'b',
        tags: [],
        people: [],
      ));
      expect(resolved, isNull);
    });

    test('merging a proposal versions the target and links the capture',
        () async {
      final capture = await givenRecording();
      final pipeline = buildPipeline([_valid, mergedJson]);
      await pipeline.process(capture.id);

      final target = await notes.createNote(
        type: NoteType.idea,
        title: 'Movie idea',
        body: 'Original body.',
        tags: const [],
      );

      final proposal = pipeline.proposalsFor(capture.id)!.single;
      final merged = await pipeline.mergeProposal(capture.id, proposal, target);

      expect(merged.body, 'Merged body keeping both details.');
      final versions = await notes.versionsFor(target.id);
      expect(versions.single.body, 'Original body.');
      expect(versions.single.changeSource, ChangeSource.voiceMerge);

      final linked = await notes.capturesFor(target.id);
      expect(linked.map((c) => c.id), contains(capture.id));
    });
  });

  test('concurrent process calls do not double-run a capture', () async {
    final capture = await givenRecording();
    // A single scripted response: a second structuring call would throw.
    final pipeline = buildPipeline([_valid]);

    await Future.wait([
      pipeline.process(capture.id),
      pipeline.process(capture.id),
    ]);

    expect(transcription.calls, 1);
    expect(await statusOf(capture.id), CaptureStatus.awaitingReview);
  });
}
