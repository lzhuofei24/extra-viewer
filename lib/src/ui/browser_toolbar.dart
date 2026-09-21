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
    this.onFileDisplayChanged,
    this.onSearch,
    this.onAdd,
    this.addLabel = '添加',
    this.onAutoSync,
    this.autoSyncPanelBuilder,
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
  final void Function(BrowserDisplayMode, BrowserListStyle)?
      onFileDisplayChanged;
  final VoidCallback? onSearch;
  final VoidCallback? onAdd;
  final String addLabel;
  final VoidCallback? onAutoSync;
  final WidgetBuilder? autoSyncPanelBuilder;
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
              if (onAutoSync != null || autoSyncPanelBuilder != null)
                _AutoSyncMenu(
                  onPressed: onAutoSync,
                  panelBuilder: autoSyncPanelBuilder,
                ),
              _BrowserOptionsMenu(
                onAdd: onAdd,
                addLabel: addLabel,
                onFolderCoverChanged: onFolderCoverChanged,
                onFileDisplayChanged: onFileDisplayChanged,
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

class _AutoSyncMenu extends StatefulWidget {
  const _AutoSyncMenu({this.onPressed, this.panelBuilder});

  final VoidCallback? onPressed;
  final WidgetBuilder? panelBuilder;

  @override
  State<_AutoSyncMenu> createState() => _AutoSyncMenuState();
}

class _AutoSyncMenuState extends State<_AutoSyncMenu> {
  final _anchorKey = GlobalKey();
  RawDialogRoute<void>? _route;

  void _open() {
    if (_route != null) return;
    if (widget.panelBuilder == null) {
      widget.onPressed?.call();
      return;
    }
    final box = _anchorKey.currentContext!.findRenderObject()! as RenderBox;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final padding = MediaQuery.paddingOf(context);
    final route = RawDialogRoute<void>(
      barrierDismissible: false,
      barrierLabel: '关闭目录自动同步',
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      pageBuilder: (context, _, __) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: CustomSingleChildLayout(
          delegate: _OptionsPosition(anchor, padding),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth:
                  (MediaQuery.sizeOf(context).width - 24).clamp(160.0, 340.0),
              maxHeight:
                  (MediaQuery.sizeOf(context).height - padding.vertical - 24)
                      .clamp(120.0, double.infinity),
            ),
            child: GestureDetector(
              onTap: () {},
              child: widget.panelBuilder!(context),
            ),
          ),
        ),
      ),
    );
    _route = route;
    Navigator.of(context).push(route).whenComplete(() => _route = null);
  }

  @override
  void dispose() {
    final route = _route;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route?.navigator != null) route!.navigator!.removeRoute(route);
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IconButton(
        key: _anchorKey,
        tooltip: '目录自动同步',
        onPressed: _open,
        icon: const Icon(Icons.sync_rounded),
      );
}

class _BrowserOptionsMenu extends StatefulWidget {
  const _BrowserOptionsMenu({
    this.onFolderCoverChanged,
    this.onFileDisplayChanged,
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
    this.onAdd,
    this.addLabel = '添加',
  });

  final bool allowSorting, allowGridStyle;
  final ValueChanged<FolderCoverStyle>? onFolderCoverChanged;
  final void Function(BrowserDisplayMode, BrowserListStyle)?
      onFileDisplayChanged;
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
  final VoidCallback? onAdd;
  final String addLabel;

  @override
  State<_BrowserOptionsMenu> createState() => _BrowserOptionsMenuState();
}

class _BrowserOptionsMenuState extends State<_BrowserOptionsMenu> {
  late final ValueNotifier<_BrowserOptionsMenu> _configuration =
      ValueNotifier(widget);
  final _anchorKey = GlobalKey();
  RawDialogRoute<void>? _route;

