import 'dart:async';

import '../core/errors.dart';
import '../core/log.dart';
import '../data/db/database.dart';
import '../data/models/enums.dart';
import '../data/models/structured_note.dart';
import '../data/repositories/capture_repository.dart';
import '../data/repositories/note_repository.dart';
import '../search/hybrid_search.dart';
import '../services/audio/audio_paths.dart';
import '../services/connectivity_service.dart';
import '../services/notes/note_writer.dart';
import '../services/structuring/structuring_service.dart';
import '../services/transcription/transcription_service.dart';

/// Drives a capture from `recorded` to `awaiting_review`, and from there to
/// `saved` once the user has dealt with every proposal (SPEC.md §7).
///
/// Every step is idempotent and reads its starting point from the database, so
/// calling [process] on a half-finished capture picks up where it left off
/// rather than redoing work — in particular it never re-transcribes audio that
/// already has a stored transcript.
class CapturePipeline {
  CapturePipeline({
    required this.captures,
    required this.notes,
    required this.transcription,
    required this.structuring,
    required this.connectivity,
    required this.search,
    required this.writer,
    required this.keytermsEnabled,
    this.paths = const AudioPaths(),
  });

  /// How many existing notes are offered to the structuring LLM as possible
  /// merge targets (SPEC.md §7.3).
  static const mergeCandidateLimit = 5;

  final CaptureRepository captures;
  final NoteRepository notes;
  final TranscriptionService transcription;
  final StructuringService structuring;
  final ConnectivityService connectivity;
  final HybridSearch search;
  final NoteWriter writer;

  /// Read at transcription time so a change in Settings takes effect on the
  /// next recording without rebuilding the pipeline.
  final bool Function() keytermsEnabled;
  final AudioPaths paths;

  /// The message shown on a capture that is waiting for a connection rather
  /// than having actually failed.
  static const queuedMessage = 'Waiting for a connection…';

  /// Proposals live in memory for the session. The schema has nowhere to put
  /// them, so after a restart they are rebuilt on demand from the stored
  /// transcript by [ensureProposals] — no re-transcription, and no LLM call
  /// until the user actually opens the review.
  final _proposals = <String, List<StructuredNote>>{};

  /// Guards against the resumer and the UI processing the same capture at once.
  final _inFlight = <String>{};

  final _changes = StreamController<String>.broadcast();

  /// Emits a capture id whenever its proposals change.
  Stream<String> get proposalsChanged => _changes.stream;

  List<StructuredNote>? proposalsFor(String captureId) => _proposals[captureId];

  /// Runs the capture as far as it can get.
  Future<void> process(String captureId) async {
    if (!_inFlight.add(captureId)) {
      logD('Pipeline', 'capture already in flight, skipping');
      return;
    }
    try {
      await _run(captureId);
    } finally {
      _inFlight.remove(captureId);
    }
  }

  Future<void> _run(String captureId) async {
    final capture = await captures.getCapture(captureId);
    if (capture == null) return;
    if (capture.status == CaptureStatus.saved) return;

    try {
      final transcript = await _ensureTranscript(capture);
      await _structureAndPark(captureId, transcript);
    } on OfflineException {
      // Not a failure: hold the capture in an in-progress state so the
      // connectivity listener and the next app start both retry it.
      await captures.setStatus(
        captureId,
        CaptureStatus.recorded,
        error: queuedMessage,
      );
      logD('Pipeline', 'capture queued until connectivity returns');
    } on AppException catch (e) {
      await captures.setStatus(captureId, CaptureStatus.failed, error: e.message);
      logE('Pipeline', 'capture failed: ${e.message}');
    } catch (e) {
      await captures.setStatus(
        captureId,
        CaptureStatus.failed,
        error: 'Something went wrong while processing this recording.',
      );
      logE('Pipeline', 'capture failed unexpectedly', e);
    }
  }

