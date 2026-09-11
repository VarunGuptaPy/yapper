import 'package:flutter/material.dart';

/// Material 3, light and dark, seeded from a single colour.
class YapTheme {
  static const _seed = Color(0xFF6B4EFF);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
    );
  }
}

/// Colour per note type, used by chips and avatars so a list scans quickly.
Color noteTypeColor(ColorScheme scheme, String typeName) => switch (typeName) {
      'idea' => scheme.primary,
      'person' => scheme.tertiary,
      'rule' => scheme.error,
      'goal' => scheme.secondary,
      _ => scheme.outline,
    };

IconData noteTypeIcon(String typeName) => switch (typeName) {
      'idea' => Icons.lightbulb_outline,
      'person' => Icons.person_outline,
      'rule' => Icons.gavel_outlined,
      'goal' => Icons.flag_outlined,
      _ => Icons.sticky_note_2_outlined,
    };
