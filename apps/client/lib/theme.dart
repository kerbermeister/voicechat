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
          secondary: dark ? const Color(0xFFF3ACA4) : const Color(0xFF805546),
          tertiary: dark ? const Color(0xFFFFB4AB) : const Color(0xFF8B4941),
          tertiaryContainer: dark
              ? const Color(0xFF653B40)
              : const Color(0xFFFFDAD5),
          onTertiaryContainer: dark
              ? const Color(0xFFFFDAD5)
              : const Color(0xFF4C293A),
          primaryContainer: dark
              ? const Color(0xFF493269)
              : const Color(0xFFEDE4FB),
          onPrimaryContainer: dark
              ? const Color(0xFFEDE4FB)
              : const Color(0xFF513285),
          onSurface: dark ? const Color(0xFFEDE7F5) : const Color(0xFF312940),
          onSurfaceVariant: dark
              ? const Color(0xFFC7BDCF)
              : const Color(0xFF736A81),
          secondaryContainer: dark
              ? const Color(0xFF55383D)
              : const Color(0xFFFFDAD5),
          surface: dark ? const Color(0xFF201B2A) : const Color(0xFFFAF8FD),
        );
    return ThemeData(
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark
          ? const Color(0xFF17131E)
          : const Color(0xFFF0EBF7),
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
