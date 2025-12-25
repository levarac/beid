import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  // Design tokens
  static const Color primary = Color(0xFF968CFF);
  static const Color border = Color(0xFF473E6B);
  static const Color textPrimary = Color(0xFF473E6B);
  static const Color textSecondary = Color(0xFF797292);
  static const Color textLink = Color(0xFF6D62DF);

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.light(
        primary: primary,
        onPrimary: Colors.white,
        secondary: textLink,
        onSecondary: Colors.white,
        surface: Colors.white,
        onSurface: textPrimary,
        onSurfaceVariant: textSecondary,
        outline: border,
        outlineVariant: border.withValues(alpha: 0.3),
      ),
      scaffoldBackgroundColor: Colors.white,
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: textPrimary,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
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
      dividerColor: border.withValues(alpha: 0.3),
    );
  }

  static ThemeData get darkTheme {
    // Dark theme uses same primary but inverted backgrounds
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.dark(
        primary: primary,
        onPrimary: textPrimary,
        secondary: textLink,
        onSecondary: Colors.white,
        surface: const Color(0xFF1E1B2E),
        onSurface: Colors.white,
        onSurfaceVariant: textSecondary,
        outline: border,
        outlineVariant: border.withValues(alpha: 0.5),
      ),
      scaffoldBackgroundColor: const Color(0xFF1E1B2E),
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 0,
        backgroundColor: Color(0xFF1E1B2E),
        foregroundColor: Colors.white,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 0,
        backgroundColor: primary,
        foregroundColor: Colors.white,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: border.withValues(alpha: 0.5), width: 1),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      dividerColor: border.withValues(alpha: 0.5),
    );
  }
}
