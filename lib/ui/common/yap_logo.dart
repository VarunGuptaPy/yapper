import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// How the logo's ground is drawn.
enum LogoGround {
  /// Rounded square, for a legacy launcher icon.
  squircle,

  /// Full circle, for a round launcher icon.
  circle,

  /// Nothing — the adaptive foreground layer, which sits on its own background.
  none,
}

/// Yap's mark: the lotus from the recording screen, closed around a mic.
///
/// The same motif the app already uses — *padma* / *hasu*, drawn radially the
/// way a kolam and a Japanese *mon* both are. Simplified hard for small sizes:
/// eight petals rather than sixteen, two accent colours, and a solid centre,
/// because a launcher icon is read at 48dp.
class YapLogoPainter extends CustomPainter {
  const YapLogoPainter({
    this.ground = LogoGround.squircle,
    this.contentScale = 1,
    this.monochrome = false,
  });

  final LogoGround ground;

  /// A single-colour silhouette for Android's themed icons, which tint the
  /// foreground flat. Painted in one colour with the microphone punched out,
  /// so the tinted result still has a shape instead of being a solid blob.
  final bool monochrome;

  /// Shrinks the mark within the canvas. Adaptive foregrounds need this: only
  /// the middle of the layer is guaranteed to survive the launcher's mask.
  final double contentScale;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final centre = size.center(Offset.zero);

    _paintGround(canvas, size, s);

    canvas
      ..save()
      ..translate(centre.dx, centre.dy)
      ..scale(contentScale)
      ..translate(-centre.dx, -centre.dy);

    final r = s / 2;

    if (monochrome) canvas.saveLayer(Offset.zero & size, Paint());

    const mono = Color(0xFF000000);
    _petals(canvas, centre, r * 0.92, r * 0.40, 8,
        monochrome ? mono : YapPalette.marigoldLight, 0);
    _petals(canvas, centre, r * 0.62, r * 0.26, 8,
        monochrome ? mono : const Color(0xFFFF9E7A), math.pi / 8);

    // The mic button from the capture screen, in the paper of the app's ground.
    canvas.drawCircle(
      centre,
      r * 0.30,
      Paint()..color = monochrome ? mono : YapPalette.washi,
    );

    // Capsule, stem and base drawn as one connected silhouette. Detached
    // parts disappear at 48dp; a single shape stays a microphone all the way
    // down.
    // On the monochrome layer the microphone is cut out of the disc rather
    // than drawn on top of it, since everything is one colour.
    final ink = Paint()
      ..color = YapPalette.indigo
      ..blendMode = monochrome ? BlendMode.clear : BlendMode.srcOver;
    final capsuleWidth = r * 0.18;

    canvas
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: centre.translate(0, -r * 0.055),
            width: capsuleWidth,
            height: r * 0.28,
          ),
          Radius.circular(capsuleWidth / 2),
        ),
        ink,
      )
      ..drawRect(
        Rect.fromCenter(
          center: centre.translate(0, r * 0.10),
          width: r * 0.055,
          height: r * 0.10,
        ),
        ink,
      )
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: centre.translate(0, r * 0.155),
            width: r * 0.22,
            height: r * 0.055,
          ),
          Radius.circular(r * 0.0275),
        ),
        ink,
      );

    if (monochrome) canvas.restore();
    canvas.restore();
  }

  void _paintGround(Canvas canvas, Size size, double s) {
    if (ground == LogoGround.none) return;

    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF3B49A8), YapPalette.indigo],
      ).createShader(Offset.zero & size);

    switch (ground) {
      case LogoGround.squircle:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Offset.zero & size,
            Radius.circular(s * 0.22),
          ),
          paint,
        );
      case LogoGround.circle:
        canvas.drawCircle(size.center(Offset.zero), s / 2, paint);
      case LogoGround.none:
        break;
    }
  }

  /// One ring of pointed petals, each a pair of arcs meeting at the tip.
  void _petals(
    Canvas canvas,
    Offset centre,
    double tip,
    double base,
    int count,
    Color color,
    double rotation,
  ) {
    final paint = Paint()..color = color;
    final half = math.pi / count;

    for (var i = 0; i < count; i++) {
      final angle = (math.pi * 2 / count) * i - math.pi / 2 + rotation;

      Offset at(double radius, double theta) =>
          centre + Offset(math.cos(theta), math.sin(theta)) * radius;

      final start = at(base, angle);
      final tipPoint = at(tip, angle);
      final left = at((tip + base) / 2 * 1.06, angle - half * 0.9);
      final right = at((tip + base) / 2 * 1.06, angle + half * 0.9);

      canvas.drawPath(
        Path()
          ..moveTo(start.dx, start.dy)
          ..quadraticBezierTo(left.dx, left.dy, tipPoint.dx, tipPoint.dy)
          ..quadraticBezierTo(right.dx, right.dy, start.dx, start.dy)
          ..close(),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(YapLogoPainter old) =>
      old.ground != ground ||
      old.contentScale != contentScale ||
      old.monochrome != monochrome;
}

/// The mark as a widget, for anywhere in the app that wants it.
class YapLogo extends StatelessWidget {
  const YapLogo({super.key, this.size = 48, this.ground = LogoGround.squircle});

  final double size;
  final LogoGround ground;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: YapLogoPainter(ground: ground),
      );
}
