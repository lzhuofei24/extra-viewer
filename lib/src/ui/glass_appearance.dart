import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

enum GlassSurfaceRole { compact, panel }

@immutable
class GlassAppearance {
  const GlassAppearance(this.brightness, this.role);

  final Brightness brightness;
  final GlassSurfaceRole role;
  bool get isDark => brightness == Brightness.dark;
  Color get foreground => Color(isDark ? 0xFFFFFFFF : 0xFF080808);
  Color get secondaryForeground => Color(isDark ? 0xFFFAFAFA : 0xFF0C0C0C);
  Color get disabledForeground => Color(isDark ? 0xFF969696 : 0xFF656565);
  Color get selectedForeground => foreground;
  Color get selectedBackground =>
      (isDark ? Colors.black : Colors.white).withValues(alpha: .24);
  Color get track => Color(isDark ? 0xFF454545 : 0xFFE0E0E0);
  Color get bufferedTrack => Color(isDark ? 0xFF969696 : 0xFF737373);

  LiquidGlassSettings get settings => LiquidGlassSettings(
        glassColor: (isDark ? Colors.black : Colors.white).withValues(
          alpha: role == GlassSurfaceRole.panel
              ? (isDark ? .60 : .54)
              : (isDark ? .55 : .48),
        ),
        blur: 8,
        thickness: 20,
        saturation: 1.2,
        lightIntensity: .5,
        chromaticAberration: .01,
      );

  // The panel already owns the backdrop; indicators must not repeat its tint.
  LiquidGlassSettings get indicatorSettings => settings.copyWith(
        glassColor: selectedBackground,
        blur: 0,
      );

  static GlassAppearance of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<GlassAppearanceScope>()
          ?.value ??
      GlassAppearance(Theme.of(context).brightness, GlassSurfaceRole.compact);
}

class GlassAppearanceScope extends InheritedWidget {
  const GlassAppearanceScope({
    super.key,
    required this.value,
    required super.child,
  });
  final GlassAppearance value;
  @override
  bool updateShouldNotify(GlassAppearanceScope oldWidget) =>
      value.brightness != oldWidget.value.brightness ||
      value.role != oldWidget.value.role;
}

class GlassContentTheme extends StatelessWidget {
  const GlassContentTheme(
      {super.key, required this.appearance, required this.child});
  final GlassAppearance appearance;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = appearance.foreground;
    final buttonForeground = WidgetStateProperty.resolveWith<Color>((states) =>
        states.contains(WidgetState.disabled)
            ? appearance.disabledForeground
            : foreground);
    final buttonStyle = ButtonStyle(
        foregroundColor: buttonForeground,
        iconColor: buttonForeground,
        overlayColor:
            WidgetStatePropertyAll(foreground.withValues(alpha: .10)));
    return GlassAppearanceScope(
      value: appearance,
      child: Theme(
        data: theme.copyWith(
          colorScheme: theme.colorScheme.copyWith(
            onSurface: foreground,
            onSurfaceVariant: appearance.secondaryForeground,
            primary: foreground,
            onPrimary: appearance.isDark ? Colors.black : Colors.white,
            secondaryContainer: appearance.selectedBackground,
            onSecondaryContainer: appearance.selectedForeground,
            outline: appearance.disabledForeground,
            outlineVariant: appearance.disabledForeground,
          ),
          disabledColor: appearance.disabledForeground,
          textTheme: theme.textTheme
              .apply(bodyColor: foreground, displayColor: foreground),
          iconTheme: theme.iconTheme.copyWith(color: foreground),
          iconButtonTheme: IconButtonThemeData(style: buttonStyle),
          textButtonTheme: TextButtonThemeData(style: buttonStyle),
          outlinedButtonTheme: OutlinedButtonThemeData(style: buttonStyle),
          filledButtonTheme: FilledButtonThemeData(
              style: buttonStyle.copyWith(
                  backgroundColor:
                      WidgetStatePropertyAll(appearance.selectedBackground))),
          sliderTheme: theme.sliderTheme.copyWith(
            activeTrackColor: foreground,
            thumbColor: foreground,
            inactiveTrackColor: appearance.track,
            secondaryActiveTrackColor: appearance.bufferedTrack,
            disabledThumbColor: appearance.disabledForeground,
            disabledActiveTrackColor: appearance.disabledForeground,
            disabledInactiveTrackColor: appearance.track,
            overlayColor: foreground.withValues(alpha: .12),
          ),
          progressIndicatorTheme: theme.progressIndicatorTheme
              .copyWith(color: foreground, linearTrackColor: appearance.track),
        ),
        child: IconTheme(
          data: IconThemeData(color: foreground),
          child: DefaultTextStyle.merge(
              style: TextStyle(color: foreground), child: child),
        ),
      ),
    );
  }
}
