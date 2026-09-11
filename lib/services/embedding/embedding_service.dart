import 'dart:typed_data';

/// Turns text into vectors for semantic search (SPEC.md §5).
abstract class EmbeddingService {
  /// Identifies the model that produced a vector. Stored alongside every
  /// embedding so vectors from different models are never compared —
  /// their coordinate spaces are unrelated.
  String get modelId;

  /// Embeds a batch. The result is parallel to [texts].
  Future<List<Float32List>> embed(List<String> texts);
}
