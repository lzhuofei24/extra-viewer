import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../core/domain/models.dart';
import '../modules/browser/thumbnail_warmup.dart';
import 'browser_state.dart';
import 'app_sidebar.dart';
import 'browser_toolbar.dart';
import 'collection_grid_layout.dart';
import 'design_tokens.dart';
import 'index_node_thumbnail.dart';
import 'gallery_layout_settings.dart';
import 'justified_entity_gallery.dart';
import 'library_widgets.dart';
import 'browser_list.dart';

class CollectionBrowserPage extends StatelessWidget {
  const CollectionBrowserPage({
    super.key,
    this.onSearchNodes,
    required this.currentNode,
    required this.nodePath,
    required this.childNodes,
    required this.nodeSummaries,
    required this.nodePreviews,
    required this.entities,
    required this.hasMoreEntities,
    required this.loadingMoreEntities,
    required this.browserState,
    required this.layoutSettings,
    required this.onOpenRootIndex,
    required this.onSortChanged,
    required this.onDisplayModeChanged,
    required this.onGridLayoutChanged,
    required this.onListStyleChanged,
    required this.immersiveBrowsing,
    required this.onToggleImmersiveBrowsing,
    required this.selectionMode,
    required this.onToggleSelectionMode,
    required this.onCloneCurrentNodeTree,
    required this.canUpdateDirectoryNode,
    required this.onUpdateDirectoryNode,
    required this.canDeleteCurrentNode,
    required this.onDeleteCurrentNode,
    required this.onOpenNode,
    required this.onPathNodeSelected,
    required this.onOpenEntity,
    required this.onShowEntityMenu,
    required this.onThumbnailNeeded,
    required this.onThumbnailEntityNeeded,
    required this.onLoadMoreEntities,
    required this.selectedEntityIds,
    required this.onToggleEntitySelection,
    required this.onStartEntitySelection,
    required this.onSelectEntitiesByDrag,
    required this.selectedNodeIds,
    required this.onToggleNodeSelection,
    required this.onStartNodeSelection,
    required this.onClearEntitySelection,
    required this.onSelectAllVisible,
    required this.onInvertVisibleSelection,
    required this.onSelectRange,
    required this.onAddToCollection,
    required this.onCreateCollection,
    required this.onRemoveFromCurrentNode,
    required this.canRemoveFromCurrentNode,
    required this.canManageCurrentCustomIndex,
    required this.onRebuildSelectedNodePreview,
    required this.onCustomizeSelectedNodePreview,
    required this.onClearSelectedNodePreviewOverride,
  });

  final IndexNode? currentNode;
  final VoidCallback? onSearchNodes;
  final List<IndexNode> nodePath;
  final List<IndexNode> childNodes;
  final Map<String, IndexNodeSummary> nodeSummaries;
  final Map<String, IndexNodePreview> nodePreviews;
  final List<EntityListItem> entities;
  final bool hasMoreEntities;
  final bool loadingMoreEntities;
  final BrowserState browserState;
  final VoidCallback onOpenRootIndex;
  final ValueChanged<EntitySortMode> onSortChanged;
  final ValueChanged<BrowserDisplayMode> onDisplayModeChanged;
  final ValueChanged<BrowserGridLayout> onGridLayoutChanged;
  final ValueChanged<BrowserListStyle> onListStyleChanged;
  final bool immersiveBrowsing;
  final VoidCallback onToggleImmersiveBrowsing;
  final bool selectionMode;
  final VoidCallback onToggleSelectionMode;
  final VoidCallback onCloneCurrentNodeTree;
  final bool canUpdateDirectoryNode;
  final VoidCallback onUpdateDirectoryNode;
  final bool canDeleteCurrentNode;
  final VoidCallback onDeleteCurrentNode;
  final ValueChanged<IndexNode> onOpenNode;
  final ValueChanged<IndexNode> onPathNodeSelected;
  final ValueChanged<EntityListItem> onOpenEntity;
  final ValueChanged<EntityListItem> onShowEntityMenu;
  final ValueChanged<EntityListItem> onThumbnailNeeded;
  final ValueChanged<String> onThumbnailEntityNeeded;
  final VoidCallback onLoadMoreEntities;
  final Set<String> selectedEntityIds;
  final ValueChanged<EntityListItem> onToggleEntitySelection;
  final ValueChanged<EntityListItem> onStartEntitySelection;
  final ValueChanged<Iterable<EntityListItem>> onSelectEntitiesByDrag;
  final Set<String> selectedNodeIds;
  final ValueChanged<IndexNode> onToggleNodeSelection;
  final ValueChanged<IndexNode> onStartNodeSelection;
  final GalleryLayoutSettings layoutSettings;
  final VoidCallback onClearEntitySelection;
  final VoidCallback onSelectAllVisible;
  final VoidCallback onInvertVisibleSelection;
  final VoidCallback onSelectRange;
  final VoidCallback onAddToCollection;
  final VoidCallback onCreateCollection;
  final VoidCallback onRemoveFromCurrentNode;
  final bool canRemoveFromCurrentNode;
  final bool canManageCurrentCustomIndex;
  final VoidCallback onRebuildSelectedNodePreview;
  final VoidCallback onCustomizeSelectedNodePreview;
  final VoidCallback onClearSelectedNodePreviewOverride;

