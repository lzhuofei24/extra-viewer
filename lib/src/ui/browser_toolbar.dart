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
                  if (browserState.displayMode == BrowserDisplayMode.grid)
                    SegmentedButton<BrowserGridLayout>(
                      segments: const [
                        ButtonSegment(
                            value: BrowserGridLayout.equalHeight,
                            label: Text('等高')),
                        ButtonSegment(
                            value: BrowserGridLayout.equalWidth,
                            label: Text('等宽')),
                        ButtonSegment(
                            value: BrowserGridLayout.square, label: Text('方形')),
                      ],
                      selected: {browserState.gridLayout},
                      onSelectionChanged: (value) =>
                          onGridLayoutChanged(value.first),
                    )
                  else
                    SegmentedButton<BrowserListStyle>(
                      segments: const [
                        ButtonSegment(
                            value: BrowserListStyle.text, label: Text('文本')),
                        ButtonSegment(
                            value: BrowserListStyle.compact, label: Text('紧凑')),
                        ButtonSegment(
                            value: BrowserListStyle.normal, label: Text('正常')),
                      ],
                      selected: {browserState.listStyle},
                      onSelectionChanged: (value) =>
                          onListStyleChanged(value.first),
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
