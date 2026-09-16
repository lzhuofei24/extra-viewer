import 'package:flutter/material.dart';

import 'browser_state.dart';
import 'collapse_grip_icon.dart';
import 'design_tokens.dart';

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

class AppSidebar extends StatelessWidget {
  const AppSidebar({
    super.key,
    required this.current,
    required this.onChanged,
    required this.rootTab,
    required this.onRootTabChanged,
    required this.collapsed,
    required this.onToggleCollapsed,
  });

  final AppSection current;
  final ValueChanged<AppSection> onChanged;
  final BrowserRootTab rootTab;
  final ValueChanged<BrowserRootTab> onRootTabChanged;
  final bool collapsed;
  final VoidCallback onToggleCollapsed;

  static const _primaryItems = [
    _SidebarItem(AppSection.data, '目录索引', Icons.folder_copy_outlined,
        Icons.folder_copy_rounded,
        dataTab: BrowserRootTab.directory),
    _SidebarItem(AppSection.data, '树索引', Icons.account_tree_outlined,
        Icons.account_tree_rounded,
        dataTab: BrowserRootTab.tree),
    _SidebarItem(AppSection.data, '图索引', Icons.hub_outlined, Icons.hub_rounded,
        dataTab: BrowserRootTab.graph),
    _SidebarItem(
        AppSection.gallery, '最近', Icons.history_outlined, Icons.history),
  ];

  static const _utilityItems = [
    _SidebarItem(
        AppSection.indexes, '管理', Icons.task_alt_outlined, Icons.task_alt),
    _SidebarItem(
        AppSection.settings, '设置', Icons.tune_outlined, Icons.tune_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: collapsed ? 36 : 80,
      color: theme.colorScheme.surface.withValues(alpha: 0.82),
      padding:
          EdgeInsets.fromLTRB(collapsed ? 2 : 6, 14, collapsed ? 2 : 6, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SidebarCollapseButton(
                  collapsed: collapsed,
                  onTap: onToggleCollapsed,
                ),
                const SizedBox(height: 8),
                for (final item in _primaryItems)
                  _SidebarButton(
                    item: item,
                    selected: _isSelected(item),
                    collapsed: collapsed,
                    onTap: () => _select(item),
                  ),
                Divider(color: theme.colorScheme.outlineVariant),
                for (final item in _utilityItems)
                  _SidebarButton(
                    item: item,
                    selected: _isSelected(item),
                    collapsed: collapsed,
                    onTap: () => _select(item),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  bool _isSelected(_SidebarItem item) {
    if (item.section == AppSection.gallery) {
      return const {
        AppSection.gallery,
        AppSection.video,
        AppSection.reading,
        AppSection.music
      }.contains(current);
    }
    if (item.section == AppSection.settings && current == AppSection.logs) {
      return true;
    }
    return current == item.section &&
        (item.dataTab == null || item.dataTab == rootTab);
  }

  void _select(_SidebarItem item) {
    final dataTab = item.dataTab;
    if (dataTab != null) {
      onRootTabChanged(dataTab);
    } else {
      onChanged(item.section);
    }
  }
}

class _SidebarItem {
  const _SidebarItem(
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

class _SidebarButton extends StatelessWidget {
  const _SidebarButton({
    required this.item,
    required this.selected,
    required this.collapsed,
    required this.onTap,
  });

  final _SidebarItem item;
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
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
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
                ? theme.colorScheme.secondaryContainer.withValues(alpha: 0.9)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          ),
          child: collapsed
              ? Center(
                  child: Icon(selected ? item.selectedIcon : item.icon,
                      color: color, size: 21),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(selected ? item.selectedIcon : item.icon,
                        color: color, size: 21),
                    const SizedBox(height: 3),
                    Text(
                      item.label,
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
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        onPressed: onTap,
        icon: const CollapseGripIcon(size: 18),
      ),
    );
  }
}
