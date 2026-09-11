import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/models/enums.dart';
import '../../pipeline/capture_pipeline.dart';
import '../../providers/capture_controller.dart';
import '../../providers/providers.dart';
import '../common/empty_state.dart';
import '../common/formatting.dart';
import '../theme.dart';
import 'review_sheet.dart';
import 'status_chip.dart';

/// Every recording and where it got to.
///
/// Lives off the Capture tab rather than under the mic: the capture screen is
/// for the thought you are having now, not for auditing the ones you already
/// had.
class RecordingsPage extends ConsumerWidget {
  const RecordingsPage({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const RecordingsPage()),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final captures = ref.watch(recentCapturesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Recordings')),
      body: captures.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline,
          title: 'Could not load your recordings',
          message: '$e',
        ),
        data: (rows) => rows.isEmpty
            ? const EmptyState(
                icon: Icons.graphic_eq_rounded,
                title: 'Nothing recorded yet',
                message: 'Tap the mic and ramble. Yap sorts it out after.',
              )
            : ListView.separated(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: rows.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, indent: 18, endIndent: 18),
                itemBuilder: (context, i) => CaptureTile(capture: rows[i]),
              ),
      ),
    );
  }
}

class CaptureTile extends ConsumerWidget {
  const CaptureTile({super.key, required this.capture});

  final CaptureRow capture;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final queued = capture.error == CapturePipeline.queuedMessage;
    final transcript = capture.rawTranscript;
    final needsReview = capture.status == CaptureStatus.awaitingReview;

    return InkWell(
      onTap: needsReview ? () => ReviewSheet.show(context, capture.id) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CaptureStatusChip(status: capture.status, queued: queued),
                const Spacer(),
                Text(
                  '${formatRelative(capture.createdAt)} · '
                  '${formatDuration(Duration(milliseconds: capture.durationMs))}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ],
            ),
            if (transcript != null && transcript.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                transcript,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ],
            if (capture.error != null && !queued) ...[
              const SizedBox(height: 8),
              Text(
                capture.error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            if (needsReview || capture.status == CaptureStatus.failed) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  if (needsReview)
                    FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 38),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                      ),
                      onPressed: () => ReviewSheet.show(context, capture.id),
                      child: const Text('Review'),
                    ),
                  if (capture.status == CaptureStatus.failed)
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 38),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                      ),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Retry'),
                      onPressed: () => ref
                          .read(captureControllerProvider.notifier)
                          .retry(capture.id),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A compact "there is something waiting for you" pill.
///
/// The recordings list moved off the capture screen, so without this a finished
/// transcription would sit unreviewed with nothing on screen to say so.
class PendingWorkPill extends ConsumerWidget {
  const PendingWorkPill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(recentCapturesProvider).value ?? const <CaptureRow>[];

    var review = 0;
    var failed = 0;
    var working = 0;
    for (final row in rows) {
      switch (row.status) {
        case CaptureStatus.awaitingReview:
          review++;
        case CaptureStatus.failed:
          failed++;
        case CaptureStatus.transcribing:
        case CaptureStatus.structuring:
          working++;
        case CaptureStatus.recorded:
        case CaptureStatus.saved:
          break;
      }
    }

    if (review == 0 && failed == 0 && working == 0) {
      return const SizedBox.shrink();
    }

    final scheme = context.scheme;
    final (label, color, icon) = switch ((review, failed, working)) {
      (final r, _, _) when r > 0 => (
          r == 1 ? '1 note to review' : '$r notes to review',
          scheme.tertiary,
          Icons.rate_review_outlined,
        ),
      (_, final f, _) when f > 0 => (
          f == 1 ? '1 recording failed' : '$f recordings failed',
          scheme.error,
          Icons.error_outline_rounded,
        ),
      _ => (
          working == 1 ? 'Working on 1 recording' : 'Working on $working',
          scheme.primary,
          Icons.hourglass_empty_rounded,
        ),
    };

    return Material(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => RecordingsPage.open(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: color),
              const SizedBox(width: 9),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded, size: 18, color: color),
            ],
          ),
        ),
      ),
    );
  }
}
