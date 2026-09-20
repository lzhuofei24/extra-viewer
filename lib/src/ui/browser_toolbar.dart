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
    required this.layoutSettings,
    this.showFiles = true,
    this.showFolders = true,
    required this.onLayoutChanged,
    this.onFolderCoverChanged,
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
  final GalleryLayoutSettings layoutSettings;
  final bool showFiles, showFolders;
  final ValueChanged<GalleryLayoutSettings> onLayoutChanged;
  final ValueChanged<FolderCoverStyle>? onFolderCoverChanged;
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
                onFolderCoverChanged: onFolderCoverChanged,
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
                layoutSettings: layoutSettings,
                showFiles: showFiles,
                showFolders: showFolders,
                onLayoutChanged: onLayoutChanged,
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
    this.onFolderCoverChanged,
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
    required this.layoutSettings,
    this.showFiles = true,
    this.showFolders = true,
    required this.onLayoutChanged,
  });

  final bool allowSorting, allowGridStyle;
  final ValueChanged<FolderCoverStyle>? onFolderCoverChanged;
  final String? sortDescription;
  final BrowserState browserState;
  final ValueChanged<EntitySortMode> onSortChanged;
  final ValueChanged<BrowserDisplayMode> onDisplayModeChanged;
  final ValueChanged<BrowserGridLayout> onGridLayoutChanged;
  final ValueChanged<BrowserListStyle> onListStyleChanged;
  final ViewerThemeChoice themeChoice;
  final ValueChanged<ViewerThemeChoice> onThemeChanged;
  final GalleryLayoutSettings layoutSettings;
  final bool showFiles, showFolders;
  final ValueChanged<GalleryLayoutSettings> onLayoutChanged;

  List<Widget> _layoutControls(BuildContext context) {
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final settings = layoutSettings;
    if (browserState.displayMode == BrowserDisplayMode.list) {
      return [
        if (portrait)
          const Text('每行 1 项（竖屏）')
        else
          _LayoutCountControl(
              label: '每行数量',
              value: settings.landscapeListColumns,
              max: 3,
              onChanged: (v) =>
                  onLayoutChanged(settings.copyWith(landscapeListColumns: v))),
      ];
    }
    return [
      if (showFiles && allowGridStyle) ...[
        const Text('文件布局'),
        if (browserState.gridLayout == BrowserGridLayout.equalHeight)
          _LayoutCountControl(
              label: '每屏行数',
              value: settings.equalHeightRows(isPortrait: portrait),
              max: 6,
              onChanged: (v) => onLayoutChanged(portrait
                  ? settings.copyWith(portraitEqualHeightRows: v)
                  : settings.copyWith(landscapeEqualHeightRows: v)))
        else if (browserState.gridLayout == BrowserGridLayout.equalWidth)
          _LayoutCountControl(
              label: '每行数量',
              value: settings.equalWidthColumns(isPortrait: portrait),
              onChanged: (v) => onLayoutChanged(portrait
                  ? settings.copyWith(portraitEqualWidthColumns: v)
                  : settings.copyWith(landscapeEqualWidthColumns: v)))
        else
          _LayoutCountControl(
              label: '每行数量',
              value: settings.squareColumns(isPortrait: portrait),
              onChanged: (v) => onLayoutChanged(portrait
                  ? settings.copyWith(portraitSquareColumns: v)
                  : settings.copyWith(landscapeSquareColumns: v))),
      ],
      if (showFolders) ...[
        const Text('文件夹布局'),
        _LayoutCountControl(
            label: '每行数量',
            value: settings.folderColumns(isPortrait: portrait),
            onChanged: (v) => onLayoutChanged(portrait
                ? settings.copyWith(portraitFolderColumns: v)
                : settings.copyWith(landscapeFolderColumns: v))),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
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
          role: GlassSurfaceRole.panel,
          borderRadius: 20,
          padding: const EdgeInsets.all(12),
          child: Builder(builder: (context) {
            final theme = Theme.of(context);
            final titleStyle = theme.textTheme.labelLarge;
            final labelStyle = theme.textTheme.labelMedium;
            return SizedBox(
              width:
                  (MediaQuery.sizeOf(context).width - 48).clamp(160.0, 276.0),
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
                    if (browserState.displayMode == BrowserDisplayMode.grid &&
                        onFolderCoverChanged != null &&
                        showFolders) ...[
                      Text('文件夹封面', style: labelStyle),
                      const SizedBox(height: 6),
                      _GlassOptionSelector<FolderCoverStyle>(
                        values: FolderCoverStyle.values,
                        labels: const ['自动', '方形', '叠加'],
                        selected: browserState.folderCoverStyle,
                        onSelected: onFolderCoverChanged!,
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
                        browserState.displayMode ==
                            BrowserDisplayMode.list) ...[
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
                    Text('布局', style: labelStyle),
                    const SizedBox(height: 6),
                    ..._layoutControls(context),
                  ],
                ),
              ),
            );
          }),
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
    final appearance = GlassAppearance.of(context);
    return SizedBox(
      width: double.infinity,
      child: GlassSegmentedControl(
        height: 40,
        useOwnLayer: true,
        quality: ImageFilter.isShaderFilterSupported
            ? GlassQuality.premium
            : GlassQuality.minimal,
        settings: appearance.indicatorSettings,
        indicatorSettings: appearance.indicatorSettings,
        backgroundColor: Colors.transparent,
        indicatorColor: appearance.selectedBackground,
        selectedTextStyle: TextStyle(
          color: appearance.foreground,
          fontWeight: FontWeight.w600,
        ),
        unselectedTextStyle: TextStyle(
          color: appearance.foreground,
          fontWeight: FontWeight.w400,
        ),
        selectedIconColor: appearance.foreground,
        unselectedIconColor: appearance.foreground,
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

class _LayoutCountControl extends StatelessWidget {
  const _LayoutCountControl(
      {required this.label,
      required this.value,
      required this.onChanged,
      this.max = 8});
  final String label;
  final int value, max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          Text(label),
          Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
                tooltip: '减少$label',
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                onPressed: value > 1 ? () => onChanged(value - 1) : null,
                icon: const Icon(Icons.remove)),
            Semantics(
                value: '$value',
                child: SizedBox(
                    width: 28,
                    child: Text('$value',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: GlassAppearance.of(context).foreground)))),
            IconButton(
                tooltip: '增加$label',
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                onPressed: value < max ? () => onChanged(value + 1) : null,
                icon: const Icon(Icons.add)),
          ]),
        ],
      );
}
