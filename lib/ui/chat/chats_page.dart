import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/chat_repository.dart';
import '../../providers/chat_controller.dart';
import '../../providers/providers.dart';
import '../common/empty_state.dart';
import '../common/formatting.dart';
import '../theme.dart';

/// Past conversations. Starting a fresh chat never destroys one, so this is
/// where the old threads live.
class ChatsPage extends ConsumerWidget {
  const ChatsPage({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ChatsPage()),
      );

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    ConversationSummary summary,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this chat?'),
        content: const Text(
          'The conversation goes. Any notes it created or changed stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref
        .read(chatControllerProvider.notifier)
        .deleteConversation(summary.conversation.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(chatConversationsProvider);
    final active = ref.watch(activeConversationProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: 'New chat',
            onPressed: () {
              ref.read(chatControllerProvider.notifier).startNewChat();
              Navigator.of(context).pop();
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: conversations.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline,
          title: 'Could not load your chats',
          message: '$e',
        ),
        data: (rows) => rows.isEmpty
            ? const EmptyState(
                icon: Icons.forum_outlined,
                title: 'No chats yet',
                message: 'Ask something on the Chat tab and it will show up '
                    'here afterwards.',
              )
            : ListView.separated(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: rows.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, indent: 18, endIndent: 18),
                itemBuilder: (context, i) => _ConversationTile(
                  summary: rows[i],
                  isActive: rows[i].conversation.id == active,
                  onOpen: () {
                    ref
                        .read(chatControllerProvider.notifier)
                        .openConversation(rows[i].conversation.id);
                    Navigator.of(context).pop();
                  },
                  onDelete: () => _confirmDelete(context, ref, rows[i]),
                ),
              ),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.summary,
    required this.isActive,
    required this.onOpen,
    required this.onDelete,
  });

  final ConversationSummary summary;
  final bool isActive;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 8, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (isActive) ...[
                        Container(
                          width: 7,
                          height: 7,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                      Expanded(
                        child: Text(
                          summary.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatRelative(summary.conversation.updatedAt),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ],
                  ),
                  if (summary.lastMessage != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      summary.lastMessage!.replaceAll(RegExp(r'\s+'), ' '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    '${summary.messageCount} '
                    'message${summary.messageCount == 1 ? '' : 's'}',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: context.accents.neutral),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
              tooltip: 'Delete',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
