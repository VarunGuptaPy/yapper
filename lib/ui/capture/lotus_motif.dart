import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// A lotus rosette behind the mic button.
///
/// The lotus is one of the few motifs both traditions genuinely share — *padma*
/// and *hasu* — and both draw it with radial symmetry, as a kolam does and as a
/// Japanese *mon* does. It gives the recording screen a centre of gravity and
/// carries the page's colour, which a large low-alpha wash cannot do over warm
/// paper without going muddy.
class LotusMotif extends StatelessWidget {
  const LotusMotif({
    super.key,
    required this.level,
    required this.active,
    this.size = 300,
  });

  final double level;
  final bool active;
  final double size;

  @override
  Widget build(BuildContext context) {
    final accents = context.accents;
    final scheme = context.scheme;

    return AnimatedScale(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      scale: active ? 1 + level.clamp(0.0, 1.0) * 0.06 : 1,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 400),
        opacity: active ? 1 : 0.86,
        child: CustomPaint(
          size: Size.square(size),
          painter: _LotusPainter(
            outer: active ? scheme.secondary : scheme.primary,
            middle: accents.person,
            inner: accents.idea,
          ),
        ),
      ),
    );
  }
}

class _LotusPainter extends CustomPainter {
  const _LotusPainter({
    required this.outer,
    required this.middle,
    required this.inner,
  });

  final Color outer;
  final Color middle;
  final Color inner;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final r = size.width / 2;

    _petals(canvas, centre, r * 0.98, r * 0.62, 16, outer, 0.45, fill: false);
    _ring(canvas, centre, r * 0.60, middle, 0.50);
    _petals(canvas, centre, r * 0.56, r * 0.30, 12, middle, 0.34, fill: true);
    _petals(canvas, centre, r * 0.56, r * 0.30, 12, middle, 0.55, fill: false);
    _ring(canvas, centre, r * 0.30, inner, 0.60);
    _petals(canvas, centre, r * 0.28, r * 0.10, 8, inner, 0.48, fill: true);
  }

  void _ring(Canvas canvas, Offset centre, double radius, Color color, double a) {
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color.withValues(alpha: a),
    );
  }

  /// One ring of pointed petals, each a pair of arcs meeting at the tip — the
  /// shape both a lotus petal and a kolam loop resolve to.
  void _petals(
    Canvas canvas,
    Offset centre,
    double tip,
    double base,
    int count,
    Color color,
    double alpha, {
    required bool fill,
  }) {
    final paint = Paint()
      ..style = fill ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..color = color.withValues(alpha: alpha);

    final half = math.pi / count;
    for (var i = 0; i < count; i++) {
      final angle = (math.pi * 2 / count) * i - math.pi / 2;

      Offset at(double radius, double theta) =>
          centre + Offset(math.cos(theta), math.sin(theta)) * radius;

      final path = Path()..moveTo(at(base, angle).dx, at(base, angle).dy);
      final tipPoint = at(tip, angle);
      final leftControl = at((tip + base) / 2 * 1.08, angle - half * 0.85);
      final rightControl = at((tip + base) / 2 * 1.08, angle + half * 0.85);

      path
        ..quadraticBezierTo(
            leftControl.dx, leftControl.dy, tipPoint.dx, tipPoint.dy)
        ..quadraticBezierTo(rightControl.dx, rightControl.dy,
            at(base, angle).dx, at(base, angle).dy)
        ..close();

      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_LotusPainter old) =>
      old.outer != outer || old.middle != middle || old.inner != inner;
}
