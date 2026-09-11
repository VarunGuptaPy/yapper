import 'package:flutter/foundation.dart';

import '../core/log.dart';
import '../data/db/database.dart';
import '../data/models/enums.dart';
import '../data/repositories/embedding_repository.dart';
import '../data/repositories/note_repository.dart';
import '../services/embedding/embedding_service.dart';
import 'cosine.dart';
import 'rrf.dart';

/// Optional narrowing applied *before* ranking, so filters never push a
/// relevant note out of the top-20 windows (SPEC.md §8).
class SearchFilters {
  const SearchFilters({this.types = const [], this.tags = const []});

  final List<NoteType> types;
  final List<String> tags;

  bool get isEmpty => types.isEmpty && tags.isEmpty;

  bool matches(NoteRow note) {
    if (types.isNotEmpty && !types.contains(note.type)) return false;
    if (tags.isNotEmpty) {
      final lower = {for (final t in note.tags) t.toLowerCase()};
      if (!tags.any((t) => lower.contains(t.toLowerCase()))) return false;
    }
    return true;
  }
}

class SearchResult {
  const SearchResult(this.note, {required this.fromText, required this.fromVector});

  final NoteRow note;

  /// Which retriever found it — useful for explaining a result, and for
  /// telling "nothing matched" apart from "semantic search is unavailable".
  final bool fromText;
  final bool fromVector;
}

/// FTS5 BM25 and cosine similarity, fused with RRF.
class HybridSearch {
  HybridSearch({
    required this.notes,
    required this.embeddings,
    required this.embeddingService,
  });

  static const candidateWindow = 20;

  final NoteRepository notes;
  final EmbeddingRepository embeddings;
  final EmbeddingService embeddingService;

  /// Runs both retrievers and fuses them.
  ///
  /// Semantic search is best-effort: if embeddings are unconfigured or the
  /// provider is down, this still returns full-text results rather than
  /// failing the whole search.
  Future<List<SearchResult>> search(
    String query, {
    SearchFilters filters = const SearchFilters(),
    int limit = 20,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    final allowed = await _allowedIds(filters);
    if (allowed != null && allowed.isEmpty) return const [];

    final textRanked = await _textSearch(trimmed, allowed);
    final vectorRanked = await _vectorSearch(trimmed, allowed);

    final fused = reciprocalRankFusion(
      [
        if (textRanked.isNotEmpty) textRanked,
        if (vectorRanked.isNotEmpty) vectorRanked,
      ],
      limit: limit,
    );
    if (fused.isEmpty) return const [];

    final rows = await notes.notesByIds(fused);
    final byId = {for (final r in rows) r.id: r};
    final textSet = textRanked.toSet();
    final vectorSet = vectorRanked.toSet();

    return [
      for (final id in fused)
        if (byId[id] != null)
          SearchResult(
            byId[id]!,
            fromText: textSet.contains(id),
            fromVector: vectorSet.contains(id),
          ),
    ];
  }

  /// Null means "no filter": every note is eligible.
  Future<Set<String>?> _allowedIds(SearchFilters filters) async {
    if (filters.isEmpty) return null;
    final all = await notes.allNotes();
    return {
      for (final note in all)
        if (filters.matches(note)) note.id,
    };
  }

  Future<List<String>> _textSearch(String query, Set<String>? allowed) async {
    // Over-fetch when filtering so the window still holds 20 eligible notes.
    final hits = await notes.searchFts(
      query,
      limit: allowed == null ? candidateWindow : candidateWindow * 4,
    );
    final ids = [
      for (final hit in hits)
        if (allowed == null || allowed.contains(hit.noteId)) hit.noteId,
    ];
    return ids.length <= candidateWindow
        ? ids
        : ids.sublist(0, candidateWindow);
  }

  Future<List<String>> _vectorSearch(String query, Set<String>? allowed) async {
    final modelId = embeddingService.modelId;
    if (modelId.isEmpty) return const [];

    try {
      final stored = await embeddings.allForModel(modelId);
      if (stored.isEmpty) return const [];

      final eligible = [
        for (final e in stored)
          if (allowed == null || allowed.contains(e.noteId)) e,
      ];
      if (eligible.isEmpty) return const [];

      final queryVectors = await embeddingService.embed([query]);
      if (queryVectors.isEmpty) return const [];

      final hits = await compute(
        cosineTopK,
        CosineRequest(
          query: queryVectors.first,
          noteIds: [for (final e in eligible) e.noteId],
          vectors: [for (final e in eligible) e.vector],
          limit: candidateWindow,
        ),
      );
      return [for (final hit in hits) hit.noteId];
    } catch (e) {
      // Degrade to full-text rather than failing the search outright.
      logE('Search', 'semantic search unavailable', e);
      return const [];
    }
  }

  /// The notes most similar to a transcript, used by the capture pipeline to
  /// offer merge candidates (SPEC.md §7.3).
  Future<List<NoteRow>> similarTo(String text, {int limit = 5}) async {
    final ids = await _vectorSearch(text, null);
    if (ids.isEmpty) return const [];

    final capped = ids.length <= limit ? ids : ids.sublist(0, limit);
    final rows = await notes.notesByIds(capped);
    final byId = {for (final r in rows) r.id: r};
    return [
      for (final id in capped)
        if (byId[id] != null) byId[id]!,
    ];
  }
}
