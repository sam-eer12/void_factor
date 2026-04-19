import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class MonolithTheme {
  MonolithTheme._();

  // ──────────────────────────────────────────────
  // COLORS — The Binary Palette
  // ──────────────────────────────────────────────
  static const Color primary = Color(0xFF000000);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color background = Color(0xFFF9F9F9);
  static const Color error = Color(0xFFBA1A1A);
  static const Color onPrimary = Color(0xFFE2E2E2);
  static const Color onSurface = Color(0xFF1A1C1C);
  static const Color outline = Color(0xFF777777);
  static const Color surfaceContainer = Color(0xFFEEEEEE);
  static const Color surfaceContainerHigh = Color(0xFFE8E8E8);

  // ──────────────────────────────────────────────
  // BORDERS
  // ──────────────────────────────────────────────
  static const double borderWidth = 2.0;
  static const double heroBorderWidth = 3.0;

  static BorderSide get defaultBorder => const BorderSide(
        color: primary,
        width: borderWidth,
      );

  static BorderSide get heroBorder => const BorderSide(
        color: primary,
        width: heroBorderWidth,
      );

  // ──────────────────────────────────────────────
  // SHADOWS — Hard Offset, Zero Blur
  // ──────────────────────────────────────────────
  static List<BoxShadow> get hardShadow => const [
        BoxShadow(
          color: primary,
          offset: Offset(4, 4),
          blurRadius: 0,
          spreadRadius: 0,
        ),
      ];

  static List<BoxShadow> get smallHardShadow => const [
        BoxShadow(
          color: primary,
          offset: Offset(2, 2),
          blurRadius: 0,
          spreadRadius: 0,
        ),
      ];

  // ──────────────────────────────────────────────
  // DECORATIONS
  // ──────────────────────────────────────────────
  static BoxDecoration get cardDecoration => BoxDecoration(
        color: surface,
        border: Border.all(color: primary, width: borderWidth),
        borderRadius: BorderRadius.zero,
        boxShadow: hardShadow,
      );

  static BoxDecoration get invertedCardDecoration => BoxDecoration(
        color: primary,
        border: Border.all(color: primary, width: borderWidth),
        borderRadius: BorderRadius.zero,
        boxShadow: hardShadow,
      );

  static BoxDecoration get containerDecoration => BoxDecoration(
        color: surface,
        border: Border.all(color: primary, width: borderWidth),
        borderRadius: BorderRadius.zero,
      );

  // ──────────────────────────────────────────────
  // TYPOGRAPHY — Space Grotesk
  // ──────────────────────────────────────────────
  static TextStyle get displayLarge => GoogleFonts.spaceGrotesk(
        fontSize: 36,
        fontWeight: FontWeight.w900,
        letterSpacing: -0.02 * 36,
        height: 1.1,
        color: primary,
      );

  static TextStyle get displayMedium => GoogleFonts.spaceGrotesk(
        fontSize: 28,
        fontWeight: FontWeight.w900,
        letterSpacing: -0.02 * 28,
        height: 1.1,
        color: primary,
      );

  static TextStyle get headlineLarge => GoogleFonts.spaceGrotesk(
        fontSize: 24,
        fontWeight: FontWeight.w900,
        letterSpacing: -0.02 * 24,
        height: 1.1,
        color: primary,
      );

  static TextStyle get headlineMedium => GoogleFonts.spaceGrotesk(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.02 * 20,
        height: 1.2,
        color: primary,
      );

  static TextStyle get bodyLarge => GoogleFonts.spaceGrotesk(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
        height: 1.5,
        color: primary,
      );

  static TextStyle get bodyMedium => GoogleFonts.spaceGrotesk(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
        height: 1.5,
        color: primary,
      );

  static TextStyle get labelLarge => GoogleFonts.spaceGrotesk(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.05 * 14,
        color: primary,
      );

  static TextStyle get labelMedium => GoogleFonts.spaceGrotesk(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.05 * 12,
        color: primary,
      );

  static TextStyle get labelSmall => GoogleFonts.spaceGrotesk(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.05 * 10,
        color: primary,
      );

  // ──────────────────────────────────────────────
  // THEME DATA
  // ──────────────────────────────────────────────
  static ThemeData get themeData => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: background,
        colorScheme: const ColorScheme.light(
          primary: primary,
          onPrimary: surface,
          surface: surface,
          onSurface: onSurface,
          error: error,
          outline: outline,
        ),
        textTheme: TextTheme(
          displayLarge: displayLarge,
          displayMedium: displayMedium,
          headlineLarge: headlineLarge,
          headlineMedium: headlineMedium,
          bodyLarge: bodyLarge,
          bodyMedium: bodyMedium,
          labelLarge: labelLarge,
          labelMedium: labelMedium,
          labelSmall: labelSmall,
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: surface,
          foregroundColor: primary,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: headlineLarge,
          shape: const Border(
            bottom: BorderSide(color: primary, width: borderWidth),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: false,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: const OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide(color: primary, width: borderWidth),
          ),
          enabledBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide(color: primary, width: borderWidth),
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide(color: primary, width: heroBorderWidth),
          ),
          errorBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide(color: error, width: heroBorderWidth),
          ),
          labelStyle: labelLarge,
          hintStyle: bodyMedium.copyWith(color: outline),
        ),
        dividerTheme: const DividerThemeData(
          color: primary,
          thickness: borderWidth,
          space: 0,
        ),
        cardTheme: const CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.zero,
            side: BorderSide(color: primary, width: borderWidth),
          ),
          color: surface,
          margin: EdgeInsets.zero,
        ),
        bottomNavigationBarTheme: BottomNavigationBarThemeData(
          backgroundColor: surface,
          selectedItemColor: primary,
          unselectedItemColor: outline,
          type: BottomNavigationBarType.fixed,
          selectedLabelStyle: labelMedium,
          unselectedLabelStyle: labelSmall,
          elevation: 0,
        ),
        drawerTheme: const DrawerThemeData(
          backgroundColor: surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          elevation: 0,
        ),
      );
}
