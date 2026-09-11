import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// The record button.
///
/// Concentric rings sit around it like a *jali* screen; while recording they
/// swell with the mic level, so you can tell the app is hearing you before you
/// talk for three minutes into a dead microphone.
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

  static const _core = 80.0;
  static const _canvas = 150.0;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final accent = isRecording ? scheme.secondary : scheme.primary;

    return SizedBox(
      width: _canvas,
      height: _canvas,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: const Size.square(_canvas),
            painter: _RingPainter(
              level: level.clamp(0.0, 1.0),
              active: isRecording,
              color: accent,
            ),
          ),
          Material(
            color: accent,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: SizedBox(
                width: _core,
                height: _core,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: Icon(
                    isRecording ? Icons.stop_rounded : Icons.mic_none_rounded,
                    key: ValueKey(isRecording),
                    size: 34,
                    color: isRecording ? scheme.onSecondary : scheme.onPrimary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.level,
    required this.active,
    required this.color,
  });

  final double level;
  final bool active;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    const core = MicButton._core / 2;

    // A halo that breathes with the level.
    if (active) {
      canvas.drawCircle(
        centre,
        core + 6 + level * 26,
        Paint()..color = color.withValues(alpha: 0.12),
      );
    }

    // Two thin rings, the outer one dashed like a lattice screen.
    canvas.drawCircle(
      centre,
      core + 10,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = color.withValues(alpha: active ? 0.55 : 0.3),
    );

    const radius = MicButton._canvas / 2 - 6;
    const ticks = 48;
    final tickPaint = Paint()
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: active ? 0.4 : 0.18);

    for (var i = 0; i < ticks; i++) {
      final angle = (math.pi * 2 / ticks) * i;
      // Every fourth tick is longer, the way a jali repeat marks its rhythm.
      final length = i % 4 == 0 ? 7.0 : 3.5;
      final grow = active ? level * 5 : 0.0;
      final inner = radius - length - grow;
      canvas.drawLine(
        centre + Offset(math.cos(angle), math.sin(angle)) * inner,
        centre + Offset(math.cos(angle), math.sin(angle)) * radius,
        tickPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.level != level || old.active != active || old.color != color;
}
