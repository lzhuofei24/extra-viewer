import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';

enum ViewerThemeChoice {
  system('跟随系统'),
  galleryLight('画廊亮色'),
  galleryDark('画廊暗色');

  const ViewerThemeChoice(this.label);
  final String label;
}

class AppTokens {
  static const Color moss = Color(0xFF4C6B54);
  static const Color brass = Color(0xFFC2984D);
  static const Color ivory = Color(0xFFF4EFE6);
  static const Color charcoal = Color(0xFF1F2621);

  static const double radiusLg = 28;
  static const double radiusMd = 20;
  static const double radiusSm = 14;

  static const EdgeInsets pagePadding = EdgeInsets.fromLTRB(20, 20, 20, 28);

  static ThemeData themeFor(ViewerThemeChoice choice) {
    final isDark = choice == ViewerThemeChoice.galleryDark;
    const scheme = FlexScheme.materialBaseline;
    final base = isDark
        ? FlexThemeData.dark(
            scheme: scheme,
            surfaceMode: FlexSurfaceMode.highScaffoldLowSurface,
            blendLevel: 10,
            subThemesData: const FlexSubThemesData(
              defaultRadius: radiusMd,
              navigationBarIndicatorRadius: radiusSm,
              navigationBarLabelBehavior:
                  NavigationDestinationLabelBehavior.alwaysShow,
              interactionEffects: true,
              inputDecoratorBorderType: FlexInputBorderType.outline,
              cardElevation: 1,
              alignedDropdown: true,
            ),
            colors: const FlexSchemeColor(
              primary: moss,
              primaryContainer: Color(0xFF6E8D74),
              secondary: brass,
              secondaryContainer: Color(0xFFD9B06A),
              tertiary: Color(0xFF87A092),
              tertiaryContainer: Color(0xFF55665C),
              appBarColor: charcoal,
              error: Color(0xFFD35D5D),
            ),
            scaffoldBackground: charcoal,
            surface: const Color(0xFF232B25),
            useMaterial3: true,
          )
        : FlexThemeData.light(
            scheme: scheme,
            surfaceMode: FlexSurfaceMode.levelSurfacesLowScaffold,
            blendLevel: 8,
            subThemesData: const FlexSubThemesData(
              defaultRadius: radiusMd,
              navigationBarIndicatorRadius: radiusSm,
              navigationBarLabelBehavior:
                  NavigationDestinationLabelBehavior.alwaysShow,
              interactionEffects: true,
              inputDecoratorBorderType: FlexInputBorderType.outline,
              cardElevation: 0.5,
              alignedDropdown: true,
            ),
            colors: const FlexSchemeColor(
              primary: moss,
              primaryContainer: Color(0xFFCCD8CC),
              secondary: brass,
              secondaryContainer: Color(0xFFE8D4AF),
              tertiary: Color(0xFF8F9B84),
              tertiaryContainer: Color(0xFFD4DACF),
              appBarColor: ivory,
              error: Color(0xFFB75656),
            ),
            scaffoldBackground: ivory,
            surface: const Color(0xFFFFFBF5),
            useMaterial3: true,
          );

    final textTheme = base.textTheme.apply(
      bodyColor: base.colorScheme.onSurface,
      displayColor: base.colorScheme.onSurface,
      fontFamily: 'Microsoft YaHei',
    );

    return base.copyWith(
      textTheme: textTheme.copyWith(
        headlineMedium: textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.8,
          fontFamily: 'Georgia',
        ),
        headlineSmall: textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          fontFamily: 'Georgia',
        ),
        titleLarge: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        titleMedium: textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        bodyMedium: textTheme.bodyMedium?.copyWith(height: 1.45),
        labelLarge: textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: base.cardTheme.copyWith(
        color: base.colorScheme.surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          side: BorderSide(
            color: base.colorScheme.outlineVariant.withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }
}
