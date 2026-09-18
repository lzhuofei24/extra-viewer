import 'dart:ui';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'package:flutter/material.dart';

import 'browser_state.dart';

enum AppSection { data, video, gallery, reading, music, indexes, logs }

class AppNavigation extends StatelessWidget {
  const AppNavigation({
    super.key,
    required this.current,
    required this.onChanged,
    required this.rootTab,
    required this.onRootTabChanged,
  });

  static const double bottomBarHeight = 72;
  static const double landscapeMaxWidth = 560;
  static const double outerMargin = 12;
  static const double contentClearance = 20;
  static const double miniPlayerGap = 8;

  final AppSection current;
  final ValueChanged<AppSection> onChanged;
  final BrowserRootTab rootTab;
  final ValueChanged<BrowserRootTab> onRootTabChanged;

  static const _primaryItems = [
    _NavigationDestination(
      AppSection.data,
      '目录',
      Icons.folder_copy_outlined,
      Icons.folder_copy_rounded,
      dataTab: BrowserRootTab.directory,
    ),
    _NavigationDestination(
      AppSection.data,
      '分类',
      Icons.account_tree_outlined,
      Icons.account_tree_rounded,
      dataTab: BrowserRootTab.tree,
    ),
    _NavigationDestination(
      AppSection.gallery,
      '最近',
      Icons.history_outlined,
      Icons.history,
    ),
  ];

  static const _utilityItems = [
    _NavigationDestination(
      AppSection.indexes,
      '管理',
      Icons.task_alt_outlined,
      Icons.task_alt,
    ),
    _NavigationDestination(
      AppSection.logs,
      '日志',
      Icons.receipt_long_outlined,
      Icons.receipt_long_rounded,
    ),
  ];

  static const _allItems = [..._primaryItems, ..._utilityItems];

  @override
  Widget build(BuildContext context) => _BottomNavigation(
        destinations: _allItems,
        onSelect: _select,
        isSelected: _isSelected,
      );

  bool _isSelected(_NavigationDestination item) {
    if (item.section == AppSection.gallery) {
      return const {
        AppSection.gallery,
        AppSection.video,
        AppSection.reading,
        AppSection.music,
      }.contains(current);
    }
    return current == item.section &&
        (item.dataTab == null || item.dataTab == rootTab);
  }

  void _select(_NavigationDestination item) {
    final dataTab = item.dataTab;
    if (dataTab != null) {
      onRootTabChanged(dataTab);
    } else {
      onChanged(item.section);
    }
  }
}

class AppNavigationObstruction extends InheritedWidget {
  const AppNavigationObstruction({
    super.key,
    required this.bottom,
    required super.child,
  });

  final double bottom;

  static EdgeInsets of(BuildContext context) => EdgeInsets.only(
      bottom: context
              .dependOnInheritedWidgetOfExactType<AppNavigationObstruction>()
              ?.bottom ??
          0);

  @override
  bool updateShouldNotify(AppNavigationObstruction oldWidget) =>
      oldWidget.bottom != bottom;
}

class FloatingGlassSurface extends StatelessWidget {
  const FloatingGlassSurface({
    super.key,
    required this.child,
    this.borderRadius = 24,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry padding;

  static const double blurSigma = 18;
  static const double darkSurfaceAlpha = 0.54;
  static const double lightSurfaceAlpha = 0.62;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: GlassContainer(
        useOwnLayer: true,
        quality: ImageFilter.isShaderFilterSupported
            ? GlassQuality.premium
            : GlassQuality.minimal,
        shape: LiquidRoundedSuperellipse(borderRadius: borderRadius),
        settings: LiquidGlassSettings(
          glassColor: colors.surface.withValues(alpha: .27),
          blur: 8,
          thickness: 20,
          saturation: 1.2,
          lightIntensity: .5,
          chromaticAberration: .01,
        ),
        child: Padding(
          padding: padding,
          child: _FloatingGlassTextTheme(child: child),
        ),
      ),
    );
  }
}

/// Glass surface for popup overlays. Menu overlays cannot reliably sample the
/// app-level liquid-glass capture layer, so use the native backdrop here and
/// leave nested interactive glass controls free to render their own effects.
class FloatingGlassOverlaySurface extends StatelessWidget {
  const FloatingGlassOverlaySurface({
    super.key,
    required this.child,
    this.borderRadius = 24,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(borderRadius);
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .18),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: FloatingGlassSurface.blurSigma,
              sigmaY: FloatingGlassSurface.blurSigma,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surface.withValues(
                  alpha: Theme.of(context).brightness == Brightness.dark
                      ? FloatingGlassSurface.darkSurfaceAlpha
                      : FloatingGlassSurface.lightSurfaceAlpha,
                ),
                borderRadius: radius,
                border: Border.all(
                  color: colors.onSurface.withValues(alpha: .24),
                  width: 1,
                ),
              ),
              child: Padding(
                padding: padding,
                child: _FloatingGlassTextTheme(child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FloatingGlassTextTheme extends StatelessWidget {
  const _FloatingGlassTextTheme({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const foreground = Colors.black;
    return Theme(
      data: theme.copyWith(
        textTheme: theme.textTheme.apply(
          bodyColor: foreground,
          displayColor: foreground,
        ),
      ),
      child: IconTheme(
        data: const IconThemeData(color: foreground),
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: foreground),
          child: child,
        ),
      ),
    );
  }
}

class _NavigationDestination {
  const _NavigationDestination(
    this.section,
    this.label,
    this.icon,
    this.selectedIcon, {
    this.dataTab,
  });

  final AppSection section;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final BrowserRootTab? dataTab;
}

class _BottomNavigation extends StatelessWidget {
  const _BottomNavigation({
    required this.destinations,
    required this.onSelect,
    required this.isSelected,
  });

  final List<_NavigationDestination> destinations;
  final ValueChanged<_NavigationDestination> onSelect;
  final bool Function(_NavigationDestination) isSelected;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: AppNavigation.bottomBarHeight,
        child: FloatingGlassSurface(
          borderRadius: 28,
          child: Material(
            color: Colors.transparent,
            child: Row(
              children: [
                for (final item in destinations)
                  Expanded(
                    child: _BottomDestinationButton(
                      item: item,
                      selected: isSelected(item),
                      onTap: () => onSelect(item),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
}

class _BottomDestinationButton extends StatelessWidget {
  const _BottomDestinationButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _NavigationDestination item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onSurfaceVariant;
    return Semantics(
      selected: selected,
      button: true,
      label: item.label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            constraints: const BoxConstraints(minWidth: 52, minHeight: 56),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            decoration: BoxDecoration(
              color: selected
                  ? theme.colorScheme.secondaryContainer.withValues(alpha: 0.68)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  selected ? item.selectedIcon : item.icon,
                  color: color,
                  size: 22,
                ),
                const SizedBox(height: 2),
                Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    height: 1.05,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
