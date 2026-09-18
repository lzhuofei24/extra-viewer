import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/domain/models.dart';
import 'browser_state.dart';
import 'app_sidebar.dart';
import 'design_tokens.dart';
import 'gallery_layout_settings.dart';

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
    required this.themeChoice,
    required this.onThemeChanged,
    required this.layoutPreset,
    required this.onLayoutPresetChanged,
    this.onSearch,
    this.onAdd,
    this.addLabel = '添加',
    this.allowSorting = true,
    this.allowGridStyle = true,
    this.sortDescription,
    this.immersive = false,
    this.onToggleImmersive,
    this.selectionMode = false,
    this.onToggleSelection,
  });

  final bool allowSorting, allowGridStyle;
  final String? sortDescription;
  final Widget leading;
  final BrowserState browserState;
  final ValueChanged<EntitySortMode> onSortChanged;
  final ValueChanged<BrowserDisplayMode> onDisplayModeChanged;
  final ValueChanged<BrowserGridLayout> onGridLayoutChanged;
  final ValueChanged<BrowserListStyle> onListStyleChanged;
  final ViewerThemeChoice themeChoice;
  final ValueChanged<ViewerThemeChoice> onThemeChanged;
  final GalleryLayoutPreset layoutPreset;
  final ValueChanged<GalleryLayoutPreset> onLayoutPresetChanged;
  final VoidCallback? onSearch;
  final VoidCallback? onAdd;
  final String addLabel;
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
              if (onAdd != null)
                IconButton(
                    tooltip: addLabel,
                    onPressed: onAdd,
                    icon: const Icon(Icons.add)),
              if (onSearch != null)
                IconButton(
                  tooltip: '搜索目录、分类或规则',
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
                allowSorting: allowSorting,
                allowGridStyle: allowGridStyle,
                sortDescription: sortDescription,
                browserState: browserState,
                onSortChanged: onSortChanged,
                onDisplayModeChanged: onDisplayModeChanged,
                onGridLayoutChanged: onGridLayoutChanged,
                onListStyleChanged: onListStyleChanged,
                themeChoice: themeChoice,
                onThemeChanged: onThemeChanged,
                layoutPreset: layoutPreset,
                onLayoutPresetChanged: onLayoutPresetChanged,
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
    required this.allowSorting,
    required this.allowGridStyle,
    this.sortDescription,
    required this.browserState,
    required this.onSortChanged,
    required this.onDisplayModeChanged,
    required this.onGridLayoutChanged,
    required this.onListStyleChanged,
    required this.themeChoice,
    required this.onThemeChanged,
    required this.layoutPreset,
    required this.onLayoutPresetChanged,
  });

  final bool allowSorting, allowGridStyle;
  final String? sortDescription;
  final BrowserState browserState;
  final ValueChanged<EntitySortMode> onSortChanged;
  final ValueChanged<BrowserDisplayMode> onDisplayModeChanged;
  final ValueChanged<BrowserGridLayout> onGridLayoutChanged;
  final ValueChanged<BrowserListStyle> onListStyleChanged;
  final ViewerThemeChoice themeChoice;
  final ValueChanged<ViewerThemeChoice> onThemeChanged;
  final GalleryLayoutPreset layoutPreset;
  final ValueChanged<GalleryLayoutPreset> onLayoutPresetChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.labelLarge?.copyWith(
      color: Colors.black,
    );
    final labelStyle = theme.textTheme.labelMedium?.copyWith(
      color: Colors.black,
    );
    return MenuAnchor(
      // The shared glass surface owns its superellipse and refracted edge.
      clipBehavior: Clip.none,
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Colors.transparent),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        shadowColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(0),
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
      ),
      menuChildren: [
        FloatingGlassSurface(
          key: const ValueKey('browser-options-surface'),
          independentBackdrop: true,
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
                  Text('浏览选项', style: titleStyle),
                  const SizedBox(height: 10),
                  if (sortDescription != null)
                    Text(sortDescription!, style: labelStyle),
                  if (allowSorting) ...[
                    Text('排序', style: labelStyle),
                    const SizedBox(height: 6),
                    _GlassOptionSelector<EntitySortMode>(
                      values: const [
                        EntitySortMode.modifiedDesc,
                        EntitySortMode.nameAsc,
                        EntitySortMode.sizeDesc,
                      ],
                      labels: const ['最近', '名称', '大小'],
                      selected: browserState.sortMode,
                      onSelected: onSortChanged,
                    ),
                    const SizedBox(height: 12),
                  ],
                  Text('显示', style: labelStyle),
                  const SizedBox(height: 6),
                  _GlassOptionSelector<BrowserDisplayMode>(
                    values: const [
                      BrowserDisplayMode.grid,
                      BrowserDisplayMode.list,
                    ],
                    labels: const ['卡片', '列表'],
                    icons: const [
                      Icons.grid_view_rounded,
                      Icons.view_agenda_rounded,
                    ],
                    selected: browserState.displayMode,
                    onSelected: onDisplayModeChanged,
                  ),
                  const SizedBox(height: 12),
                  if (allowGridStyle ||
                      browserState.displayMode == BrowserDisplayMode.list) ...[
                    Text('样式', style: labelStyle),
                    const SizedBox(height: 6),
                    if (browserState.displayMode == BrowserDisplayMode.grid)
                      _GlassOptionSelector<BrowserGridLayout>(
                        values: const [
                          BrowserGridLayout.equalHeight,
                          BrowserGridLayout.equalWidth,
                          BrowserGridLayout.square,
                        ],
                        labels: const ['等高', '等宽', '方形'],
                        selected: browserState.gridLayout,
                        onSelected: onGridLayoutChanged,
                      )
                    else
                      _GlassOptionSelector<BrowserListStyle>(
                        values: const [
                          BrowserListStyle.text,
                          BrowserListStyle.compact,
                          BrowserListStyle.normal,
                        ],
                        labels: const ['文本', '紧凑', '正常'],
                        selected: browserState.listStyle,
                        onSelected: onListStyleChanged,
                      ),
                    const SizedBox(height: 12),
                  ],
                  Text('主题', style: labelStyle),
                  const SizedBox(height: 6),
                  _GlassOptionSelector<ViewerThemeChoice>(
                    values: const [
                      ViewerThemeChoice.system,
                      ViewerThemeChoice.galleryDark,
                      ViewerThemeChoice.galleryLight,
                    ],
                    labels: const ['系统', '暗色', '亮色'],
                    selected: themeChoice,
                    onSelected: onThemeChanged,
                  ),
                  const SizedBox(height: 12),
                  Text('布局', style: labelStyle),
                  const SizedBox(height: 6),
                  _GlassOptionSelector<GalleryLayoutPreset>(
                    values: const [
                      GalleryLayoutPreset.compact,
                      GalleryLayoutPreset.standard,
                      GalleryLayoutPreset.spacious,
                    ],
                    labels: const ['紧凑', '默认', '宽阔'],
                    selected: layoutPreset,
                    onSelected: onLayoutPresetChanged,
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

class _GlassOptionSelector<T> extends StatelessWidget {
  const _GlassOptionSelector({
    required this.values,
    required this.labels,
    required this.selected,
    required this.onSelected,
    this.icons,
  })  : assert(values.length == labels.length),
        assert(icons == null || icons.length == values.length);

  final List<T> values;
  final List<String> labels;
  final List<IconData>? icons;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final selectedIndex = values.indexOf(selected);
    return SizedBox(
      width: double.infinity,
      child: GlassSegmentedControl(
        height: 40,
        useOwnLayer: true,
        quality: ImageFilter.isShaderFilterSupported
            ? GlassQuality.premium
            : GlassQuality.minimal,
        settings: FloatingGlassSurface.settingsOf(context),
        selectedTextStyle: const TextStyle(
          color: Colors.black,
          fontWeight: FontWeight.w600,
        ),
        unselectedTextStyle: const TextStyle(
          color: Colors.black,
          fontWeight: FontWeight.w400,
        ),
        selectedIconColor: Colors.black,
        unselectedIconColor: Colors.black,
        segments: [
          for (var index = 0; index < values.length; index++)
            GlassSegment(
              label: labels[index],
              icon: icons == null ? null : Icon(icons![index], size: 16),
            ),
        ],
        selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
        onSegmentSelected: (index) => onSelected(values[index]),
      ),
    );
  }
}
