import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/data/db/database.dart';
import 'package:yapapp/data/models/enums.dart';
import 'package:yapapp/providers/providers.dart';
import 'package:yapapp/services/settings/settings_model.dart';
import 'package:yapapp/ui/capture/capture_page.dart';
import 'package:yapapp/ui/capture/recordings_page.dart';
import 'package:yapapp/ui/capture/note_edit_sheet.dart';
import 'package:yapapp/ui/notes/note_detail_page.dart';
import 'package:yapapp/ui/notes/notes_page.dart';

/// These tests stub the providers rather than using a real drift database:
/// drift's asynchronous queries do not resolve under `flutter_test`'s fake
/// clock, and the database itself is covered directly in `test/db`.

NoteRow buildNote({
  String id = 'n1',
  String title = 'Time-loop movie',
  String body = 'A courier reliving one Mumbai delivery run.',
  NoteType type = NoteType.idea,
  List<String> tags = const ['movie'],
}) =>
    NoteRow(
      id: id,
      type: type,
      title: title,
      body: body,
      tags: tags,
      createdAt: DateTime(2026, 9, 1),
      updatedAt: DateTime(2026, 9, 1),
    );

CaptureRow buildCapture({
  String id = 'c1',
  CaptureStatus status = CaptureStatus.saved,
  String? transcript,
  String? error,
  int durationMs = 12000,
}) =>
    CaptureRow(
      id: id,
      audioPath: '/audio/$id.m4a',
      durationMs: durationMs,
      rawTranscript: transcript,
      status: status,
      error: error,
      createdAt: DateTime(2026, 9, 1),
    );