  @override
  Widget build(BuildContext context) {
    final visibleNodes = currentNode == null
        ? childNodes
            .where((node) => _rootTabMatchesNode(browserState.rootTab, node))
            .toList(growable: false)
        : childNodes;
    final hasNodes = visibleNodes.isNotEmpty && !immersiveBrowsing;
    final hasEntities = entities.isNotEmpty;
    final listMode = !immersiveBrowsing &&
        browserState.displayMode == BrowserDisplayMode.list;
    final obstruction = AppNavigationObstruction.of(context);
    final topChromeInset =
        MediaQuery.sizeOf(context).width < 600 ? 116.0 : 76.0;
    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              Expanded(
                child: _BrowserScrollShell(
                  key: ValueKey(
                      '${browserState.rootTab.name}:${currentNode?.id ?? "home"}:$immersiveBrowsing'),
                  warmupEnabled: !listMode ||
                      browserState.listStyle != BrowserListStyle.text,
                  preloadScopeKey:
                      '${currentNode?.id ?? ''}:${immersiveBrowsing ? 'recursive' : 'direct'}',
                  entities: entities,
                  hasMore: hasMoreEntities,
                  onLoadMore: onLoadMoreEntities,
                  selectionMode: selectionMode,
                  onSelectEntitiesByDrag: onSelectEntitiesByDrag,
                  child: (controller, selectionRegistry) => CustomScrollView(
                    key: PageStorageKey(
                        '${browserState.rootTab.name}:${currentNode?.id ?? "home"}:$immersiveBrowsing'),
                    controller: controller,
                    scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                    slivers: [
                      if (!immersiveBrowsing)
                        SliverToBoxAdapter(
                          child: SizedBox(height: topChromeInset),
                        ),
                      if (hasNodes && currentNode == null)
                        (listMode
                            ? _NodeListSliver(
                                style: browserState.listStyle,
                                previews: nodePreviews,
                                nodes: visibleNodes,
                                summaries: nodeSummaries,
                                onOpenNode: onOpenNode,
                                selectedNodeIds: selectedNodeIds,
                                selectionMode: selectionMode,
                                onToggleNodeSelection: onToggleNodeSelection,
                                onStartNodeSelection: onStartNodeSelection,
                                horizontalPadding: layoutSettings.pageMargin,
                              )
                            : _NodeGridSliver(
                                nodes: visibleNodes,
                                summaries: nodeSummaries,
                                previews: nodePreviews,
                                onOpenNode: onOpenNode,
                                onThumbnailEntityNeeded:
                                    onThumbnailEntityNeeded,
                                selectedNodeIds: selectedNodeIds,
                                selectionMode: selectionMode,
                                onToggleNodeSelection: onToggleNodeSelection,
                                onStartNodeSelection: onStartNodeSelection,
                                layoutSettings: layoutSettings,
                              )),
                      if (hasNodes && currentNode != null)
                        listMode
                            ? _NodeListSliver(
                                style: browserState.listStyle,
                                previews: nodePreviews,
                                nodes: childNodes,
                                summaries: nodeSummaries,
                                onOpenNode: onOpenNode,
                                selectedNodeIds: selectedNodeIds,
                                selectionMode: selectionMode,
                                onToggleNodeSelection: onToggleNodeSelection,
                                onStartNodeSelection: onStartNodeSelection,
                                horizontalPadding: layoutSettings.pageMargin,
                              )
                            : _NodeGridSliver(
                                nodes: childNodes,
                                summaries: nodeSummaries,
                                previews: nodePreviews,
                                onOpenNode: onOpenNode,
                                onThumbnailEntityNeeded:
                                    onThumbnailEntityNeeded,
                                selectedNodeIds: selectedNodeIds,
                                selectionMode: selectionMode,
                                onToggleNodeSelection: onToggleNodeSelection,
                                onStartNodeSelection: onStartNodeSelection,
                                layoutSettings: layoutSettings,
                              ),
                      if (!hasNodes && !hasEntities)
                        SliverPadding(
                          padding: const EdgeInsets.all(20),
                          sliver: SliverToBoxAdapter(
                            child: EmptyStateCard(
                              title: immersiveBrowsing
                                  ? '沉浸式浏览为空'
                                  : currentNode == null
                                      ? '${browserState.rootTab.label}中暂无内容'
                                      : '当前分组为空',
                              message: immersiveBrowsing
                                  ? '当前分组及其下级分组中没有可展示的文件。'
                                  : '可从“管理”页面重新检查，或返回首页继续浏览。',
                            ),
                          ),
                        ),
                      if (hasNodes && hasEntities)
                        SliverPadding(
                          padding: EdgeInsets.symmetric(
                              horizontal: layoutSettings.pageMargin),
                          sliver: SliverToBoxAdapter(
                            child: Divider(
                                height: 1,
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant),
                          ),
                        ),
                      if (hasEntities)
                        immersiveBrowsing ||
                                browserState.displayMode ==
                                    BrowserDisplayMode.grid
                            ? switch (browserState.gridLayout) {
                                BrowserGridLayout.equalHeight =>
                                  _EntityGridSliver(
                                    entities: entities,
                                    immersive: immersiveBrowsing,
                                    selectedEntityIds: selectedEntityIds,
                                    selectionMode: selectionMode,
                                    selectionRegistry: selectionRegistry,
                                    onOpenEntity: onOpenEntity,
                                    onShowEntityMenu: onShowEntityMenu,
                                    onThumbnailNeeded: onThumbnailNeeded,
                                    onToggleEntitySelection:
                                        onToggleEntitySelection,
                                    onStartEntitySelection:
                                        onStartEntitySelection,
                                    layoutSettings: layoutSettings,
                                  ),
                                BrowserGridLayout.equalWidth =>
                                  _EntityMasonryGridSliver(
                                    entities: entities,
                                    immersive: immersiveBrowsing,
                                    selectedEntityIds: selectedEntityIds,
                                    selectionMode: selectionMode,
                                    selectionRegistry: selectionRegistry,
                                    onOpenEntity: onOpenEntity,
                                    onShowEntityMenu: onShowEntityMenu,
                                    onThumbnailNeeded: onThumbnailNeeded,
                                    onToggleEntitySelection:
                                        onToggleEntitySelection,
                                    onStartEntitySelection:
                                        onStartEntitySelection,
                                    layoutSettings: layoutSettings,
                                  ),
                                BrowserGridLayout.square =>
                                  _SquareEntityGridSliver(
                                      entities: entities,
                                      immersive: immersiveBrowsing,
                                      selectionMode: selectionMode,
                                      selectionRegistry: selectionRegistry,
                                      onOpenEntity: onOpenEntity,
                                      onShowEntityMenu: onShowEntityMenu,
                                      onThumbnailNeeded: onThumbnailNeeded,
                                      selectedEntityIds: selectedEntityIds,
                                      onToggleEntitySelection:
                                          onToggleEntitySelection,
                                      onStartEntitySelection:
                                          onStartEntitySelection,
                                      layoutSettings: layoutSettings),
                              }
                            : _EntityListSliver(
                                style: browserState.listStyle,
                                entities: entities,
                                selectedEntityIds: selectedEntityIds,
                                selectionMode: selectionMode,
                                onOpenEntity: onOpenEntity,
                                onShowEntityMenu: onShowEntityMenu,
                                onThumbnailNeeded: onThumbnailNeeded,
                                onToggleEntitySelection:
                                    onToggleEntitySelection,
                                onStartEntitySelection: onStartEntitySelection,
                                horizontalPadding: layoutSettings.pageMargin,
                              ),
                      if (hasMoreEntities)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 20),
                            child: Center(
                              child: loadingMoreEntities
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : TextButton(
                                      onPressed: onLoadMoreEntities,
                                      child: const Text('加载更多'),
                                    ),
                            ),
                          ),
                        ),
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: 28 +
                              obstruction.bottom +
                              (selectionMode ? 80 : 0),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (!immersiveBrowsing)
          Positioned(
            top: 4,
            left: 8,
            right: 8,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: _PathBar(
                  onSearchNodes: onSearchNodes,
                  currentNode: currentNode,
                  path: nodePath,
                  onOpenRootIndex: onOpenRootIndex,
                  onPathNodeSelected: onPathNodeSelected,
                  browserState: browserState,
                  onSortChanged: onSortChanged,
                  onDisplayModeChanged: onDisplayModeChanged,
                  onGridLayoutChanged: onGridLayoutChanged,
                  onListStyleChanged: onListStyleChanged,
                  immersiveBrowsing: immersiveBrowsing,
                  onToggleImmersiveBrowsing: onToggleImmersiveBrowsing,
                  selectionMode: selectionMode,
                  onToggleSelectionMode: onToggleSelectionMode,
                  onCloneCurrentNodeTree: onCloneCurrentNodeTree,
                  canUpdateDirectoryNode: canUpdateDirectoryNode,
                  onUpdateDirectoryNode: onUpdateDirectoryNode,
                  canDeleteCurrentNode: canDeleteCurrentNode,
                  onDeleteCurrentNode: onDeleteCurrentNode,
                  canCreateNode: canManageCurrentCustomIndex,
                  onCreateNode: onCreateCollection,
                ),
              ),
            ),
          ),
        if (immersiveBrowsing)
          Positioned(
            top: 8,
            right: 8,
            child: FloatingGlassSurface(
              borderRadius: 24,
              child: Material(
                color: Colors.transparent,
                child: IconButton(
                  tooltip: '退出沉浸式浏览',
                  onPressed: onToggleImmersiveBrowsing,
                  icon: const Icon(Icons.fullscreen_exit_rounded),
                ),
              ),
            ),
          ),
        if (selectionMode)
          Positioned(
            left: obstruction.left + 12,
            right: 12,
            bottom: obstruction.bottom + 8,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: FloatingGlassSurface(
                  borderRadius: 28,
                  child: _SelectionActionBar(
                    managementActions: [
                      if (canUpdateDirectoryNode)
                        BrowserToolbarAction(
                          label: '更新当前文件夹',
                          icon: Icons.refresh_rounded,
                          onPressed: onUpdateDirectoryNode,
                        ),
                      if (currentNode != null)
                        BrowserToolbarAction(
                          label: '复制结构到分类',
                          icon: Icons.account_tree_outlined,
                          onPressed: onCloneCurrentNodeTree,
                        ),
                      if (canManageCurrentCustomIndex)
                        BrowserToolbarAction(
                          label: '新建分类',
                          icon: Icons.create_new_folder_outlined,
                          onPressed: onCreateCollection,
                        ),
                      if (canDeleteCurrentNode)
                        BrowserToolbarAction(
                          label: '删除当前分类',
                          icon: Icons.delete_outline_rounded,
                          onPressed: onDeleteCurrentNode,
                        ),
                    ],
                    entityCount: selectedEntityIds.length,
                    nodeCount: selectedNodeIds.length,
                    onExit: onToggleSelectionMode,
                    onSelectAll: onSelectAllVisible,
                    onInvert: onInvertVisibleSelection,
                    onSelectRange: onSelectRange,
                    onAddToCollection: onAddToCollection,
                    canRemoveFromCurrentNode: canRemoveFromCurrentNode,
                    onRemoveFromCurrentNode: onRemoveFromCurrentNode,
                    onRebuildSelectedNodePreview: onRebuildSelectedNodePreview,
                    onCustomizeSelectedNodePreview:
                        onCustomizeSelectedNodePreview,
                    onClearSelectedNodePreviewOverride:
                        onClearSelectedNodePreviewOverride,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _BrowserScrollShell extends StatefulWidget {
  const _BrowserScrollShell({
    super.key,
    required this.warmupEnabled,
    required this.preloadScopeKey,
    required this.entities,
    required this.hasMore,
    required this.onLoadMore,
    required this.selectionMode,
    required this.onSelectEntitiesByDrag,
    required this.child,
  });

  final String preloadScopeKey;
  final bool warmupEnabled;
  final List<EntityListItem> entities;
  final bool hasMore;
  final VoidCallback onLoadMore;
  final bool selectionMode;
  final ValueChanged<Iterable<EntityListItem>> onSelectEntitiesByDrag;
  final Widget Function(
    ScrollController controller,
    _EntitySelectionRegistry selectionRegistry,
  ) child;

  @override
  State<_BrowserScrollShell> createState() => _BrowserScrollShellState();
}

class _BrowserScrollShellState extends State<_BrowserScrollShell> {
  final ScrollController _scrollController = ScrollController();
  final Map<String, int> _warmPaths = {};
  Map<String, int> _entityPositions = {};
  Timer? _warmTimer;
  bool _warmRunning = false;
  String _activePreloadScope = '';
  int _thumbnailPreloadGeneration = 0;
  final _EntitySelectionRegistry _selectionRegistry =
      _EntitySelectionRegistry();
  final Map<int, Map<String, EntityListItem>> _dragEntitiesByPointer =
      <int, Map<String, EntityListItem>>{};
  final Set<int> _activeDragPointers = <int>{};

  @override
  void initState() {
    super.initState();
    _activePreloadScope = widget.preloadScopeKey;
    _indexEntities();
    _scrollController.addListener(_handleScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleWarmup());
  }

  @override
  void didUpdateWidget(covariant _BrowserScrollShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.entities, oldWidget.entities)) _indexEntities();
    if (widget.preloadScopeKey == _activePreloadScope) {
      _scheduleWarmup();
      return;
    }
    _activePreloadScope = widget.preloadScopeKey;
    _thumbnailPreloadGeneration++;
    _clearWarmup();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleWarmup());
  }

  @override
  void dispose() {
    _thumbnailPreloadGeneration++;
    _warmTimer?.cancel();
    _clearWarmup();
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _handleScroll() {
    _scheduleWarmup();
    if (!_scrollController.hasClients) return;
    if (widget.hasMore && _scrollController.position.extentAfter < 640) {
      widget.onLoadMore();
    }
  }

  void _beginPointerSelection(PointerDownEvent event) {
    if (!widget.selectionMode) return;
    final entity = _selectionRegistry.entityAt(event.position);
    if (entity == null) return;
    _dragEntitiesByPointer[event.pointer] = {entity.id: entity};
  }

  void _extendPointerSelection(PointerMoveEvent event) {
    if (!widget.selectionMode) return;
    final dragged = _dragEntitiesByPointer[event.pointer];
    if (dragged == null) return;
    final entity = _selectionRegistry.entityAt(event.position);
    if (entity == null) return;
    if (_activeDragPointers.add(event.pointer)) {
      dragged[entity.id] = entity;
      widget.onSelectEntitiesByDrag(dragged.values);
      return;
    }
    if (dragged.containsKey(entity.id)) return;
    dragged[entity.id] = entity;
    widget.onSelectEntitiesByDrag([entity]);
  }

  void _indexEntities() {
    _entityPositions = {
      for (var i = 0; i < widget.entities.length; i++) widget.entities[i].id: i,
    };
  }

  void _clearWarmup() {
    for (final path in _warmPaths.keys) {
      PaintingBinding.instance.imageCache.evict(FileImage(File(path)));
    }
    _warmPaths.clear();
  }

  void _scheduleWarmup() {
    if (!mounted) return;
    _thumbnailPreloadGeneration++;
    _warmTimer?.cancel();
    _warmTimer = Timer(const Duration(milliseconds: 150), () {
      unawaited(_warmVisibleNeighbors(_thumbnailPreloadGeneration));
    });
  }

  Future<void> _warmVisibleNeighbors(int generation) async {
    if (!widget.warmupEnabled) return;
    if (_warmRunning) return;
    _warmRunning = true;
    try {
      await _performWarmup(generation);
    } finally {
      _warmRunning = false;
      if (mounted && generation != _thumbnailPreloadGeneration) {
        _scheduleWarmup();
      }
    }
  }

  Future<void> _performWarmup(int generation) async {
    if (!mounted || generation != _thumbnailPreloadGeneration) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    final viewport = box.localToGlobal(Offset.zero) & box.size;
    final visible = _selectionRegistry.entitiesIn(viewport).toList();
    final positions = visible
        .map((e) => _entityPositions[e.id])
        .whereType<int>()
        .toList()
      ..sort();
    final visiblePaths = visible.map((e) => e.thumbnailPath).toSet();
    // Once displayed, an image belongs to the normal LRU cache, not preheating.
    _warmPaths.removeWhere((path, _) => visiblePaths.contains(path));
    final candidates = positions.isEmpty
        ? const <EntityListItem>[]
        : thumbnailWarmupWindow(widget.entities,
            firstVisible: positions.first,
            lastVisible: positions.last,
            cacheBytes: PaintingBinding.instance.imageCache.maximumSizeBytes);
    final nextPaths = candidates.map((e) => e.thumbnailPath).toSet();
    for (final path in _warmPaths.keys.toList()) {
      if (!nextPaths.contains(path)) {
        PaintingBinding.instance.imageCache.evict(FileImage(File(path)));
        _warmPaths.remove(path);
      }
    }
    for (final entity in candidates) {
      if (!mounted || generation != _thumbnailPreloadGeneration) return;
      final path = entity.thumbnailPath!;
      if (_warmPaths.containsKey(path)) continue;
      final provider = FileImage(File(path));
      final status = PaintingBinding.instance.imageCache.statusForKey(provider);
      if (status.keepAlive || status.live || status.pending) continue;
      _warmPaths[path] = thumbnailDecodedBytes(entity);
      await precacheImage(provider, context, onError: (_, __) {});
      if (!mounted || generation != _thumbnailPreloadGeneration) {
        PaintingBinding.instance.imageCache.evict(provider);
        _warmPaths.remove(path);
        return;
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _beginPointerSelection,
        onPointerMove: _extendPointerSelection,
        onPointerUp: (event) {
          _dragEntitiesByPointer.remove(event.pointer);
          _activeDragPointers.remove(event.pointer);
        },
        onPointerCancel: (event) {
          _dragEntitiesByPointer.remove(event.pointer);
          _activeDragPointers.remove(event.pointer);
        },
        child: widget.child(_scrollController, _selectionRegistry),
      );
}

class _EntitySelectionRegistry {
  final Map<String, GlobalKey> _keys = <String, GlobalKey>{};
  final Map<String, EntityListItem> _entities = <String, EntityListItem>{};

  GlobalKey keyFor(EntityListItem entity) {
    _entities[entity.id] = entity;
    return _keys.putIfAbsent(entity.id, GlobalKey.new);
  }

  Iterable<EntityListItem> entitiesIn(Rect viewport) sync* {
    for (final id in _keys.keys.toList()) {
      final context = _keys[id]!.currentContext;
      if (context == null) {
        _keys.remove(id);
        _entities.remove(id);
        continue;
      }
      final box = context.findRenderObject();
      if (box is RenderBox &&
          box.attached &&
          viewport.overlaps(box.localToGlobal(Offset.zero) & box.size)) {
        yield _entities[id]!;
      }
    }
  }

  EntityListItem? entityAt(Offset globalPosition) {
    for (final entry in _keys.entries) {
      final renderObject = entry.value.currentContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.attached) continue;
      final origin = renderObject.localToGlobal(Offset.zero);
      if ((origin & renderObject.size).contains(globalPosition)) {
        return _entities[entry.key];
      }
    }
    return null;
  }
}

class _PathBar extends StatelessWidget {
  const _PathBar({
    this.onSearchNodes,
    required this.currentNode,
    required this.path,
    required this.onOpenRootIndex,
    required this.onPathNodeSelected,
    required this.browserState,
    required this.onSortChanged,
    required this.onDisplayModeChanged,
    required this.onGridLayoutChanged,
    required this.onListStyleChanged,
    required this.immersiveBrowsing,
    required this.onToggleImmersiveBrowsing,
    required this.selectionMode,
    required this.onToggleSelectionMode,
    required this.onCloneCurrentNodeTree,
    required this.canUpdateDirectoryNode,
    required this.onUpdateDirectoryNode,
    required this.canDeleteCurrentNode,
    required this.onDeleteCurrentNode,
    required this.canCreateNode,
    required this.onCreateNode,
  });

  final IndexNode? currentNode;
  final List<IndexNode> path;
  final VoidCallback? onSearchNodes;
  final VoidCallback onOpenRootIndex;
  final ValueChanged<IndexNode> onPathNodeSelected;
  final BrowserState browserState;
  final ValueChanged<EntitySortMode> onSortChanged;
  final ValueChanged<BrowserDisplayMode> onDisplayModeChanged;
  final ValueChanged<BrowserGridLayout> onGridLayoutChanged;
  final ValueChanged<BrowserListStyle> onListStyleChanged;
  final bool immersiveBrowsing;
  final VoidCallback onToggleImmersiveBrowsing;
  final bool selectionMode;
  final VoidCallback onToggleSelectionMode;
  final VoidCallback onCloneCurrentNodeTree;
  final bool canUpdateDirectoryNode;
  final VoidCallback onUpdateDirectoryNode;
  final bool canDeleteCurrentNode;
  final VoidCallback onDeleteCurrentNode;
  final bool canCreateNode;
  final VoidCallback onCreateNode;

  @override
  Widget build(BuildContext context) {
    return BrowserToolbar(
      leading: _IndexPathRail(
        currentNode: currentNode,
        path: path,
        onOpenRootIndex: onOpenRootIndex,
        onPathNodeSelected: onPathNodeSelected,
      ),
      browserState: browserState,
      onSortChanged: onSortChanged,
      onDisplayModeChanged: onDisplayModeChanged,
      onGridLayoutChanged: onGridLayoutChanged,
      onListStyleChanged: onListStyleChanged,
      onSearch: onSearchNodes,
      immersive: immersiveBrowsing,
      onToggleImmersive: onToggleImmersiveBrowsing,
      selectionMode: selectionMode,
      onToggleSelection: onToggleSelectionMode,
    );
  }
}

class _EntityGridSliver extends StatelessWidget {
  const _EntityGridSliver({
    required this.entities,
    required this.immersive,
    required this.selectionMode,
    required this.selectionRegistry,
    required this.onOpenEntity,
    required this.onShowEntityMenu,
    required this.onThumbnailNeeded,
    required this.selectedEntityIds,
    required this.onToggleEntitySelection,
    required this.onStartEntitySelection,
    required this.layoutSettings,
  });

  final List<EntityListItem> entities;
  final bool immersive;
  final bool selectionMode;
  final _EntitySelectionRegistry selectionRegistry;
  final ValueChanged<EntityListItem> onOpenEntity;
  final ValueChanged<EntityListItem> onShowEntityMenu;
  final ValueChanged<EntityListItem> onThumbnailNeeded;
  final Set<String> selectedEntityIds;
  final ValueChanged<EntityListItem> onToggleEntitySelection;
  final ValueChanged<EntityListItem> onStartEntitySelection;
  final GalleryLayoutSettings layoutSettings;

  @override
  Widget build(BuildContext context) {
    return JustifiedEntityGallerySliver(
      entities: entities,
      immersive: immersive,
      selectionMode: selectionMode,
      keyFor: selectionRegistry.keyFor,
      onOpenEntity: onOpenEntity,
      onShowEntityMenu: onShowEntityMenu,
      onThumbnailNeeded: onThumbnailNeeded,
      selectedEntityIds: selectedEntityIds,
      layoutSettings: layoutSettings,
      onToggleEntitySelection: onToggleEntitySelection,
      onStartEntitySelection: onStartEntitySelection,
    );
  }
}

class _EntityMasonryGridSliver extends StatelessWidget {
  const _EntityMasonryGridSliver({
    required this.entities,
    required this.immersive,
    required this.selectionMode,
    required this.selectionRegistry,
    required this.onOpenEntity,
    required this.onShowEntityMenu,
    required this.onThumbnailNeeded,
    required this.selectedEntityIds,
    required this.onToggleEntitySelection,
    required this.onStartEntitySelection,
    required this.layoutSettings,
  });

  final List<EntityListItem> entities;
  final bool immersive;
  final bool selectionMode;
  final _EntitySelectionRegistry selectionRegistry;
  final ValueChanged<EntityListItem> onOpenEntity;
  final ValueChanged<EntityListItem> onShowEntityMenu;
  final ValueChanged<EntityListItem> onThumbnailNeeded;
  final Set<String> selectedEntityIds;
  final ValueChanged<EntityListItem> onToggleEntitySelection;
  final ValueChanged<EntityListItem> onStartEntitySelection;
  final GalleryLayoutSettings layoutSettings;

  @override
  Widget build(BuildContext context) {
    final gap =
        immersive ? GalleryLayoutSettings.immersiveGap : layoutSettings.cardGap;
    final margin = immersive
        ? GalleryLayoutSettings.immersiveMargin
        : layoutSettings.pageMargin;
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final layout = CollectionGridLayout.calculate(
          availableWidth: constraints.crossAxisExtent,
          horizontalPadding: margin,
          gap: gap,
          columnCount: layoutSettings.equalWidthColumns(
            isPortrait:
                MediaQuery.orientationOf(context) == Orientation.portrait,
          ),
        );
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(
            margin,
            immersive ? GalleryLayoutSettings.immersiveMargin : margin,
            margin,
            0,
          ),
          sliver: SliverMasonryGrid.count(
            crossAxisCount: layout.columnCount,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
            childCount: entities.length,
            itemBuilder: (context, index) => EntityCard(
              key: selectionRegistry.keyFor(entities[index]),
              entity: entities[index],
              onOpen: () => onOpenEntity(entities[index]),
              selected: selectedEntityIds.contains(entities[index].id),
              immersive: immersive,
              cardRadius: layoutSettings.cardRadius,
              selectionMode: selectionMode,
              onToggleSelection: () => onToggleEntitySelection(entities[index]),
              onShowMenu: () => onShowEntityMenu(entities[index]),
              onThumbnailNeeded: () => onThumbnailNeeded(entities[index]),
              onStartSelection: () => onStartEntitySelection(entities[index]),
            ),
          ),
        );
      },
    );
  }
}

