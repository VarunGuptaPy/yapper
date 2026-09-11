import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/data/db/database.dart';
import 'package:yapapp/data/models/enums.dart';
import 'package:yapapp/providers/providers.dart';
import 'package:yapapp/ui/capture/voice_waveform.dart';
import 'package:yapapp/ui/chat/chat_markdown.dart';
import 'package:yapapp/ui/common/patterns.dart';
import 'package:yapapp/ui/theme.dart';

NoteRow buildNote({String id = 'n1', String title = 'Ritu Sharma'}) => NoteRow(
      id: id,
      type: NoteType.person,
      title: title,
      body: 'Freelance video editor.',
      tags: const [],
      createdAt: DateTime(2026, 9, 1),
      updatedAt: DateTime(2026, 9, 1),
    );

/// Collects rendered text from the whole tree.
///
/// MarkdownBody renders selectable content through SelectableText rather than
/// a plain RichText, so looking at only one of them misses the prose.
String renderedText(WidgetTester tester) {
  final buffer = StringBuffer();
  for (final widget in tester.allWidgets) {
    switch (widget) {
      case SelectableText(:final textSpan, :final data):
        buffer.write(' ${textSpan?.toPlainText() ?? data ?? ''}');
      case RichText(:final text):
        buffer.write(' ${text.toPlainText()}');
      case Text(:final data, :final textSpan):
        buffer.write(' ${data ?? textSpan?.toPlainText() ?? ''}');
    }
  }
  return buffer.toString();
}

/// Text from every span that carries a tap recognizer — i.e. the live links.
String tappableSpanText(WidgetTester tester) {
  final buffer = StringBuffer();
  for (final widget in tester.allWidgets) {
    final InlineSpan? root = switch (widget) {
      SelectableText(:final textSpan) => textSpan,
      RichText(:final text) => text,
      _ => null,
    };
    root?.visitChildren((span) {
      if (span is TextSpan && span.recognizer != null) {
        buffer.write(span.text ?? '');
      }
      return true;
    });
  }
  return buffer.toString();
}

Widget themed(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: brightness == Brightness.light ? YapTheme.light() : YapTheme.dark(),
      home: Scaffold(body: child),
    );