  @override
  void didUpdateWidget(_BrowserOptionsMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_route == null) {
      _configuration.value = widget;
    } else {
      // The menu lives in another route; publish after the parent finishes building.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _configuration.value = widget;
      });
    }
  }

  @override
  void dispose() {
    final route = _route;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route?.navigator != null) route!.navigator!.removeRoute(route);
      _configuration.dispose();
    });
    super.dispose();
  }

  void _open() {
    if (_route != null) return;
    final box = _anchorKey.currentContext!.findRenderObject()! as RenderBox;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final route = RawDialogRoute<void>(
      barrierDismissible: false,
      barrierLabel: '关闭浏览选项',
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      pageBuilder: (context, _, __) =>
          _BrowserOptionsPanel(configuration: _configuration, anchor: anchor),
    );
    _route = route;
    Navigator.of(context).push(route).whenComplete(() => _route = null);
  }

  @override
  Widget build(BuildContext context) => IconButton(
      key: _anchorKey,
      tooltip: '浏览选项',
      onPressed: _open,
      icon: const Icon(Icons.tune_rounded));
}

enum _OptionsSection { main, folders, files }

enum _FileDisplay { cards, list, compact }

class _BrowserOptionsPanel extends StatefulWidget {
  const _BrowserOptionsPanel(
      {required this.configuration, required this.anchor});
  final ValueNotifier<_BrowserOptionsMenu> configuration;
  final Rect anchor;
  @override
  State<_BrowserOptionsPanel> createState() => _BrowserOptionsPanelState();
}