class _SquareEntityGridSliver extends StatelessWidget {
  const _SquareEntityGridSliver(
      {required this.entities,
      required this.immersive,
      required this.selectionMode,
      required this.selectionRegistry,
      required this.onOpenEntity,
      required this.onShowEntityMenu,
      required this.onThumbnailNeeded,
      required this.selectedEntityIds,
      required this.onToggleEntitySelection,
      required this.onStartEntitySelection,
      required this.layoutSettings});
  final List<EntityListItem> entities;
  final bool immersive;
  final bool selectionMode;
  final _EntitySelectionRegistry selectionRegistry;
  final ValueChanged<EntityListItem> onOpenEntity;
  final ValueChanged<EntityListItem> onShowEntityMenu;
  final ValueChanged<EntityListItem> onThumbnailNeeded;
  final Set<String> selectedEntityIds;
  final ValueChanged<EntityListItem> onToggleEntitySelection;
  final ValueChanged<EntityListItem> onStartEntitySelection;
  final GalleryLayoutSettings layoutSettings;
  @override
  Widget build(BuildContext context) =>
      SliverLayoutBuilder(builder: (context, constraints) {
        final gap = immersive
            ? GalleryLayoutSettings.immersiveGap
            : layoutSettings.cardGap;
        final margin = immersive
            ? GalleryLayoutSettings.immersiveMargin
            : layoutSettings.pageMargin;
        final layout = CollectionGridLayout.calculate(
            availableWidth: constraints.crossAxisExtent,
            horizontalPadding: margin,
            gap: gap,
            columnCount: layoutSettings.squareColumns(
                isPortrait:
                    MediaQuery.orientationOf(context) == Orientation.portrait));
        return SliverPadding(
            padding: EdgeInsets.fromLTRB(margin, margin, margin, 0),
            sliver: SliverGrid(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final entity = entities[index];
                  return EntityCard(
                      key: selectionRegistry.keyFor(entity),
                      entity: entity,
                      onOpen: () => onOpenEntity(entity),
                      selected: selectedEntityIds.contains(entity.id),
                      immersive: immersive,
                      cardRadius: layoutSettings.cardRadius,
                      selectionMode: selectionMode,
                      onToggleSelection: () => onToggleEntitySelection(entity),
                      onShowMenu: () => onShowEntityMenu(entity),
                      onThumbnailNeeded: () => onThumbnailNeeded(entity),
                      onStartSelection: () => onStartEntitySelection(entity));
                }, childCount: entities.length),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: layout.columnCount,
                    mainAxisSpacing: gap,
                    crossAxisSpacing: gap,
                    childAspectRatio: 1)));
      });
}

