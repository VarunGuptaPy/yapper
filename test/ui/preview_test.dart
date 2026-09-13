@Tags(['preview'])
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/data/db/database.dart';
import 'package:yapapp/data/models/enums.dart';
import 'package:yapapp/providers/providers.dart';
import 'package:yapapp/services/chat/note_proposal.dart';
import 'package:yapapp/services/settings/settings_model.dart';
import 'package:yapapp/ui/capture/capture_page.dart';
import 'package:yapapp/ui/chat/chat_page.dart';
import 'package:yapapp/ui/notes/note_detail_page.dart';
import 'package:yapapp/ui/notes/notes_page.dart';
import 'package:yapapp/ui/theme.dart';

/// Renders populated screens to PNG so the design can be reviewed without a
/// device. Run with:
///   flutter test test/ui/preview_test.dart --update-goldens --tags preview
/// The images land in test/ui/previews/.
const _previewBodyFont = 'PreviewBody';
bool _bodyFontLoaded = false;

/// Finds Flutter's bundled Roboto and Material icon font.
///
/// `Platform.resolvedExecutable` is the Dart VM inside the SDK
/// (`flutter/bin/cache/dart-sdk/bin/dart`), so the fonts sit a few levels up
/// under `artifacts/`. Walking up beats hard-coding a depth that changes
/// between Flutter versions.
Directory? _materialFonts() {
  final candidates = <String>[];

  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null && root.isNotEmpty) {
    candidates.add('$root/bin/cache/artifacts/material_fonts');
  }

  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 6; i++) {
    candidates.add('${dir.path}/artifacts/material_fonts');
    dir = dir.parent;
  }

  for (final path in candidates) {
    final directory = Directory(path);
    if (directory.existsSync()) return directory;
  }
  return null;
}

