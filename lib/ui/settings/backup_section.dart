import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../providers/backup_controller.dart';
import '../../providers/providers.dart';
import '../../services/backup/backup_service.dart';
import '../common/formatting.dart';
import '../theme.dart';
import 'passphrase_dialog.dart';

/// Export and restore, on the Settings screen (SPEC.md §11).
class BackupSection extends ConsumerStatefulWidget {
  const BackupSection({super.key});

  @override
  ConsumerState<BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends ConsumerState<BackupSection> {
  bool _includeEmbeddings = false;

  Future<void> _export() async {
    final passphrase = await _ask(
      title: 'Choose a passphrase',
      actionLabel: 'Back up',
      confirm: true,
      message: 'Your notes are encrypted with this. There is no way to '
          'recover it — if you lose the passphrase, the backup is gone.',
    );
    if (passphrase == null) return;

    final file = await ref.read(backupControllerProvider.notifier).export(
          passphrase: passphrase,
          includeEmbeddings: _includeEmbeddings,
        );
    if (file == null || !mounted) return;

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        fileNameOverrides: [file.uri.pathSegments.last],
        subject: 'Yap backup',
      ),
    );
  }

  Future<void> _restore() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: 'Choose a Yap backup',
    );
    final path = picked?.path;
    if (path == null || !mounted) return;

    final passphrase = await _ask(
      title: 'Passphrase for this backup',
      actionLabel: 'Unlock',
    );
    if (passphrase == null) return;

    final controller = ref.read(backupControllerProvider.notifier);
    final prepared = await controller.prepare(
      file: File(path),
      passphrase: passphrase,
    );
    if (prepared == null || !mounted) return;

    final manifest = prepared.manifest;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace everything?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This backup holds ${manifest.noteCount} '
              'note${manifest.noteCount == 1 ? '' : 's'} and '
              '${manifest.captureCount} '
              'recording${manifest.captureCount == 1 ? '' : 's'}, made '
              '${formatRelative(manifest.createdAt)}.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Everything currently in Yap is replaced. A copy of the current '
              'database is kept on this phone first, in case this was a '
              'mistake.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final outcome = await controller.apply(prepared);
    if (outcome == null || !mounted) return;

    final needsReindex = !outcome.manifest.embeddingsIncluded;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Restored ${outcome.manifest.noteCount} notes.'
          '${needsReindex ? ' Search needs re-indexing.' : ''}',
        ),
        duration: const Duration(seconds: 8),
        action: needsReindex
            ? SnackBarAction(
                label: 'Re-index',
                onPressed: () async {
                  await for (final _
                      in ref.read(embeddingIndexerProvider).indexMissing()) {}
                },
              )
            : null,
      ),
    );
  }

  Future<String?> _ask({
    required String title,
    required String actionLabel,
    String? message,
    bool confirm = false,
  }) =>
      PassphraseDialog.show(
        context,
        title: title,
        actionLabel: actionLabel,
        message: message,
        confirm: confirm,
      );

  @override
  Widget build(BuildContext context) {
    final backup = ref.watch(backupControllerProvider);
    final theme = Theme.of(context);

    ref.listen(backupControllerProvider, (previous, next) {
      final error = next.error;
      if (error != null && error != previous?.error) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error)));
        ref.read(backupControllerProvider.notifier).dismissError();
      }
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'One encrypted .${BackupService.fileExtension} file holding every '
          'note, version and chat. Recordings are not included — they are the '
          'bulk of the data and the notes are what matter.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _includeEmbeddings,
          onChanged: backup.isBusy
              ? null
              : (v) => setState(() => _includeEmbeddings = v),
          title: Text('Include search index', style: theme.textTheme.bodyMedium),
          subtitle: Text(
            'Much larger file. Leave off — it is rebuilt after restoring.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: backup.isBusy ? null : _export,
                icon: const Icon(Icons.lock_outline_rounded, size: 18),
                label: const Text('Back up'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: backup.isBusy ? null : _restore,
                icon: const Icon(Icons.restore_rounded, size: 18),
                label: const Text('Restore'),
              ),
            ),
          ],
        ),
        if (backup.isBusy) ...[
          const SizedBox(height: 14),
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(
            switch (backup.phase) {
              BackupPhase.exporting => 'Encrypting your notes…',
              BackupPhase.verifying => 'Unlocking and checking the backup…',
              BackupPhase.restoring => 'Restoring…',
              BackupPhase.idle => '',
            },
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded,
                size: 15, color: context.accents.neutral),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Uninstalling Yap deletes everything on this phone. Keep a '
                'backup somewhere else.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: context.accents.neutral),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
