import 'dart:ui';

import 'package:flutter/material.dart';

import 'browser_state.dart';
import 'collapse_grip_icon.dart';

enum AppSection {
  data,
  video,
  gallery,
  reading,
  music,
  indexes,
  logs,
  settings
}

enum AppNavigationLayout { rail, bottom }

class AppNavigation extends StatelessWidget {
  const AppNavigation({
    super.key,
    required this.layout,
    required this.current,
    required this.onChanged,
    required this.rootTab,
    required this.onRootTabChanged,
    required this.collapsed,
    required this.onToggleCollapsed,
  });

  static const double expandedRailWidth = 80;
  static const double collapsedRailWidth = 40;
  static const double bottomBarHeight = 72;
  static const double outerMargin = 12;
  static const double contentClearance = 20;
  static const double miniPlayerGap = 8;

  final AppNavigationLayout layout;
  final AppSection current;
  final ValueChanged<AppSection> onChanged;
  final BrowserRootTab rootTab;
  final ValueChanged<BrowserRootTab> onRootTabChanged;
  final bool collapsed;
  final VoidCallback onToggleCollapsed;

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
      AppSection.settings,
      '设置',
      Icons.tune_outlined,
      Icons.tune_rounded,
    ),
  ];

  static const _allItems = [..._primaryItems, ..._utilityItems];

  double get railWidth => collapsed ? collapsedRailWidth : expandedRailWidth;

  @override
  Widget build(BuildContext context) {
    return switch (layout) {
      AppNavigationLayout.rail => _NavigationRail(
          width: railWidth,
          destinations: _allItems,
          collapsed: collapsed,
          onToggleCollapsed: onToggleCollapsed,
          onSelect: _select,
          isSelected: _isSelected,
        ),
      AppNavigationLayout.bottom => _BottomNavigation(
          destinations: _allItems,
          onSelect: _select,
          isSelected: _isSelected,
        ),
    };
  }

  bool _isSelected(_NavigationDestination item) {
    if (item.section == AppSection.gallery) {
      return const {
        AppSection.gallery,
        AppSection.video,
        AppSection.reading,
        AppSection.music,
      }.contains(current);
    }
    if (item.section == AppSection.settings && current == AppSection.logs) {
      return true;
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
    required this.insets,
    required super.child,
  });

  final EdgeInsets insets;

  static EdgeInsets of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AppNavigationObstruction>()
          ?.insets ??
      EdgeInsets.zero;

  @override
  bool updateShouldNotify(AppNavigationObstruction oldWidget) =>
      oldWidget.insets != insets;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: _glassShadow(theme, borderRadius),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: DecoratedBox(
              decoration: _glassSurface(theme, borderRadius),
              child: Padding(padding: padding, child: child),
            ),
          ),
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

class _NavigationRail extends StatelessWidget {
  const _NavigationRail({
    required this.width,
    required this.destinations,
    required this.collapsed,
    required this.onToggleCollapsed,
    required this.onSelect,
    required this.isSelected,
  });

  final double width;
  final List<_NavigationDestination> destinations;
  final bool collapsed;
  final VoidCallback onToggleCollapsed;
  final ValueChanged<_NavigationDestination> onSelect;
  final bool Function(_NavigationDestination) isSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: width,
      decoration: _glassShadow(theme, 24),
      child: RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: DecoratedBox(
              decoration: _glassSurface(theme, 24),
              child: Material(
                color: Colors.transparent,
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    collapsed ? 3 : 6,
                    10,
                    collapsed ? 3 : 6,
                    10,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _SidebarCollapseButton(
                        collapsed: collapsed,
                        onTap: onToggleCollapsed,
                      ),
                      const SizedBox(height: 8),
                      for (var index = 0;
                          index < destinations.length;
                          index++) ...[
                        if (index == 3)
                          Divider(
                            height: 12,
                            color: theme.colorScheme.outlineVariant
                                .withValues(alpha: 0.6),
                          ),
                        _RailDestinationButton(
                          item: destinations[index],
                          selected: isSelected(destinations[index]),
                          collapsed: collapsed,
                          onTap: () => onSelect(destinations[index]),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: AppNavigation.bottomBarHeight,
      child: DecoratedBox(
        decoration: _glassShadow(theme, 28),
        child: RepaintBoundary(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: DecoratedBox(
                decoration: _glassSurface(theme, 28),
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
            ),
          ),
        ),
      ),
    );
  }
}

BoxDecoration _glassSurface(ThemeData theme, double radius) {
  final isDark = theme.brightness == Brightness.dark;
  return BoxDecoration(
    color: theme.colorScheme.surface.withValues(alpha: isDark ? 0.66 : 0.74),
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(
      color: theme.colorScheme.outlineVariant
          .withValues(alpha: isDark ? 0.4 : 0.55),
      width: 0.7,
    ),
  );
}

BoxDecoration _glassShadow(ThemeData theme, double radius) => BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(
            alpha: theme.brightness == Brightness.dark ? 0.28 : 0.16,
          ),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
      ],
    );

class _RailDestinationButton extends StatelessWidget {
  const _RailDestinationButton({
    required this.item,
    required this.selected,
    required this.collapsed,
    required this.onTap,
  });

  final _NavigationDestination item;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: collapsed ? 0 : 5,
            vertical: collapsed ? 10 : 8,
          ),
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.secondaryContainer.withValues(alpha: 0.72)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: collapsed
              ? Center(
                  child: Icon(
                    selected ? item.selectedIcon : item.icon,
                    color: color,
                    size: 21,
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      selected ? item.selectedIcon : item.icon,
                      color: color,
                      size: 21,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: color,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
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

class _SidebarCollapseButton extends StatelessWidget {
  const _SidebarCollapseButton({
    required this.collapsed,
    required this.onTap,
  });

  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        tooltip: collapsed ? '展开功能栏' : '收起功能栏',
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        onPressed: onTap,
        icon: const CollapseGripIcon(size: 18),
      ),
    );
  }
}
