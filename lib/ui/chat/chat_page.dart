import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../providers/chat_controller.dart';
import '../../providers/providers.dart';
import '../../services/chat/note_proposal.dart';
import '../common/empty_state.dart';
import '../common/patterns.dart';
import 'chat_markdown.dart';
import 'citation_chip.dart';
import 'proposal_card.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    await ref.read(chatControllerProvider.notifier).send(text);
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(chatMessagesProvider);
    final chat = ref.watch(chatControllerProvider);
    final settings = ref.watch(currentSettingsProvider);
    final theme = Theme.of(context);

    ref.listen(chatControllerProvider, (previous, next) {
      final error = next.error;
      if (error != null && error != previous?.error) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error)));
        ref.read(chatControllerProvider.notifier).dismissError();
      }
    });

    return Column(
      children: [
        if (!settings.isStructuringConfigured)
          _Banner(
            message: settings.missingSetupMessage ??
                'Finish setting up the LLM in Settings.',
          )
        else if (!settings.isEmbeddingConfigured)
          const _Banner(
            message: 'Without an embedding model, chat searches your notes by '
                'keyword only. Add one in Settings for meaning-based search.',
          ),
        Expanded(
          child: messages.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => EmptyState(
              icon: Icons.error_outline,
              title: 'Could not load the conversation',
              message: '$e',
            ),
            data: (rows) => rows.isEmpty
                ? const PatternBackdrop(
                    pattern: YapPattern.kolam,
                    scale: 34,
                    child: EmptyState(
                      icon: Icons.forum_outlined,
                      title: 'Ask about your notes',
                      message: 'Try "which of my connections could help with '
                          'video editing?" or "did I ever have a movie idea?"',
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
                    itemCount: rows.length,
                    itemBuilder: (context, i) => _MessageBubble(message: rows[i]),
                  ),
          ),
        ),
        if (chat.sending) const _Thinking(),
        const Divider(height: 1),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: 'Ask about your notes…',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide(
                          color: theme.colorScheme.primary,
                          width: 1.6,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 13,
                      ),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: chat.sending ? null : _send,
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessageRow message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final proposal = NoteProposal.decode(message.proposal);

    if (message.role == 'user') {
      return Padding(
        padding: const EdgeInsets.only(bottom: 18, left: 40),
        child: Align(
          alignment: Alignment.centerRight,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: Text(
              message.content,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                height: 1.4,
              ),
            ),
          ),
        ),
      );
    }

    // An answer can run to several paragraphs. A bubble round that is a wall;
    // an open column with a thin rule down the left reads like a margin note.
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 2,
            margin: const EdgeInsets.only(top: 4, right: 14),
            constraints: const BoxConstraints(minHeight: 22),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ChatMarkdown(
                  content: message.content,
                  citations: message.citations,
                ),
                if (message.citations.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (var i = 0; i < message.citations.length; i++)
                        CitationChip(
                          noteId: message.citations[i],
                          index: i + 1,
                        ),
                    ],
                  ),
                ],
                if (proposal != null) ...[
                  const SizedBox(height: 14),
                  ProposalCard(
                    messageId: message.id,
                    proposal: proposal,
                    status: ProposalStatus.fromWire(message.proposalStatus),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Thinking extends StatelessWidget {
  const _Thinking();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(
              'Searching your notes…',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: scheme.onTertiaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}
