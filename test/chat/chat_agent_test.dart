import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/data/db/database.dart';
import 'package:yapapp/data/models/enums.dart';
import 'package:yapapp/data/repositories/embedding_repository.dart';
import 'package:yapapp/data/repositories/note_repository.dart';
import 'package:yapapp/search/hybrid_search.dart';
import 'package:yapapp/services/chat/chat_agent.dart';
import 'package:yapapp/services/chat/chat_tools.dart';
import 'package:yapapp/services/chat/note_proposal.dart';
import 'package:yapapp/services/llm/llm_models.dart';
import 'package:yapapp/services/llm/llm_service.dart';

import '../db/test_db.dart';
import '../fakes.dart';

/// Replays scripted turns: either a plain answer, or a set of tool calls.
class ScriptedToolLlm implements LlmService {
  ScriptedToolLlm(this.turns);

  final List<Object> turns;
  int calls = 0;
  final List<List<ChatMessage>> received = [];
  final List<List<ToolDefinition>> toolsOffered = [];

  @override
  Future<LlmResponse> complete(
    List<ChatMessage> messages, {
    bool jsonMode = false,
    List<ToolDefinition> tools = const [],
    double temperature = 0.2,
  }) async {
    received.add(List.of(messages));
    toolsOffered.add(tools);
    if (calls >= turns.length) {
      throw StateError('ScriptedToolLlm ran out of turns');
    }
    final turn = turns[calls++];
    if (turn is String) return LlmResponse(content: turn);
    return LlmResponse(toolCalls: turn as List<ToolCall>);
  }
}

ToolCall call(String name, Map<String, dynamic> args, {String id = 'c1'}) =>
    ToolCall(id: id, name: name, argumentsJson: jsonEncode(args));