void main() {
  group('theme', () {
    test('both brightnesses carry the accent extension', () {
      for (final theme in [YapTheme.light(), YapTheme.dark()]) {
        final accents = theme.extension<YapAccents>();
        expect(accents, isNotNull);
        expect(accents!.waveform, hasLength(3));
      }
    });

    test('every note type gets its own colour', () {
      final theme = YapTheme.light();
      final accents = theme.extension<YapAccents>()!;
      final colours = {
        accents.idea,
        accents.person,
        accents.rule,
        accents.goal,
        accents.neutral,
      };
      expect(colours, hasLength(5), reason: 'types must be distinguishable');
    });

    testWidgets('note type colours resolve from context', (tester) async {
      late Color idea;
      late Color person;
      await tester.pumpWidget(themed(Builder(builder: (context) {
        idea = noteTypeColor(context, 'idea');
        person = noteTypeColor(context, 'person');
        return const SizedBox();
      })));
      expect(idea, isNot(person));
    });

    testWidgets('display styles use the bundled serif', (tester) async {
      late TextTheme text;
      await tester.pumpWidget(themed(Builder(builder: (context) {
        text = Theme.of(context).textTheme;
        return const SizedBox();
      })));
      expect(text.headlineLarge?.fontFamily, 'InstrumentSerif');
      expect(text.titleLarge?.fontFamily, 'InstrumentSerif');
      // Body text stays on the platform font so Devanagari in raw transcripts
      // still renders correctly.
      expect(text.bodyMedium?.fontFamily, isNot('InstrumentSerif'));
    });
  });

  group('VoiceWaveform', () {
    testWidgets('settles when idle, so it is not repainting forever',
        (tester) async {
      await tester.pumpWidget(
        themed(const VoiceWaveform(level: 0, active: false)),
      );
      // Would time out if the animation clock kept scheduling frames.
      await tester.pumpAndSettle();
      expect(find.byType(VoiceWaveform), findsOneWidget);
    });

    testWidgets('animates while recording', (tester) async {
      await tester.pumpWidget(
        themed(const VoiceWaveform(level: 0.8, active: true)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.binding.hasScheduledFrame, isTrue);
    });

    testWidgets('starts its clock when recording begins', (tester) async {
      await tester.pumpWidget(
        themed(const VoiceWaveform(level: 0, active: false)),
      );
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        themed(const VoiceWaveform(level: 0.6, active: true)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.binding.hasScheduledFrame, isTrue);
    });

    testWidgets('drains and stops after recording ends', (tester) async {
      await tester.pumpWidget(
        themed(const VoiceWaveform(level: 0.9, active: true)),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.pumpWidget(
        themed(const VoiceWaveform(level: 0, active: false)),
      );
      // The trailing wave is allowed to settle, then the clock parks itself.
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      expect(find.byType(VoiceWaveform), findsOneWidget);
    });

    testWidgets('renders in dark mode too', (tester) async {
      await tester.pumpWidget(themed(
        const VoiceWaveform(level: 0.4, active: false),
        brightness: Brightness.dark,
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('patterns', () {
    for (final pattern in YapPattern.values) {
      testWidgets('${pattern.name} paints without error', (tester) async {
        await tester.pumpWidget(themed(
          SizedBox(
            width: 300,
            height: 200,
            child: PatternBackdrop(pattern: pattern, child: const Text('hi')),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('hi'), findsOneWidget);
      });
    }

    testWidgets('survives a zero-size box', (tester) async {
      await tester.pumpWidget(themed(
        const SizedBox(
          width: 0,
          height: 0,
          child: PatternBackdrop(pattern: YapPattern.asanoha),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('MotifDivider renders', (tester) async {
      await tester.pumpWidget(themed(const MotifDivider()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('ChatMarkdown', () {
    Widget host(String content, {List<String> citations = const []}) =>
        ProviderScope(
          overrides: [
            noteProvider.overrideWith((ref, id) => Stream.value(buildNote(id: id))),
            noteCapturesProvider.overrideWith((ref, id) async => []),
            noteVersionsProvider.overrideWith((ref, id) async => []),
            notePeopleProvider.overrideWith((ref, id) async => []),
            notesMentioningProvider.overrideWith((ref, id) async => []),
          ],
          child: MaterialApp(
            theme: YapTheme.light(),
            home: Scaffold(
              body: ChatMarkdown(content: content, citations: citations),
            ),
          ),
        );

    testWidgets('renders plain prose', (tester) async {
      await tester.pumpWidget(host('Just a sentence.'));
      await tester.pumpAndSettle();
      expect(renderedText(tester), contains('Just a sentence.'));
    });

    testWidgets('renders bold and bullet lists as markdown', (tester) async {
      await tester.pumpWidget(host('**Bold** text\n\n- one\n- two'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final texts = renderedText(tester);
      expect(texts, contains('Bold'));
      expect(texts, contains('one'));
      expect(texts, contains('two'));
    });

    testWidgets('renders a citation as a marker, not as raw markdown',
        (tester) async {
      await tester.pumpWidget(
        host('Ritu can help [1].', citations: const ['n1']),
      );
      await tester.pumpAndSettle();

      final texts = renderedText(tester);
      expect(texts, contains('[1]'),
          reason: 'a bare digit would read as part of the sentence');

      // The rewrite builds a markdown link. If any of it leaks through as
      // literal text the sentence is ruined, and `contains('[1]')` alone does
      // not catch that — the broken form contains it too.
      expect(texts, isNot(contains('yapnote')));
      expect(texts, isNot(contains(r'$_scheme')));
      expect(texts, isNot(contains('citations[')));
      expect(texts, isNot(contains('](')));
      expect(texts, isNot(contains(r'\[')));
      expect(texts, contains('Ritu can help [1].'),
          reason: 'the sentence must read exactly as written');
    });

    testWidgets('a citation is a live link, not just styled text',
        (tester) async {
      await tester.pumpWidget(
        host('Ritu can help [1].', citations: const ['n1']),
      );
      await tester.pumpAndSettle();

      expect(tappableSpanText(tester), contains('[1]'),
          reason: 'the marker must carry a tap recognizer to open the note');
    });

    testWidgets('a marker with no citation behind it is not a link',
        (tester) async {
      await tester.pumpWidget(host('See [4].', citations: const ['n1']));
      await tester.pumpAndSettle();

      expect(tappableSpanText(tester), isEmpty);
    });

    testWidgets('leaves a marker with no matching citation alone',
        (tester) async {
      await tester.pumpWidget(host('See [4].', citations: const ['n1']));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final texts = renderedText(tester);
      expect(texts, contains('[4]'));
      expect(texts, isNot(contains('yapnote')));
    });

    testWidgets('renders text containing no citations unchanged',
        (tester) async {
      await tester.pumpWidget(host('No markers here at all.'));
      await tester.pumpAndSettle();
      expect(renderedText(tester), contains('No markers here at all.'));
    });
  });
}
