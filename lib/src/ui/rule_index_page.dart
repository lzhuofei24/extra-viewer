import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../core/domain/models.dart';
import '../modules/library/library_queries.dart';
import 'app_preferences.dart';
import 'app_sidebar.dart';
import 'browser_list.dart';
import 'browser_state.dart';
import 'browser_toolbar.dart';
import 'collection_grid_layout.dart';
import 'gallery_layout_settings.dart';
import 'library_widgets.dart';

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
    required this.onBrowserStateChanged,
    required this.onAddToCollection,
    required this.onEditRule,
    required this.onDeleteRule,
    this.initialRuleId,
  });

  final LibraryQueries queries;
  final BrowserState browserState;
  final GalleryLayoutSettings layoutSettings;
  final AppPreferencesController preferences;
  final void Function(EntityListItem entity, List<EntityListItem> queue)
      onOpenEntity;
  final ValueChanged<EntityListItem> onThumbnailNeeded;
  final VoidCallback onSearch;
  final ValueChanged<BrowserState> onBrowserStateChanged;
  final Future<void> Function(Set<String>) onAddToCollection;
  final Future<void> Function(RuleDefinition) onEditRule;
  final Future<void> Function(RuleDefinition) onDeleteRule;
  final String? initialRuleId;

  @override
  State<RuleIndexPage> createState() => _RuleIndexPageState();
}

