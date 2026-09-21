import 'dart:async';

import 'browser_node_grid.dart';
import 'browser_path_rail.dart';
import 'library_widgets.dart';
import 'package:flutter/material.dart';
import '../core/domain/models.dart';
import '../modules/library/library_queries.dart';
import 'app_preferences.dart';
import 'browser_list.dart';
import 'browser_state.dart';
import 'browser_toolbar.dart';
import 'browser_page_scaffold.dart';
import 'browser_entity_sliver.dart';
import 'rule_browser_controller.dart';
import 'gallery_layout_settings.dart';

class RuleIndexPage extends StatefulWidget {
  const RuleIndexPage({
    super.key,
    required this.queries,
    required this.browserState,
    required this.layoutSettings,
    required this.preferences,
    required this.onOpenEntity,
    required this.onThumbnailNeeded,
    required this.onSearch,
    this.onAutoSync,
    required this.onBrowserStateChanged,
    required this.onAddToCollection,
    required this.onEditRule,
    required this.onDeleteRule,
    this.initialRuleId,
    required this.onSelectionModeChanged,
    this.controller,
    this.onCreateRule,
    this.onImmersiveChanged,
  });

  final LibraryQueries queries;
  final BrowserState browserState;
  final GalleryLayoutSettings layoutSettings;
  final AppPreferencesController preferences;
  final void Function(EntityListItem entity, List<EntityListItem> queue)
      onOpenEntity;
  final ValueChanged<EntityListItem> onThumbnailNeeded;
  final VoidCallback onSearch;
  final VoidCallback? onAutoSync;
  final ValueChanged<BrowserState> onBrowserStateChanged;
  final Future<void> Function(Set<String>) onAddToCollection;
  final Future<void> Function(RuleDefinition) onEditRule;
  final Future<void> Function(RuleDefinition) onDeleteRule;
  final String? initialRuleId;
  final ValueChanged<bool> onSelectionModeChanged;
  final RuleBrowserController? controller;
  final VoidCallback? onCreateRule;
  final ValueChanged<bool>? onImmersiveChanged;

  @override
  State<RuleIndexPage> createState() => _RuleIndexPageState();
}

class _RuleIndexPageState extends State<RuleIndexPage> {
  late final RuleBrowserController _controller;
  bool get _immersive => _controller.immersive;
  void _setImmersive(bool value) {
    _controller.setImmersive(value);
    widget.onImmersiveChanged?.call(value);
    if (_controller.activeRule != null) {
      unawaited(_controller.loadPage(reset: true));
    }
  }

