import 'package:flutter/material.dart';

/// Shared visual language for Amadeus' onboarding and settings surfaces.
///
/// The pet itself stays visually quiet and transparent. Configuration surfaces
/// use a restrained wine accent, cool neutrals, and generous spacing so they
/// read like a desktop product instead of a mobile settings list.
abstract final class AmadeusTheme {
  static const wine = Color(0xFFB8667A);
  static const wineLight = Color(0xFFE6A6B5);
  static const ink = Color(0xFF18151A);
  static const mist = Color(0xFFF7F3F4);
  static const blueGrey = Color(0xFF95A4BE);
  static const mint = Color(0xFF79BDA8);

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: wine,
          brightness: brightness,
          dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
        ).copyWith(
          primary: dark ? wineLight : const Color(0xFF8F3F56),
          onPrimary: dark ? const Color(0xFF4B1125) : Colors.white,
          secondary: dark ? const Color(0xFFBAC5D9) : const Color(0xFF526079),
          tertiary: dark ? const Color(0xFF9ED9C5) : const Color(0xFF2E725F),
          surface: dark ? const Color(0xFF151317) : mist,
          surfaceContainerLowest: dark
              ? const Color(0xFF100E12)
              : const Color(0xFFFFFFFF),
          surfaceContainerLow: dark
              ? const Color(0xFF1C191F)
              : const Color(0xFFFBF8F9),
          surfaceContainer: dark
              ? const Color(0xFF242027)
              : const Color(0xFFF2ECEE),
          surfaceContainerHigh: dark
              ? const Color(0xFF2C2730)
              : const Color(0xFFECE4E7),
          outline: dark ? const Color(0xFF7B737F) : const Color(0xFF81747A),
          outlineVariant: dark
              ? const Color(0xFF3B3540)
              : const Color(0xFFD8CDD1),
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
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.8)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 13,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
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
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 42),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}