class _EntityListSliver extends StatelessWidget {
  const _EntityListSliver(
      {required this.entities,
      required this.style,
      required this.selectionMode,
      required this.onOpenEntity,
      required this.onShowEntityMenu,
      required this.onThumbnailNeeded,
      required this.selectedEntityIds,
      required this.onToggleEntitySelection,
      required this.onStartEntitySelection,
      required this.horizontalPadding});
  final List<EntityListItem> entities;
  final BrowserListStyle style;
  final bool selectionMode;
  final ValueChanged<EntityListItem> onOpenEntity,
      onShowEntityMenu,
      onThumbnailNeeded,
      onToggleEntitySelection,
      onStartEntitySelection;
  final Set<String> selectedEntityIds;
  final double horizontalPadding;
  @override
  Widget build(BuildContext context) => BrowserListSliver(
      count: entities.length,
      style: style,
      padding: horizontalPadding,
      itemBuilder: (context, index) {
        final entity = entities[index];
        return BrowserListTile(
            style: style,
            title: entity.title,
            subtitle:
                '${entity.format.toUpperCase()} · ${formatTime(entity.modifiedAtMs)}',
            selected: selectedEntityIds.contains(entity.id),
            onTap: () => selectionMode
                ? onToggleEntitySelection(entity)
                : onOpenEntity(entity),
            onLongPress: () => onStartEntitySelection(entity),
            onSecondaryTap: () => onShowEntityMenu(entity),
            previewBuilder: (_) => EntityArtwork(
                entityType: entity.entityType,
                format: entity.format,
                title: entity.title,
                contentExcerpt: entity.contentExcerpt,
                thumbnailPath: entity.thumbnailPath,
                onThumbnailNeeded: () => onThumbnailNeeded(entity)));
      });
}

