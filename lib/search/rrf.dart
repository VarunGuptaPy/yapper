/// Reciprocal Rank Fusion: merges independently-ranked lists without needing
/// their scores to be on comparable scales (SPEC.md §8).
///
/// BM25 is lower-is-better and unbounded; cosine is higher-is-better in
/// [-1, 1]. Fusing by *rank* sidesteps normalising between them, and a note
/// that both methods like outranks one that only one of them found.
library;

const defaultRrfK = 60;

/// Fuses ranked lists of note ids. Each list must already be in its own
/// best-first order.
List<String> reciprocalRankFusion(
  List<List<String>> rankedLists, {
  int k = defaultRrfK,
  int? limit,
}) {
  final scores = <String, double>{};
  // Ties are broken by the best rank any list gave a note, so the order is
  // deterministic rather than dependent on map iteration.
  final bestRank = <String, int>{};

  for (final list in rankedLists) {
    for (var rank = 0; rank < list.length; rank++) {
      final id = list[rank];
      scores[id] = (scores[id] ?? 0) + 1.0 / (k + rank + 1);
      final previous = bestRank[id];
      if (previous == null || rank < previous) bestRank[id] = rank;
    }
  }

  final fused = scores.keys.toList()
    ..sort((a, b) {
      final byScore = scores[b]!.compareTo(scores[a]!);
      if (byScore != 0) return byScore;
      return bestRank[a]!.compareTo(bestRank[b]!);
    });

  if (limit == null || fused.length <= limit) return fused;
  return fused.sublist(0, limit);
}
