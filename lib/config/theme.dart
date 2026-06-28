import 'package:flutter/material.dart';

class AppTheme {
  static const Color primaryColor = Color(0xFF2679FF);
  static const Color primaryDark = Color(0xFF1A5CC8);
  static const Color primaryLight = Color(0xFF5C9AFF);
  static const Color accentColor = Color(0xFFFF6B35);
  static const Color textPrimary = Color(0xFF333333);
  static const Color textSecondary = Color(0xFF999999);
  static const Color textHint = Color(0xFFCCCCCC);
  static const Color backgroundLight = Color(0xFFF5F5F5);
  static const Color cardColor = Colors.white;
  static const Color dividerColor = Color(0xFFEEEEEE);
  static const Color readingPaper = Color(0xFFFFF8ED);
  static const Color readingGreen = Color(0xFFC7EDCC);
  static const Color readingGray = Color(0xFFF2F2F2);
  static const Color nightBackground = Color(0xFF1A1A1A);
  static const Color nightCard = Color(0xFF2B2B2B);
  static const Color nightText = Color(0xFF999999);

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryColor,
        brightness: Brightness.light,
        primary: primaryColor,
        secondary: accentColor,
        surface: Colors.white,
      ),
      scaffoldBackgroundColor: backgroundLight,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: textPrimary,
        elevation: 0.5,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Colors.white,
        selectedItemColor: primaryColor,
        unselectedItemColor: textSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
        selectedLabelStyle: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
        unselectedLabelStyle: TextStyle(fontSize: 11),
      ),
      tabBarTheme: const TabBarThemeData(
        labelColor: primaryColor,
        unselectedLabelColor: textSecondary,
        indicatorColor: primaryColor,
        labelStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        unselectedLabelStyle: TextStyle(fontSize: 15),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      dividerTheme: const DividerThemeData(color: dividerColor, thickness: 0.5),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: textPrimary,
        ),
        headlineMedium: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        titleLarge: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        titleMedium: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: textPrimary,
        ),
        bodyLarge: TextStyle(fontSize: 16, color: textPrimary),
        bodyMedium: TextStyle(fontSize: 14, color: textSecondary),
        bodySmall: TextStyle(fontSize: 12, color: textHint),
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryColor,
        brightness: Brightness.dark,
        primary: primaryLight,
        secondary: accentColor,
        surface: nightCard,
      ),
      scaffoldBackgroundColor: nightBackground,
      appBarTheme: const AppBarTheme(
        backgroundColor: nightCard,
        foregroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: nightCard,
        selectedItemColor: primaryLight,
        unselectedItemColor: nightText,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
        selectedLabelStyle: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
        unselectedLabelStyle: TextStyle(fontSize: 11),
      ),
      cardTheme: CardThemeData(
        color: nightCard,
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF3A3A3A),
        thickness: 0.5,
      ),
      listTileTheme: const ListTileThemeData(
        textColor: Colors.white,
        iconColor: nightText,
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
        headlineMedium: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
        titleLarge: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
        titleMedium: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: Colors.white,
        ),
        bodyLarge: TextStyle(fontSize: 16, color: Colors.white),
        bodyMedium: TextStyle(fontSize: 14, color: nightText),
        bodySmall: TextStyle(fontSize: 12, color: textHint),
      ),
    );
  }
}
