@Tags(['icons'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/ui/common/yap_logo.dart';

/// Renders the launcher icons from [YapLogoPainter], so the icon and the app
/// are drawn by the same code in the same palette.
///
///   flutter test test/tool/generate_icons_test.dart --run-skipped
void main() {
  const res = 'android/app/src/main/res';

  /// Android's density buckets, as multiples of the 48dp baseline.
  const densities = {
    'mdpi': 1,
    'hdpi': 1.5,
    'xhdpi': 2,
    'xxhdpi': 3,
    'xxxhdpi': 4,
  };

  Future<void> write(String path, int pixels, YapLogoPainter painter) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    painter.paint(canvas, Size(pixels.toDouble(), pixels.toDouble()));
    final image = await recorder.endRecording().toImage(pixels, pixels);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);

    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List(), flush: true);
  }

  testWidgets('write launcher icons', (tester) async {
    await tester.runAsync(() async {
      for (final entry in densities.entries) {
        final dir = '$res/mipmap-${entry.key}';
        final legacy = (48 * entry.value).round();
        // Adaptive layers are 108dp; only the middle survives the mask, so the
        // mark is scaled to sit inside the safe zone.
        final adaptive = (108 * entry.value).round();

        await write(
          '$dir/ic_launcher.png',
          legacy,
          const YapLogoPainter(),
        );
        await write(
          '$dir/ic_launcher_round.png',
          legacy,
          const YapLogoPainter(ground: LogoGround.circle),
        );
        await write(
          '$dir/ic_launcher_foreground.png',
          adaptive,
          const YapLogoPainter(ground: LogoGround.none, contentScale: 0.60),
        );
        await write(
          '$dir/ic_launcher_monochrome.png',
          adaptive,
          const YapLogoPainter(
            ground: LogoGround.none,
            contentScale: 0.60,
            monochrome: true,
          ),
        );
      }

      // A large flat render for the Play listing and for eyeballing the design.
      await write(
        'test/ui/previews/logo.png',
        512,
        const YapLogoPainter(),
      );
    });

    for (final density in densities.keys) {
      expect(File('$res/mipmap-$density/ic_launcher.png').existsSync(), isTrue);
      expect(
        File('$res/mipmap-$density/ic_launcher_foreground.png').existsSync(),
        isTrue,
      );
    }
  });
}
