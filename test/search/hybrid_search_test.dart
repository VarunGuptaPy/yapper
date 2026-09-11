import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/data/db/database.dart';
import 'package:yapapp/data/models/enums.dart';
import 'package:yapapp/data/repositories/embedding_repository.dart';
import 'package:yapapp/data/repositories/note_repository.dart';
import 'package:yapapp/search/embedding_indexer.dart';
import 'package:yapapp/search/hybrid_search.dart';
import 'package:yapapp/services/embedding/openai_compatible_embedding_service.dart';

import '../db/test_db.dart';
import '../fakes.dart';

void main() {
  late AppDatabase db;
  late NoteRepository notes;
  late EmbeddingRepository embeddings;
  late FakeEmbeddingService embedder;
  late EmbeddingIndexer indexer;
  late HybridSearch search;

  setUp(() {
    db = openTestDatabase();
    notes = NoteRepository(db);
    embeddings = EmbeddingRepository(db);
    embedder = FakeEmbeddingService();
    indexer = EmbeddingIndexer(
      notes: notes,
      embeddings: embeddings,
      service: embedder,
    );
    search = HybridSearch(
      notes: notes,
      embeddings: embeddings,
      embeddingService: embedder,
    );
  });

  tearDown(() => db.close());

  Future<NoteRow> given({
    required NoteType type,
    required String title,
    required String body,
    List<String> tags = const [],
    bool index = true,
  }) async {
    final note = await notes.createNote(
      type: type,
      title: title,
      body: body,
      tags: tags,
    );
    if (index) await indexer.indexNote(note.id);
    return note;
  }

  test('finds a note by exact wording through full text', () async {
    final note = await given(
      type: NoteType.person,
      title: 'Ritu Sharma',
      body: 'Freelance video editing, met at a wedding.',
    );

    final hits = await search.search('Ritu');
    expect(hits.map((h) => h.note.id), contains(note.id));
    expect(hits.first.fromText, isTrue);
  });

  test('finds a note by meaning when the wording does not match', () async {
    // "editing" is in the fake vocabulary but not in the query string, so
    // only the vector half can connect these.
    final note = await given(
      type: NoteType.person,
      title: 'Ritu Sharma',
      body: 'Does video editing for brands.',
    );

    final hits = await search.search('editing video');
    final hit = hits.firstWhere((h) => h.note.id == note.id);
    expect(hit.fromVector, isTrue);
  });

  test('a note both halves find is ranked above one only one finds', () async {
    final both = await given(
      type: NoteType.idea,
      title: 'Movie idea',
      body: 'A movie idea about editing.',
    );
    await given(
      type: NoteType.note,
      title: 'Unrelated',
      body: 'Something about food entirely.',
    );

    final hits = await search.search('movie idea');
    expect(hits.first.note.id, both.id);
  });

  test('still returns text results when embeddings are unconfigured', () async {
    final offline = HybridSearch(
      notes: notes,
      embeddings: embeddings,
      embeddingService: const UnconfiguredEmbeddingService('not set up'),
    );
    final note = await given(
      type: NoteType.idea,
      title: 'Kabaddi documentary',
      body: 'Follow one village team.',
    );

    final hits = await offline.search('kabaddi');
    expect(hits.single.note.id, note.id);
    expect(hits.single.fromText, isTrue);
    expect(hits.single.fromVector, isFalse);
  });

  test('degrades to text when the embedding provider throws', () async {
    final note = await given(
      type: NoteType.idea,
      title: 'Kabaddi documentary',
      body: 'Follow one village team.',
    );
    embedder.error = Exception('provider down');

    final hits = await search.search('kabaddi');
    expect(hits.single.note.id, note.id);
    expect(hits.single.fromVector, isFalse);
  });

  test('type filters are applied before ranking', () async {
    await given(
      type: NoteType.idea,
      title: 'Movie idea',
      body: 'About editing video.',
    );
    final person = await given(
      type: NoteType.person,
      title: 'Editor friend',
      body: 'Does video editing.',
    );

    final hits = await search.search(
      'video editing',
      filters: const SearchFilters(types: [NoteType.person]),
    );

    expect(hits, hasLength(1));
    expect(hits.single.note.id, person.id);
  });

  test('tag filters are applied before ranking', () async {
    final tagged = await given(
      type: NoteType.idea,
      title: 'Tagged idea',
      body: 'About movie things.',
      tags: ['film'],
    );
    await given(
      type: NoteType.idea,
      title: 'Untagged idea',
      body: 'About movie things.',
    );

    final hits = await search.search(
      'movie',
      filters: const SearchFilters(tags: ['FILM']),
    );

    expect(hits.map((h) => h.note.id), [tagged.id]);
  });

  test('an empty query returns nothing', () async {
    await given(type: NoteType.note, title: 'x', body: 'y');
    expect(await search.search('   '), isEmpty);
  });

  test('a filter matching no note short-circuits', () async {
    await given(type: NoteType.idea, title: 'Movie', body: 'body');
    final hits = await search.search(
      'movie',
      filters: const SearchFilters(types: [NoteType.goal]),
    );
    expect(hits, isEmpty);
  });

  group('similarTo', () {
    test('returns the closest notes for a transcript', () async {
      final movie = await given(
        type: NoteType.idea,
        title: 'Movie idea',
        body: 'A movie about editing.',
      );
      await given(
        type: NoteType.rule,
        title: 'No food after ten',
        body: 'Personal food rule.',
      );

      final similar = await search.similarTo('another movie idea about editing');
      expect(similar.first.id, movie.id);
    });

    test('returns nothing when embeddings are unconfigured', () async {
      await given(type: NoteType.idea, title: 'Movie', body: 'body');
      final offline = HybridSearch(
        notes: notes,
        embeddings: embeddings,
        embeddingService: const UnconfiguredEmbeddingService('nope'),
      );
      expect(await offline.similarTo('movie'), isEmpty);
    });

    test('honours the limit', () async {
      for (var i = 0; i < 8; i++) {
        await given(
          type: NoteType.idea,
          title: 'Movie idea $i',
          body: 'A movie about editing.',
        );
      }
      final similar = await search.similarTo('movie editing', limit: 3);
      expect(similar, hasLength(3));
    });
  });

  group('indexer', () {
    test('only compares vectors from the current model', () async {
      final note = await given(
        type: NoteType.idea,
        title: 'Movie idea',
        body: 'About editing.',
      );

      // The note is indexed under the old model; the search uses a new one.
      final renamed = HybridSearch(
        notes: notes,
        embeddings: embeddings,
        embeddingService: FakeEmbeddingService(modelId: 'different-model'),
      );

      final hits = await renamed.search('movie editing');
      final hit = hits.firstWhere((h) => h.note.id == note.id);
      expect(hit.fromVector, isFalse,
          reason: 'vectors from another model must be ignored');
    });

    test('indexMissing only embeds notes without a vector', () async {
      await given(type: NoteType.idea, title: 'Indexed', body: 'movie');
      await given(
        type: NoteType.idea,
        title: 'Not indexed',
        body: 'movie',
        index: false,
      );

      final callsBefore = embedder.calls;
      final progress = await indexer.indexMissing().toList();

      expect(progress.last.total, 1);
      expect(progress.last.isComplete, isTrue);
      expect(embedder.calls, callsBefore + 1);
      expect(await embeddings.countForModel(embedder.modelId), 2);
    });

    test('reembedAll covers every note', () async {
      await given(type: NoteType.idea, title: 'One', body: 'movie');
      await given(type: NoteType.idea, title: 'Two', body: 'food');

      final progress = await indexer.reembedAll().toList();
      expect(progress.last.total, 2);
      expect(progress.last.done, 2);
    });

    test('reports an error instead of throwing mid-run', () async {
      await given(type: NoteType.idea, title: 'One', body: 'movie', index: false);
      embedder.error = Exception('rate limited');

      final progress = await indexer.reembedAll().toList();
      expect(progress.last.error, contains('rate limited'));
    });

    test('says so when the model is not configured', () async {
      final unconfigured = EmbeddingIndexer(
        notes: notes,
        embeddings: embeddings,
        service: const UnconfiguredEmbeddingService('nope'),
      );
      final progress = await unconfigured.reembedAll().toList();
      expect(progress.single.error, contains('Settings'));
    });

    test('a failed embed never blocks saving the note', () async {
      embedder.error = Exception('down');
      final note = await notes.createNote(
        type: NoteType.idea,
        title: 'Saved anyway',
        body: 'body',
        tags: const [],
      );

      await indexer.indexNote(note.id);

      expect(await notes.getNote(note.id), isNotNull);
      expect(await embeddings.countForModel(embedder.modelId), 0);
    });
  });
}
