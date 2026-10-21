import 'package:flutter/material.dart';

enum AppPalette { lavender, ocean, midnight }

extension PaletteTheme on AppPalette {
  String get label => switch (this) {
    AppPalette.lavender => 'Lavender Soft',
    AppPalette.ocean => 'Ocean Calm',
    AppPalette.midnight => 'Midnight',
  };

  ThemeData get theme {
    final dark = this == AppPalette.midnight;
    final primary = switch (this) {
      AppPalette.lavender => const Color(0xFF8055D7),
      AppPalette.ocean => const Color(0xFF256E82),
      AppPalette.midnight => const Color(0xFFBCA2FA),
    };
    final scheme =
        ColorScheme.fromSeed(
          seedColor: primary,
          brightness: dark ? Brightness.dark : Brightness.light,
        ).copyWith(
          primary: primary,
          secondary: dark ? const Color(0xFFF3ACA4) : const Color(0xFF9B403A),
          secondaryContainer: dark
              ? const Color(0xFF55383D)
              : const Color(0xFFFFDAD5),
          surface: dark ? const Color(0xFF201B2A) : const Color(0xFFFAF8FD),
        );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
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
