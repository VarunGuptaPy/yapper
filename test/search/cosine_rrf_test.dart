import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/data/repositories/embedding_repository.dart';
import 'package:yapapp/search/cosine.dart';
import 'package:yapapp/search/rrf.dart';

Float32List vec(List<double> values) => Float32List.fromList(values);

void main() {
  group('cosineTopK', () {
    test('ranks an identical vector first', () {
      final hits = cosineTopK(CosineRequest(
        query: vec([1, 0, 0]),
        noteIds: const ['orthogonal', 'same', 'close'],
        vectors: [vec([0, 1, 0]), vec([1, 0, 0]), vec([0.9, 0.1, 0])],
        limit: 10,
      ));

      expect(hits.first.noteId, 'same');
      expect(hits.first.score, closeTo(1.0, 1e-6));
      expect(hits[1].noteId, 'close');
      expect(hits.last.noteId, 'orthogonal');
      expect(hits.last.score, closeTo(0.0, 1e-6));
    });

    test('is scale invariant — magnitude must not beat direction', () {
      final hits = cosineTopK(CosineRequest(
        query: vec([1, 1, 0]),
        noteIds: const ['long_wrong', 'short_right'],
        vectors: [vec([100, -100, 0]), vec([0.01, 0.01, 0])],
        limit: 10,
      ));

      expect(hits.first.noteId, 'short_right');
    });

    test('scores an opposite vector at -1', () {
      final hits = cosineTopK(CosineRequest(
        query: vec([1, 2, 3]),
        noteIds: const ['opposite'],
        vectors: [vec([-1, -2, -3])],
        limit: 10,
      ));
      expect(hits.single.score, closeTo(-1.0, 1e-6));
    });

    test('honours the limit', () {
      final hits = cosineTopK(CosineRequest(
        query: vec([1, 0]),
        noteIds: List.generate(50, (i) => 'n$i'),
        vectors: List.generate(50, (i) => vec([1, i / 50])),
        limit: 5,
      ));
      expect(hits, hasLength(5));
    });

    test('skips vectors of a different length instead of crashing', () {
      final hits = cosineTopK(CosineRequest(
        query: vec([1, 0, 0]),
        noteIds: const ['wrong_dims', 'right_dims'],
        vectors: [vec([1, 0]), vec([1, 0, 0])],
        limit: 10,
      ));

      expect(hits, hasLength(1));
      expect(hits.single.noteId, 'right_dims');
    });

    test('skips zero vectors, which have no direction', () {
      final hits = cosineTopK(CosineRequest(
        query: vec([1, 0]),
        noteIds: const ['zero', 'real'],
        vectors: [vec([0, 0]), vec([1, 0])],
        limit: 10,
      ));
      expect(hits.map((h) => h.noteId), ['real']);
    });

    test('an all-zero query returns nothing rather than NaN', () {
      final hits = cosineTopK(CosineRequest(
        query: vec([0, 0]),
        noteIds: const ['a'],
        vectors: [vec([1, 0])],
        limit: 10,
      ));
      expect(hits, isEmpty);
    });
  });

  group('reciprocalRankFusion', () {
    test('a note both retrievers found beats one only one found', () {
      final fused = reciprocalRankFusion([
        ['both', 'text_only'],
        ['both', 'vector_only'],
      ]);
      expect(fused.first, 'both');
    });

    test('preserves order within a single list', () {
      final fused = reciprocalRankFusion([
        ['a', 'b', 'c'],
      ]);
      expect(fused, ['a', 'b', 'c']);
    });

    test('uses the documented k = 60', () {
      expect(defaultRrfK, 60);

      // With k=60, rank 0 scores 1/61 and rank 1 scores 1/62. Two second
      // places (1/62 + 1/62) therefore beat a single first place (1/61).
      final fused = reciprocalRankFusion([
        ['first_once', 'second_twice'],
        ['other', 'second_twice'],
      ]);
      expect(fused.first, 'second_twice');
    });

    test('ignores empty lists', () {
      final fused = reciprocalRankFusion([
        [],
        ['a', 'b'],
        [],
      ]);
      expect(fused, ['a', 'b']);
    });

    test('returns nothing when every list is empty', () {
      expect(reciprocalRankFusion([[], []]), isEmpty);
    });

    test('applies the limit', () {
      final fused = reciprocalRankFusion([
        ['a', 'b', 'c', 'd'],
      ], limit: 2);
      expect(fused, ['a', 'b']);
    });

    test('breaks ties by best rank, deterministically', () {
      // Both appear exactly once at the same rank in different lists.
      final first = reciprocalRankFusion([
        ['x'],
        ['y'],
      ]);
      final second = reciprocalRankFusion([
        ['x'],
        ['y'],
      ]);
      expect(first, second, reason: 'fusion must be stable across runs');
    });
  });

  group('vector encoding', () {
    test('round-trips through the blob format', () {
      final original = vec([0.5, -0.25, 1e-8, 12345.678]);
      final decoded = EmbeddingRepository.decode(
        EmbeddingRepository.encode(original),
      );

      expect(decoded.length, original.length);
      for (var i = 0; i < original.length; i++) {
        expect(decoded[i], closeTo(original[i], 1e-3));
      }
    });

    test('survives a misaligned buffer', () {
      final original = vec([1, 2, 3, 4]);
      final encoded = EmbeddingRepository.encode(original);

      // Simulate a blob handed back at a 1-byte offset.
      final padded = Uint8List(encoded.length + 1)..setRange(1, encoded.length + 1, encoded);
      final misaligned = Uint8List.view(padded.buffer, 1, encoded.length);

      final decoded = EmbeddingRepository.decode(misaligned);
      expect(decoded, [1, 2, 3, 4]);
    });
  });
}
