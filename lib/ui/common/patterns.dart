import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Which lattice to draw behind a surface.
enum YapPattern {
  /// Japanese hemp leaf: a hexagonal star lattice.
  asanoha,

  /// Indian pulli kolam: a dot grid on the diagonal, with a light lattice.
  kolam,

  /// Japanese seigaiha: overlapping wave scallops.
  seigaiha,
}

/// Paints a traditional lattice very faintly behind its child.
///
/// The point is texture, not decoration — at these opacities you notice the
/// surface has a weave without ever reading a motif. Anything louder turns a
/// notes app into a souvenir shop.
class PatternBackdrop extends StatelessWidget {
  const PatternBackdrop({
    super.key,
    required this.pattern,
    this.child,
    this.scale = 26,
    this.fadeDirection = Axis.vertical,
    this.opacity = 1,
  });

  final YapPattern pattern;
  final Widget? child;

  /// Cell size in logical pixels.
  final double scale;

  /// The axis the lattice fades out along, so it never collides with text.
  final Axis fadeDirection;

  /// Extra multiplier on top of the theme's already-faint pattern ink.
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _PatternPainter(
        pattern: pattern,
        color: context.accents.pattern.withValues(
          alpha: context.accents.pattern.a * opacity,
        ),
        scale: scale,
        fadeDirection: fadeDirection,
      ),
      child: child,
    );
  }
}

class _PatternPainter extends CustomPainter {
  const _PatternPainter({
    required this.pattern,
    required this.color,
    required this.scale,
    required this.fadeDirection,
  });

  final YapPattern pattern;
  final Color color;
  final double scale;
  final Axis fadeDirection;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || color.a == 0) return;

    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color
      ..shader = LinearGradient(
        begin: fadeDirection == Axis.vertical
            ? Alignment.topCenter
            : Alignment.centerLeft,
        end: fadeDirection == Axis.vertical
            ? Alignment.bottomCenter
            : Alignment.centerRight,
        colors: [color, color.withValues(alpha: 0)],
        stops: const [0.0, 0.95],
      ).createShader(rect);

    canvas.save();
    canvas.clipRect(rect);
    switch (pattern) {
      case YapPattern.asanoha:
        _asanoha(canvas, size, paint);
      case YapPattern.kolam:
        _kolam(canvas, size, paint);
      case YapPattern.seigaiha:
        _seigaiha(canvas, size, paint);
    }
    canvas.restore();
  }

  /// Hexagons on a staggered grid, each with spokes to its vertices — the
  /// six-pointed star that gives asanoha its name.
  void _asanoha(Canvas canvas, Size size, Paint paint) {
    final r = scale;
    final dx = r * math.sqrt(3);
    final dy = r * 1.5;

    final path = Path();
    for (var row = -1; row * dy < size.height + r; row++) {
      final offsetX = row.isEven ? 0.0 : dx / 2;
      for (var col = -1; col * dx + offsetX < size.width + dx; col++) {
        final cx = col * dx + offsetX;
        final cy = row * dy;

        final vertices = [
          for (var i = 0; i < 6; i++)
            Offset(
              cx + r * math.cos((math.pi / 180) * (30 + i * 60)),
              cy + r * math.sin((math.pi / 180) * (30 + i * 60)),
            ),
        ];

        path.addPolygon(vertices, true);
        // Spokes: only three of the six, alternating, so neighbouring cells
        // complete each other's stars instead of double-drawing every line.
        for (var i = 0; i < 6; i += 2) {
          path
            ..moveTo(cx, cy)
            ..lineTo(vertices[i].dx, vertices[i].dy);
        }
      }
    }
    canvas.drawPath(path, paint);
  }

  /// A pulli kolam grid: dots on the diagonal with a light connecting lattice.
  void _kolam(Canvas canvas, Size size, Paint paint) {
    final step = scale;
    final dotPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = paint.shader
      ..color = color;

    final lattice = Path();
    for (var row = 0; row * step < size.height + step; row++) {
      final offsetX = row.isEven ? 0.0 : step / 2;
      for (var col = 0; col * step + offsetX < size.width + step; col++) {
        final cx = col * step + offsetX;
        final cy = row * step;
        canvas.drawCircle(Offset(cx, cy), 1.4, dotPaint);

        // Diagonals through each dot, giving the woven look a kolam gets from
        // the curve looping around its dots.
        lattice
          ..moveTo(cx - step / 2, cy)
          ..lineTo(cx, cy - step / 2)
          ..moveTo(cx, cy - step / 2)
          ..lineTo(cx + step / 2, cy);
      }
    }
    canvas.drawPath(lattice, paint..strokeWidth = 0.8);
  }

  /// Overlapping scallops of concentric arcs.
  void _seigaiha(Canvas canvas, Size size, Paint paint) {
    final r = scale;
    final path = Path();
    for (var row = 0; row * r * 0.62 < size.height + r; row++) {
      final offsetX = row.isEven ? 0.0 : r;
      for (var col = -1; col * r * 2 + offsetX < size.width + r * 2; col++) {
        final cx = col * r * 2 + offsetX;
        final cy = row * r * 0.62;
        for (var ring = 3; ring >= 1; ring--) {
          path.addArc(
            Rect.fromCircle(center: Offset(cx, cy), radius: r * ring / 3),
            math.pi,
            math.pi,
          );
        }
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_PatternPainter old) =>
      old.pattern != pattern ||
      old.color != color ||
      old.scale != scale ||
      old.fadeDirection != fadeDirection;
}

/// A section rule with a centred diamond.
///
/// Both traditions break a line with a small centred mark rather than running
/// it edge to edge; it gives a section heading air without a heavy border.
class MotifDivider extends StatelessWidget {
  const MotifDivider({super.key, this.width = 120, this.color});

  final double width;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ink = color ?? context.scheme.outlineVariant;
    return SizedBox(
      width: width,
      height: 10,
      child: CustomPaint(painter: _MotifDividerPainter(ink)),
    );
  }
}

class _MotifDividerPainter extends CustomPainter {
  const _MotifDividerPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final gap = 9.0;
    final line = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    canvas
      ..drawLine(Offset(0, mid), Offset(size.width / 2 - gap, mid), line)
      ..drawLine(Offset(size.width / 2 + gap, mid), Offset(size.width, mid), line);

    final diamond = Path()
      ..moveTo(size.width / 2, mid - 4)
      ..lineTo(size.width / 2 + 4, mid)
      ..lineTo(size.width / 2, mid + 4)
      ..lineTo(size.width / 2 - 4, mid)
      ..close();
    canvas.drawPath(diamond, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_MotifDividerPainter old) => old.color != color;
}