class _SelectionActionBar extends StatelessWidget {
  const _SelectionActionBar({
    required this.managementActions,
    required this.entityCount,
    required this.nodeCount,
    required this.onExit,
    required this.onSelectAll,
    required this.onInvert,
    required this.onSelectRange,
    required this.onAddToCollection,
    required this.canRemoveFromCurrentNode,
    required this.onRemoveFromCurrentNode,
    required this.onRebuildSelectedNodePreview,
    required this.onCustomizeSelectedNodePreview,
    required this.onClearSelectedNodePreviewOverride,
  });

  final List<BrowserToolbarAction> managementActions;
  final int entityCount;
  final int nodeCount;
  final VoidCallback onExit;
  final VoidCallback onSelectAll;
  final VoidCallback onInvert;
  final VoidCallback onSelectRange;
  final VoidCallback onAddToCollection;
  final bool canRemoveFromCurrentNode;
  final VoidCallback onRemoveFromCurrentNode;
  final VoidCallback onRebuildSelectedNodePreview;
  final VoidCallback onCustomizeSelectedNodePreview;
  final VoidCallback onClearSelectedNodePreviewOverride;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final management = MenuAnchor(
              menuChildren: [
                for (final action in managementActions)
                  MenuItemButton(
                      onPressed: action.onPressed, child: Text(action.label))
              ],
              builder: (context, controller, _) => TextButton(
                  onPressed: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                  child: const Text('管理')),
            );
            final hasSelection = entityCount > 0 || nodeCount > 0;
            final previewOnly = entityCount == 0 && nodeCount == 1;
            final count = Text('已选 $entityCount 个文件 | $nodeCount 个分组');
            final add = OutlinedButton(
              onPressed: hasSelection ? onAddToCollection : null,
              child: const Text('加入分类'),
            );
            final remove = canRemoveFromCurrentNode
                ? OutlinedButton(
                    onPressed: hasSelection ? onRemoveFromCurrentNode : null,
                    child: Text(
                      nodeCount > 0 && entityCount == 0 ? '删除分组' : '删除',
                    ),
                  )
                : null;
            if (constraints.maxWidth < 700) {
              return Row(
                children: [
                  Expanded(child: count),
                  TextButton(onPressed: onExit, child: const Text('退出')),
                  MenuAnchor(
                    menuChildren: [
                      MenuItemButton(
                          onPressed: onSelectAll, child: const Text('全选')),
                      MenuItemButton(
                          onPressed: onInvert, child: const Text('反选')),
                      MenuItemButton(
                        onPressed: onSelectRange,
                        child: const Text('区间选择'),
                      ),
                      if (previewOnly) ...[
                        MenuItemButton(
                          onPressed: onRebuildSelectedNodePreview,
                          child: const Text('重新生成预览'),
                        ),
                        MenuItemButton(
                          onPressed: onCustomizeSelectedNodePreview,
                          child: const Text('自定义生成预览'),
                        ),
                        MenuItemButton(
                          onPressed: onClearSelectedNodePreviewOverride,
                          child: const Text('恢复自动预览'),
                        ),
                      ],
                    ],
                    builder: (context, controller, child) => TextButton(
                      onPressed: () => controller.isOpen
                          ? controller.close()
                          : controller.open(),
                      child: const Text('更多'),
                    ),
                  ),
                  if (managementActions.isNotEmpty) management,
                  add,
                  if (remove != null) remove,
                ],
              );
            }
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                count,
                if (managementActions.isNotEmpty) management,
                TextButton(onPressed: onExit, child: const Text('退出')),
                TextButton(onPressed: onSelectAll, child: const Text('全选')),
                TextButton(onPressed: onInvert, child: const Text('反选')),
                TextButton(
                  onPressed: onSelectRange,
                  child: const Text('区间选择'),
                ),
                if (previewOnly)
                  MenuAnchor(
                    menuChildren: [
                      MenuItemButton(
                        onPressed: onRebuildSelectedNodePreview,
                        child: const Text('重新生成预览'),
                      ),
                      MenuItemButton(
                        onPressed: onCustomizeSelectedNodePreview,
                        child: const Text('自定义生成预览'),
                      ),
                      MenuItemButton(
                        onPressed: onClearSelectedNodePreviewOverride,
                        child: const Text('恢复自动预览'),
                      ),
                    ],
                    builder: (context, controller, child) => TextButton(
                      onPressed: () => controller.isOpen
                          ? controller.close()
                          : controller.open(),
                      child: const Text('预览'),
                    ),
                  ),
                add,
                if (remove != null) remove,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _IndexPathRail extends StatelessWidget {
  const _IndexPathRail({
    required this.currentNode,
    required this.path,
    required this.onOpenRootIndex,
    required this.onPathNodeSelected,
  });

  final IndexNode? currentNode;
  final List<IndexNode> path;
  final VoidCallback onOpenRootIndex;
  final ValueChanged<IndexNode> onPathNodeSelected;

  @override
  Widget build(BuildContext context) {
    final visiblePath = <IndexNode>[];
    final seen = <String>{};
    for (final node in path) {
      if (seen.add(node.id)) visiblePath.add(node);
    }
    return _HorizontalNodeRail(
      children: [
        _NodeRailEntry(
          label: '首页',
          selected: currentNode == null,
          onTap: onOpenRootIndex,
        ),
        for (final node in visiblePath)
          _NodeRailEntry(
            label: node.name,
            selected: node.id == currentNode?.id,
            onTap: () => onPathNodeSelected(node),
          ),
      ],
    );
  }
}

bool _rootTabMatchesNode(BrowserRootTab tab, IndexNode node) {
  return switch (tab) {
    BrowserRootTab.directory => node.nodeType == NodeType.directoryIndexRoot,
    BrowserRootTab.tree => node.nodeType == NodeType.customIndexRoot,
  };
}

class _NodeListSliver extends StatelessWidget {
  const _NodeListSliver(
      {required this.nodes,
      required this.summaries,
      required this.previews,
      required this.style,
      required this.onOpenNode,
      required this.selectedNodeIds,
      required this.selectionMode,
      required this.onToggleNodeSelection,
      required this.onStartNodeSelection,
      required this.horizontalPadding});
  final List<IndexNode> nodes;
  final Map<String, IndexNodeSummary> summaries;
  final Map<String, IndexNodePreview> previews;
  final BrowserListStyle style;
  final ValueChanged<IndexNode> onOpenNode,
      onToggleNodeSelection,
      onStartNodeSelection;
  final Set<String> selectedNodeIds;
  final bool selectionMode;
  final double horizontalPadding;
  @override
  Widget build(BuildContext context) => BrowserListSliver(
      count: nodes.length,
      style: style,
      padding: horizontalPadding,
      itemBuilder: (context, index) {
        final node = nodes[index];
        final summary = summaries[node.id];
        return BrowserListTile(
            style: style,
            title: node.name,
            subtitle:
                '${summary?.childNodeCount ?? 0} 个分组 · ${summary?.directEntityCount ?? 0} 个文件',
            icon: Icons.folder_outlined,
            selected: selectedNodeIds.contains(node.id),
            onTap: () =>
                selectionMode ? onToggleNodeSelection(node) : onOpenNode(node),
            onLongPress: () => onStartNodeSelection(node),
            previewBuilder: (_) => IndexNodeThumbnail(
                preview: previews[node.id],
                nodeName: node.name,
                hasContent: true,
                portrait: true,
                borderRadius: 6));
      });
}

class _NodeGridSliver extends StatelessWidget {
  const _NodeGridSliver({
    required this.nodes,
    required this.summaries,
    required this.previews,
    required this.onOpenNode,
    required this.onThumbnailEntityNeeded,
    required this.selectedNodeIds,
    required this.selectionMode,
    required this.onToggleNodeSelection,
    required this.onStartNodeSelection,
    required this.layoutSettings,
  });

