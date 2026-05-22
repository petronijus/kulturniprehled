import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

const String _serif = 'Gloock';
const String _sans = 'StackSansHeadline';

// Monochrome theme — Material 3 generates tinted neutrals from any seed
// colour, so we don't seed at all. Every accent slot is hand-set to
// black / white / grey so buttons, chips, focus rings, errors, and
// status indicators stay strictly black-and-white across the app.

ThemeData buildLightTheme() => _baseTheme(_lightScheme);
ThemeData buildDarkTheme() => _baseTheme(_darkScheme);

const ColorScheme _lightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: Colors.black,
  onPrimary: Colors.white,
  primaryContainer: Color(0xFFEEEEEE),
  onPrimaryContainer: Colors.black,
  secondary: Colors.black,
  onSecondary: Colors.white,
  secondaryContainer: Color(0xFFEEEEEE),
  onSecondaryContainer: Colors.black,
  tertiary: Colors.black,
  onTertiary: Colors.white,
  tertiaryContainer: Color(0xFFEEEEEE),
  onTertiaryContainer: Colors.black,
  error: Color(0xFF1F1F1F),
  onError: Colors.white,
  errorContainer: Color(0xFFE0E0E0),
  onErrorContainer: Colors.black,
  surface: Colors.white,
  onSurface: Colors.black,
  surfaceDim: Color(0xFFE0E0E0),
  surfaceBright: Colors.white,
  surfaceContainerLowest: Colors.white,
  surfaceContainerLow: Color(0xFFFAFAFA),
  surfaceContainer: Color(0xFFF5F5F5),
  surfaceContainerHigh: Color(0xFFEFEFEF),
  surfaceContainerHighest: Color(0xFFE8E8E8),
  onSurfaceVariant: Color(0xFF616161),
  outline: Color(0xFFBDBDBD),
  outlineVariant: Color(0xFFE0E0E0),
  inverseSurface: Color(0xFF1A1A1A),
  onInverseSurface: Colors.white,
  inversePrimary: Colors.white,
  surfaceTint: Colors.black,
  scrim: Color(0xCC000000),
  shadow: Colors.black,
);

const ColorScheme _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: Colors.white,
  onPrimary: Colors.black,
  primaryContainer: Color(0xFF2A2A2A),
  onPrimaryContainer: Colors.white,
  secondary: Colors.white,
  onSecondary: Colors.black,
  secondaryContainer: Color(0xFF2A2A2A),
  onSecondaryContainer: Colors.white,
  tertiary: Colors.white,
  onTertiary: Colors.black,
  tertiaryContainer: Color(0xFF2A2A2A),
  onTertiaryContainer: Colors.white,
  error: Color(0xFFE0E0E0),
  onError: Colors.black,
  errorContainer: Color(0xFF2A2A2A),
  onErrorContainer: Colors.white,
  surface: Colors.black,
  onSurface: Colors.white,
  surfaceDim: Color(0xFF101010),
  surfaceBright: Color(0xFF2A2A2A),
  surfaceContainerLowest: Colors.black,
  surfaceContainerLow: Color(0xFF121212),
  surfaceContainer: Color(0xFF1A1A1A),
  surfaceContainerHigh: Color(0xFF222222),
  surfaceContainerHighest: Color(0xFF2A2A2A),
  onSurfaceVariant: Color(0xFFBDBDBD),
  outline: Color(0xFF616161),
  outlineVariant: Color(0xFF2A2A2A),
  inverseSurface: Colors.white,
  onInverseSurface: Colors.black,
  inversePrimary: Colors.black,
  surfaceTint: Colors.white,
  scrim: Color(0xCC000000),
  shadow: Colors.black,
);

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
