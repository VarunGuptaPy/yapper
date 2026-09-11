import 'package:flutter/material.dart';

/// Yap's colour language.
///
/// The two traditions this app borrows from share more than it first looks.
/// Indigo is both Indian *neel* and Japanese *ai*; vermillion is both *sindoor*
/// and *shu*. Those two dyes carry the palette. Marigold and a deep teal come
/// in as accents, and the ground is warm paper rather than white — *washi* in
/// light, *sumi* ink in dark.
///
/// The layout discipline is the Japanese half (generous space, thin rules,
/// restraint); the saturation is the Indian half.
abstract final class YapPalette {
  // Indigo — ai / neel
  static const indigo = Color(0xFF2E3A87);
  static const indigoLight = Color(0xFFAEB8FF);

  // Vermillion — shu / sindoor
  static const vermillion = Color(0xFFC0452A);
  static const vermillionLight = Color(0xFFFFB4A0);

  // Marigold — genda
  static const marigold = Color(0xFFB97A12);
  static const marigoldLight = Color(0xFFF0C26A);

  // Deep teal — the fourth accent, for people
  static const teal = Color(0xFF0F6E70);
  static const tealLight = Color(0xFF6FD6D3);

  // Grounds
  static const washi = Color(0xFFFAF5EC);
  static const washiRaised = Color(0xFFFFFCF6);
  static const washiSunk = Color(0xFFF2EADC);
  static const sumi = Color(0xFF121319);
  static const sumiRaised = Color(0xFF1C1D27);
  static const sumiHigh = Color(0xFF272833);
}

/// Accents Material's [ColorScheme] has no slot for.
@immutable
class YapAccents extends ThemeExtension<YapAccents> {
  const YapAccents({
    required this.idea,
    required this.person,
    required this.rule,
    required this.goal,
    required this.neutral,
    required this.pattern,
    required this.waveform,
  });

  final Color idea;
  final Color person;
  final Color rule;
  final Color goal;
  final Color neutral;

  /// Ink for the background lattices. Already faint — painters use it as-is.
  final Color pattern;

  /// Left-to-right gradient for the voice waveform.
  final List<Color> waveform;

  static const _light = YapAccents(
    idea: YapPalette.marigold,
    person: YapPalette.teal,
    rule: YapPalette.vermillion,
    goal: YapPalette.indigo,
    neutral: Color(0xFF7C756B),
    pattern: Color(0x0F2E3A87),
    waveform: [YapPalette.indigo, YapPalette.teal, YapPalette.vermillion],
  );

  static const _dark = YapAccents(
    idea: YapPalette.marigoldLight,
    person: YapPalette.tealLight,
    rule: YapPalette.vermillionLight,
    goal: YapPalette.indigoLight,
    neutral: Color(0xFF9A9288),
    pattern: Color(0x14AEB8FF),
    waveform: [
      YapPalette.indigoLight,
      YapPalette.tealLight,
      YapPalette.marigoldLight,
    ],
  );

  @override
  YapAccents copyWith({
    Color? idea,
    Color? person,
    Color? rule,
    Color? goal,
    Color? neutral,
    Color? pattern,
    List<Color>? waveform,
  }) =>
      YapAccents(
        idea: idea ?? this.idea,
        person: person ?? this.person,
        rule: rule ?? this.rule,
        goal: goal ?? this.goal,
        neutral: neutral ?? this.neutral,
        pattern: pattern ?? this.pattern,
        waveform: waveform ?? this.waveform,
      );

  @override
  YapAccents lerp(YapAccents? other, double t) {
    if (other == null) return this;
    return YapAccents(
      idea: Color.lerp(idea, other.idea, t)!,
      person: Color.lerp(person, other.person, t)!,
      rule: Color.lerp(rule, other.rule, t)!,
      goal: Color.lerp(goal, other.goal, t)!,
      neutral: Color.lerp(neutral, other.neutral, t)!,
      pattern: Color.lerp(pattern, other.pattern, t)!,
      waveform: [
        for (var i = 0; i < waveform.length; i++)
          Color.lerp(waveform[i], other.waveform[i], t)!,
      ],
    );
  }
}

/// Convenience: `context.accents.person`.
extension YapThemeContext on BuildContext {
  YapAccents get accents =>
      Theme.of(this).extension<YapAccents>() ?? YapAccents._light;
  ColorScheme get scheme => Theme.of(this).colorScheme;
}

class YapTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static const _display = 'InstrumentSerif';

  static ThemeData _build(Brightness brightness) {
    final isLight = brightness == Brightness.light;
    final scheme = isLight ? _lightScheme : _darkScheme;
    final accents = isLight ? YapAccents._light : YapAccents._dark;

    final base = ThemeData(colorScheme: scheme, useMaterial3: true);

    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      extensions: [accents],
      textTheme: _textTheme(base.textTheme, scheme),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: _display,
          fontSize: 26,
          height: 1.1,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        margin: EdgeInsets.zero,
      ),
      chipTheme: ChipThemeData(
        side: BorderSide(color: scheme.outlineVariant),
        backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        labelStyle: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: _inputBorder(scheme.outlineVariant),
        enabledBorder: _inputBorder(scheme.outlineVariant),
        focusedBorder: _inputBorder(scheme.primary, width: 1.6),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer,
        elevation: 0,
        height: 66,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11.5,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.7),
        thickness: 1,
        space: 1,
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color, width: width),
      );

  /// Display sizes use the bundled serif; everything you actually read at
  /// length stays on the platform font, which also keeps Devanagari correct in
  /// raw transcripts.
  static TextTheme _textTheme(TextTheme base, ColorScheme scheme) {
    TextStyle serif(double size, {double height = 1.12}) => TextStyle(
          fontFamily: _display,
          fontSize: size,
          height: height,
          color: scheme.onSurface,
          letterSpacing: 0,
        );

    return base.copyWith(
      displayLarge: serif(44),
      displayMedium: serif(36),
      displaySmall: serif(30),
      headlineLarge: serif(30),
      headlineMedium: serif(26),
      headlineSmall: serif(23),
      titleLarge: serif(21, height: 1.2),
      titleMedium: base.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
      ),
      bodyLarge: base.bodyLarge?.copyWith(height: 1.45),
      bodyMedium: base.bodyMedium?.copyWith(height: 1.45),
      labelLarge: base.labelLarge?.copyWith(letterSpacing: 0.3),
      labelMedium: base.labelMedium?.copyWith(
        letterSpacing: 0.6,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  static const _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: YapPalette.indigo,
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFDFE2F7),
    onPrimaryContainer: Color(0xFF141C4D),
    secondary: YapPalette.vermillion,
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFFBE0D8),
    onSecondaryContainer: Color(0xFF4A1408),
    tertiary: YapPalette.marigold,
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFFBEBCB),
    onTertiaryContainer: Color(0xFF432C00),
    error: Color(0xFFA8321F),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFBDCD6),
    onErrorContainer: Color(0xFF410E06),
    surface: YapPalette.washi,
    onSurface: Color(0xFF1D1B19),
    onSurfaceVariant: Color(0xFF574F46),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: YapPalette.washiRaised,
    surfaceContainer: Color(0xFFF5EEE2),
    surfaceContainerHigh: YapPalette.washiSunk,
    surfaceContainerHighest: Color(0xFFEDE4D4),
    outline: Color(0xFF837B71),
    outlineVariant: Color(0xFFD9D0C2),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: Color(0xFF32302D),
    onInverseSurface: Color(0xFFF6EFE4),
    inversePrimary: YapPalette.indigoLight,
  );

  static const _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: YapPalette.indigoLight,
    onPrimary: Color(0xFF19225E),
    primaryContainer: Color(0xFF2C3679),
    onPrimaryContainer: Color(0xFFDDE1FF),
    secondary: YapPalette.vermillionLight,
    onSecondary: Color(0xFF5C1A0A),
    secondaryContainer: Color(0xFF7A2B16),
    onSecondaryContainer: Color(0xFFFFDBD1),
    tertiary: YapPalette.marigoldLight,
    onTertiary: Color(0xFF432C00),
    tertiaryContainer: Color(0xFF5F4100),
    onTertiaryContainer: Color(0xFFFFDEA8),
    error: Color(0xFFFFB4A8),
    onError: Color(0xFF5F1408),
    errorContainer: Color(0xFF862013),
    onErrorContainer: Color(0xFFFFDAD4),
    surface: YapPalette.sumi,
    onSurface: Color(0xFFE9E3D9),
    onSurfaceVariant: Color(0xFFC9C1B6),
    surfaceContainerLowest: Color(0xFF0C0D12),
    surfaceContainerLow: Color(0xFF17181F),
    surfaceContainer: YapPalette.sumiRaised,
    surfaceContainerHigh: Color(0xFF22232D),
    surfaceContainerHighest: YapPalette.sumiHigh,
    outline: Color(0xFF938C82),
    outlineVariant: Color(0xFF3B3A44),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: Color(0xFFE9E3D9),
    onInverseSurface: Color(0xFF32302D),
    inversePrimary: YapPalette.indigo,
  );
}

/// Colour per note type, so a list scans by hue before you read a word.
Color noteTypeColor(BuildContext context, String typeName) {
  final a = context.accents;
  return switch (typeName) {
    'idea' => a.idea,
    'person' => a.person,
    'rule' => a.rule,
    'goal' => a.goal,
    _ => a.neutral,
  };
}

IconData noteTypeIcon(String typeName) => switch (typeName) {
      'idea' => Icons.auto_awesome_outlined,
      'person' => Icons.person_outline_rounded,
      'rule' => Icons.shield_outlined,
      'goal' => Icons.flag_outlined,
      _ => Icons.subject_rounded,
    };
