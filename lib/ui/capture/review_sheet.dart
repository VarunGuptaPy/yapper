import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../data/db/database.dart';
import '../../data/models/structured_note.dart';
import '../../providers/providers.dart';
import '../theme.dart';
import 'note_edit_sheet.dart';

/// Steps through the notes the LLM proposed for one recording.
///
/// Nothing is written until a card is explicitly saved, and discarding a card
/// only drops the suggestion — the recording and its transcript stay put.
class ReviewSheet extends ConsumerStatefulWidget {
  const ReviewSheet({super.key, required this.captureId});

  final String captureId;

  static Future<void> show(BuildContext context, String captureId) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ReviewSheet(captureId: captureId),
    );
  }

  @override
  ConsumerState<ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends ConsumerState<ReviewSheet> {
  late Future<List<StructuredNote>> _future;
  int _saved = 0;
  int _index = 0;
  bool _finishing = false;
  bool _busy = false;
  final _targets = <int, Future<NoteRow?>>{};

  @override
  void initState() {
    super.initState();
    _future = ref.read(capturePipelineProvider).ensureProposals(widget.captureId);
  }

  /// Resolves the merge target once per card.
  ///
  /// The future is memoised by card index: handing FutureBuilder a fresh
  /// future on every rebuild would re-query on each setState and flicker the
  /// button away mid-tap.
  Future<NoteRow?> _targetFor(int index, StructuredNote proposal) =>
      _targets.putIfAbsent(
        index,
        () => ref.read(capturePipelineProvider).mergeTargetFor(proposal),
      );

  Future<void> _mergeCurrent(StructuredNote proposal, NoteRow target) async {
    setState(() => _busy = true);
    try {
      await ref
          .read(capturePipelineProvider)
          .mergeProposal(widget.captureId, proposal, target);
      _saved++;
      _advance();
    } on AppException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not merge that note.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveCurrent(StructuredNote proposal) async {
    final pipeline = ref.read(capturePipelineProvider);
    try {
      await pipeline.saveProposal(widget.captureId, proposal);
      _saved++;
      _advance();
    } on AppException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save that note.')),
      );
    }
  }

  Future<void> _editCurrent(StructuredNote proposal) async {
    final draft = await NoteEditSheet.show(
      context,
      heading: 'Edit note',
      saveLabel: 'Save as new',
      initial: NoteDraft(
        type: proposal.type,
        title: proposal.title,
        body: proposal.body,
        tags: proposal.tags,
      ),
    );
    if (draft == null) return;

    await _saveCurrent(proposal.copyWith(
      type: draft.type,
      title: draft.title,
      body: draft.body,
      tags: draft.tags,
    ));
  }

  void _advance() => setState(() => _index++);

  /// Guarded: build can run more than once while the deck is empty, and a
  /// second pop would close the page underneath this sheet.
  Future<void> _finishIfDone(int total) async {
    if (_finishing || _index < total) return;
    _finishing = true;
    await ref.read(capturePipelineProvider).completeReview(widget.captureId);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => FutureBuilder<List<StructuredNote>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const _ReviewMessage(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Reading your notes back…'),
                ],
              ),
            );
          }

          if (snapshot.hasError) {
            final error = snapshot.error;
            return _ReviewMessage(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 40),
                  const SizedBox(height: 12),
                  Text(
                    error is AppException ? error.message : 'Something went wrong.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          final proposals = snapshot.data ?? const <StructuredNote>[];
          if (proposals.isEmpty) {
            return const _ReviewMessage(
              child: Text('No notes were found in this recording.'),
            );
          }

          if (_index >= proposals.length) {
            // Everything has been dealt with; close out the capture.
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _finishIfDone(proposals.length),
            );
            return _ReviewMessage(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_circle_outline, size: 40),
                  const SizedBox(height: 12),
                  Text(_saved == 0
                      ? 'Nothing saved. The recording is still here.'
                      : 'Saved $_saved note${_saved == 1 ? '' : 's'}.'),
                ],
              ),
            );
          }

          final proposal = proposals[_index];
          return ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Review ${_index + 1} of ${proposals.length}',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Finish later',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _ProposalCard(proposal: proposal),
              const SizedBox(height: 20),
              FutureBuilder<NoteRow?>(
                future: _targetFor(_index, proposal),
                builder: (context, snapshot) {
                  final target = snapshot.data;
                  if (target == null) return const SizedBox.shrink();

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (proposal.mergeReason != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              proposal.mergeReason!,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          ),
                        FilledButton.icon(
                          icon: const Icon(Icons.merge_type),
                          label: Text(
                            'Merge into "${target.title}"',
                            overflow: TextOverflow.ellipsis,
                          ),
                          onPressed:
                              _busy ? null : () => _mergeCurrent(proposal, target),
                        ),
                      ],
                    ),
                  );
                },
              ),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.check),
                label: const Text('Save as new'),
                onPressed: _busy ? null : () => _saveCurrent(proposal),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit'),
                onPressed: _busy ? null : () => _editCurrent(proposal),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                icon: const Icon(Icons.delete_outline),
                label: const Text('Discard'),
                onPressed: _busy ? null : _advance,
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ProposalCard extends StatelessWidget {
  const _ProposalCard({required this.proposal});

  final StructuredNote proposal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = noteTypeColor(context, proposal.type.name);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(noteTypeIcon(proposal.type.name), size: 18, color: color),
                const SizedBox(width: 6),
                Text(
                  proposal.type.label,
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: color, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(proposal.title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(proposal.body, style: theme.textTheme.bodyLarge),
            if (proposal.tags.isNotEmpty) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in proposal.tags)
                    Chip(
                      label: Text(tag),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                ],
              ),
            ],
            if (proposal.people.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Mentions: ${proposal.people.join(', ')}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReviewMessage extends StatelessWidget {
  const _ReviewMessage({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(padding: const EdgeInsets.all(32), child: child),
      );
}
