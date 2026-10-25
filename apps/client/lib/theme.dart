import 'package:flutter/material.dart';
import 'app_motion.dart';

Color onlinePresenceColor(ColorScheme colors) =>
    colors.brightness == Brightness.dark
    ? const Color(0xFF42E67A)
    : const Color(0xFF007A38);

@immutable
class MessageColors extends ThemeExtension<MessageColors> {
  final Color start, end, foreground;
  const MessageColors(this.start, this.end, this.foreground);
  @override
  MessageColors copyWith({Color? start, Color? end, Color? foreground}) =>
      MessageColors(
        start ?? this.start,
        end ?? this.end,
        foreground ?? this.foreground,
      );
  @override
  MessageColors lerp(covariant MessageColors? other, double t) => other == null
      ? this
      : MessageColors(
          Color.lerp(start, other.start, t)!,
          Color.lerp(end, other.end, t)!,
          Color.lerp(foreground, other.foreground, t)!,
        );
}

enum AppPalette {
  lavender,
  ocean,
  midnight,
  lagoon,
  reef,
  bioluminescence,
  sunset,
  halo,
}

extension PaletteTheme on AppPalette {
  String get label => switch (this) {
    AppPalette.halo => 'Halo',
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
        this == AppPalette.halo ||
        this == AppPalette.midnight ||
        this == AppPalette.bioluminescence;
    // Primary, gradient accent, warm accent, surface, text and soft surface from the selected references.
    final (a, b, c, bg, ink, soft) = switch (this) {
      AppPalette.halo => (
        0xFFC3D0FF,
        0xFF8FA9DF,
        0xFF9CAFE7,
        0xFF101A35,
        0xFFF1F3FA,
        0xFF2C3D60,
      ),
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
    var scheme = base.copyWith(
      primary: primary,
      onPrimary: dark ? Color(bg) : Colors.white,
      secondary: Color(b),
      tertiary: accent.primary,
      primaryContainer: Color(soft),
      onPrimaryContainer: Color(ink),
      tertiaryContainer: dark ? Color.lerp(Color(bg), Color(c), .25) : Color(c),
      onTertiaryContainer: Color(ink),
      secondaryContainer: Color.lerp(Color(bg), Color(b), .18),
      surface: Color(bg),
      onSurface: Color(ink),
      onSurfaceVariant: dark
          ? const Color(0xFFC9BED7)
          : const Color(0xFF736A81),
      surfaceContainerLowest: dark
          ? Color.lerp(Color(bg), Colors.white, .04)
          : Colors.white,
    );
    if (this == AppPalette.halo) {
      scheme = scheme.copyWith(
        surfaceContainerLowest: const Color(0xFF1C2B4B),
        surfaceContainerLow: const Color(0xFF1C2B4B),
        surfaceContainer: const Color(0xFF1C2B4B),
        surfaceContainerHigh: const Color(0xFF2C3D60),
        surfaceContainerHighest: const Color(0xFF2C3D60),
        onSurfaceVariant: const Color(0xFFBDC8E1),
        tertiaryContainer: const Color(0xFF1C2B4B),
        secondaryContainer: const Color(0xFF2C3D60),
        outline: const Color(0xFF7C91B8),
        outlineVariant: const Color(0xFF425577),
      );
    }
    return ThemeData(
      extensions: [
        this == AppPalette.halo
            ? const MessageColors(
                Color(0xFF365B8B),
                Color(0xFF304E77),
                Color(0xFFF1F3FA),
              )
            : MessageColors(scheme.primary, scheme.primary, scheme.onPrimary),
      ],
      useMaterial3: true,
      pageTransitionsTheme: PageTransitionsTheme(
        builders: {
          for (final platform in TargetPlatform.values)
            platform: const AppPageTransitions(),
        },
      ),
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      colorScheme: scheme,
      scaffoldBackgroundColor: Color.lerp(scheme.surface, scheme.primary, .04),
      dividerColor: scheme.outlineVariant.withValues(alpha: .5),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.tertiaryContainer,
        foregroundColor: scheme.onTertiaryContainer,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        toolbarHeight: 64,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        ),
      ),
      chipTheme: ChipThemeData(
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      listTileTheme: ListTileThemeData(iconColor: scheme.primary),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 22,
          fontWeight: FontWeight.w700,
        ),
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
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 16,
        ),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15),
        floatingLabelBehavior: FloatingLabelBehavior.always,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: scheme.primary, width: 2),
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