void main() {
  late AppDatabase db;
  late NoteRepository notes;
  late ChatToolRunner runner;

  setUp(() {
    db = openTestDatabase();
    notes = NoteRepository(db);
    final embedder = FakeEmbeddingService();
    runner = ChatToolRunner(
      notes: notes,
      search: HybridSearch(
        notes: notes,
        embeddings: EmbeddingRepository(db),
        embeddingService: embedder,
      ),
    );
  });

  tearDown(() => db.close());

  Future<NoteRow> givenNote({
    NoteType type = NoteType.person,
    String title = 'Ritu Sharma',
    String body = 'Freelance video editing, met at a wedding shoot.',
    List<String> tags = const ['video'],
  }) =>
      notes.createNote(type: type, title: title, body: body, tags: tags);

  group('tools', () {
    test('search_notes returns notes with refs and ids', () async {
      final note = await givenNote();
      final outcome = await runner.run(call('search_notes', {'query': 'Ritu'}));
      final result = jsonDecode(outcome.resultJson) as Map<String, dynamic>;

      expect(result['count'], 1);
      final first = (result['notes'] as List).first as Map;
      expect(first['id'], note.id);
      expect(first['ref'], 1);
      expect(first['title'], 'Ritu Sharma');
    });

    test('search_notes hints when nothing matched', () async {
      final outcome =
          await runner.run(call('search_notes', {'query': 'nonexistent'}));
      final result = jsonDecode(outcome.resultJson) as Map<String, dynamic>;
      expect(result['count'], 0);
      expect(result['hint'], contains('Nothing matched'));
    });

    test('search_notes requires a query', () async {
      final outcome = await runner.run(call('search_notes', {}));
      expect(jsonDecode(outcome.resultJson), containsPair('error', isNotNull));
    });

    test('list_notes filters by type', () async {
      await givenNote();
      await givenNote(type: NoteType.idea, title: 'Movie idea', body: 'b');

      final outcome = await runner.run(call('list_notes', {'type': 'person'}));
      final result = jsonDecode(outcome.resultJson) as Map<String, dynamic>;

      expect(result['count'], 1);
      expect(((result['notes'] as List).first as Map)['title'], 'Ritu Sharma');
    });

    test('list_notes rejects an unknown type', () async {
      final outcome = await runner.run(call('list_notes', {'type': 'movie'}));
      expect(jsonDecode(outcome.resultJson), containsPair('error', isNotNull));
    });

    test('get_note returns linked people', () async {
      final person = await givenNote();
      final idea = await givenNote(
        type: NoteType.idea,
        title: 'Short film',
        body: 'Needs an editor.',
      );
      await notes.linkPerson(idea.id, person.id);

      final outcome = await runner.run(call('get_note', {'id': idea.id}));
      final result = jsonDecode(outcome.resultJson) as Map<String, dynamic>;

      expect(result['title'], 'Short film');
      expect((result['people'] as List).single, containsPair('title', 'Ritu Sharma'));
    });

    test('get_note reports a missing id', () async {
      final outcome = await runner.run(call('get_note', {'id': 'nope'}));
      expect(jsonDecode(outcome.resultJson), containsPair('error', isNotNull));
    });

    test('malformed arguments produce an error, not a crash', () async {
      final outcome = await runner.run(
        const ToolCall(id: 'x', name: 'search_notes', argumentsJson: 'not json'),
      );
      expect(jsonDecode(outcome.resultJson), containsPair('error', isNotNull));
    });

    test('an unknown tool is reported back to the model', () async {
      final outcome = await runner.run(call('delete_everything', {}));
      expect(
        (jsonDecode(outcome.resultJson) as Map)['error'],
        contains('Unknown tool'),
      );
    });

    test('refs are stable across calls for the same note', () async {
      await givenNote();
      await runner.run(call('search_notes', {'query': 'Ritu'}));
      final second = await runner.run(call('search_notes', {'query': 'Ritu'}));
      final notesOut = (jsonDecode(second.resultJson) as Map)['notes'] as List;
      expect((notesOut.first as Map)['ref'], 1);
    });
  });

  group('proposals', () {
    test('propose_create_note does not write', () async {
      final outcome = await runner.run(call('propose_create_note', {
        'type': 'rule',
        'title': 'Never eat prawns',
        'body': 'Allergic reaction in Goa.',
        'tags': ['food'],
      }));

      expect(outcome.proposal, isNotNull);
      expect(outcome.proposal!.kind, ProposalKind.create);
      expect(outcome.proposal!.type, NoteType.rule);
      expect(outcome.proposal!.title, 'Never eat prawns');
      expect(await notes.allNotes(), isEmpty,
          reason: 'nothing may be written before the user confirms');
    });

    test('propose_create_note validates its fields', () async {
      final outcome = await runner.run(call('propose_create_note', {
        'type': 'rule',
        'title': '  ',
        'body': 'b',
      }));
      expect(outcome.proposal, isNull);
      expect(jsonDecode(outcome.resultJson), containsPair('error', isNotNull));
    });

    test('propose_update_note targets an existing note', () async {
      final note = await givenNote();
      final outcome = await runner.run(call('propose_update_note', {
        'id': note.id,
        'new_body': 'Also does colour grading.',
        'reason': 'You mentioned colour grading.',
      }));

      expect(outcome.proposal!.kind, ProposalKind.update);
      expect(outcome.proposal!.noteId, note.id);
      expect(outcome.proposal!.body, 'Also does colour grading.');
      expect(outcome.proposal!.tags, isNull, reason: 'tags were not mentioned');
      expect((await notes.getNote(note.id))!.body, isNot(contains('colour')));
    });

    test('propose_update_note rejects a no-op', () async {
      final note = await givenNote();
      final outcome = await runner.run(call('propose_update_note', {
        'id': note.id,
        'reason': 'because',
      }));
      expect(outcome.proposal, isNull);
      expect(
        (jsonDecode(outcome.resultJson) as Map)['error'],
        contains('Nothing to change'),
      );
    });

    test('a proposal survives the JSON round trip', () async {
      final outcome = await runner.run(call('propose_create_note', {
        'type': 'idea',
        'title': 'T',
        'body': 'B',
        'tags': ['x', 'y'],
      }));
      final decoded = NoteProposal.decode(outcome.proposal!.encode())!;

      expect(decoded.kind, ProposalKind.create);
      expect(decoded.type, NoteType.idea);
      expect(decoded.tags, ['x', 'y']);
    });
  });

  group('citations', () {
    test('maps [n] markers back to note ids', () async {
      final note = await givenNote();
      await runner.run(call('search_notes', {'query': 'Ritu'}));

      final cited = runner.normalizeCitations('Ritu can help [1].');
      expect(cited.noteIds, [note.id]);
      expect(cited.text, 'Ritu can help [1].');
    });

    test('ignores references the model invented', () async {
      await givenNote();
      await runner.run(call('search_notes', {'query': 'Ritu'}));

      final cited = runner.normalizeCitations('See [7].');
      expect(cited.noteIds, isEmpty);
      expect(cited.text, 'See [7].', reason: 'left alone, not silently renumbered');
    });

    test('de-duplicates repeated citations', () async {
      final note = await givenNote();
      await runner.run(call('search_notes', {'query': 'Ritu'}));

      final cited = runner.normalizeCitations('[1] and again [1]');
      expect(cited.noteIds, [note.id]);
      expect(cited.text, '[1] and again [1]');
    });

    test('renumbers so the text matches the citation chips', () async {
      final a = await givenNote(title: 'Ritu Sharma');
      final b = await givenNote(title: 'Ritu Desai', body: 'Also an editor.');
      // Put both notes in the ref table, then cite only the second and a
      // nonexistent one — the model's numbering is now out of step.
      await runner.run(call('search_notes', {'query': 'Ritu'}));

      final refs = runner.references;
      final refForB = refs.entries.firstWhere((e) => e.value == b.id).key;

      final cited = runner.normalizeCitations('Only this one matters [$refForB].');

      expect(cited.noteIds, [b.id]);
      expect(cited.text, 'Only this one matters [1].',
          reason: 'chips are numbered by position, so the text must be too');
      expect(cited.noteIds, isNot(contains(a.id)));
    });
  });

  group('agent loop', () {
    test('searches, then answers with citations', () async {
      final note = await givenNote();
      final llm = ScriptedToolLlm([
        [call('search_notes', {'query': 'video editing'})],
        'Ritu Sharma does video editing [1].',
      ]);

      final answer =
          await ChatAgent(llm: llm, runner: runner).ask('who can edit video?');

      expect(answer.content, contains('Ritu Sharma'));
      expect(answer.citedNoteIds, [note.id]);
      expect(llm.calls, 2);
    });

    test('offers the tools on every round', () async {
      final llm = ScriptedToolLlm(['No notes yet.']);
      await ChatAgent(llm: llm, runner: runner).ask('hello');

      final names = llm.toolsOffered.first.map((t) => t.name);
      expect(
        names,
        containsAll([
          'search_notes',
          'list_notes',
          'get_note',
          'propose_create_note',
          'propose_update_note',
        ]),
      );
    });

    test('sends the system prompt and prior turns', () async {
      final llm = ScriptedToolLlm(['ok']);
      await ChatAgent(llm: llm, runner: runner).ask(
        'and what else?',
        history: [
          ChatMessageRow(
            id: 'm1',
            role: 'user',
            content: 'earlier question',
            citations: const [],
            createdAt: DateTime(2026, 9, 1),
          ),
          ChatMessageRow(
            id: 'm2',
            role: 'assistant',
            content: 'earlier answer',
            citations: const [],
            createdAt: DateTime(2026, 9, 1),
          ),
        ],
      );

      final sent = llm.received.single;
      expect(sent.first.role, ChatRole.system);
      expect(sent.first.content, contains('search the notes first'));
      expect(sent[1].content, 'earlier question');
      expect(sent[2].content, 'earlier answer');
      expect(sent.last.content, 'and what else?');
    });

    test('handles several tool calls in one round', () async {
      await givenNote();
      final llm = ScriptedToolLlm([
        [
          call('search_notes', {'query': 'Ritu'}, id: 'a'),
          call('list_notes', {'type': 'person'}, id: 'b'),
        ],
        'Found them [1].',
      ]);

      final answer = await ChatAgent(llm: llm, runner: runner).ask('who?');
      expect(answer.citedNoteIds, hasLength(1));

      // Each tool call must be answered by a matching tool message.
      final second = llm.received[1];
      final toolMessages =
          second.where((m) => m.role == ChatRole.tool).toList();
      expect(toolMessages.map((m) => m.toolCallId), ['a', 'b']);
    });

    test('carries a proposal out of the loop', () async {
      final llm = ScriptedToolLlm([
        [
          call('propose_create_note', {
            'type': 'rule',
            'title': 'Never eat prawns',
            'body': 'Allergic reaction in Goa.',
          })
        ],
        'I have suggested a rule.',
      ]);

      final answer = await ChatAgent(llm: llm, runner: runner)
          .ask('remember I cannot eat prawns');

      expect(answer.proposal, isNotNull);
      expect(answer.proposal!.title, 'Never eat prawns');
    });

    test('stops after five tool rounds and forces an answer', () async {
      await givenNote();
      final llm = ScriptedToolLlm([
        for (var i = 0; i < ChatAgent.maxToolRounds; i++)
          [call('search_notes', {'query': 'again'})],
        'Fine, here is what I found.',
      ]);

      final answer = await ChatAgent(llm: llm, runner: runner).ask('loop?');

      expect(answer.content, 'Fine, here is what I found.');
      expect(llm.calls, ChatAgent.maxToolRounds + 1);
      // The forcing turn must not offer tools, or the loop never ends.
      expect(llm.toolsOffered.last, isEmpty);
    });

    test('an empty answer with nothing proposed is an error', () async {
      final llm = ScriptedToolLlm(['   ']);
      await expectLater(
        ChatAgent(llm: llm, runner: runner).ask('hi'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
