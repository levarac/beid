import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  // Design tokens - Monotone
  static const Color primary = Color(0xFF1A1A1A);
  static const Color primaryLight = Color(0xFF4A4A4A);
  static const Color border = Color(0xFFD0D0D0);
  static const Color borderDark = Color(0xFF3A3A3A);
  static const Color textPrimary = Color(0xFF1A1A1A);
  static const Color textSecondary = Color(0xFF6B6B6B);
  static const Color textTertiary = Color(0xFF9A9A9A);
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.light(
        primary: primary,
        onPrimary: Colors.white,
        secondary: primaryLight,
        onSecondary: Colors.white,
        surface: Colors.white,
        onSurface: textPrimary,
        onSurfaceVariant: textSecondary,
        outline: border,
        outlineVariant: border.withValues(alpha: 0.5),
        primaryContainer: const Color(0xFFF5F5F5),
        onPrimaryContainer: textPrimary,
        secondaryContainer: const Color(0xFFEEEEEE),
        onSecondaryContainer: textPrimary,
        errorContainer: const Color(0xFFFFEBEE),
        onErrorContainer: const Color(0xFFC62828),
      ),
      scaffoldBackgroundColor: Colors.white,
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: textPrimary,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        elevation: 0,
        backgroundColor: primary,
        foregroundColor: Colors.white,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: border, width: 1),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: textPrimary),
        bodyMedium: TextStyle(color: textPrimary),
        bodySmall: TextStyle(color: textSecondary),
        titleLarge: TextStyle(color: textPrimary),
        titleMedium: TextStyle(color: textPrimary),
        titleSmall: TextStyle(color: textPrimary),
        labelLarge: TextStyle(color: textPrimary),
        labelMedium: TextStyle(color: textSecondary),
        labelSmall: TextStyle(color: textSecondary),
      ),
      dividerColor: border.withValues(alpha: 0.5),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          side: const BorderSide(color: primary),
        ),
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.dark(
        primary: Colors.white,
        onPrimary: const Color(0xFF1A1A1A),
        secondary: const Color(0xFFB0B0B0),
        onSecondary: const Color(0xFF1A1A1A),
        surface: const Color(0xFF121212),
        onSurface: Colors.white,
        onSurfaceVariant: const Color(0xFFB0B0B0),
        outline: borderDark,
        outlineVariant: borderDark.withValues(alpha: 0.5),
        primaryContainer: const Color(0xFF2A2A2A),
        onPrimaryContainer: Colors.white,
        secondaryContainer: const Color(0xFF3A3A3A),
        onSecondaryContainer: Colors.white,
        errorContainer: const Color(0xFF442222),
        onErrorContainer: const Color(0xFFFF8A80),
      ),
      scaffoldBackgroundColor: const Color(0xFF121212),
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 0,
        backgroundColor: Color(0xFF121212),
        foregroundColor: Colors.white,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Color(0xFF1A1A1A),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: borderDark.withValues(alpha: 0.5), width: 1),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      dividerColor: borderDark.withValues(alpha: 0.5),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF1A1A1A),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: const BorderSide(color: Colors.white),
        ),
      ),
    );
  }
}
