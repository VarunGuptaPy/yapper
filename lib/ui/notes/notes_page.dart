import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../data/db/database.dart';
import '../../data/models/enums.dart';
import '../../providers/providers.dart';
import '../../search/hybrid_search.dart';
import '../common/empty_state.dart';
import '../common/formatting.dart';
import '../theme.dart';
import 'note_detail_page.dart';

class NotesPage extends ConsumerStatefulWidget {
  const NotesPage({super.key});

  @override
  ConsumerState<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends ConsumerState<NotesPage> {
  final _search = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// Hybrid search costs an embedding call per query, so it waits for a pause
  /// in typing rather than firing on every keystroke.
  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      ref.read(noteSearchQueryProvider.notifier).set(value);
    });
    setState(() {});
  }

  void _clearSearch() {
    _debounce?.cancel();
    _search.clear();
    ref.read(noteSearchQueryProvider.notifier).set('');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final notes = ref.watch(notesProvider);
    final filter = ref.watch(noteTypeFilterProvider);
    final query = ref.watch(noteSearchQueryProvider);
    final searching = query.trim().isNotEmpty;
    final results = ref.watch(noteSearchResultsProvider);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: TextField(
            controller: _search,
            onChanged: _onQueryChanged,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search your notes',
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: _clearSearch,
                    ),
            ),
          ),
        ),
        SizedBox(
          height: 56,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            children: [
              _FilterChip(
                label: 'All',
                selected: filter == null,
                onSelected: () =>
                    ref.read(noteTypeFilterProvider.notifier).select(null),
              ),
              for (final type in NoteType.values)
                _FilterChip(
                  label: type.label,
                  selected: filter == type,
                  onSelected: () =>
                      ref.read(noteTypeFilterProvider.notifier).select(type),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: searching
              ? _SearchResults(results: results, onClear: _clearSearch)
              : notes.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => EmptyState(
              icon: Icons.error_outline,
              title: 'Could not load your notes',
              message: '$e',
            ),
            data: (rows) => rows.isEmpty
                ? EmptyState(
                    icon: Icons.sticky_note_2_outlined,
                    title: filter == null
                        ? 'No notes yet'
                        : 'No ${filter.label.toLowerCase()} notes yet',
                    message: filter == null
                        ? 'Record something on the Capture tab and it will show up here.'
                        : 'Try another filter.',
                  )
                : ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) => _NoteTile(note: rows[i]),
                  ),
          ),
        ),
      ],
    );
  }
}

class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.results, required this.onClear});

  final AsyncValue<List<SearchResult>> results;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => results.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline,
          title: 'Search failed',
          message: e is AppException ? e.message : '$e',
        ),
        data: (hits) => hits.isEmpty
            ? EmptyState(
                icon: Icons.search_off,
                title: 'Nothing matched',
                message: 'Try fewer words, or a different filter.',
                action: TextButton(
                  onPressed: onClear,
                  child: const Text('Clear search'),
                ),
              )
            : ListView.separated(
                itemCount: hits.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) => _NoteTile(
                  note: hits[i].note,
                  // Shown only when the vector half found something the text
                  // half did not — that is the part worth explaining.
                  semanticOnly: hits[i].fromVector && !hits[i].fromText,
                ),
              ),
      );
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilterChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => onSelected(),
        ),
      );
}

class _NoteTile extends StatelessWidget {
  const _NoteTile({required this.note, this.semanticOnly = false});

  final NoteRow note;
  final bool semanticOnly;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = noteTypeColor(theme.colorScheme, note.type.name);

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.15),
        child: Icon(noteTypeIcon(note.type.name), size: 20, color: color),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(note.title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (semanticOnly) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: 'Matched by meaning, not by wording',
              child: Icon(Icons.auto_awesome,
                  size: 14, color: theme.colorScheme.tertiary),
            ),
          ],
        ],
      ),
      subtitle: Text(
        note.body,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        formatRelative(note.updatedAt),
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: note.id)),
      ),
    );
  }
}
