import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/core/errors.dart';
import 'package:yapapp/data/models/enums.dart';
import 'package:yapapp/data/models/structured_note.dart';
import 'package:yapapp/services/llm/llm_models.dart';
import 'package:yapapp/services/structuring/structuring_service.dart';

import '../fakes.dart';

const _valid = '''
{"notes":[{"type":"idea","title":"Time-loop movie",
"body":"A courier reliving one Mumbai delivery run.","tags":["movie"],
"people":[],"merge_target_id":null,"merge_reason":null}]}
''';

void main() {
  group('parser', () {
    const parser = StructuredNoteParser();

    test('parses a well-formed response', () {
      final notes = parser.parse(_valid);
      expect(notes, hasLength(1));
      expect(notes.single.type, NoteType.idea);
      expect(notes.single.title, 'Time-loop movie');
      expect(notes.single.tags, ['movie']);
      expect(notes.single.mergeTargetId, isNull);
    });

    test('parses several notes from one transcript', () {
      final notes = parser.parse('''
{"notes":[
 {"type":"idea","title":"A","body":"b","tags":[],"people":[]},
 {"type":"rule","title":"B","body":"b","tags":[],"people":[]}]}''');
      expect(notes, hasLength(2));
      expect(notes.last.type, NoteType.rule);
    });

    test('tolerates a markdown code fence', () {
      final notes = parser.parse('```json\n$_valid\n```');
      expect(notes, hasLength(1));
    });

    test('reads people and merge fields', () {
      final notes = parser.parse('''
{"notes":[{"type":"person","title":"Ritu","body":"Video editor.",
"tags":["video"],"people":["Ritu Sharma"],
"merge_target_id":"abc-123","merge_reason":"same person"}]}''');
      expect(notes.single.people, ['Ritu Sharma']);
      expect(notes.single.mergeTargetId, 'abc-123');
      expect(notes.single.mergeReason, 'same person');
    });

    test('treats the literal string "null" as null', () {
      final notes = parser.parse('''
{"notes":[{"type":"note","title":"t","body":"b","tags":[],"people":[],
"merge_target_id":"null","merge_reason":""}]}''');
      expect(notes.single.mergeTargetId, isNull);
      expect(notes.single.mergeReason, isNull);
    });

    test('defaults missing tags and people to empty lists', () {
      final notes = parser.parse(
          '{"notes":[{"type":"note","title":"t","body":"b"}]}');
      expect(notes.single.tags, isEmpty);
      expect(notes.single.people, isEmpty);
    });

    group('rejects', () {
      void expectRejected(String raw, Matcher messageMatcher) {
        expect(
          () => parser.parse(raw),
          throwsA(isA<ValidationException>()
              .having((e) => e.message, 'message', messageMatcher)),
        );
      }

      test('non-JSON', () => expectRejected('sorry, I cannot', contains('not valid JSON')));
      test('empty output', () => expectRejected('   ', contains('empty')));
      test('a bare array', () => expectRejected('[]', contains('Top level')));
      test('a missing notes key',
          () => expectRejected('{"items":[]}', contains('Missing required key')));
      test('notes of the wrong type',
          () => expectRejected('{"notes":{}}', contains('must be an array')));
      test('an empty notes array',
          () => expectRejected('{"notes":[]}', contains('at least one note')));
      test('an unknown type', () {
        expectRejected(
          '{"notes":[{"type":"movie","title":"t","body":"b"}]}',
          allOf(contains('notes[0].type'), contains('idea, person, rule, goal, note')),
        );
      });
      test('a missing title', () {
        expectRejected('{"notes":[{"type":"idea","body":"b"}]}',
            contains('notes[0].title is required'));
      });
      test('an empty body', () {
        expectRejected('{"notes":[{"type":"idea","title":"t","body":"  "}]}',
            contains('notes[0].body must not be empty'));
      });
      test('a non-string tag', () {
        expectRejected(
            '{"notes":[{"type":"idea","title":"t","body":"b","tags":[1]}]}',
            contains('notes[0].tags[0] must be a string'));
      });
      test('Devanagari in the body, naming the field', () {
        expectRejected(
          '{"notes":[{"type":"idea","title":"t","body":"मेरा phone number"}]}',
          allOf(contains('notes[0].body'), contains('Devanagari')),
        );
      });
      test('Devanagari in a tag', () {
        expectRejected(
          '{"notes":[{"type":"idea","title":"t","body":"b","tags":["फिल्म"]}]}',
          contains('notes[0].tags[0]'),
        );
      });
      test('the index of the offending note', () {
        expectRejected(
          '{"notes":[{"type":"idea","title":"t","body":"b"},{"type":"nope","title":"t","body":"b"}]}',
          contains('notes[1].type'),
        );
      });
    });
  });

  group('StructuringService', () {
    test('returns notes when the first response is valid', () async {
      final llm = ScriptedLlmService([_valid]);
      final notes =
          await StructuringService(llm).structure(transcript: 'kuch idea hai');

      expect(notes, hasLength(1));
      expect(llm.calls, 1, reason: 'no retry needed');
    });

    test('sends the system prompt and the transcript', () async {
      final llm = ScriptedLlmService([_valid]);
      await StructuringService(llm).structure(transcript: 'my transcript here');

      final messages = llm.received.single;
      expect(messages.first.role, ChatRole.system);
      expect(messages.first.content, contains('Never use Devanagari'));
      expect(messages.last.content, contains('my transcript here'));
      expect(messages.last.content, contains('(none)'),
          reason: 'Phase 1 sends no merge candidates');
    });

    test('offers known names so the model can fix a mangled one', () async {
      final llm = ScriptedLlmService([_valid]);
      await StructuringService(llm).structure(
        transcript: 'transcript',
        knownPeople: ['Parvesh Rawal', 'Manas Mahendra'],
      );

      final user = llm.received.single.last.content!;
      expect(user, contains('Parvesh Rawal'));
      expect(user, contains('Manas Mahendra'));

      // Without this the roster becomes the same trap as keyterm biasing:
      // an unrelated word gets forced onto a known name.
      expect(user, contains('Do NOT replace any other name'));
      expect(user, contains('keep it exactly as transcribed'));
    });

    test('says nothing about people when there are none', () async {
      final llm = ScriptedLlmService([_valid]);
      await StructuringService(llm).structure(transcript: 'transcript');

      expect(
        llm.received.single.last.content,
        isNot(contains('People the speaker already has notes about')),
      );
    });

    test('retries once with the validation error appended', () async {
      final llm = ScriptedLlmService([
        '{"notes":[{"type":"movie","title":"t","body":"b"}]}',
        _valid,
      ]);

      final notes =
          await StructuringService(llm).structure(transcript: 'transcript');

      expect(notes, hasLength(1));
      expect(llm.calls, 2);

      final retry = llm.received.last;
      expect(retry, hasLength(4), reason: 'system, user, assistant, correction');
      expect(retry[2].role, ChatRole.assistant);
      expect(retry[3].content, contains('notes[0].type'),
          reason: 'the model must be told exactly what was wrong');
      expect(retry[3].content, contains('rejected'));
    });

    test('fails after a second invalid response, without a third call', () async {
      final llm = ScriptedLlmService([
        'not json at all',
        '{"notes":[]}',
      ]);

      await expectLater(
        StructuringService(llm).structure(transcript: 'transcript'),
        throwsA(isA<ValidationException>()
            .having((e) => e.message, 'message', contains('invalid notes twice'))),
      );
      expect(llm.calls, 2);
    });

    test('rejects an empty transcript without calling the LLM', () async {
      final llm = ScriptedLlmService([_valid]);
      await expectLater(
        StructuringService(llm).structure(transcript: '   '),
        throwsA(isA<ValidationException>()),
      );
      expect(llm.calls, 0);
    });
  });
}