  bool _selectionMode = false;
  final Set<String> _selected = {};
  String get _scope => _controller.activeRule?.node.id ?? 'home';

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? RuleBrowserController(widget.queries);
    _controller.addListener(_changed);
    if (widget.initialRuleId != null &&
        widget.initialRuleId != _controller.activeRule?.node.id) {
      _controller.loadRules(initialRuleId: widget.initialRuleId);
    } else if (_controller.activeRule == null) {
      _controller.loadRules();
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  void _select([String? id]) {
    final entering = !_selectionMode;
    setState(() {
      _selectionMode = true;
      if (id != null && !_selected.add(id)) _selected.remove(id);
    });
    if (entering) widget.onSelectionModeChanged(true);
  }

  void _exitSelection() {
    if (!_selectionMode) return;
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
    widget.onSelectionModeChanged(false);
  }

  void _open(RuleDefinition rule) {
    _exitSelection();
    _setImmersive(false);
    _controller.openRule(rule);
  }

  void _close() {
    _exitSelection();
    _setImmersive(false);
    _controller.closeRule();
  }

  Iterable<String> get _visibleIds => _controller.activeRule == null
      ? _controller.rules.map((r) => r.node.id)
      : _controller.items.map((e) => e.id);

  @override
  Widget build(BuildContext context) {
    final rule = _controller.activeRule;
    return BrowserPageScaffold(
      immersive: _immersive,
      onExitImmersive: () => _setImmersive(false),
      toolbar: _toolbar(rule),
      selectionBar: _selectionMode ? _selectionBar() : null,
      body: BrowserScrollShell(
        key: ValueKey('rule:$_scope:$_immersive'),
        preloadScopeKey: 'rule:$_scope:${_controller.temporarySort}',
        warmupEnabled: rule != null &&
            (_immersive ||
                widget.browserState.displayMode != BrowserDisplayMode.list ||
                widget.browserState.listStyle != BrowserListStyle.text),
        entities: _controller.items,
        hasMore: _controller.hasMore &&
            !_controller.loading &&
            _controller.error == null,
        onLoadMore: _controller.loadPage,
        selectionMode: _selectionMode,
        onSelectEntitiesByDrag: (items) =>
            setState(() => _selected.addAll(items.map((e) => e.id))),
        child: (scroll, registry) => CustomScrollView(
          key: PageStorageKey('rule:$_scope:$_immersive'),
          controller: scroll,
          slivers: [
            if (!_immersive)
              SliverToBoxAdapter(
                  child:
                      SizedBox(height: BrowserPageScaffold.topInset(context))),
            if (_controller.loading)
              const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()))
            else if (_controller.error != null && _controller.items.isEmpty)
              SliverFillRemaining(
                  child: _ErrorState(
                      error: _controller.error!,
                      onRetry: () => rule == null
                          ? _controller.loadRules()
                          : _controller.loadPage(reset: true)))
            else if (rule == null)
              _homeSliver()
            else if (_controller.items.isEmpty)
              SliverFillRemaining(
                  child: Center(
                      child: Text(_controller.activeRule?.scopeMissing == true
                          ? '原目录或分类已删除，请编辑规则重新选择范围'
                          : _immersive
                              ? '没有可沉浸浏览的文件'
                              : '没有符合规则的文件')))
            else
              BrowserEntitySliver(
                  entities: _controller.items,
                  browserState: widget.browserState,
                  layoutSettings: widget.layoutSettings,
                  immersive: _immersive,
                  selectionMode: _selectionMode,
                  selectionRegistry: registry,
                  selectedEntityIds: _selected,
                  onOpenEntity: (e) =>
                      widget.onOpenEntity(e, _controller.items),
                  onShowEntityMenu: (e) => _select(e.id),
                  onThumbnailNeeded: widget.onThumbnailNeeded,
                  onToggleEntitySelection: (e) => _select(e.id),
                  onStartEntitySelection: (e) => _select(e.id)),
            if (_controller.hasMore)
              SliverToBoxAdapter(
                  child: Center(
                      child: TextButton(
                          onPressed: _controller.loadingMore
                              ? null
                              : _controller.loadPage,
                          child: Text(_controller.loadingMore
                              ? '加载中…'
                              : _controller.error != null
                                  ? '重试加载'
                                  : '加载更多')))),
            SliverToBoxAdapter(
                child: SizedBox(
                    height: BrowserPageScaffold.bottomInset(context,
                        selecting: _selectionMode))),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(RuleDefinition? rule) => BrowserToolbar(
        showFiles: true,
        showFolders: true,
        leading: BrowserPathRail(
            currentNode: rule?.node,
            path: [if (rule != null) rule.node],
            onOpenRootIndex: _close,
            onPathNodeSelected: (_) {}),
        browserState:
            widget.browserState.copyWith(sortMode: _displaySort(rule)),
        allowSorting: rule != null && !rule.isBuiltIn,
        allowGridStyle: rule != null,
        sortDescription: rule?.isBuiltIn == true
            ? rule!.builtInKind == BuiltInRuleKind.frequent
                ? '固定排序：访问次数'
                : '固定排序：最近打开'
            : rule != null && _controller.temporarySort == null
                ? '规则默认排序：${_sortLabel(rule.defaultSort)}'
                : null,
        onSortChanged: (value) => _controller.sort(_ruleSort(value)),
        onFileDisplayChanged: (display, style) => widget.onBrowserStateChanged(
            widget.browserState
                .copyWith(displayMode: display, listStyle: style)),
        onDisplayModeChanged: (v) => widget.onBrowserStateChanged(
            widget.browserState.copyWith(displayMode: v)),
        onGridLayoutChanged: (v) => widget
            .onBrowserStateChanged(widget.browserState.copyWith(gridLayout: v)),
        onListStyleChanged: (v) => widget
            .onBrowserStateChanged(widget.browserState.copyWith(listStyle: v)),
        themeChoice: widget.preferences.value.themeChoice,
        onThemeChanged: widget.preferences.setTheme,
        layoutSettings: widget.preferences.value.layout,
        onLayoutChanged: widget.preferences.setLayout,
        onSearch: widget.onSearch,
        onAutoSync: widget.onAutoSync,
        onFolderCoverChanged: rule == null
            ? (value) => widget.onBrowserStateChanged(
                widget.browserState.copyWith(folderCoverStyle: value))
            : null,
        onAdd: rule == null ? widget.onCreateRule : null,
        addLabel: '新建规则',
        onToggleImmersive: rule == null ? null : () => _setImmersive(true),
        selectionMode: _selectionMode,
        onToggleSelection: _selectionMode ? _exitSelection : () => _select(),
      );

  EntitySortMode _displaySort(RuleDefinition? rule) =>
      switch (_controller.temporarySort ?? rule?.defaultSort) {
        RuleSortMode.name => EntitySortMode.nameAsc,
        RuleSortMode.size => EntitySortMode.sizeDesc,
        _ => EntitySortMode.modifiedDesc,
      };

  Widget _homeSliver() {
    if (widget.layoutSettings
            .folders(
                isPortrait:
                    MediaQuery.orientationOf(context) == Orientation.portrait)
            .display ==
        FolderDisplay.list) {
      return BrowserListSliver(
          landscapeColumns: widget.layoutSettings.landscapeFolders.listColumns,
          portraitColumns: widget.layoutSettings.portraitFolders.listColumns,
          count: _controller.rules.length,
          style: BrowserListStyle.normal,
          padding: widget.layoutSettings.pageMargin,
          itemBuilder: (_, i) {
            final rule = _controller.rules[i];
            return BrowserListTile(
                style: BrowserListStyle.normal,
                title: '${rule.node.name}${rule.isBuiltIn ? " · 内置" : ""}',
                subtitle:
                    '${_ruleSummary(rule)} · ${rule.resultCount ?? 0} 个文件',
                selected: _selected.contains(rule.node.id),
                onTap: () =>
                    _selectionMode ? _select(rule.node.id) : _open(rule),
                onLongPress: () => _select(rule.node.id),
                previewBuilder: (_) => _cover(rule));
          });
    }
    final rules = {for (final rule in _controller.rules) rule.node.id: rule};
    return BrowserNodeGridSliver(
      folderCoverStyle: widget.browserState.folderCoverStyle,
      nodes: _controller.rules.map((r) => r.node).toList(),
      summaries: const {},
      previews: const {},
      selectedNodeIds: _selected,
      selectionMode: _selectionMode,
      layoutSettings: widget.layoutSettings,
      onOpenNode: (node) => _open(rules[node.id]!),
      onToggleNodeSelection: (node) => _select(node.id),
      onStartNodeSelection: (node) => _select(node.id),
      onThumbnailEntityNeeded: (_) {},
      coverAspectRatio: (node) {
        final cover = _controller.covers[node.id];
        final width = cover?.thumbnailWidth ?? 0,
            height = cover?.thumbnailHeight ?? 0;
        return width > 0 && height > 0 ? width / height : 1;
      },
      countLabel: (node) =>
          '${rules[node.id]!.resultCount ?? 0} 个文件${rules[node.id]!.isBuiltIn ? " · 内置" : ""}',
      description: (node) => _ruleSummary(rules[node.id]!),
      coverBuilder: (node, portrait) => _cover(rules[node.id]!),
    );
  }

  Widget _cover(RuleDefinition rule) {
    final entity = _controller.covers[rule.node.id];
    if (entity == null) {
      return ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Center(
              child: Icon(_ruleIcon(rule.builtInKind),
                  size: 56,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)));
    }
    return EntityArtwork(
        entityType: entity.entityType,
        format: entity.format,
        title: entity.title,
        borderRadius: BorderRadius.zero,
        thumbnailPath: entity.thumbnailPath,
        thumbnailStatus: entity.thumbnailStatus,
        onThumbnailNeeded: entity.thumbnailStatus == ThumbnailStatus.failed
            ? null
            : () => widget.onThumbnailNeeded(entity));
  }

  Widget _selectionBar() {
    final home = _controller.activeRule == null;
    final selectedRules =
        _controller.rules.where((r) => _selected.contains(r.node.id)).toList();
    final editable =
        selectedRules.isNotEmpty && selectedRules.every((r) => !r.isBuiltIn);
    return BrowserSelectionBar(
        count: _selected.length,
        onExit: _exitSelection,
        onSelectAll: () => setState(() => _selected.addAll(_visibleIds)),
        onInvert: () => setState(() {
              for (final id in _visibleIds) {
                if (!_selected.add(id)) _selected.remove(id);
              }
            }),
        actions: home
            ? [
                if (selectedRules.any((r) => r.isBuiltIn))
                  const Text('内置规则不可修改'),
                TextButton(
                    onPressed: editable && selectedRules.length == 1
                        ? () async {
                            await widget.onEditRule(selectedRules.single);
                            if (!mounted) return;
                            _exitSelection();
                            await _controller.loadRules();
                          }
                        : null,
                    child: const Text('编辑')),
                TextButton(
                    onPressed: editable
                        ? () async {
                            for (final rule in selectedRules) {
                              await widget.onDeleteRule(rule);
                              if (!mounted) return;
                            }
                            _exitSelection();
                            await _controller.loadRules();
                          }
                        : null,
                    child: const Text('删除')),
              ]
            : [
                TextButton(
                    onPressed: _selected.isEmpty
                        ? null
                        : () async {
                            await widget.onAddToCollection(Set.of(_selected));
                            if (mounted) _exitSelection();
                          },
                    child: const Text('加入分类')),
              ]);
  }
}

String _sortLabel(RuleSortMode mode) => switch (mode) {
      RuleSortMode.name => '名称',
      RuleSortMode.size => '大小',
      RuleSortMode.modified => '修改时间',
      _ => mode.name == 'openCount' ? '访问次数' : '最近打开',
    };

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
          child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('加载失败：$error'),
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: onRetry, child: const Text('重试'))
        ],
      ));
}

