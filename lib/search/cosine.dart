import 'dart:math' as math;
import 'dart:typed_data';

/// A note id with its similarity to the query, highest first.
class SimilarityHit {
  const SimilarityHit(this.noteId, this.score);

  final String noteId;
  final double score;
}

/// The payload handed to the isolate. Plain data so it transfers cheaply.
class CosineRequest {
  const CosineRequest({
    required this.query,
    required this.noteIds,
    required this.vectors,
    required this.limit,
  });

  final Float32List query;
  final List<String> noteIds;
  final List<Float32List> vectors;
  final int limit;
}

/// Brute-force cosine similarity over every candidate vector.
///
/// Top-level and free of app state so it can run under `compute` in a
/// background isolate, keeping a few thousand dot products off the UI thread
/// (SPEC.md §3, §8).
List<SimilarityHit> cosineTopK(CosineRequest request) {
  final query = request.query;
  final queryNorm = _norm(query);
  if (queryNorm == 0) return const [];

  final hits = <SimilarityHit>[];
  for (var i = 0; i < request.vectors.length; i++) {
    final vector = request.vectors[i];
    // Vectors from a different model, or a truncated row, cannot be compared.
    if (vector.length != query.length) continue;

    final norm = _norm(vector);
    if (norm == 0) continue;

    var dot = 0.0;
    for (var j = 0; j < vector.length; j++) {
      dot += query[j] * vector[j];
    }
    hits.add(SimilarityHit(request.noteIds[i], dot / (queryNorm * norm)));
  }

  hits.sort((a, b) => b.score.compareTo(a.score));
  return hits.length <= request.limit ? hits : hits.sublist(0, request.limit);
}

double _norm(Float32List v) {
  var sum = 0.0;
  for (var i = 0; i < v.length; i++) {
    sum += v[i] * v[i];
  }
  return sum <= 0 ? 0 : math.sqrt(sum);
}
