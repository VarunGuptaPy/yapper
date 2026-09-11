import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/models/enums.dart';
import '../../pipeline/capture_pipeline.dart';
import '../../providers/capture_controller.dart';
import '../../providers/providers.dart';
import '../common/empty_state.dart';
import '../common/formatting.dart';
import 'mic_button.dart';
import 'review_sheet.dart';
import 'status_chip.dart';

class CapturePage extends ConsumerWidget {
  const CapturePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recording = ref.watch(captureControllerProvider);
    final controller = ref.read(captureControllerProvider.notifier);
    final captures = ref.watch(recentCapturesProvider);
    final settings = ref.watch(currentSettingsProvider);

    ref.listen(captureControllerProvider, (previous, next) {
      final error = next.error;
      if (error != null && error != previous?.error) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error)));
        controller.dismissError();
      }
    });

    return Column(
      children: [
        const SizedBox(height: 24),
        MicButton(
          isRecording: recording.isRecording,
          level: recording.level,
          onPressed: controller.toggle,
        ),
        const SizedBox(height: 16),
        Text(
          formatDuration(recording.elapsed),
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
        ),
        Text(
          recording.isRecording ? 'Listening — tap to stop' : 'Tap to start talking',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        if (recording.isRecording) ...[
          const SizedBox(height: 4),
          TextButton(
            onPressed: controller.cancel,
            child: const Text('Discard'),
          ),
        ],
        if (!settings.isCaptureReady) ...[
          const SizedBox(height: 12),
          _SetupBanner(message: settings.missingSetupMessage!),
        ],
        const SizedBox(height: 20),
        const Divider(height: 1),
        Expanded(
          child: captures.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => EmptyState(
              icon: Icons.error_outline,
              title: 'Could not load your recordings',
              message: '$e',
            ),
            data: (rows) => rows.isEmpty
                ? const EmptyState(
                    icon: Icons.graphic_eq,
                    title: 'No recordings yet',
                    message: 'Tap the mic and ramble. Yap sorts it out after.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) => _CaptureTile(capture: rows[i]),
                  ),
          ),
        ),
      ],
    );
  }
}

class _SetupBanner extends StatelessWidget {
  const _SetupBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: scheme.onTertiaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptureTile extends ConsumerWidget {
  const _CaptureTile({required this.capture});

  final CaptureRow capture;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final queued = capture.error == CapturePipeline.queuedMessage;
    final transcript = capture.rawTranscript;

    return ListTile(
      title: Row(
        children: [
          CaptureStatusChip(status: capture.status, queued: queued),
          const Spacer(),
          Text(
            '${formatRelative(capture.createdAt)} · '
            '${formatDuration(Duration(milliseconds: capture.durationMs))}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (transcript != null && transcript.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              transcript,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ],
          if (capture.error != null && !queued) ...[
            const SizedBox(height: 6),
            Text(
              capture.error!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              if (capture.status == CaptureStatus.awaitingReview)
                FilledButton.tonal(
                  onPressed: () => ReviewSheet.show(context, capture.id),
                  child: const Text('Review'),
                ),
              if (capture.status == CaptureStatus.failed)
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Retry'),
                  onPressed: () => ref
                      .read(captureControllerProvider.notifier)
                      .retry(capture.id),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
