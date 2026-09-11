import 'package:drift/drift.dart';

import '../db/database.dart';
import '../models/enums.dart';

class CaptureRepository {
  CaptureRepository(this._db);

  final AppDatabase _db;

  Future<CaptureRow> createCapture({
    required String id,
    required String audioPath,
    required int durationMs,
  }) async {
    final row = CaptureRow(
      id: id,
      audioPath: audioPath,
      durationMs: durationMs,
      status: CaptureStatus.recorded,
      createdAt: DateTime.now(),
    );
    await _db.into(_db.captures).insert(row);
    return row;
  }

  Stream<List<CaptureRow>> watchRecent({int limit = 30}) =>
      (_db.select(_db.captures)
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
            ..limit(limit))
          .watch();

  Future<CaptureRow?> getCapture(String id) =>
      (_db.select(_db.captures)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Captures left mid-flight by a crash or a force-quit, oldest first so they
  /// are resumed in the order they were spoken (SPEC.md §7.6).
  Future<List<CaptureRow>> inProgress() async {
    final wire = [
      for (final s in CaptureStatus.values)
        if (s.isInProgress) s.wire,
    ];
    return (_db.select(_db.captures)
          ..where((t) => t.status.isIn(wire))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
  }

  Future<void> setStatus(
    String id,
    CaptureStatus status, {
    String? error,
    bool clearError = false,
  }) async {
    await (_db.update(_db.captures)..where((t) => t.id.equals(id))).write(
      CapturesCompanion(
        status: Value(status),
        error: error != null
            ? Value(error)
            : (clearError ? const Value(null) : const Value.absent()),
      ),
    );
  }

  Future<void> setTranscript(String id, String transcript) async {
    await (_db.update(_db.captures)..where((t) => t.id.equals(id))).write(
      CapturesCompanion(rawTranscript: Value(transcript)),
    );
  }

  /// Deletes a capture row. The audio file on disk is the caller's problem —
  /// the spec keeps recordings as the source of truth, so only an explicit
  /// user action should ever remove one.
  Future<void> deleteCapture(String id) =>
      (_db.delete(_db.captures)..where((t) => t.id.equals(id))).go();
}
