import 'dart:typed_data';

import 'package:drift/drift.dart';

import '../db/database.dart';

/// One note's stored vector.
class StoredEmbedding {
  const StoredEmbedding(this.noteId, this.vector);

  final String noteId;
  final Float32List vector;
}

class EmbeddingRepository {
  EmbeddingRepository(this._db);

  final AppDatabase _db;

  /// Vectors are stored as raw little-endian float32. Every device Yap runs on
  /// is little-endian, and keeping the bytes native makes the isolate hand-off
  /// a straight buffer view rather than a parse.
  static Uint8List encode(Float32List vector) =>
      vector.buffer.asUint8List(vector.offsetInBytes, vector.lengthInBytes);

  static Float32List decode(Uint8List bytes) {
    // A Float32List view needs 4-byte alignment, which a blob read back from
    // SQLite does not guarantee — copy when it is misaligned.
    if (bytes.offsetInBytes % 4 == 0) {
      return bytes.buffer
          .asFloat32List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
    }
    return Float32List.fromList(
      Uint8List.fromList(bytes).buffer.asFloat32List(),
    );
  }

  Future<void> put(String noteId, String modelId, Float32List vector) =>
      _db.into(_db.embeddings).insertOnConflictUpdate(
            EmbeddingRow(
              noteId: noteId,
              modelId: modelId,
              dims: vector.length,
              vector: encode(vector),
            ),
          );

  Future<void> putAll(
    String modelId,
    Map<String, Float32List> vectorsByNoteId,
  ) async {
    if (vectorsByNoteId.isEmpty) return;
    await _db.batch((batch) {
      for (final entry in vectorsByNoteId.entries) {
        batch.insert(
          _db.embeddings,
          EmbeddingRow(
            noteId: entry.key,
            modelId: modelId,
            dims: entry.value.length,
            vector: encode(entry.value),
          ),
          onConflict: DoUpdate((_) => EmbeddingsCompanion(
                dims: Value(entry.value.length),
                vector: Value(encode(entry.value)),
              )),
        );
      }
    });
  }

  /// Every vector for the given model. Only these are ever compared —
  /// a vector from another model lives in a different space (SPEC.md §8).
  Future<List<StoredEmbedding>> allForModel(String modelId) async {
    final rows = await (_db.select(_db.embeddings)
          ..where((t) => t.modelId.equals(modelId)))
        .get();
    return [
      for (final r in rows) StoredEmbedding(r.noteId, decode(r.vector)),
    ];
  }

  Future<Set<String>> noteIdsWithEmbedding(String modelId) async {
    final rows = await (_db.selectOnly(_db.embeddings)
          ..addColumns([_db.embeddings.noteId])
          ..where(_db.embeddings.modelId.equals(modelId)))
        .get();
    return {for (final r in rows) r.read(_db.embeddings.noteId)!};
  }

  Future<int> countForModel(String modelId) async {
    final count = _db.embeddings.noteId.count();
    final row = await (_db.selectOnly(_db.embeddings)
          ..addColumns([count])
          ..where(_db.embeddings.modelId.equals(modelId)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<void> deleteForNote(String noteId) =>
      (_db.delete(_db.embeddings)..where((t) => t.noteId.equals(noteId))).go();

  /// Drops vectors from models that are no longer selected, freeing the space
  /// they take after a model switch.
  Future<void> deleteOtherModels(String keepModelId) =>
      (_db.delete(_db.embeddings)..where((t) => t.modelId.equals(keepModelId).not()))
          .go();
}