RuleSortMode _ruleSort(EntitySortMode sort) => switch (sort) {
      EntitySortMode.nameAsc || EntitySortMode.nameDesc => RuleSortMode.name,
      EntitySortMode.sizeAsc || EntitySortMode.sizeDesc => RuleSortMode.size,
      _ => RuleSortMode.modified,
    };

IconData _ruleIcon(BuiltInRuleKind? kind) => switch (kind) {
      BuiltInRuleKind.frequent => Icons.local_fire_department_outlined,
      BuiltInRuleKind.recentImages => Icons.image_outlined,
      BuiltInRuleKind.recentVideos => Icons.movie_outlined,
      BuiltInRuleKind.recentText => Icons.article_outlined,
      BuiltInRuleKind.recentMusic => Icons.music_note_outlined,
      null => Icons.rule_outlined,
    };

String _ruleSummary(RuleDefinition rule) {
  if (rule.isBuiltIn) {
    return switch (rule.builtInKind!) {
      BuiltInRuleKind.frequent => '访问越多，位置越靠前',
      BuiltInRuleKind.recentImages => '最近打开过的图片',
      BuiltInRuleKind.recentVideos => '最近打开过的视频',
      BuiltInRuleKind.recentText => '最近打开过的文本和文档',
      BuiltInRuleKind.recentMusic => '最近打开过的音乐',
    };
  }
  final parts = <String>[];
  if (rule.entityTypes.isNotEmpty) {
    parts.add(rule.entityTypes.map((e) => e.value).join('、'));
  }
  if (rule.extensions.isNotEmpty) parts.add(rule.extensions.join('、'));
  if (rule.scopeNodeId != null) parts.add('限定位置');
  if (rule.minSize != null || rule.maxSize != null) parts.add('限定大小');
  if (rule.modifiedWithinDays != null) parts.add('最近修改');
  if (rule.openedWithinDays != null) parts.add('最近打开');
  return parts.isEmpty ? '全部文件' : parts.join(' · ');
}