  final List<IndexNode> nodes;
  final Map<String, IndexNodeSummary> summaries;
  final Map<String, IndexNodePreview> previews;
  final ValueChanged<IndexNode> onOpenNode;
  final ValueChanged<String> onThumbnailEntityNeeded;
  final Set<String> selectedNodeIds;
  final bool selectionMode;
  final ValueChanged<IndexNode> onToggleNodeSelection;
  final ValueChanged<IndexNode> onStartNodeSelection;
  final GalleryLayoutSettings layoutSettings;

  @override
  Widget build(BuildContext context) => _JustifiedNodeGridSliver(
        nodes: nodes,
        summaries: summaries,
        previews: previews,
        onOpenNode: onOpenNode,
        onThumbnailEntityNeeded: onThumbnailEntityNeeded,
        selectedNodeIds: selectedNodeIds,
        selectionMode: selectionMode,
        onToggleNodeSelection: onToggleNodeSelection,
        onStartNodeSelection: onStartNodeSelection,
        layoutSettings: layoutSettings,
      );
}

class _JustifiedNodeGridSliver extends StatelessWidget {
  const _JustifiedNodeGridSliver({
    required this.nodes,
    required this.summaries,
    required this.previews,
    required this.onOpenNode,
    required this.onThumbnailEntityNeeded,
    required this.selectedNodeIds,
    required this.selectionMode,
    required this.onToggleNodeSelection,
    required this.onStartNodeSelection,
    required this.layoutSettings,
  });

