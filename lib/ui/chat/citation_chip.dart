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
    final theme = Theme.of(context);
    // A cited note can have been deleted since the answer was written.
    if (note == null) return const SizedBox.shrink();

    final color = noteTypeColor(theme.colorScheme, note.type.name);

    return ActionChip(
      avatar: Icon(noteTypeIcon(note.type.name), size: 16, color: color),
      label: Text(
        '[$index] ${note.title}',
        overflow: TextOverflow.ellipsis,
      ),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: noteId)),
      ),
    );
  }
}
