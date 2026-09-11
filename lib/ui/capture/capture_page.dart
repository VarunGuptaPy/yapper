import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/capture_controller.dart';
import '../../providers/providers.dart';
import '../common/formatting.dart';
import '../common/patterns.dart';
import '../theme.dart';
import 'lotus_motif.dart';
import 'mic_button.dart';
import 'recordings_page.dart';
import 'voice_waveform.dart';

/// The recording screen, and nothing else.
///
/// Everything already recorded lives on [RecordingsPage]; this page is for the
/// thought you are having right now, so it stays a single uncluttered target.
class CapturePage extends ConsumerWidget {
  const CapturePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recording = ref.watch(captureControllerProvider);
    final controller = ref.read(captureControllerProvider.notifier);
    final settings = ref.watch(currentSettingsProvider);
    final theme = Theme.of(context);

    ref.listen(captureControllerProvider, (previous, next) {
      final error = next.error;
      if (error != null && error != previous?.error) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error)));
        controller.dismissError();
      }
    });

    return _CaptureStage(
      recording: recording.isRecording,
      child: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Short screens shrink the lotus rather than clipping it, and the
            // whole column scrolls if even that is not enough.
            final compact = constraints.maxHeight < 640;
            final lotus = compact ? 224.0 : 300.0;

            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(height: compact ? 8 : 20),
                    VoiceWaveform(
                      level: recording.level,
                      active: recording.isRecording,
                      height: compact ? 64 : 96,
                    ),
                    SizedBox(height: compact ? 6 : 14),
                    Text(
                      formatDuration(recording.elapsed),
                      style: theme.textTheme.displayMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: recording.isRecording
                            ? theme.colorScheme.secondary
                            : theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      recording.isRecording
                          ? 'Listening — tap to stop'
                          : 'Tap to start talking',
                      style: theme.textTheme.bodyLarge
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    SizedBox(height: compact ? 8 : 18),
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        LotusMotif(
                          level: recording.level,
                          active: recording.isRecording,
                          size: lotus,
                        ),
                        MicButton(
                          isRecording: recording.isRecording,
                          level: recording.level,
                          onPressed: controller.toggle,
                        ),
                      ],
                    ),
                    SizedBox(
                      height: 44,
                      child: recording.isRecording
                          ? TextButton.icon(
                              onPressed: controller.cancel,
                              icon: const Icon(Icons.close_rounded, size: 18),
                              label: const Text('Discard'),
                            )
                          : null,
                    ),
                    SizedBox(height: compact ? 8 : 20),
                    if (!settings.isCaptureReady)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child:
                            _SetupBanner(message: settings.missingSetupMessage!),
                      ),
                    const PendingWorkPill(),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The full-bleed recording surface: a tinted wash under a hemp-leaf lattice.
/// The colour is what keeps a page with one button on it from reading as empty.
class _CaptureStage extends StatelessWidget {
  const _CaptureStage({required this.recording, required this.child});

  final bool recording;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;

    // No background wash: a low-alpha tint over warm paper goes grey, and a
    // gradient stop leaves a visible band across the screen. The colour lives
    // in the lotus, the mic and the type accents instead.
    return ColoredBox(
      color: scheme.surface,
      child: PatternBackdrop(
        pattern: YapPattern.asanoha,
        scale: 30,
        opacity: recording ? 3.4 : 2.6,
        child: child,
      ),
    );
  }
}

class _SetupBanner extends StatelessWidget {
  const _SetupBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.tertiary.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded,
              size: 18, color: scheme.onTertiaryContainer),
          const SizedBox(width: 10),
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
