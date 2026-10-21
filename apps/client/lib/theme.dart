import 'package:flutter/material.dart';

Color onlinePresenceColor(ColorScheme colors) =>
    colors.brightness == Brightness.dark
    ? const Color(0xFF42E67A)
    : const Color(0xFF007A38);

enum AppPalette {
  lavender,
  ocean,
  midnight,
  lagoon,
  reef,
  bioluminescence,
  sunset,
}

extension PaletteTheme on AppPalette {
  String get label => switch (this) {
    AppPalette.lavender => 'Lavender Soft',
    AppPalette.ocean => 'Ocean Calm',
    AppPalette.midnight => 'Midnight',
    AppPalette.lagoon => 'Лагуна',
    AppPalette.reef => 'Коралловый риф',
    AppPalette.bioluminescence => 'Биолюминесценция',
    AppPalette.sunset => 'Закат в бухте',
  };

  ThemeData get theme {
    final dark =
        this == AppPalette.midnight || this == AppPalette.bioluminescence;
    // Primary, gradient accent, warm accent, surface, text and soft surface from the selected references.
    final (a, b, c, bg, ink, soft) = switch (this) {
      AppPalette.lavender => (
        0xFF8055D7,
        0xFFAA8DF0,
        0xFFFA8D83,
        0xFFFAF8FD,
        0xFF312940,
        0xFFEDE4FB,
      ),
      AppPalette.ocean => (
        0xFF256E82,
        0xFF66AAB8,
        0xFFF0BAA0,
        0xFFF4FAFA,
        0xFF25444C,
        0xFFDCEEF0,
      ),
      AppPalette.midnight => (
        0xFFBCA2FA,
        0xFF8D80B3,
        0xFFF3ACA4,
        0xFF201B2A,
        0xFFEDE7F5,
        0xFF493269,
      ),
      AppPalette.lagoon => (
        0xFF087E86,
        0xFF5CCBC5,
        0xFFFFE2AD,
        0xFFF1FAF7,
        0xFF184B4B,
        0xFFD4F0E9,
      ),
      AppPalette.reef => (
        0xFFAB4D59,
        0xFFEB9D94,
        0xFF7AC6BD,
        0xFFFFF8F1,
        0xFF57313C,
        0xFFF7DFD7,
      ),
      AppPalette.bioluminescence => (
        0xFF79E2D3,
        0xFF254778,
        0xFFBF99F7,
        0xFF111E32,
        0xFFEAF4F8,
        0xFF223B4D,
      ),
      AppPalette.sunset => (
        0xFF8B5B9D,
        0xFFE59D9B,
        0xFFFFD3A1,
        0xFFFFF7F2,
        0xFF50374F,
        0xFFF2DFE9,
      ),
    };
    final primary = Color(a);
    final base = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: dark ? Brightness.dark : Brightness.light,
    );
    final accent = ColorScheme.fromSeed(
      seedColor: Color(c),
      brightness: base.brightness,
    );
    final scheme = base.copyWith(
      primary: primary,
      secondary: Color(b),
      tertiary: accent.primary,
      primaryContainer: Color(soft),
      onPrimaryContainer: Color(ink),
      tertiaryContainer: Color.lerp(Color(bg), Color(c), dark ? .25 : .55),
      onTertiaryContainer: Color(ink),
      secondaryContainer: Color.lerp(Color(bg), Color(b), .18),
      surface: Color(bg),
      onSurface: Color(ink),
    );
    return ThemeData(
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      colorScheme: scheme,
      scaffoldBackgroundColor: Color.lerp(scheme.surface, scheme.primary, .04),
      dividerColor: scheme.outlineVariant.withValues(alpha: .5),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          side: const WidgetStatePropertyAll(BorderSide.none),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.surfaceContainerLowest,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? scheme.onPrimary
                : scheme.onSurfaceVariant,
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide.none,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
    );
  }
}
