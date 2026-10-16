import 'package:flutter/material.dart';

class AppColors {
  // Brand / semantic colours — same in both modes
  static const navy = Color(0xFF163A5F);
  static const green = Color(0xFF208A5A);
  static const red = Color(0xFFC83737);
  static const orange = Color(0xFFD97818);

  // Light-mode surface colours
  static const cardWhite = Color(0xFFFFFFFF);
  static const background = Color(0xFFF5F7FA);
  static const textPrimary = Color(0xFF1D2939);
  static const textSecondary = Color(0xFF667085);

  // Dark-mode surface colours
  static const darkBackground = Color(0xFF0F1923);
  static const darkCard = Color(0xFF1A2535);
  static const darkSurface = Color(0xFF243044);
  static const darkTextPrimary = Color(0xFFE8EDF4);
  static const darkTextSecondary = Color(0xFF8FA3BF);
}

class AppTheme {
  static final theme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.navy,
      brightness: Brightness.light,
    ),
    scaffoldBackgroundColor: AppColors.background,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.navy,
      foregroundColor: Colors.white,
    ),
    cardTheme: CardThemeData(
      color: AppColors.cardWhite,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dividerColor: Color(0xFFE4E7EC),
    listTileTheme: const ListTileThemeData(
      iconColor: AppColors.navy,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? AppColors.navy : null,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? AppColors.navy.withValues(alpha: 0.4)
            : null,
      ),
    ),
    sliderTheme: const SliderThemeData(activeTrackColor: AppColors.navy),
  );

  static final darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.navy,
      brightness: Brightness.dark,
    ).copyWith(
      surface: AppColors.darkCard,
      onSurface: AppColors.darkTextPrimary,
      primary: const Color(0xFF4D8FCC),
      onPrimary: Colors.white,
    ),
    scaffoldBackgroundColor: AppColors.darkBackground,
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF0D1E2E),
      foregroundColor: AppColors.darkTextPrimary,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: AppColors.darkCard,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF2A3A50), width: 1),
      ),
    ),
    dividerColor: const Color(0xFF2A3A50),
    listTileTheme: const ListTileThemeData(
      iconColor: Color(0xFF4D8FCC),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) =>
            s.contains(WidgetState.selected) ? const Color(0xFF4D8FCC) : null,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? const Color(0xFF4D8FCC).withValues(alpha: 0.4)
            : null,
      ),
    ),
    sliderTheme: const SliderThemeData(activeTrackColor: Color(0xFF4D8FCC)),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(color: AppColors.darkTextPrimary),
      bodySmall: TextStyle(color: AppColors.darkTextSecondary),
    ),
  );
}
