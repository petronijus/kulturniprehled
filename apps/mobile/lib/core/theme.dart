import 'package:flutter/material.dart';

// Material 3, dark-first. The seed colour leans into the cultural-event
// vibe — deep red-violet that still feels at home in the system gallery
// and on both Android and iOS.

const Color _seedColor = Color(0xFF8B3A6F);

ThemeData buildLightTheme() {
  final ColorScheme scheme = ColorScheme.fromSeed(seedColor: _seedColor);
  return _baseTheme(scheme);
}

ThemeData buildDarkTheme() {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: _seedColor,
    brightness: Brightness.dark,
  );
  return _baseTheme(scheme);
}

ThemeData _baseTheme(ColorScheme scheme) {
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.adaptivePlatformDensity,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      centerTitle: false,
      scrolledUnderElevation: 1,
    ),
    cardTheme: const CardThemeData(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    ),
  );
}
