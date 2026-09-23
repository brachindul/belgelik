import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Light Theme Colors ("Prestijli Parşömen")
  static const _lightPrimary = Color(0xFF1E3A3A);
  static const _lightOnPrimary = Color(0xFFFFFFFF);
  static const _lightPrimaryContainer = Color(0xFFE2EFEA);
  static const _lightOnPrimaryContainer = Color(0xFF0A2525);
  static const _lightSurface = Color(0xFFFDFBF7);
  static const _lightOnSurface = Color(0xFF1A2221);
  static const _lightSurfaceLowest = Color(0xFFFFFFFF);
  static const _lightSurfaceHighest = Color(0xFFF1EDE4);
  static const _lightOutline = Color(0xFF7A8F85);
  static const _lightOutlineVariant = Color(0xFFE4DFD5);
  static const _lightSecondary = Color(0xFF536A60);
  static const _lightOnSecondary = Color(0xFFFFFFFF);

  // Dark Theme Colors ("Gece Kütüphanesi")
  static const _darkPrimary = Color(0xFF2A5C54);
  static const _darkOnPrimary = Color(0xFF0F1214);
  static const _darkPrimaryContainer = Color(0xFF1B3D37);
  static const _darkOnPrimaryContainer = Color(0xFF8FE8D9);
  static const _darkSurface = Color(0xFF0F1214);
  static const _darkOnSurface = Color(0xFFE2E8F0);
  static const _darkSurfaceLowest = Color(0xFF161B1E);
  static const _darkSurfaceHighest = Color(0xFF222B2F);
  static const _darkOutline = Color(0xFF4C5B61);
  static const _darkOutlineVariant = Color(0xFF2A3438);
  static const _darkSecondary = Color(0xFF8DAA9D);
  static const _darkOnSecondary = Color(0xFF162520);

  static ThemeData light() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: _lightPrimary,
          brightness: Brightness.light,
        ).copyWith(
          primary: _lightPrimary,
          onPrimary: _lightOnPrimary,
          primaryContainer: _lightPrimaryContainer,
          onPrimaryContainer: _lightOnPrimaryContainer,
          surface: _lightSurface,
          onSurface: _lightOnSurface,
          surfaceContainerLowest: _lightSurfaceLowest,
          surfaceContainerHighest: _lightSurfaceHighest,
          outline: _lightOutline,
          outlineVariant: _lightOutlineVariant,
          secondary: _lightSecondary,
          onSecondary: _lightOnSecondary,
          error: const Color(0xFFBA1A1A),
          onError: const Color(0xFFFFFFFF),
        );
    return _theme(scheme, false);
  }

  static ThemeData dark() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: _darkPrimary,
          brightness: Brightness.dark,
        ).copyWith(
          primary: _darkPrimary,
          onPrimary: _darkOnPrimary,
          primaryContainer: _darkPrimaryContainer,
          onPrimaryContainer: _darkOnPrimaryContainer,
          surface: _darkSurface,
          onSurface: _darkOnSurface,
          surfaceContainerLowest: _darkSurfaceLowest,
          surfaceContainerHighest: _darkSurfaceHighest,
          outline: _darkOutline,
          outlineVariant: _darkOutlineVariant,
          secondary: _darkSecondary,
          onSecondary: _darkOnSecondary,
          error: const Color(0xFFFFB4AB),
          onError: const Color(0xFF690005),
        );
    return _theme(scheme, true);
  }

  static ThemeData _theme(ColorScheme scheme, bool isDark) {
    final baseTextTheme = isDark
        ? ThemeData.dark().textTheme
        : ThemeData.light().textTheme;

    final textTheme = GoogleFonts.plusJakartaSansTextTheme(baseTextTheme)
        .copyWith(
          titleLarge: GoogleFonts.outfit(
            textStyle: baseTextTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
              letterSpacing: 0,
            ),
          ),
          titleMedium: GoogleFonts.outfit(
            textStyle: baseTextTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
              letterSpacing: 0,
            ),
          ),
          headlineSmall: GoogleFonts.outfit(
            textStyle: baseTextTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
              letterSpacing: 0,
            ),
          ),
          headlineMedium: GoogleFonts.outfit(
            textStyle: baseTextTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
              letterSpacing: 0,
            ),
          ),
        );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      textTheme: textTheme,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        titleTextStyle: GoogleFonts.outfit(
          color: scheme.onSurface,
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: scheme.outlineVariant.withAlpha(180),
            width: 0.75,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withAlpha(isDark ? 100 : 150),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: scheme.primary.withAlpha(100),
            width: 1.5,
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 2,
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
