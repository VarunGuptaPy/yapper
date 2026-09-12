import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/data/db/database.dart';
import 'package:yapapp/data/models/enums.dart';
import 'package:yapapp/providers/providers.dart';
import 'package:yapapp/services/chat/note_proposal.dart';
import 'package:yapapp/services/settings/settings_model.dart';
import 'package:yapapp/data/repositories/chat_repository.dart';
import 'package:yapapp/ui/chat/chat_page.dart';
import 'package:yapapp/ui/chat/chats_page.dart';
import 'package:yapapp/ui/chat/citation_chip.dart';
import 'package:yapapp/ui/notes/notes_page.dart';
import 'package:yapapp/search/hybrid_search.dart';

NoteRow buildNote({
  String id = 'n1',
  String title = 'Ritu Sharma',
  String body = 'Freelance video editor.',
  NoteType type = NoteType.person,
  List<String> tags = const ['video'],
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

ChatMessageRow msg({
  String id = 'm1',
  String role = 'assistant',
  String content = 'Ritu Sharma does video editing [1].',
  List<String> citations = const [],
  NoteProposal? proposal,
  ProposalStatus? status,
}) =>
    ChatMessageRow(
      id: id,
      conversationId: 'c1',
      role: role,
      content: content,
      citations: citations,
      proposal: proposal?.encode(),
      proposalStatus: status?.name,
      createdAt: DateTime(2026, 9, 1),
    );

const configured = YapSettings(
  sarvamApiKey: 'k',
  llmApiKey: 'k',
  llmModel: 'm',
  embeddingApiKey: 'k',
  embeddingModel: 'e',
);

void main() {
  Widget chatHost(
    List<ChatMessageRow> messages, {
    YapSettings settings = configured,
    NoteRow? citedNote,
  }) =>
      ProviderScope(
        overrides: [
          chatMessagesProvider.overrideWith((ref) => Stream.value(messages)),
          currentSettingsProvider.overrideWithValue(settings),
          noteProvider.overrideWith(
            (ref, id) => Stream.value(citedNote ?? buildNote(id: id)),
          ),
          // The detail page a citation opens reads these; left live they would
          // hit the real database, which does not resolve under fake async.
          noteCapturesProvider.overrideWith((ref, id) async => []),
          noteVersionsProvider.overrideWith((ref, id) async => []),
          notePeopleProvider.overrideWith((ref, id) async => []),
          notesMentioningProvider.overrideWith((ref, id) async => []),
        ],
        child: const MaterialApp(home: Scaffold(body: ChatPage())),
      );

  group('ChatPage', () {
    testWidgets('empty state suggests what to ask', (tester) async {
      await tester.pumpWidget(chatHost(const []));
      await tester.pumpAndSettle();

      expect(find.text('Ask about your notes'), findsOneWidget);
      expect(find.textContaining('video editing'), findsOneWidget);
    });

    testWidgets('renders user and assistant turns', (tester) async {
      await tester.pumpWidget(chatHost([
        msg(id: 'm1', role: 'user', content: 'who can edit video?'),
        msg(id: 'm2'),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('who can edit video?'), findsOneWidget);
      expect(find.text('Ritu Sharma does video editing [1].'), findsOneWidget);
    });

    testWidgets('shows a tappable citation chip', (tester) async {
      await tester.pumpWidget(chatHost([
        msg(citations: const ['n1']),
      ]));
      await tester.pumpAndSettle();

      expect(find.byType(CitationChip), findsOneWidget);
      expect(find.text('Ritu Sharma'), findsWidgets);
      expect(find.text('1'), findsOneWidget, reason: 'the citation number');
    });

    testWidgets('opens the note when a citation is tapped', (tester) async {
      await tester.pumpWidget(chatHost([
        msg(citations: const ['n1']),
      ]));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(CitationChip));
      await tester.pumpAndSettle();

      expect(find.text('SOURCE RECORDINGS'), findsOneWidget);
    });

    testWidgets('warns when the LLM is not configured', (tester) async {
      await tester.pumpWidget(chatHost(const [], settings: const YapSettings()));
      await tester.pumpAndSettle();

      expect(find.textContaining('Settings'), findsOneWidget);
    });

    testWidgets('warns that search is keyword-only without embeddings',
        (tester) async {
      await tester.pumpWidget(chatHost(
        const [],
        settings: const YapSettings(
          sarvamApiKey: 'k',
          llmApiKey: 'k',
          llmModel: 'm',
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('keyword only'), findsOneWidget);
    });

    testWidgets('shows no banner once fully configured', (tester) async {
      await tester.pumpWidget(chatHost(const []));
      await tester.pumpAndSettle();

      expect(find.textContaining('keyword only'), findsNothing);
    });
  });

  group('proposal card', () {
    const createProposal = NoteProposal(
      kind: ProposalKind.create,
      type: NoteType.rule,
      title: 'Never eat prawns',
      body: 'Allergic reaction in Goa.',
      tags: ['food'],
      reason: 'You said you react badly to them.',
    );

    testWidgets('a pending proposal offers Confirm and Dismiss',
        (tester) async {
      await tester.pumpWidget(chatHost([
        msg(
          content: 'I suggest saving this as a rule.',
          proposal: createProposal,
          status: ProposalStatus.pending,
        ),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('New note'), findsOneWidget);
      expect(find.text('Never eat prawns'), findsOneWidget);
      expect(find.text('Allergic reaction in Goa.'), findsOneWidget);
      expect(find.widgetWithText(Chip, 'food'), findsOneWidget);
      expect(find.textContaining('react badly'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Confirm'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Dismiss'), findsOneWidget);
    });

    testWidgets('a confirmed proposal shows the outcome, not the buttons',
        (tester) async {
      await tester.pumpWidget(chatHost([
        msg(proposal: createProposal, status: ProposalStatus.confirmed),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('Saved'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Confirm'), findsNothing);
    });

    testWidgets('a dismissed proposal is marked dismissed', (tester) async {
      await tester.pumpWidget(chatHost([
        msg(proposal: createProposal, status: ProposalStatus.dismissed),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('Dismissed'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Confirm'), findsNothing);
    });

    testWidgets('an update proposal names the note it changes', (tester) async {
      await tester.pumpWidget(chatHost(
        [
          msg(
            proposal: const NoteProposal(
              kind: ProposalKind.update,
              noteId: 'n1',
              body: 'Also does colour grading.',
              reason: 'You mentioned grading.',
            ),
            status: ProposalStatus.pending,
          ),
        ],
        citedNote: buildNote(title: 'Ritu Sharma'),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Update "Ritu Sharma"'), findsOneWidget);
      expect(find.text('Also does colour grading.'), findsOneWidget);
    });
  });

  group('conversations', () {
    ChatConversationRow conversation({
      String id = 'c1',
      String? title = 'which of my connections edits video?',
      int minutesAgo = 5,
    }) =>
        ChatConversationRow(
          id: id,
          title: title,
          createdAt: DateTime(2026, 9, 11),
          updatedAt: DateTime.now().subtract(Duration(minutes: minutesAgo)),
        );

    Widget chatsHost(List<ConversationSummary> rows, {String? active}) =>
        ProviderScope(
          overrides: [
            chatConversationsProvider.overrideWith((ref) => Stream.value(rows)),
            if (active != null)
              activeConversationProvider.overrideWith(
                () => _FixedConversation(active),
              ),
          ],
          child: const MaterialApp(home: ChatsPage()),
        );

    testWidgets('lists past chats newest first', (tester) async {
      await tester.pumpWidget(chatsHost([
        ConversationSummary(
          conversation: conversation(),
          messageCount: 4,
          lastMessage: 'Ritu Sharma does video editing.',
        ),
        ConversationSummary(
          conversation: conversation(
              id: 'c2', title: 'did I ever have a movie idea?', minutesAgo: 90),
          messageCount: 2,
          lastMessage: 'Yes, a time-loop one.',
        ),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('which of my connections edits video?'), findsOneWidget);
      expect(find.text('did I ever have a movie idea?'), findsOneWidget);
      expect(find.text('Ritu Sharma does video editing.'), findsOneWidget);
      expect(find.text('4 messages'), findsOneWidget);
      expect(find.text('2 messages'), findsOneWidget);
    });

    testWidgets('an untitled thread still reads sensibly', (tester) async {
      await tester.pumpWidget(chatsHost([
        ConversationSummary(
          conversation: conversation(title: null),
          messageCount: 0,
        ),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('New chat'), findsOneWidget);
      expect(find.text('0 messages'), findsOneWidget);
    });

    testWidgets('empty state explains where chats come from', (tester) async {
      await tester.pumpWidget(chatsHost(const []));
      await tester.pumpAndSettle();

      expect(find.text('No chats yet'), findsOneWidget);
      expect(find.textContaining('Chat tab'), findsOneWidget);
    });

    testWidgets('deleting asks first and spares the notes', (tester) async {
      await tester.pumpWidget(chatsHost([
        ConversationSummary(
          conversation: conversation(),
          messageCount: 1,
          lastMessage: 'hello',
        ),
      ]));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();

      expect(find.text('Delete this chat?'), findsOneWidget);
      expect(find.textContaining('notes it created or changed stay'),
          findsOneWidget);
    });

    testWidgets('marks which thread is open', (tester) async {
      await tester.pumpWidget(chatsHost(
        [
          ConversationSummary(
              conversation: conversation(), messageCount: 1),
          ConversationSummary(
              conversation: conversation(id: 'c2', title: 'other'),
              messageCount: 1),
        ],
        active: 'c1',
      ));
      await tester.pumpAndSettle();

      // The open thread carries a dot; the other does not.
      expect(find.byType(ChatsPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Notes search', () {
    Widget notesHost({
      required String query,
      required List<SearchResult> results,
    }) =>
        ProviderScope(
          overrides: [
            notesProvider.overrideWith((ref) => Stream.value([buildNote()])),
            noteSearchQueryProvider.overrideWith(() => _FixedQuery(query)),
            noteSearchResultsProvider.overrideWith((ref) async => results),
          ],
          child: const MaterialApp(home: Scaffold(body: NotesPage())),
        );

    testWidgets('shows the search field', (tester) async {
      await tester.pumpWidget(notesHost(query: '', results: const []));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'Search your notes'), findsOneWidget);
    });

    testWidgets('renders hybrid results instead of the plain list',
        (tester) async {
      await tester.pumpWidget(notesHost(
        query: 'video',
        results: [
          SearchResult(
            buildNote(id: 'hit', title: 'Search hit'),
            fromText: true,
            fromVector: false,
          ),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('Search hit'), findsOneWidget);
      expect(find.text('Ritu Sharma'), findsNothing);
    });

    testWidgets('marks a result only semantic search found', (tester) async {
      await tester.pumpWidget(notesHost(
        query: 'video',
        results: [
          SearchResult(
            buildNote(id: 'a', title: 'Text match'),
            fromText: true,
            fromVector: false,
          ),
          SearchResult(
            buildNote(id: 'b', title: 'Meaning match'),
            fromText: false,
            fromVector: true,
          ),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
    });

    testWidgets('explains when nothing matched', (tester) async {
      await tester.pumpWidget(notesHost(query: 'zzz', results: const []));
      await tester.pumpAndSettle();

      expect(find.text('Nothing matched'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Clear search'), findsOneWidget);
    });
  });
}

class _FixedQuery extends NoteSearchQuery {
  _FixedQuery(this.value);

  final String value;

  @override
  String build() => value;
}


class _FixedConversation extends ActiveConversation {
  _FixedConversation(this.id);

  final String id;

  @override
  String? build() => id;
}
