import 'dart:typed_data';

import '../core/log.dart';
import '../data/db/database.dart';
import '../data/repositories/embedding_repository.dart';
import '../data/repositories/note_repository.dart';
import '../services/embedding/embedding_service.dart';

/// Progress of a bulk re-embed, for the Settings screen.
class ReembedProgress {
  const ReembedProgress({
    required this.done,
    required this.total,
    this.error,
  });

  final int done;
  final int total;
  final String? error;

  bool get isComplete => error == null && done >= total;
  double get fraction => total == 0 ? 1 : done / total;
}

/// Keeps the `embeddings` table in step with the notes.
class EmbeddingIndexer {
  EmbeddingIndexer({
    required this.notes,
    required this.embeddings,
    required this.service,
  });

  final NoteRepository notes;
  final EmbeddingRepository embeddings;
  final EmbeddingService service;

  /// What actually gets embedded: title, body and tags together, so a search
  /// for a tag or a name hits the same vector as a search for the substance.
  static String textFor(NoteRow note) {
    final buffer = StringBuffer()
      ..writeln(note.title)
      ..writeln(note.body);
    if (note.tags.isNotEmpty) buffer.writeln(note.tags.join(', '));
    return buffer.toString().trim();
  }

  bool get isConfigured => service.modelId.isNotEmpty;

  /// Embeds one note. Failures are logged, never thrown: a note that cannot be
  /// embedded is still perfectly usable, it just won't show up in semantic
  /// results until the next successful index.
  Future<void> indexNote(String noteId) async {
    if (!isConfigured) return;
    try {
      final note = await notes.getNote(noteId);
      if (note == null) return;
      final vectors = await service.embed([textFor(note)]);
      if (vectors.isEmpty) return;
      await embeddings.put(noteId, service.modelId, vectors.first);
    } catch (e) {
      logE('Indexer', 'could not embed note', e);
    }
  }

  /// Embeds notes that have no vector for the current model — the cheap catch
  /// up after adding a key, or after notes were saved while offline.
  Stream<ReembedProgress> indexMissing() =>
      _index(onlyMissing: true);

  /// Re-embeds everything, used after changing the embedding model.
  Stream<ReembedProgress> reembedAll() => _index(onlyMissing: false);

  Stream<ReembedProgress> _index({required bool onlyMissing}) async* {
    if (!isConfigured) {
      yield const ReembedProgress(
        done: 0,
        total: 0,
        error: 'Add your embedding model in Settings first.',
      );
      return;
    }

    final all = await notes.allNotes();
    final existing = onlyMissing
        ? await embeddings.noteIdsWithEmbedding(service.modelId)
        : const <String>{};
    final pending = [
      for (final note in all)
        if (!existing.contains(note.id)) note,
    ];

    final total = pending.length;
    if (total == 0) {
      yield const ReembedProgress(done: 0, total: 0);
      return;
    }

    var done = 0;
    yield ReembedProgress(done: 0, total: total);

    const chunk = 32;
    for (var i = 0; i < pending.length; i += chunk) {
      final end = (i + chunk).clamp(0, pending.length);
      final batch = pending.sublist(i, end);

      try {
        final vectors = await service.embed([for (final n in batch) textFor(n)]);
        final map = <String, Float32List>{};
        for (var j = 0; j < batch.length && j < vectors.length; j++) {
          map[batch[j].id] = vectors[j];
        }
        await embeddings.putAll(service.modelId, map);
      } catch (e) {
        logE('Indexer', 'bulk embed failed', e);
        yield ReembedProgress(
          done: done,
          total: total,
          error: e is Exception ? '$e'.replaceFirst('Exception: ', '') : '$e',
        );
        return;
      }

      done += batch.length;
      yield ReembedProgress(done: done, total: total);
    }
  }
}
