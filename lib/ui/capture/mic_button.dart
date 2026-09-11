import 'package:flutter/material.dart';

/// The big record button. Grows with the mic level so you can see it is
/// actually hearing you before you talk for three minutes into a dead mic.
class MicButton extends StatelessWidget {
  const MicButton({
    super.key,
    required this.isRecording,
    required this.level,
    required this.onPressed,
  });

  final bool isRecording;
  final double level;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const base = 96.0;
    final halo = base + (level.clamp(0.0, 1.0) * 44);

    return SizedBox(
      width: base + 44,
      height: base + 44,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (isRecording)
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: halo,
              height: halo,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary.withValues(alpha: 0.18),
              ),
            ),
          Material(
            color: isRecording ? scheme.error : scheme.primary,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: SizedBox(
                width: base,
                height: base,
                child: Icon(
                  isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                  size: 40,
                  color: isRecording ? scheme.onError : scheme.onPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