/// Riverpod 3 does not export its `Override` type, so tests build the
/// ProviderScope themselves and use this only for the app frame.
Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('CapturePage', () {
    Widget capture({
      YapSettings settings = const YapSettings(
        sarvamApiKey: 'k',
        llmApiKey: 'k',
        llmModel: 'm',
      ),
      List<CaptureRow> rows = const [],
    }) =>
        ProviderScope(
          overrides: [
            recentCapturesProvider.overrideWith((ref) => Stream.value(rows)),
            currentSettingsProvider.overrideWithValue(settings),
          ],
          child: host(const CapturePage()),
        );

    testWidgets('idle state shows the timer and prompt', (tester) async {
      await tester.pumpWidget(capture());
      await tester.pumpAndSettle();

      expect(find.text('00:00'), findsOneWidget);
      expect(find.text('Tap to start talking'), findsOneWidget);
      expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
    });

    testWidgets('carries only the recording controls, not the archive',
        (tester) async {
      await tester.pumpWidget(capture(rows: [
        buildCapture(status: CaptureStatus.saved, transcript: 'old thought'),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('old thought'), findsNothing,
          reason: 'past recordings belong on the Recordings page');
      expect(find.text('RECENT'), findsNothing);
    });

    testWidgets('warns when Settings is incomplete', (tester) async {
      await tester.pumpWidget(capture(settings: const YapSettings()));
      await tester.pumpAndSettle();

      expect(find.textContaining('Sarvam API key'), findsOneWidget);
    });

    testWidgets('hides the warning once configured', (tester) async {
      await tester.pumpWidget(capture());
      await tester.pumpAndSettle();

      expect(find.textContaining('in Settings'), findsNothing);
    });

    testWidgets('surfaces notes waiting to be reviewed', (tester) async {
      await tester.pumpWidget(capture(rows: [
        buildCapture(status: CaptureStatus.awaitingReview),
        buildCapture(id: 'c2', status: CaptureStatus.awaitingReview),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('2 notes to review'), findsOneWidget);
    });

    testWidgets('surfaces a failed recording', (tester) async {
      await tester.pumpWidget(capture(rows: [
        buildCapture(status: CaptureStatus.failed, error: 'Sarvam said no'),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('1 recording failed'), findsOneWidget);
    });

    testWidgets('review takes priority over a failure in the pill',
        (tester) async {
      await tester.pumpWidget(capture(rows: [
        buildCapture(status: CaptureStatus.failed),
        buildCapture(id: 'c2', status: CaptureStatus.awaitingReview),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('1 note to review'), findsOneWidget);
      expect(find.text('1 recording failed'), findsNothing);
    });

    testWidgets('stays quiet when there is nothing pending', (tester) async {
      await tester.pumpWidget(capture(rows: [
        buildCapture(status: CaptureStatus.saved),
      ]));
      await tester.pumpAndSettle();

      expect(find.byType(PendingWorkPill), findsOneWidget);
      expect(find.textContaining('to review'), findsNothing);
      expect(find.textContaining('failed'), findsNothing);
    });
  });

  group('RecordingsPage', () {
    Widget recordings(List<CaptureRow> rows) => ProviderScope(
          overrides: [
            recentCapturesProvider.overrideWith((ref) => Stream.value(rows)),
          ],
          child: const MaterialApp(home: RecordingsPage()),
        );

    testWidgets('empty state explains what to do', (tester) async {
      await tester.pumpWidget(recordings(const []));
      await tester.pumpAndSettle();

      expect(find.text('Nothing recorded yet'), findsOneWidget);
    });

    testWidgets('a capture awaiting review offers Review', (tester) async {
      await tester.pumpWidget(recordings([
        buildCapture(
          status: CaptureStatus.awaitingReview,
          transcript: 'mera ek idea hai',
        ),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('Needs review'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Review'), findsOneWidget);
      expect(find.text('mera ek idea hai'), findsOneWidget);
    });

    testWidgets('a failed capture shows the error and a Retry button',
        (tester) async {
      await tester.pumpWidget(recordings([
        buildCapture(
          status: CaptureStatus.failed,
          error: 'Sarvam rejected your API key.',
        ),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('Failed'), findsOneWidget);
      expect(find.text('Sarvam rejected your API key.'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);
    });

    testWidgets('an offline capture reads as Queued, not Failed',
        (tester) async {
      await tester.pumpWidget(recordings([
        buildCapture(
          status: CaptureStatus.recorded,
          error: 'Waiting for a connection…',
        ),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('Queued'), findsOneWidget);
      expect(find.text('Failed'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsNothing);
    });

    testWidgets('an in-flight capture shows a spinner', (tester) async {
      await tester.pumpWidget(recordings([
        buildCapture(status: CaptureStatus.transcribing),
      ]));
      await tester.pump();

      expect(find.text('Transcribing'), findsOneWidget);
    });
  });

  group('NotesPage', () {
    testWidgets('lists notes', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          notesProvider.overrideWith((ref) => Stream.value([
                buildNote(),
                buildNote(id: 'n2', title: 'Ritu Sharma', type: NoteType.person),
              ])),
        ],
        child: host(const NotesPage()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Time-loop movie'), findsOneWidget);
      expect(find.text('Ritu Sharma'), findsOneWidget);
    });

    testWidgets('offers a chip per note type plus All', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [notesProvider.overrideWith((ref) => Stream.value([]))],
        child: host(const NotesPage()),
      ));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilterChip, 'All'), findsOneWidget);
      for (final type in NoteType.values) {
        expect(find.widgetWithText(FilterChip, type.label), findsOneWidget);
      }
    });

    testWidgets('selecting a chip updates the filter', (tester) async {
      late NoteType? observed;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          notesProvider.overrideWith((ref) {
            observed = ref.watch(noteTypeFilterProvider);
            return Stream.value([]);
          }),
        ],
        child: host(const NotesPage()),
      ));
      await tester.pumpAndSettle();
      expect(observed, isNull);

      await tester.tap(find.widgetWithText(FilterChip, 'Person'));
      await tester.pumpAndSettle();

      expect(observed, NoteType.person);
    });

    testWidgets('empty state explains where notes come from', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [notesProvider.overrideWith((ref) => Stream.value([]))],
        child: host(const NotesPage()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('No notes yet'), findsOneWidget);
      expect(find.textContaining('Capture tab'), findsOneWidget);
    });
  });

  group('NoteDetailPage', () {
    Widget detail({
      List<CaptureRow> captures = const [],
      List<NoteVersionRow> versions = const [],
    }) =>
        ProviderScope(
          overrides: [
            noteProvider.overrideWith((ref, id) => Stream.value(buildNote())),
            noteCapturesProvider.overrideWith((ref, id) async => captures),
            noteVersionsProvider.overrideWith((ref, id) async => versions),
          ],
          child: const MaterialApp(home: NoteDetailPage(noteId: 'n1')),
        );

    testWidgets('renders title, body and tags', (tester) async {
      await tester.pumpWidget(detail());
      await tester.pumpAndSettle();

      expect(find.text('Time-loop movie'), findsOneWidget);
      expect(find.text('A courier reliving one Mumbai delivery run.'),
          findsOneWidget);
      expect(find.widgetWithText(Chip, 'movie'), findsOneWidget);
      expect(find.text('IDEA'), findsOneWidget,
          reason: 'the type badge is set in small caps');
    });

    testWidgets('says so when there is no recording behind the note',
        (tester) async {
      await tester.pumpWidget(detail());
      await tester.pumpAndSettle();

      expect(
        find.text('This note was written by hand — no recording behind it.'),
        findsOneWidget,
      );
      expect(find.text('No edits yet.'), findsOneWidget);
    });

    testWidgets('shows a source recording with its raw transcript',
        (tester) async {
      await tester.pumpWidget(detail(captures: [
        buildCapture(transcript: 'mera ek idea hai, time loop movie'),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('Raw transcript'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

      await tester.tap(find.text('Raw transcript'));
      await tester.pumpAndSettle();
      expect(find.text('mera ek idea hai, time loop movie'), findsOneWidget);
    });

    testWidgets('lists version history with its change source', (tester) async {
      await tester.pumpWidget(detail(versions: [
        NoteVersionRow(
          id: 'v1',
          noteId: 'n1',
          title: 'Old title',
          body: 'Old body',
          tags: const [],
          changedAt: DateTime(2026, 8, 30),
          changeSource: ChangeSource.manualEdit,
        ),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('Old title'), findsOneWidget);
      expect(find.textContaining('Edited by hand'), findsOneWidget);
    });
  });

  group('NoteEditSheet', () {
    testWidgets('returns the edited draft', (tester) async {
      NoteDraft? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                result = await NoteEditSheet.show(
                  context,
                  heading: 'Edit note',
                  initial: const NoteDraft(
                    type: NoteType.idea,
                    title: 'Original',
                    body: 'Body',
                    tags: ['one'],
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Original'), 'Edited title');
      await tester.tap(find.widgetWithText(ChoiceChip, 'Rule'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.title, 'Edited title');
      expect(result!.type, NoteType.rule);
      expect(result!.tags, ['one']);
    });

    testWidgets('refuses to save an empty title', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: NoteEditSheet(
          initial: NoteDraft(
            type: NoteType.idea,
            title: 'Original',
            body: 'Body',
            tags: [],
          ),
          heading: 'Edit note',
          saveLabel: 'Save',
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Original'), '   ');
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.text('Give it a title'), findsOneWidget);
    });
  });

}
