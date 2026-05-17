import 'package:flutter/material.dart';

const Color _seedColor = Color(0xFF8B3A6F);
const String _serif = 'Gloock';
const String _sans = 'StackSansNotch';

ThemeData buildLightTheme() {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: _seedColor,
  ).copyWith(surface: Colors.white);
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
  final TextTheme base = ThemeData(brightness: scheme.brightness).textTheme;
  final TextTheme text = base
      .apply(fontFamily: _sans)
      .copyWith(
        displayLarge: base.displayLarge?.copyWith(
          fontFamily: _serif,
          fontWeight: FontWeight.w400,
          height: 1.0,
        ),
        displayMedium: base.displayMedium?.copyWith(
          fontFamily: _serif,
          fontWeight: FontWeight.w400,
          height: 1.0,
        ),
        displaySmall: base.displaySmall?.copyWith(
          fontFamily: _serif,
          fontWeight: FontWeight.w400,
        ),
        headlineLarge: base.headlineLarge?.copyWith(fontFamily: _serif),
        headlineMedium: base.headlineMedium?.copyWith(fontFamily: _serif),
        headlineSmall: base.headlineSmall?.copyWith(fontFamily: _serif),
      );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.adaptivePlatformDensity,
    scaffoldBackgroundColor: scheme.surface,
    fontFamily: _sans,
    textTheme: text,
    // Cupertino-style transitions on both platforms — the swipe-back
    // gesture is driven by Flutter's Navigator instead of Android's
    // predictive-back system animation, so Hero flights actually run
    // when the user swipes back from a detail screen.
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
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
