import 'package:flutter/material.dart';

/// Shared visual language for Amadeus' onboarding and settings surfaces.
///
/// The pet itself stays visually quiet and transparent. Configuration surfaces
/// use a restrained wine accent, cool neutrals, and generous spacing so they
/// read like a desktop product instead of a mobile settings list.
abstract final class AmadeusTheme {
  static const wine = Color(0xFFB8667A);
  static const wineLight = Color(0xFFE6A6B5);
  static const sage = Color(0xFF738A79);
  static const sageLight = Color(0xFFAFC0B3);
  static const ink = Color(0xFF18151A);
  static const mist = Color(0xFFF7F5F1);
  static const blueGrey = Color(0xFF95A4BE);
  static const mint = sage;
  static const focus = Color(0xFFD6A15F);
  static const memory = Color(0xFF9B8AC4);
  static const event = Color(0xFF6E91C7);

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: sage,
          brightness: brightness,
          dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
        ).copyWith(
          primary: dark ? sageLight : const Color(0xFF536B5A),
          onPrimary: dark ? const Color(0xFF213329) : Colors.white,
          secondary: dark ? wineLight : const Color(0xFF8F5664),
          tertiary: dark ? const Color(0xFFBAC5D9) : const Color(0xFF59667A),
          surface: dark ? const Color(0xFF161714) : mist,
          surfaceContainerLowest: dark
              ? const Color(0xFF10110F)
              : const Color(0xFFFFFFFF),
          surfaceContainerLow: dark
              ? const Color(0xFF1D1E1B)
              : const Color(0xFFFCFAF7),
          surfaceContainer: dark
              ? const Color(0xFF252622)
              : const Color(0xFFF0ECE6),
          surfaceContainerHigh: dark
              ? const Color(0xFF2D2F2A)
              : const Color(0xFFE8E2DA),
          outline: dark ? const Color(0xFF7B8079) : const Color(0xFF7B7770),
          outlineVariant: dark
              ? const Color(0xFF3A3D37)
              : const Color(0xFFD8D1C8),
        );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: Colors.transparent,
      dividerColor: scheme.outlineVariant.withValues(alpha: 0.7),
      textTheme: Typography.material2021(platform: TargetPlatform.macOS).white
          .apply(
            bodyColor: scheme.onSurface,
            displayColor: scheme.onSurface,
            fontFamilyFallback: const [
              'SF Pro Text',
              'Segoe UI',
              'Microsoft YaHei',
            ],
          ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.8)),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 13,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        selectedIconTheme: IconThemeData(color: scheme.primary),
        selectedLabelTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 13,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 42),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 42),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }
}
