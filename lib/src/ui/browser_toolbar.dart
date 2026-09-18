import 'package:flutter/material.dart';

import '../core/domain/models.dart';
import 'browser_state.dart';

class BrowserToolbarAction {
  const BrowserToolbarAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
}

class BrowserToolbar extends StatelessWidget {
  const BrowserToolbar({
    super.key,
    required this.leading,
    required this.browserState,
    required this.onSortChanged,
    required this.onDisplayModeChanged,
    required this.onGridLayoutChanged,
    this.onSearch,
    this.immersive = false,
    this.onToggleImmersive,
    this.selectionMode = false,
    this.onToggleSelection,
    this.moreActions = const [],
  });

  final Widget leading;
  final BrowserState browserState;
  final ValueChanged<EntitySortMode> onSortChanged;
  final ValueChanged<BrowserDisplayMode> onDisplayModeChanged;
  final ValueChanged<BrowserGridLayout> onGridLayoutChanged;
  final VoidCallback? onSearch;
  final bool immersive;
  final VoidCallback? onToggleImmersive;
  final bool selectionMode;
  final VoidCallback? onToggleSelection;
  final List<BrowserToolbarAction> moreActions;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(child: leading),
          if (onSearch != null)
            IconButton(
              tooltip: '搜索目录或分类',
              onPressed: onSearch,
              icon: const Icon(Icons.search),
            ),
          if (onToggleImmersive != null)
            IconButton(
              tooltip: immersive ? '退出沉浸式浏览' : '沉浸式浏览',
              onPressed: onToggleImmersive,
              icon: Icon(immersive
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded),
            ),
          if (onToggleSelection != null)
            IconButton(
              tooltip: selectionMode ? '退出选择模式' : '选择模式',
              onPressed: onToggleSelection,
              icon: Icon(selectionMode
                  ? Icons.checklist_rounded
                  : Icons.checklist_outlined),
            ),
          const SizedBox(width: 4),
          _BrowserOptionsMenu(
            browserState: browserState,
            onSortChanged: onSortChanged,
            onDisplayModeChanged: onDisplayModeChanged,
            onGridLayoutChanged: onGridLayoutChanged,
          ),
          if (moreActions.isNotEmpty) _MoreActionsMenu(actions: moreActions),
        ],
      );
}

class _BrowserOptionsMenu extends StatelessWidget {
  const _BrowserOptionsMenu({
    required this.browserState,
    required this.onSortChanged,
    required this.onDisplayModeChanged,
    required this.onGridLayoutChanged,
  });

  final BrowserState browserState;
  final ValueChanged<EntitySortMode> onSortChanged;
  final ValueChanged<BrowserDisplayMode> onDisplayModeChanged;
  final ValueChanged<BrowserGridLayout> onGridLayoutChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MenuAnchor(
      menuChildren: [
        SizedBox(
          width: 276,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('浏览选项', style: theme.textTheme.labelLarge),
                const SizedBox(height: 10),
                Text('排序', style: theme.textTheme.labelMedium),
                const SizedBox(height: 6),
                SegmentedButton<EntitySortMode>(
                  segments: const [
                    ButtonSegment(
                        value: EntitySortMode.modifiedDesc, label: Text('最近')),
                    ButtonSegment(
                        value: EntitySortMode.nameAsc, label: Text('名称')),
                    ButtonSegment(
                        value: EntitySortMode.sizeDesc, label: Text('大小')),
                  ],
                  selected: {browserState.sortMode},
                  onSelectionChanged: (value) => onSortChanged(value.first),
                ),
                const SizedBox(height: 12),
                Text('显示方式', style: theme.textTheme.labelMedium),
                const SizedBox(height: 6),
                SegmentedButton<BrowserDisplayMode>(
                  segments: const [
                    ButtonSegment(
                      value: BrowserDisplayMode.grid,
                      icon: Icon(Icons.grid_view_rounded),
                      label: Text('卡片'),
                    ),
                    ButtonSegment(
                      value: BrowserDisplayMode.list,
                      icon: Icon(Icons.view_agenda_rounded),
                      label: Text('列表'),
                    ),
                  ],
                  selected: {browserState.displayMode},
                  onSelectionChanged: (value) =>
                      onDisplayModeChanged(value.first),
                ),
                if (browserState.displayMode == BrowserDisplayMode.grid) ...[
                  const SizedBox(height: 12),
                  Text('卡片对齐方式', style: theme.textTheme.labelMedium),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final mode in BrowserGridLayout.values)
                        _GridLayoutOption(
                          mode: mode,
                          selected: browserState.gridLayout == mode,
                          onSelected: () => onGridLayoutChanged(mode),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
      builder: (context, controller, child) => IconButton(
        tooltip: '浏览选项',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.tune_rounded),
      ),
    );
  }
}

class _MoreActionsMenu extends StatelessWidget {
  const _MoreActionsMenu({required this.actions});

  final List<BrowserToolbarAction> actions;

  @override
  Widget build(BuildContext context) => MenuAnchor(
        menuChildren: [
          for (final action in actions)
            MenuItemButton(
              onPressed: action.onPressed,
              leadingIcon: Icon(action.icon),
              child: Text(action.label),
            ),
        ],
        builder: (context, controller, child) => IconButton(
          tooltip: '更多',
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
          icon: const Icon(Icons.more_vert_rounded),
        ),
      );
}

class _GridLayoutOption extends StatelessWidget {
  const _GridLayoutOption({
    required this.mode,
    required this.selected,
    required this.onSelected,
  });

  final BrowserGridLayout mode;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 119,
      height: 48,
      child: Material(
        color: selected
            ? colors.secondaryContainer.withValues(alpha: .72)
            : colors.surfaceContainerHighest.withValues(alpha: .42),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onSelected,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: selected
                    ? colors.primary.withValues(alpha: .76)
                    : colors.outlineVariant.withValues(alpha: .58),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(_gridLayoutIcon(mode), size: 18),
                const SizedBox(width: 7),
                Text(
                  _gridLayoutLabel(mode),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: selected ? colors.primary : null,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
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

String _gridLayoutLabel(BrowserGridLayout mode) => switch (mode) {
      BrowserGridLayout.equalHeight => '等高',
      BrowserGridLayout.equalWidth => '等宽',
      BrowserGridLayout.adaptive => '自适应',
      BrowserGridLayout.square => '方格',
    };

IconData _gridLayoutIcon(BrowserGridLayout mode) => switch (mode) {
      BrowserGridLayout.equalHeight => Icons.view_stream_outlined,
      BrowserGridLayout.equalWidth => Icons.view_column_outlined,
      BrowserGridLayout.adaptive => Icons.auto_awesome_mosaic_outlined,
      BrowserGridLayout.square => Icons.grid_on_outlined,
    };
