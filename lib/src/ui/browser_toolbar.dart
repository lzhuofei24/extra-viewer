import 'package:flutter/material.dart';

import '../core/domain/models.dart';
import 'browser_state.dart';
import 'app_sidebar.dart';

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
    required this.onListStyleChanged,
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
  final ValueChanged<BrowserListStyle> onListStyleChanged;
  final VoidCallback? onSearch;
  final bool immersive;
  final VoidCallback? onToggleImmersive;
  final bool selectionMode;
  final VoidCallback? onToggleSelection;
  final List<BrowserToolbarAction> moreActions;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final actions = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
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
                onListStyleChanged: onListStyleChanged,
              ),
              if (moreActions.isNotEmpty)
                _MoreActionsMenu(actions: moreActions),
            ],
          );
          if (constraints.maxWidth < 600) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 44,
                  width: double.infinity,
                  child: FloatingGlassSurface(
                    borderRadius: 22,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: leading,
                  ),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: FloatingGlassSurface(
                    borderRadius: 22,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: actions,
                  ),
                ),
              ],
            );
          }
          return FloatingGlassSurface(
            borderRadius: 24,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Expanded(child: leading),
                actions,
              ],
            ),
          );
        },
      );
}

class _BrowserOptionsMenu extends StatelessWidget {
  const _BrowserOptionsMenu({
    required this.browserState,
    required this.onSortChanged,
    required this.onDisplayModeChanged,
    required this.onGridLayoutChanged,
    required this.onListStyleChanged,
  });

  final BrowserState browserState;
  final ValueChanged<EntitySortMode> onSortChanged;
  final ValueChanged<BrowserDisplayMode> onDisplayModeChanged;
  final ValueChanged<BrowserGridLayout> onGridLayoutChanged;
  final ValueChanged<BrowserListStyle> onListStyleChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MenuAnchor(
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Colors.transparent),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        shadowColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(0),
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
      ),
      menuChildren: [
        FloatingGlassSurface(
          borderRadius: 20,
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: (MediaQuery.sizeOf(context).width - 48).clamp(160.0, 276.0),
            child: SingleChildScrollView(
              primary: false,
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
                          value: EntitySortMode.modifiedDesc,
                          label: Text('最近')),
                      ButtonSegment(
                          value: EntitySortMode.nameAsc, label: Text('名称')),
                      ButtonSegment(
                          value: EntitySortMode.sizeDesc, label: Text('大小')),
                    ],
                    selected: {browserState.sortMode},
                    onSelectionChanged: (value) => onSortChanged(value.first),
                  ),
                  const SizedBox(height: 12),
                  Text('显示', style: theme.textTheme.labelMedium),
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
                  const SizedBox(height: 12),
                  Text('样式', style: theme.textTheme.labelMedium),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children:
                        browserState.displayMode == BrowserDisplayMode.grid
                            ? [
                                for (final mode in [
                                  BrowserGridLayout.equalHeight,
                                  BrowserGridLayout.equalWidth,
                                  BrowserGridLayout.square,
                                ])
                                  _GridLayoutOption(
                                    mode: mode,
                                    selected: browserState.gridLayout == mode,
                                    onSelected: () => onGridLayoutChanged(mode),
                                  ),
                              ]
                            : [
                                for (final style in BrowserListStyle.values)
                                  _ListStyleOption(
                                    style: style,
                                    selected: browserState.listStyle == style,
                                    onSelected: () => onListStyleChanged(style),
                                  ),
                              ],
                  ),
                ],
              ),
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
    this.label,
  });

  final String? label;
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
                  label ?? _gridLayoutLabel(mode),
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
      BrowserGridLayout.square => '方形',
    };

IconData _gridLayoutIcon(BrowserGridLayout mode) => switch (mode) {
      BrowserGridLayout.equalHeight => Icons.view_stream_outlined,
      BrowserGridLayout.equalWidth => Icons.view_column_outlined,
      BrowserGridLayout.square => Icons.grid_on_outlined,
    };

class _ListStyleOption extends StatelessWidget {
  const _ListStyleOption(
      {required this.style, required this.selected, required this.onSelected});
  final BrowserListStyle style;
  final bool selected;
  final VoidCallback onSelected;
  @override
  Widget build(BuildContext context) => _GridLayoutOption(
        mode: BrowserGridLayout.equalHeight,
        label: switch (style) {
          BrowserListStyle.text => '文本',
          BrowserListStyle.compact => '紧凑',
          BrowserListStyle.normal => '正常'
        },
        selected: selected,
        onSelected: onSelected,
      );
}
