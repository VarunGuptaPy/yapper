import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/models/enums.dart';
import '../../providers/providers.dart';
import '../capture/note_edit_sheet.dart';
import '../common/formatting.dart';
import '../theme.dart';
import 'source_recording_tile.dart';

class NoteDetailPage extends ConsumerWidget {
  const NoteDetailPage({super.key, required this.noteId});

  final String noteId;

  Future<void> _edit(BuildContext context, WidgetRef ref, NoteRow note) async {
    final draft = await NoteEditSheet.show(
      context,
      heading: 'Edit note',
      initial: NoteDraft(
        type: note.type,
        title: note.title,
        body: note.body,
        tags: note.tags,
      ),
    );
    if (draft == null) return;

    await ref.read(noteWriterProvider).applyManualEdit(
          id: note.id,
          type: draft.type,
          title: draft.title,
          body: draft.body,
          tags: draft.tags,
        );
    ref.invalidate(noteVersionsProvider(note.id));
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, NoteRow note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this note?'),
        content: const Text(
          'The recording and its transcript are kept — only the note goes.',
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
    if (confirmed != true || !context.mounted) return;

    await ref.read(noteWriterProvider).delete(note.id);
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final note = ref.watch(noteProvider(noteId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Note'),
        actions: [
          if (note.value != null) ...[
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit',
              onPressed: () => _edit(context, ref, note.value!),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: () => _confirmDelete(context, ref, note.value!),
            ),
          ],
        ],
      ),
      body: note.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (row) => row == null
            ? const Center(child: Text('This note no longer exists.'))
            : _NoteBody(note: row),
      ),
    );
  }
}

class _NoteBody extends ConsumerWidget {
  const _NoteBody({required this.note});

  final NoteRow note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final color = noteTypeColor(theme.colorScheme, note.type.name);
    final captures = ref.watch(noteCapturesProvider(note.id));
    final versions = ref.watch(noteVersionsProvider(note.id));

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      children: [
        Row(
          children: [
            Icon(noteTypeIcon(note.type.name), size: 18, color: color),
            const SizedBox(width: 6),
            Text(
              note.type.label,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Text(
              'Updated ${formatRelative(note.updatedAt)}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SelectableText(note.title, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 16),
        SelectableText(note.body, style: theme.textTheme.bodyLarge),
        if (note.tags.isNotEmpty) ...[
          const SizedBox(height: 20),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in note.tags)
                Chip(
                  label: Text(tag),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          ),
        ],
        const SizedBox(height: 28),
        _PeopleSection(note: note),
        _SectionHeading(
          'Source recordings',
          trailing: captures.value?.length.toString(),
        ),
        const SizedBox(height: 8),
        captures.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          ),
          error: (e, _) => Text('$e', style: theme.textTheme.bodySmall),
          data: (rows) => rows.isEmpty
              ? Text(
                  'This note was written by hand — no recording behind it.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                )
              : Column(
                  children: [
                    for (final capture in rows)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: SourceRecordingTile(capture: capture),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 28),
        _SectionHeading(
          'Version history',
          trailing: versions.value?.length.toString(),
        ),
        const SizedBox(height: 8),
        versions.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          ),
          error: (e, _) => Text('$e', style: theme.textTheme.bodySmall),
          data: (rows) => rows.isEmpty
              ? Text(
                  'No edits yet.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                )
              : Column(
                  children: [for (final v in rows) _VersionTile(version: v)],
                ),
        ),
      ],
    );
  }
}

/// For a person note this lists the notes that mention them; for anything
/// else it lists the people the note mentions. Both directions of the same
/// link, shown from whichever side you are standing on.
class _PeopleSection extends ConsumerWidget {
  const _PeopleSection({required this.note});

  final NoteRow note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPerson = note.type == NoteType.person;
    final linked = isPerson
        ? ref.watch(notesMentioningProvider(note.id))
        : ref.watch(notePeopleProvider(note.id));

    final rows = linked.value ?? const <NoteRow>[];
    if (rows.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeading(
          isPerson ? 'Mentioned in' : 'People',
          trailing: rows.length.toString(),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final row in rows)
              ActionChip(
                avatar: Icon(noteTypeIcon(row.type.name), size: 16),
                label: Text(row.title),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => NoteDetailPage(noteId: row.id),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 28),
      ],
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.label, {this.trailing});

  final String label;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(label, style: theme.textTheme.titleSmall),
        if (trailing != null) ...[
          const SizedBox(width: 6),
          Text(
            trailing!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

class _VersionTile extends StatelessWidget {
  const _VersionTile({required this.version});

  final NoteVersionRow version;

  String get _sourceLabel => switch (version.changeSource) {
        ChangeSource.manualEdit => 'Edited by hand',
        ChangeSource.voiceMerge => 'Merged from a recording',
        ChangeSource.chatEdit => 'Changed from chat',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(version.title, style: theme.textTheme.bodyMedium),
        subtitle: Text(
          '$_sourceLabel · ${formatRelative(version.changedAt)}',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SelectableText(
                version.body,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