ThemeData withPreviewFont(ThemeData theme) {
  if (!_bodyFontLoaded) return theme;

  TextStyle? body(TextStyle? style) =>
      style?.fontFamily == 'InstrumentSerif'
          ? style
          : style?.copyWith(fontFamily: _previewBodyFont);

  WidgetStateProperty<TextStyle?>? buttonText(ButtonStyle? style) {
    final resolved = style?.textStyle?.resolve({});
    return WidgetStatePropertyAll(body(resolved ?? const TextStyle()));
  }

  final t = theme.textTheme;
  return theme.copyWith(
    textTheme: t.copyWith(
      bodyLarge: body(t.bodyLarge),
      bodyMedium: body(t.bodyMedium),
      bodySmall: body(t.bodySmall),
      labelLarge: body(t.labelLarge),
      labelMedium: body(t.labelMedium),
      labelSmall: body(t.labelSmall),
      titleMedium: body(t.titleMedium),
      titleSmall: body(t.titleSmall),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: theme.filledButtonTheme.style
          ?.copyWith(textStyle: buttonText(theme.filledButtonTheme.style)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: theme.outlinedButtonTheme.style
          ?.copyWith(textStyle: buttonText(theme.outlinedButtonTheme.style)),
    ),
    chipTheme: theme.chipTheme.copyWith(
      labelStyle: body(theme.chipTheme.labelStyle),
    ),
    navigationBarTheme: theme.navigationBarTheme.copyWith(
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => body(
          theme.navigationBarTheme.labelTextStyle?.resolve(states),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(() async {
    final serif = FontLoader('InstrumentSerif')
      ..addFont(rootBundle.load('assets/fonts/InstrumentSerif-Regular.ttf'));
    await serif.load();

    // The test renderer ships no real fonts, so everything would come out as
    // Ahem boxes and these previews would say nothing about the design.
    // Flutter's own cache has Roboto and the Material icon font, which is
    // exactly what the app uses on a device.
    final fonts = _materialFonts();
    if (fonts == null) {
      debugPrint('PREVIEW: no material_fonts found — text will be Ahem boxes');
      return;
    }
    debugPrint('PREVIEW: fonts from ${fonts.path}');

    Future<ByteData> read(String name) async => ByteData.view(
          Uint8List.fromList(
            await File('${fonts.path}/$name').readAsBytes(),
          ).buffer,
        );

    final body = FontLoader(_previewBodyFont);
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      final file = File('${fonts.path}/Roboto-$weight.ttf');
      if (file.existsSync()) body.addFont(read('Roboto-$weight.ttf'));
    }
    await body.load();

    final icons = File('${fonts.path}/MaterialIcons-Regular.otf');
    if (icons.existsSync()) {
      await (FontLoader('MaterialIcons')
            ..addFont(read('MaterialIcons-Regular.otf')))
          .load();
    }

    _bodyFontLoaded = true;
  });

  NoteRow note({
    required String id,
    required String title,
    required String body,
    required NoteType type,
    List<String> tags = const [],
    int daysAgo = 1,
  }) =>
      NoteRow(
        id: id,
        type: type,
        title: title,
        body: body,
        tags: tags,
        createdAt: DateTime(2026, 9, 1),
        updatedAt: DateTime(2026, 9, 11).subtract(Duration(days: daysAgo)),
      );

  final notes = [
    note(
      id: 'n1',
      title: 'Time-loop delivery movie',
      body: 'A courier in Mumbai reliving one monsoon delivery run. '
          'Each loop he learns one more thing about the woman at the last stop.',
      type: NoteType.idea,
      tags: ['movie', 'scifi'],
    ),
    note(
      id: 'n2',
      title: 'Ritu Sharma',
      body: 'Freelance video editor, met at the Goa wedding shoot. '
          'Does colour grading too. Happy to help on short films.',
      type: NoteType.person,
      tags: ['video', 'editing'],
      daysAgo: 3,
    ),
    note(
      id: 'n3',
      title: 'Never eat prawns',
      body: 'Bad reaction in Goa, twice. Not worth testing a third time.',
      type: NoteType.rule,
      tags: ['food'],
      daysAgo: 9,
    ),
    note(
      id: 'n4',
      title: 'Ship Yap by December',
      body: 'Daily voice notes for a month, then decide if it is worth '
          'putting on the Play Store.',
      type: NoteType.goal,
      tags: ['yap'],
      daysAgo: 20,
    ),
  ];

  final chat = [
    ChatMessageRow(
      id: 'm1',
      conversationId: 'c1',
      role: 'user',
      content: 'which of my connections could help with video editing?',
      citations: const [],
      createdAt: DateTime(2026, 9, 11, 10),
    ),
    ChatMessageRow(
      id: 'm2',
      conversationId: 'c1',
      role: 'assistant',
      content: '**Ritu Sharma** is your one editor [1]. She freelances on '
          'video and also does colour grading, and you met her at the Goa '
          'wedding shoot.\n\nWorth knowing:\n\n- She offered to help on short '
          'films\n- Your time-loop idea [2] would need exactly this',
      citations: const ['n2', 'n1'],
      createdAt: DateTime(2026, 9, 11, 10, 1),
    ),
    ChatMessageRow(
      id: 'm3',
      conversationId: 'c1',
      role: 'user',
      content: 'remember I should never eat prawns',
      citations: const [],
      createdAt: DateTime(2026, 9, 11, 10, 2),
    ),
    ChatMessageRow(
      id: 'm4',
      conversationId: 'c1',
      role: 'assistant',
      content: 'You already have that as a rule, so here is an update '
          'instead of a duplicate.',
      citations: const [],
      proposal: const NoteProposal(
        kind: ProposalKind.update,
        noteId: 'n3',
        body: 'Bad reaction in Goa, twice. Not worth testing a third time. '
            'Confirmed again in conversation.',
        reason: 'You repeated it, so worth reinforcing the note.',
      ).encode(),
      proposalStatus: 'pending',
      createdAt: DateTime(2026, 9, 11, 10, 3),
    ),
  ];

  final deleteChat = [
    ChatMessageRow(
      id: 'd1',
      conversationId: 'c1',
      role: 'user',
      content: 'delete the prawns rule, I tested it and I am fine',
      citations: const [],
      createdAt: DateTime(2026, 9, 13, 10),
    ),
    ChatMessageRow(
      id: 'd2',
      conversationId: 'c1',
      role: 'assistant',
      content: 'That rule is the only note about prawns, so here it is.',
      citations: const [],
      proposal: const NoteProposal(
        kind: ProposalKind.delete,
        noteId: 'n3',
        title: 'Never eat prawns',
        reason: 'You said you tested it and reacted fine.',
      ).encode(),
      proposalStatus: 'pending',
      createdAt: DateTime(2026, 9, 13, 10, 1),
    ),
  ];

  Widget app(
    Widget child,
    Brightness brightness, {
    List<ChatMessageRow>? chatMessages,
  }) {
    final messages = chatMessages ?? chat;
    return ProviderScope(
        overrides: [
          notesProvider.overrideWith((ref) => Stream.value(notes)),
          noteProvider.overrideWith(
            (ref, id) => Stream.value(notes.firstWhere((n) => n.id == id)),
          ),
          noteCapturesProvider.overrideWith((ref, id) async => [
                CaptureRow(
                  id: 'c1',
                  audioPath: '/audio/c1.m4a',
                  durationMs: 42000,
                  rawTranscript: 'mera ek idea hai, time loop movie '
                      'about a courier in Mumbai',
                  status: CaptureStatus.saved,
                  createdAt: DateTime(2026, 9, 1),
                ),
              ]),
          noteVersionsProvider.overrideWith((ref, id) async => [
                NoteVersionRow(
                  id: 'v1',
                  noteId: id,
                  title: 'Time-loop movie',
                  body: 'A courier reliving one delivery run.',
                  tags: const ['movie'],
                  changedAt: DateTime(2026, 9, 5),
                  changeSource: ChangeSource.voiceMerge,
                ),
              ]),
          notePeopleProvider.overrideWith(
            (ref, id) async => [notes[1]],
          ),
          notesMentioningProvider.overrideWith((ref, id) async => []),
          noteSearchResultsProvider.overrideWith((ref) async => const []),
          chatMessagesProvider.overrideWith((ref) => Stream.value(messages)),
          // ChatPage watches this to decide whether to offer 'Past chats'.
          chatConversationsProvider.overrideWith((ref) => Stream.value(const [])),
          recentCapturesProvider.overrideWith((ref) => Stream.value(const [])),
          currentSettingsProvider.overrideWithValue(const YapSettings(
            sarvamApiKey: 'k',
            llmApiKey: 'k',
            llmModel: 'm',
            embeddingApiKey: 'k',
            embeddingModel: 'e',
          )),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: withPreviewFont(
            brightness == Brightness.light
                ? YapTheme.light()
                : YapTheme.dark(),
          ),
          home: child,
        ),
      );
  }

  Future<void> shoot(
    WidgetTester tester,
    String name,
    Widget child, {
    Brightness brightness = Brightness.light,
    List<ChatMessageRow>? chatMessages,
  }) async {
    await tester.binding.setSurfaceSize(const Size(412, 900));
    await tester.pumpWidget(app(child, brightness, chatMessages: chatMessages));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../../docs/screenshots/$name.png'),
    );
  }

  testWidgets('notes list', (tester) async {
    await shoot(
      tester,
      'notes_light',
      const Scaffold(body: SafeArea(child: NotesPage())),
    );
  });

  testWidgets('notes list dark', (tester) async {
    await shoot(
      tester,
      'notes_dark',
      const Scaffold(body: SafeArea(child: NotesPage())),
      brightness: Brightness.dark,
    );
  });

  testWidgets('note detail', (tester) async {
    await shoot(tester, 'note_detail_light', const NoteDetailPage(noteId: 'n1'));
  });

  testWidgets('chat', (tester) async {
    await shoot(
      tester,
      'chat_light',
      const Scaffold(body: SafeArea(child: ChatPage())),
    );
  });

  testWidgets('capture', (tester) async {
    await shoot(tester, 'capture_light',
        const Scaffold(body: SafeArea(child: CapturePage())));
  });

  testWidgets('capture dark', (tester) async {
    await shoot(tester, 'capture_dark',
        const Scaffold(body: SafeArea(child: CapturePage())),
        brightness: Brightness.dark);
  });

  testWidgets('note detail dark', (tester) async {
    await shoot(tester, 'note_detail_dark', const NoteDetailPage(noteId: 'n1'),
        brightness: Brightness.dark);
  });

  testWidgets('chat delete proposal', (tester) async {
    await shoot(
      tester,
      'chat_delete',
      const Scaffold(body: SafeArea(child: ChatPage())),
      chatMessages: deleteChat,
    );
  });

  testWidgets('chat dark', (tester) async {
    await shoot(
      tester,
      'chat_dark',
      const Scaffold(body: SafeArea(child: ChatPage())),
      brightness: Brightness.dark,
    );
  });
}