class _RuleIndexPageState extends State<RuleIndexPage> {
  List<RuleDefinition> _rules = const [];
  RuleDefinition? _activeRule;
  List<EntityListItem> _items = const [];
  RulePageCursor? _cursor;
  RuleSortMode? _temporarySort;
  bool _loading = true;
  bool _loadingMore = false;
  bool _immersive = false;
  bool _selectionMode = false;
  final Set<String> _selected = <String>{};
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadRules();
  }

  Future<void> _loadRules() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rules = await widget.queries.listRules();
      if (!mounted) return;
      setState(() {
        _rules = rules;
        _loading = false;
      });
      final initialId = widget.initialRuleId;
      if (initialId != null) {
        final matches = rules.where((rule) => rule.node.id == initialId);
        if (matches.isNotEmpty) await _openRule(matches.first);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _loading = false;
        });
      }
    }
  }

  Future<void> _openRule(RuleDefinition rule) async {
    setState(() {
      _activeRule = rule;
      _items = const [];
      _cursor = null;
      _temporarySort = null;
      _loading = true;
      _error = null;
    });
    await _loadPage(reset: true);
  }

  Future<void> _loadPage({bool reset = false}) async {
    final rule = _activeRule;
    if (rule == null || _loadingMore) return;
    if (reset) {
      setState(() => _loading = true);
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final page = await widget.queries.loadRulePage(
        ruleNodeId: rule.node.id,
        sortMode: rule.isBuiltIn ? null : _temporarySort,
        after: reset ? null : _cursor,
      );
      if (!mounted || _activeRule?.node.id != rule.node.id) return;
      setState(() {
        _items = reset ? page.items : [..._items, ...page.items];
        _cursor = page.cursor;
        _loading = false;
        _loadingMore = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  void _closeRule() {
    setState(() {
      _activeRule = null;
      _items = const [];
      _cursor = null;
      _temporarySort = null;
      _immersive = false;
      _selectionMode = false;
      _selected.clear();
    });
    _loadRules();
  }

  void _toggleSelection([String? entityId]) {
    setState(() {
      _selectionMode = true;
      if (entityId != null && !_selected.add(entityId)) {
        _selected.remove(entityId);
      }
    });
  }

  void _exitSelection() => setState(() {
        _selectionMode = false;
        _selected.clear();
      });

  @override
  Widget build(BuildContext context) {
    if (_activeRule == null) return _buildHome(context);
    return _buildResults(context, _activeRule!);
  }

  Widget _buildHome(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _ErrorState(error: _error!, onRetry: _loadRules);
    final obstruction = AppNavigationObstruction.of(context);
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    return RefreshIndicator(
      onRefresh: _loadRules,
      child: GridView.builder(
        padding: EdgeInsets.fromLTRB(12, 20, 12, 100 + obstruction.bottom),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: portrait ? 1 : 3,
          mainAxisExtent: 116,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemCount: _rules.length,
        itemBuilder: (context, index) {
          final rule = _rules[index];
          return Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _openRule(rule),
              onLongPress: rule.isBuiltIn
                  ? null
                  : () async {
                      await widget.onEditRule(rule);
                      await _loadRules();
                    },
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  CircleAvatar(
                    child: Icon(_ruleIcon(rule.builtInKind)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(children: [
                          Expanded(
                              child: Text(rule.node.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      Theme.of(context).textTheme.titleMedium)),
                          if (rule.isBuiltIn)
                            const Icon(Icons.lock_outline, size: 16),
                        ]),
                        const SizedBox(height: 5),
                        Text(_ruleSummary(rule),
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        if (rule.resultCount != null)
                          Text('${rule.resultCount} 个文件',
                              style: Theme.of(context).textTheme.labelSmall),
                      ],
                    ),
                  ),
                  if (!rule.isBuiltIn)
                    PopupMenuButton<String>(
                      onSelected: (value) async {
                        if (value == 'edit') await widget.onEditRule(rule);
                        if (value == 'delete') await widget.onDeleteRule(rule);
                        await _loadRules();
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('编辑')),
                        PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildResults(BuildContext context, RuleDefinition rule) {
    final obstruction = AppNavigationObstruction.of(context);
    final topInset = MediaQuery.sizeOf(context).width < 600 ? 116.0 : 76.0;
    return Stack(children: [
      CustomScrollView(slivers: [
        if (!_immersive) SliverToBoxAdapter(child: SizedBox(height: topInset)),
        if (_loading)
          const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()))
        else if (_error != null)
          SliverFillRemaining(
              child: _ErrorState(
                  error: _error!, onRetry: () => _loadPage(reset: true)))
        else if (_items.isEmpty)
          const SliverFillRemaining(child: Center(child: Text('没有符合规则的文件')))
        else
          _buildEntitySliver(context),
        if (_cursor != null)
          SliverToBoxAdapter(
            child: Center(
                child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.tonal(
                onPressed: _loadingMore ? null : _loadPage,
                child: Text(_loadingMore ? '加载中…' : '加载更多'),
              ),
            )),
          ),
        SliverPadding(
            padding: EdgeInsets.only(bottom: 100 + obstruction.bottom)),
      ]),
      if (!_immersive)
        Positioned(
          top: 8,
          left: 12,
          right: 12,
          child: Center(
              child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: BrowserToolbar(
              leading: Row(children: [
                IconButton(
                    onPressed: _closeRule, icon: const Icon(Icons.arrow_back)),
                Expanded(
                    child: Text(rule.node.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (rule.isBuiltIn)
                  const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: Icon(Icons.lock_outline, size: 16)),
              ]),
              browserState: widget.browserState,
              onSortChanged: (sort) {
                widget.onBrowserStateChanged(
                    widget.browserState.copyWith(sortMode: sort));
                if (!rule.isBuiltIn) {
                  _temporarySort = _ruleSort(sort);
                  _loadPage(reset: true);
                }
              },
              onDisplayModeChanged: (mode) => widget.onBrowserStateChanged(
                  widget.browserState.copyWith(displayMode: mode)),
              onGridLayoutChanged: (layout) => widget.onBrowserStateChanged(
                  widget.browserState.copyWith(gridLayout: layout)),
              onListStyleChanged: (style) => widget.onBrowserStateChanged(
                  widget.browserState.copyWith(listStyle: style)),
              themeChoice: widget.preferences.value.themeChoice,
              onThemeChanged: widget.preferences.setTheme,
              layoutPreset: widget.preferences.value.layoutPreset,
              onLayoutPresetChanged: widget.preferences.setLayoutPreset,
              onSearch: widget.onSearch,
              onToggleImmersive: () => setState(() => _immersive = true),
              selectionMode: _selectionMode,
              onToggleSelection:
                  _selectionMode ? _exitSelection : () => _toggleSelection(),
            ),
          )),
        ),
      if (_immersive)
        Positioned(
            top: 8,
            right: 8,
            child: FloatingGlassSurface(
              borderRadius: 24,
              child: IconButton(
                tooltip: '退出沉浸式浏览',
                onPressed: () => setState(() => _immersive = false),
                icon: const Icon(Icons.fullscreen_exit_rounded),
              ),
            )),
      if (_selectionMode)
        Positioned(
          left: 16,
          right: 16,
          bottom: obstruction.bottom + 8,
          child: Center(
              child: FloatingGlassSurface(
            borderRadius: 28,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('已选 ${_selected.length} 项'),
              IconButton(
                tooltip: '加入分类',
                onPressed: _selected.isEmpty
                    ? null
                    : () async {
                        await widget.onAddToCollection(Set.of(_selected));
                        if (mounted) _exitSelection();
                      },
                icon: const Icon(Icons.playlist_add_rounded),
              ),
              IconButton(
                  tooltip: '退出选择',
                  onPressed: _exitSelection,
                  icon: const Icon(Icons.close)),
            ]),
          )),
        ),
    ]);
  }

  Widget _buildEntitySliver(BuildContext context) {
    final state = widget.browserState;
    if (!_immersive && state.displayMode == BrowserDisplayMode.list) {
      return BrowserListSliver(
        count: _items.length,
        style: state.listStyle,
        padding: widget.layoutSettings.pageMargin,
        itemBuilder: (context, index) {
          final entity = _items[index];
          return BrowserListTile(
            style: state.listStyle,
            title: entity.title,
            subtitle:
                '${entity.format.toUpperCase()} · ${_formatSize(entity.size)}',
            selected: _selected.contains(entity.id),
            onTap: () => _selectionMode
                ? _toggleSelection(entity.id)
                : widget.onOpenEntity(entity, _items),
            onLongPress: () => _toggleSelection(entity.id),
            previewBuilder: (_) => EntityArtwork(
              entityType: entity.entityType,
              format: entity.format,
              title: entity.title,
              contentExcerpt: entity.contentExcerpt,
              thumbnailStatus: entity.thumbnailStatus,
              thumbnailPath: entity.thumbnailPath,
              onThumbnailNeeded: () => widget.onThumbnailNeeded(entity),
            ),
          );
        },
      );
    }
    return SliverLayoutBuilder(builder: (context, constraints) {
      final layout = widget.layoutSettings;
      final portrait =
          MediaQuery.orientationOf(context) == Orientation.portrait;
      final columns = state.gridLayout == BrowserGridLayout.square
          ? layout.squareColumns(isPortrait: portrait)
          : layout.equalWidthColumns(isPortrait: portrait);
      final grid = CollectionGridLayout.calculate(
        availableWidth: constraints.crossAxisExtent,
        horizontalPadding: _immersive
            ? GalleryLayoutSettings.immersiveMargin
            : layout.pageMargin,
        gap: _immersive ? GalleryLayoutSettings.immersiveGap : layout.cardGap,
        columnCount: columns,
      );
      final gap =
          _immersive ? GalleryLayoutSettings.immersiveGap : layout.cardGap;
      return SliverPadding(
        padding: EdgeInsets.all(_immersive
            ? GalleryLayoutSettings.immersiveMargin
            : layout.pageMargin),
        sliver: SliverMasonryGrid.count(
          crossAxisCount: grid.columnCount,
          mainAxisSpacing: gap,
          crossAxisSpacing: gap,
          childCount: _items.length,
          itemBuilder: (context, index) {
            final entity = _items[index];
            return EntityCard(
              entity: entity,
              immersive: _immersive,
              selectionMode: _selectionMode,
              selected: _selected.contains(entity.id),
              onOpen: () => widget.onOpenEntity(entity, _items),
              onToggleSelection: () => _toggleSelection(entity.id),
              onStartSelection: () => _toggleSelection(entity.id),
              onThumbnailNeeded: () => widget.onThumbnailNeeded(entity),
              cardRadius: layout.cardRadius,
            );
          },
        ),
      );
    });
  }
}

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

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