class _BrowserOptionsPanelState extends State<_BrowserOptionsPanel> {
  _OptionsSection _section = _OptionsSection.main;
  final _scroll = ScrollController();
  void _show(_OptionsSection value) {
    setState(() => _section = value);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<Widget> _group(String label, Widget child) => [
        Text(label),
        const SizedBox(height: 6),
        child,
        const SizedBox(height: 12)
      ];

  Widget _fileDensity(BuildContext context, _BrowserOptionsMenu config) {
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final settings = config.layoutSettings;
    final browser = config.browserState;
    if (browser.displayMode == BrowserDisplayMode.list) {
      final text = browser.listStyle == BrowserListStyle.text;
      return _LayoutCountControl(
          label: '每行数量',
          value: settings.fileListColumns(isPortrait: portrait, textOnly: text),
          max: portrait ? 3 : 4,
          onChanged: (v) => config.onLayoutChanged(
              settings.withFileListColumns(portrait, text, v)));
    }
    if (browser.gridLayout == BrowserGridLayout.equalHeight) {
      return _LayoutCountControl(
          label: '高度级别',
          value: settings.equalHeightLevel(isPortrait: portrait),
          suffix:
              '${settings.equalHeight(isPortrait: portrait, viewportWidth: MediaQuery.sizeOf(context).width - MediaQuery.paddingOf(context).horizontal).round()}dp',
          onChanged: (v) => config.onLayoutChanged(portrait
              ? settings.copyWith(portraitEqualHeightLevel: v)
              : settings.copyWith(landscapeEqualHeightLevel: v)));
    }
    final square = browser.gridLayout == BrowserGridLayout.square;
    return _LayoutCountControl(
        label: '每行数量',
        value: square
            ? settings.squareColumns(isPortrait: portrait)
            : settings.equalWidthColumns(isPortrait: portrait),
        onChanged: (v) => config.onLayoutChanged(square
            ? (portrait
                ? settings.copyWith(portraitSquareColumns: v)
                : settings.copyWith(landscapeSquareColumns: v))
            : (portrait
                ? settings.copyWith(portraitEqualWidthColumns: v)
                : settings.copyWith(landscapeEqualWidthColumns: v))));
  }

  List<Widget> _content(BuildContext context, _BrowserOptionsMenu config) {
    final browser = config.browserState;
    if (_section == _OptionsSection.main) {
      return [
        if (config.sortDescription != null) Text(config.sortDescription!),
        if (config.allowSorting)
          ..._group(
              '排序',
              _GlassOptionSelector<EntitySortMode>(values: const [
                EntitySortMode.modifiedDesc,
                EntitySortMode.nameAsc,
                EntitySortMode.sizeDesc
              ], labels: const [
                '最近',
                '名称',
                '大小'
              ], selected: browser.sortMode, onSelected: config.onSortChanged)),
        ..._group(
            '主题',
            _GlassOptionSelector<ViewerThemeChoice>(
                values: const [
                  ViewerThemeChoice.system,
                  ViewerThemeChoice.galleryDark,
                  ViewerThemeChoice.galleryLight
                ],
                labels: const [
                  '系统',
                  '暗色',
                  '亮色'
                ],
                selected: config.themeChoice,
                onSelected: config.onThemeChanged)),
        if (config.showFolders) _entry('文件夹设置', _OptionsSection.folders),
        if (config.showFiles) _entry('文件设置', _OptionsSection.files),
        if (config.onAdd != null)
          TextButton.icon(
            onPressed: config.onAdd,
            icon: const Icon(Icons.add),
            label: Text(config.addLabel),
          ),
      ];
    }
    if (_section == _OptionsSection.folders) {
      final portrait =
          MediaQuery.orientationOf(context) == Orientation.portrait;
      final settings = config.layoutSettings;
      final folders = settings.folders(isPortrait: portrait);
      void change(FolderViewSettings value) =>
          config.onLayoutChanged(settings.withFolders(portrait, value));
      final list = folders.display == FolderDisplay.list;
      final high = folders.cardLayout == FolderCardLayout.equalHeight;
      final columns = 9 - folders.heightLevel;
      final height = ((MediaQuery.sizeOf(context).width -
                  MediaQuery.paddingOf(context).horizontal -
                  2 * settings.pageMargin -
                  (columns - 1) * settings.cardGap) /
              columns)
          .clamp(1.0, double.infinity);
      return [
        ..._group(
            '显示',
            _GlassOptionSelector<FolderDisplay>(
                values: FolderDisplay.values,
                labels: const ['叠加卡片', '方形卡片', '列表'],
                selected: folders.display,
                onSelected: (v) => change(folders.copyWith(display: v)))),
        if (!list)
          ..._group(
              '布局',
              _GlassOptionSelector<FolderCardLayout>(
                  values: FolderCardLayout.values,
                  labels: const ['等高', '等宽'],
                  selected: folders.cardLayout,
                  onSelected: (v) => change(folders.copyWith(cardLayout: v)))),
        _LayoutCountControl(
            label: !list && high ? '高度级别' : '每行数量',
            value: list
                ? folders.listColumns
                : high
                    ? folders.heightLevel
                    : folders.columns,
            max: list ? (portrait ? 3 : 4) : 8,
            suffix: !list && high ? '${height.round()}dp' : null,
            onChanged: (v) => change(list
                ? folders.copyWith(listColumns: v)
                : high
                    ? folders.copyWith(heightLevel: v)
                    : folders.copyWith(columns: v))),
      ];
    }
    final display = browser.displayMode == BrowserDisplayMode.grid
        ? _FileDisplay.cards
        : browser.listStyle == BrowserListStyle.text
            ? _FileDisplay.compact
            : _FileDisplay.list;
    return [
      ..._group(
          '显示',
          _GlassOptionSelector<_FileDisplay>(
              values: _FileDisplay.values,
              labels: const ['卡片', '列表', '紧凑列表'],
              selected: display,
              onSelected: (v) {
                if (config.onFileDisplayChanged != null) {
                  config.onFileDisplayChanged!(
                      v == _FileDisplay.cards
                          ? BrowserDisplayMode.grid
                          : BrowserDisplayMode.list,
                      v == _FileDisplay.cards
                          ? browser.listStyle
                          : v == _FileDisplay.compact
                              ? BrowserListStyle.text
                              : BrowserListStyle.normal);
                  return;
                }
                if (v != _FileDisplay.cards) {
                  config.onListStyleChanged(v == _FileDisplay.compact
                      ? BrowserListStyle.text
                      : BrowserListStyle.normal);
                }
                config.onDisplayModeChanged(v == _FileDisplay.cards
                    ? BrowserDisplayMode.grid
                    : BrowserDisplayMode.list);
              })),
      if (display == _FileDisplay.cards)
        ..._group(
            '布局',
            _GlassOptionSelector<BrowserGridLayout>(
                values: const [
                  BrowserGridLayout.equalHeight,
                  BrowserGridLayout.equalWidth,
                  BrowserGridLayout.square
                ],
                labels: const [
                  '等高',
                  '等宽',
                  '方形'
                ],
                selected: browser.gridLayout,
                onSelected: config.onGridLayoutChanged)),
      _fileDensity(context, config),
    ];
  }

  Widget _entry(String label, _OptionsSection section) => TextButton(
      onPressed: () => _show(section),
      child: Row(children: [
        Expanded(child: Text(label)),
        const Icon(Icons.chevron_right)
      ]));

  @override
  Widget build(BuildContext context) => PopScope<void>(
        canPop: _section == _OptionsSection.main,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _show(_OptionsSection.main);
        },
        child: ValueListenableBuilder<_BrowserOptionsMenu>(
          valueListenable: widget.configuration,
          builder: (context, config, _) {
            final size = MediaQuery.sizeOf(context);
            final padding = MediaQuery.paddingOf(context);
            return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).pop(),
                child: Material(
                    type: MaterialType.transparency,
                    child: CustomSingleChildLayout(
                      delegate: _OptionsPosition(widget.anchor, padding),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                            maxWidth: (size.width - 24).clamp(160.0, 340.0),
                            maxHeight: (size.height - padding.vertical - 24)
                                .clamp(80.0, double.infinity)),
                        child: GestureDetector(
                            onTap: () {},
                            child: FloatingGlassSurface(
                              key: const ValueKey('browser-options-surface'),
                              independentBackdrop: true,
                              role: GlassSurfaceRole.panel,
                              borderRadius: 20,
                              padding: const EdgeInsets.all(12),
                              child: Builder(
                                  builder: (context) => SingleChildScrollView(
                                        controller: _scroll,
                                        primary: false,
                                        child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              if (_section !=
                                                  _OptionsSection.main)
                                                Row(children: [
                                                  IconButton(
                                                      tooltip: '返回浏览选项',
                                                      onPressed: () => _show(
                                                          _OptionsSection.main),
                                                      icon: const Icon(
                                                          Icons.arrow_back)),
                                                  Expanded(
                                                      child: Text(_section ==
                                                              _OptionsSection
                                                                  .folders
                                                          ? '文件夹设置'
                                                          : '文件设置')),
                                                ]),
                                              ..._content(context, config),
                                            ]),
                                      )),
                            )),
                      ),
                    )));
          },
        ),
      );
}

class _OptionsPosition extends SingleChildLayoutDelegate {
  const _OptionsPosition(this.anchor, this.padding);
  final Rect anchor;
  final EdgeInsets padding;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
          maxWidth: (constraints.maxWidth - padding.horizontal - 24)
              .clamp(0.0, double.infinity),
          maxHeight: (constraints.maxHeight - padding.vertical - 24)
              .clamp(0.0, double.infinity));
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = (anchor.right - childSize.width).clamp(
        padding.left + 12,
        (size.width - padding.right - childSize.width - 12)
            .clamp(padding.left + 12, double.infinity));
    final maxTop = (size.height - padding.bottom - childSize.height - 12)
        .clamp(padding.top + 12, double.infinity);
    return Offset(left, (anchor.bottom + 6).clamp(padding.top + 12, maxTop));
  }

  @override
  bool shouldRelayout(_OptionsPosition oldDelegate) =>
      anchor != oldDelegate.anchor || padding != oldDelegate.padding;
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
      this.max = 8,
      this.suffix});
  final String label;
  final String? suffix;
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
                    width: suffix == null ? 28 : 100,
                    child: Text(suffix == null ? '$value' : '$value级 · $suffix',
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
