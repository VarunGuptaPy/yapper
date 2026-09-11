import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_controller.dart';
import '../../providers/providers.dart';
import '../../services/chat/note_proposal.dart';

/// The confirmation card for a `propose_*` tool call. Nothing is written
/// until Confirm is tapped.
class ProposalCard extends ConsumerWidget {
  const ProposalCard({
    super.key,
    required this.messageId,
    required this.proposal,
    required this.status,
  });

  final String messageId;
  final NoteProposal proposal;
  final ProposalStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isCreate = proposal.kind == ProposalKind.create;
    final existing = proposal.noteId == null
        ? null
        : ref.watch(noteProvider(proposal.noteId!)).value;

    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isCreate ? Icons.note_add_outlined : Icons.edit_note_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  isCreate
                      ? 'New note'
                      : 'Update "${existing?.title ?? 'a note'}"',
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (proposal.title != null)
              Text(proposal.title!, style: theme.textTheme.titleMedium),
            if (proposal.body != null) ...[
              const SizedBox(height: 8),
              Text(proposal.body!, style: theme.textTheme.bodyMedium),
            ],
            if (proposal.tags != null && proposal.tags!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in proposal.tags!)
                    Chip(
                      label: Text(tag),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                ],
              ),
            ],
            if (proposal.reason != null) ...[
              const SizedBox(height: 12),
              Text(
                proposal.reason!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 12),
            switch (status) {
              ProposalStatus.pending => Row(
                  children: [
                    FilledButton(
                      onPressed: () => ref
                          .read(chatControllerProvider.notifier)
                          .confirmProposal(messageId, proposal),
                      child: const Text('Confirm'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => ref
                          .read(chatControllerProvider.notifier)
                          .dismissProposal(messageId),
                      child: const Text('Dismiss'),
                    ),
                  ],
                ),
              ProposalStatus.confirmed => _Outcome(
                  icon: Icons.check_circle_outline,
                  label: isCreate ? 'Saved' : 'Applied',
                  color: theme.colorScheme.primary,
                ),
              ProposalStatus.dismissed => _Outcome(
                  icon: Icons.cancel_outlined,
                  label: 'Dismissed',
                  color: theme.colorScheme.outline,
                ),
            },
          ],
        ),
      ),
    );
  }
}

class _Outcome extends StatelessWidget {
  const _Outcome({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(color: color),
          ),
        ],
      );
}