  final List<IndexNode> nodes;
  final Map<String, IndexNodeSummary> summaries;
  final Map<String, IndexNodePreview> previews;
  final ValueChanged<IndexNode> onOpenNode;
  final ValueChanged<String> onThumbnailEntityNeeded;
  final Set<String> selectedNodeIds;
  final bool selectionMode;
  final ValueChanged<IndexNode> onToggleNodeSelection;
  final ValueChanged<IndexNode> onStartNodeSelection;
  final GalleryLayoutSettings layoutSettings;

  @override
  Widget build(BuildContext context) {
    final gap = layoutSettings.cardGap;
    final margin = layoutSettings.pageMargin;
    final targetHeight = layoutSettings.folderHeight;
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    if (portrait) {
      return SliverPadding(
        padding: EdgeInsets.fromLTRB(margin, 0, margin, margin),
        sliver: SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: layoutSettings.portraitFolderColumns,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
          ),
          itemCount: nodes.length,
          itemBuilder: (context, index) => _nodeCard(
            nodes[index],
            portrait: true,
          ),
        ),
      );
    }
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final rows = _FixedHeightNodeRows.calculate(
          nodes: nodes,
          availableWidth: constraints.crossAxisExtent - margin * 2,
          height: targetHeight,
          gap: gap,
          aspectRatio: (node) => indexNodePreviewAspectRatio(previews[node.id]),
        );
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(margin, 0, margin, margin),
          sliver: SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (context, rowIndex) {
              final row = rows[rowIndex];
              return Padding(
                padding: EdgeInsets.only(bottom: gap),
                child: SizedBox(
                  height: targetHeight,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var index = 0; index < row.nodes.length; index++)
                          Padding(
                            padding: EdgeInsets.only(
                              right: index == row.nodes.length - 1 ? 0 : gap,
                            ),
                            child: SizedBox(
                              width: row.widths[index],
                              height: targetHeight,
                              child: _nodeCard(row.nodes[index]),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _nodeCard(IndexNode node, {bool portrait = false}) {
    return IndexNodePreviewCard(
      node: node,
      preview: previews[node.id],
      summary: summaries[node.id],
      selected: selectedNodeIds.contains(node.id),
      onTap: selectionMode
          ? () => onToggleNodeSelection(node)
          : () => onOpenNode(node),
      onLongPress: () => onStartNodeSelection(node),
      onThumbnailEntityNeeded: onThumbnailEntityNeeded,
      cardRadius: layoutSettings.cardRadius,
      portrait: portrait,
      internalGap: layoutSettings.cardGap,
    );
  }
}

class _FixedHeightNodeRows {
  const _FixedHeightNodeRows._();

  static List<_FixedHeightNodeRow> calculate({
    required List<IndexNode> nodes,
    required double availableWidth,
    required double height,
    required double gap,
    required double Function(IndexNode node) aspectRatio,
  }) {
    if (nodes.isEmpty || availableWidth <= 0 || height <= 0) return const [];
    final rows = <_FixedHeightNodeRow>[];
    final pending = <IndexNode>[];
    final widths = <double>[];
    var occupiedWidth = 0.0;

    void commit() {
      if (pending.isEmpty) return;
      rows.add(_FixedHeightNodeRow(
        nodes: List.unmodifiable(pending),
        widths: List.unmodifiable(widths),
      ));
      pending.clear();
      widths.clear();
      occupiedWidth = 0;
    }

    for (final node in nodes) {
      final width = (aspectRatio(node).clamp(.12, 8) * height).toDouble();
      final requiredWidth = pending.isEmpty ? width : gap + width;
      if (pending.isNotEmpty &&
          occupiedWidth + requiredWidth > availableWidth) {
        commit();
      }
      pending.add(node);
      widths.add(width);
      occupiedWidth += pending.length == 1 ? width : gap + width;
    }
    commit();
    return rows;
  }
}

class _FixedHeightNodeRow {
  const _FixedHeightNodeRow({required this.nodes, required this.widths});

  final List<IndexNode> nodes;
  final List<double> widths;
}

class IndexNodePreviewCard extends StatelessWidget {
  const IndexNodePreviewCard({
    super.key,
    required this.node,
    required this.preview,
    required this.summary,
    required this.onTap,
    required this.onThumbnailEntityNeeded,
    this.selected = false,
    this.onLongPress,
    this.cardRadius = 16,
    this.portrait = false,
    this.internalGap = 0,
  });

  final IndexNode node;
  final IndexNodePreview? preview;
  final IndexNodeSummary? summary;
  final VoidCallback onTap;
  final ValueChanged<String> onThumbnailEntityNeeded;
  final bool selected;
  final VoidCallback? onLongPress;
  final double cardRadius;
  final bool portrait;
  final double internalGap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(cardRadius),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: portrait ? 1 : indexNodePreviewAspectRatio(preview),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(cardRadius),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    IndexNodeThumbnail(
                      preview: preview,
                      nodeName: node.name,
                      hasContent: (summary?.childNodeCount ?? 0) > 0 ||
                          (summary?.directEntityCount ?? 0) > 0,
                      borderRadius: cardRadius,
                      portrait: portrait,
                      internalGap: internalGap,
                    ),
                    Positioned(
                      top: 6,
                      right: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .46),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          child: Text(
                            '${summary?.childNodeCount ?? 0} | ${summary?.directEntityCount ?? 0}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Colors.white.withValues(alpha: .92),
                              fontSize: 10,
                              height: 1,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (selected)
                      Positioned(
                        top: 6,
                        left: 6,
                        child: Icon(
                          Icons.check_circle_rounded,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      left: 0,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Colors.transparent, Color(0xA8000000)],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(9, 20, 9, 8),
                          child: Text(
                            node.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w500,
                              shadows: const [
                                Shadow(blurRadius: 3, color: Colors.black54),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HorizontalNodeRail extends StatelessWidget {
  const _HorizontalNodeRail({
    required this.children,
  });

  final List<_NodeRailEntry> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 42,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        key: ValueKey(children.map((entry) => entry.label).join('/')),
        reverse: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (var index = 0; index < children.length; index++) ...[
              if (index > 0)
                _RailSeparator(color: theme.colorScheme.outlineVariant),
              children[index],
            ],
          ],
        ),
      ),
    );
  }
}

class _RailSeparator extends StatelessWidget {
  const _RailSeparator({this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.zero,
      child: Text(
        '|',
        style: theme.textTheme.titleSmall?.copyWith(
          color: color ?? theme.colorScheme.outline,
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }
}

class _NodeRailEntry extends StatelessWidget {
  const _NodeRailEntry({
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: selected
                          ? theme.colorScheme.primary
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        softWrap: false,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: foreground,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