  /// Returns the stored transcript, transcribing first if there isn't one.
  Future<String> _ensureTranscript(CaptureRow capture) async {
    final existing = capture.rawTranscript;
    if (existing != null && existing.trim().isNotEmpty) return existing;

    if (!await connectivity.isOnline()) throw const OfflineException();

    await captures.setStatus(
      capture.id,
      CaptureStatus.transcribing,
      clearError: true,
    );

    final audio = await paths.resolve(capture.audioPath);
    // Person names become keyterms so known names come back spelled
    // consistently. Off by request when biasing does more harm than good.
    final keyterms = keytermsEnabled() ? await notes.personNames() : const <String>[];

    final transcript = await transcription.transcribe(
      audio,
      keyterms: keyterms,
      duration: Duration(milliseconds: capture.durationMs),
    );

    final text = transcript.text.trim();
    if (text.isEmpty) {
      throw const ValidationException(
        'Nothing was transcribed — the recording may be silent.',
      );
    }

    await captures.setTranscript(capture.id, text);
    logD('Pipeline', 'transcribed ${redact(text)}');
    return text;
  }

  Future<void> _structureAndPark(String captureId, String transcript) async {
    if (!await connectivity.isOnline()) throw const OfflineException();

    await captures.setStatus(
      captureId,
      CaptureStatus.structuring,
      clearError: true,
    );

    // Semantic neighbours of the transcript become the merge candidates the
    // model may point `merge_target_id` at. Best-effort: if embeddings are
    // unconfigured this returns nothing and structuring still runs.
    final candidates = await search.similarTo(
      transcript,
      limit: mergeCandidateLimit,
    );

    final proposals = await structuring.structure(
      transcript: transcript,
      candidates: candidates,
      // The model fixes mangled names against this roster, which is safer
      // than biasing the recogniser towards them.
      knownPeople: await notes.personNames(),
    );

    _proposals[captureId] = proposals;
    _changes.add(captureId);
    await captures.setStatus(
      captureId,
      CaptureStatus.awaitingReview,
      clearError: true,
    );
  }

  /// Proposals for a capture that is awaiting review, rebuilding them from the
  /// stored transcript if this session has none (i.e. after a restart).
  Future<List<StructuredNote>> ensureProposals(String captureId) async {
    final cached = _proposals[captureId];
    if (cached != null) return cached;

    final capture = await captures.getCapture(captureId);
    final transcript = capture?.rawTranscript;
    if (capture == null || transcript == null || transcript.trim().isEmpty) {
      throw const ValidationException('This recording has no transcript yet.');
    }

    await _structureAndPark(captureId, transcript);
    return _proposals[captureId] ?? const [];
  }

  /// Saves one reviewed proposal as a new note, linked back to its recording.
  Future<NoteRow> saveProposal(String captureId, StructuredNote proposal) =>
      writer.createFromProposal(proposal, captureId: captureId);

  /// The note a proposal offers to merge into, or null when it suggests none
  /// or names one that has since been deleted.
  Future<NoteRow?> mergeTargetFor(StructuredNote proposal) async {
    final id = proposal.mergeTargetId;
    if (id == null) return null;
    return notes.getNote(id);
  }

  /// Folds a reviewed proposal into the note it extends, keeping the previous
  /// state in `note_versions`.
  Future<NoteRow> mergeProposal(
    String captureId,
    StructuredNote proposal,
    NoteRow target,
  ) =>
      writer.mergeIntoExisting(
        existing: target,
        incoming: proposal,
        captureId: captureId,
      );

  /// Marks the review done. The audio and transcript stay on disk either way —
  /// discarding a proposal discards the *suggestion*, never the recording.
  Future<void> completeReview(String captureId) async {
    _proposals.remove(captureId);
    _changes.add(captureId);
    await captures.setStatus(captureId, CaptureStatus.saved, clearError: true);
  }

  /// Re-runs a failed capture from wherever it stopped.
  Future<void> retry(String captureId) async {
    await captures.setStatus(
      captureId,
      CaptureStatus.recorded,
      clearError: true,
    );
    await process(captureId);
  }

  void dispose() => _changes.close();
}
