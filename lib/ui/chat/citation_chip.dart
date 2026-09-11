import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../notes/note_detail_page.dart';
import '../theme.dart';

/// A tappable reference to a note the answer used (SPEC.md §9).
class CitationChip extends ConsumerWidget {
  const CitationChip({super.key, required this.noteId, required this.index});

  final String noteId;

  /// The `[n]` the model wrote, so the chip and the text line up.
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final note = ref.watch(noteProvider(noteId)).value;
    // A cited note can have been deleted since the answer was written.
    if (note == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final color = noteTypeColor(context, note.type.name);

    return Material(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: noteId)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 5, 10, 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$index',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 7),
              Icon(noteTypeIcon(note.type.name), size: 14, color: color),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  note.title,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
