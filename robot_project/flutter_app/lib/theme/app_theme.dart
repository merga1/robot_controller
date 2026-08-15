import 'package:flutter/material.dart';

class AppColors {
  static const navy = Color(0xFF163A5F);
  static const green = Color(0xFF208A5A);
  static const red = Color(0xFFC83737);
  static const orange = Color(0xFFD97818);
  static const cardWhite = Color(0xFFFFFFFF);
  static const background = Color(0xFFF5F7FA);
  static const textPrimary = Color(0xFF1D2939);
  static const textSecondary = Color(0xFF667085);
}

class AppTheme {
  static final theme = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: AppColors.navy),
    scaffoldBackgroundColor: const Color(0xFFF5F7FA),
    appBarTheme: const AppBarTheme(backgroundColor: AppColors.navy, foregroundColor: Colors.white),
    cardTheme: CardThemeData(color: AppColors.cardWhite, elevation: 2, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
  );
}
