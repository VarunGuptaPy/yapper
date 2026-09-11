import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// The live voice line.
///
/// A single stroke that rests flat, then lifts into a travelling wave as you
/// speak. Loudness is pushed into a rolling buffer each frame and drawn left to
/// right, so the shape of what you just said keeps sliding away rather than
/// snapping — that trailing motion is what makes it read as listening rather
/// than as a level meter.
///
/// The animation clock only runs while recording, and for the moment it takes
/// the wave to drain afterwards.
class VoiceWaveform extends StatefulWidget {
  const VoiceWaveform({
    super.key,
    required this.level,
    required this.active,
    this.height = 96,
  });

  /// Current microphone level, 0 to 1.
  final double level;

  /// Whether recording is running. The clock stops when this goes false and
  /// the trailing wave has settled.
  final bool active;

  final double height;

  @override
  State<VoiceWaveform> createState() => _VoiceWaveformState();
}

class _VoiceWaveformState extends State<VoiceWaveform>
    with SingleTickerProviderStateMixin {
  /// One sample per frame; at 60fps the buffer holds about a second of speech.
  static const _sampleCount = 72;

  late final AnimationController _clock;

  /// Mutated in place every frame and read by the painter, which repaints off
  /// the same controller. Going through setState 60 times a second would
  /// rebuild the whole subtree for a change only the painter cares about.
  final _samples = List<double>.filled(_sampleCount, 0);

  double _smoothed = 0;
  double _phase = 0;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..addListener(_onFrame);
    if (widget.active) _clock.repeat();
  }

  @override
  void didUpdateWidget(VoiceWaveform old) {
    super.didUpdateWidget(old);
    if (widget.active && !_clock.isAnimating) _clock.repeat();
  }

  @override
  void dispose() {
    _clock
      ..removeListener(_onFrame)
      ..dispose();
    super.dispose();
  }

  void _onFrame() {
    final target = widget.active ? widget.level.clamp(0.0, 1.0) : 0.0;

    // Rise quickly so a sudden word is visible, fall slowly so the line settles
    // instead of flickering between syllables.
    final rate = target > _smoothed ? 0.35 : 0.08;
    _smoothed += (target - _smoothed) * rate;

    for (var i = 0; i < _sampleCount - 1; i++) {
      _samples[i] = _samples[i + 1];
    }
    _samples[_sampleCount - 1] = _smoothed;

    _phase += 0.055;
    if (_phase > math.pi * 2000) _phase = 0;

    // Once recording has stopped and the trailing wave has drained, park the
    // clock. A 60fps repaint that nobody is looking at costs battery all day
    // on the tab the app opens to — and it is what stops `pumpAndSettle` from
    // ever settling in tests.
    if (!widget.active && _smoothed < 0.004 && _isDrained) {
      _clock.stop();
    }
  }

  bool get _isDrained {
    for (final sample in _samples) {
      if (sample > 0.004) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: CustomPaint(
        painter: _WaveformPainter(
          repaint: _clock,
          samples: _samples,
          phase: () => _phase,
          active: widget.active,
          colors: context.accents.waveform,
          baseline: context.scheme.outlineVariant,
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required Listenable repaint,
    required this.samples,
    required this.phase,
    required this.active,
    required this.colors,
    required this.baseline,
  }) : super(repaint: repaint);

  final List<double> samples;
  final double Function() phase;
  final bool active;
  final List<Color> colors;
  final Color baseline;

  /// Three strokes at different phases and weights. One line reads as a meter;
  /// layered lines read as a voice.
  static const _layers = [
    (lift: 1.0, width: 2.6, alpha: 1.0, offset: 0.0, freq: 2.3),
    (lift: 0.72, width: 1.6, alpha: 0.45, offset: 0.9, freq: 3.1),
    (lift: 0.48, width: 1.1, alpha: 0.26, offset: 1.9, freq: 4.3),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final cy = size.height / 2;
    final maxLift = size.height * 0.42;
    final p = phase();

    // How loud the buffer currently is. The coloured strokes fade in and out
    // with this, so a silent screen shows a quiet hairline rather than a
    // rainbow rule stranded across it.
    var peak = 0.0;
    for (final sample in samples) {
      if (sample > peak) peak = sample;
    }
    final energy = (peak * 3.2).clamp(0.0, 1.0);

    // At rest this is a short centred stroke, not a full-width rule — a line
    // spanning the screen reads as a stray divider. It opens outwards as you
    // speak, which is the same gesture as the wave itself.
    final half = size.width * (0.16 + energy * 0.34);
    canvas.drawLine(
      Offset(size.width / 2 - half, cy),
      Offset(size.width / 2 + half, cy),
      Paint()
        ..color = baseline.withValues(alpha: 0.55 - energy * 0.3)
        ..strokeWidth = 1
        ..strokeCap = StrokeCap.round,
    );

    if (energy <= 0.01) return;

    final shader = LinearGradient(colors: colors).createShader(
      Rect.fromLTWH(0, 0, size.width, size.height),
    );

    for (final layer in _layers) {
      final path = Path();
      const step = 2.0;

      for (var x = 0.0; x <= size.width; x += step) {
        final t = x / size.width;
        final amp = _sampleAt(t);

        // Taper both ends into the baseline so the stroke resolves rather than
        // being clipped off at the edge of the widget.
        final envelope = math.pow(math.sin(math.pi * t), 0.65).toDouble();

        final drive = amp;

        final carrier =
            0.68 * math.sin(t * layer.freq * math.pi * 2 - p + layer.offset) +
                0.32 * math.sin(t * layer.freq * 2.1 * math.pi * 2 + p * 0.6);

        final y = cy + carrier * drive * maxLift * envelope * layer.lift;
        if (x == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }

      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = layer.width
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..shader = shader
          ..color = Colors.white.withValues(alpha: layer.alpha * energy),
      );
    }
  }

  /// Reads the rolling buffer at a fractional position, interpolating between
  /// neighbouring samples so the line stays smooth instead of stepping.
  double _sampleAt(double t) {
    final pos = t * (samples.length - 1);
    final i = pos.floor().clamp(0, samples.length - 1);
    final j = (i + 1).clamp(0, samples.length - 1);
    return samples[i] + (samples[j] - samples[i]) * (pos - i);
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.active != active || old.colors != colors || old.baseline != baseline;
}
