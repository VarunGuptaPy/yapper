import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_controller.dart';
import '../../providers/providers.dart';
import '../../data/db/database.dart';
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
    final isDelete = proposal.kind == ProposalKind.delete;
    final existing = proposal.noteId == null
        ? null
        : ref.watch(noteProvider(proposal.noteId!)).value;

    if (isDelete) {
      return _DeleteCard(
        messageId: messageId,
        proposal: proposal,
        status: status,
        // Null once it is gone; the title on the proposal still names it.
        note: existing,
      );
    }

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
                // A note title can be long; without this the header row
                // overflows instead of truncating.
                Flexible(
                  child: Text(
                    isCreate
                        ? 'New note'
                        : 'Update "${existing?.title ?? 'a note'}"',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: theme.colorScheme.primary),
                  ),
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

/// Deleting is the one thing in Yap that cannot be undone, so the card shows
/// the whole note rather than just its title — if the model picked the wrong
/// one from a vague request, that has to be obvious before Confirm is tapped.
class _DeleteCard extends ConsumerWidget {
  const _DeleteCard({
    required this.messageId,
    required this.proposal,
    required this.status,
    required this.note,
  });

  final String messageId;
  final NoteProposal proposal;
  final ProposalStatus status;
  final NoteRow? note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = note?.title ?? proposal.title ?? 'this note';

    return Card(
      color: scheme.errorContainer.withValues(alpha: 0.55),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.error.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.delete_outline_rounded, size: 18, color: scheme.error),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'Delete "$title"',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: scheme.error),
                  ),
                ),
              ],
            ),
            if (note != null) ...[
              const SizedBox(height: 12),
              Text(note!.body, style: theme.textTheme.bodyMedium),
              if (note!.tags.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in note!.tags)
                      Chip(
                        label: Text(tag),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                  ],
                ),
              ],
            ],
            if (proposal.reason != null) ...[
              const SizedBox(height: 12),
              Text(
                proposal.reason!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            if (status == ProposalStatus.pending) ...[
              const SizedBox(height: 12),
              Text(
                'Its edit history goes too, and cannot be recovered. '
                'The recording and transcript stay.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError,
                    ),
                    onPressed: () => ref
                        .read(chatControllerProvider.notifier)
                        .confirmProposal(messageId, proposal),
                    child: const Text('Delete'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => ref
                        .read(chatControllerProvider.notifier)
                        .dismissProposal(messageId),
                    child: const Text('Keep it'),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 12),
              _Outcome(
                icon: status == ProposalStatus.confirmed
                    ? Icons.delete_sweep_outlined
                    : Icons.cancel_outlined,
                label: status == ProposalStatus.confirmed ? 'Deleted' : 'Kept',
                color: status == ProposalStatus.confirmed
                    ? scheme.error
                    : scheme.outline,
              ),
            ],
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
