import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../core/domain/models.dart';
import 'browser_state.dart';
import 'collection_grid_layout.dart';
import 'design_tokens.dart';
import 'index_node_thumbnail.dart';
import 'gallery_metrics.dart';
import 'justified_entity_gallery.dart';
import 'library_widgets.dart';
import 'spanning_grid.dart';

class CollectionBrowserPage extends StatelessWidget {
  const CollectionBrowserPage({
    super.key,
    required this.currentNode,
    required this.nodePath,
    required this.childNodes,
    required this.nodeSummaries,
    required this.nodePreviews,
    required this.entities,
    required this.hasMoreEntities,
    required this.loadingMoreEntities,
    required this.browserState,
    required this.onOpenRootIndex,
    required this.onSortChanged,
    required this.onDisplayModeChanged,
    required this.onGridLayoutChanged,
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
  final VoidCallback onLoadMoreEntities;
  final Set<String> selectedEntityIds;
  final ValueChanged<EntityListItem> onToggleEntitySelection;
  final ValueChanged<EntityListItem> onStartEntitySelection;
  final ValueChanged<Iterable<EntityListItem>> onSelectEntitiesByDrag;
  final Set<String> selectedNodeIds;
  final ValueChanged<IndexNode> onToggleNodeSelection;
  final ValueChanged<IndexNode> onStartNodeSelection;
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
    final hasNodes = childNodes.isNotEmpty && !immersiveBrowsing;
    final hasEntities = entities.isNotEmpty;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: _PathBar(
            currentNode: currentNode,
            path: nodePath,
            onOpenRootIndex: onOpenRootIndex,
            onPathNodeSelected: onPathNodeSelected,
            browserState: browserState,
            onSortChanged: onSortChanged,
            onDisplayModeChanged: onDisplayModeChanged,
            onGridLayoutChanged: onGridLayoutChanged,
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
        if (selectionMode)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: _SelectionActionBar(
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
              onCustomizeSelectedNodePreview: onCustomizeSelectedNodePreview,
              onClearSelectedNodePreviewOverride:
                  onClearSelectedNodePreviewOverride,
            ),
          ),
        Expanded(
          child: _BrowserScrollShell(
            entities: entities,
            hasMore: hasMoreEntities,
            onLoadMore: onLoadMoreEntities,
            selectionMode: selectionMode,
            onSelectEntitiesByDrag: onSelectEntitiesByDrag,
            child: (controller, selectionRegistry) => CustomScrollView(
              controller: controller,
              slivers: [
                if (hasNodes && currentNode == null)
                  ..._rootIndexGroupSlivers(
                    childNodes,
                    summaries: nodeSummaries,
                    previews: nodePreviews,
                    onOpenNode: onOpenNode,
                    selectedNodeIds: selectedNodeIds,
                    selectionMode: selectionMode,
                    onToggleNodeSelection: onToggleNodeSelection,
                    onStartNodeSelection: onStartNodeSelection,
                  ),
                if (hasNodes && currentNode != null)
                  _NodeGridSliver(
                    nodes: childNodes,
                    summaries: nodeSummaries,
                    previews: nodePreviews,
                    onOpenNode: onOpenNode,
                    selectedNodeIds: selectedNodeIds,
                    selectionMode: selectionMode,
                    onToggleNodeSelection: onToggleNodeSelection,
                    onStartNodeSelection: onStartNodeSelection,
                  ),
                if (!hasNodes && !hasEntities)
                  SliverPadding(
                    padding: const EdgeInsets.all(20),
                    sliver: SliverToBoxAdapter(
                      child: EmptyStateCard(
                        title: immersiveBrowsing ? '沉浸式浏览为空' : '当前索引节点为空',
                        message: immersiveBrowsing
                            ? '当前节点及其下级节点中没有可展示的实体。'
                            : '可从“索引”页面重新扫描，或返回根索引继续浏览。',
                      ),
                    ),
                  ),
                if (hasNodes && hasEntities)
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    sliver: SliverToBoxAdapter(
                      child: Divider(
                          height: 1,
                          color: Theme.of(context).colorScheme.outlineVariant),
                    ),
                  ),
                if (hasEntities)
                  immersiveBrowsing ||
                          browserState.displayMode == BrowserDisplayMode.grid
                      ? switch (browserState.gridLayout) {
                          BrowserGridLayout.equalHeight => _EntityGridSliver(
                              entities: entities,
                              immersive: immersiveBrowsing,
                              selectedEntityIds: selectedEntityIds,
                              selectionMode: selectionMode,
                              selectionRegistry: selectionRegistry,
                              onOpenEntity: onOpenEntity,
                              onShowEntityMenu: onShowEntityMenu,
                              onToggleEntitySelection: onToggleEntitySelection,
                              onStartEntitySelection: onStartEntitySelection,
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
                              onToggleEntitySelection: onToggleEntitySelection,
                              onStartEntitySelection: onStartEntitySelection,
                            ),
                          BrowserGridLayout.adaptive =>
                            _SpanningEntityGridSliver(
                                entities: entities,
                                immersive: immersiveBrowsing,
                                selectionMode: selectionMode,
                                selectionRegistry: selectionRegistry,
                                onOpenEntity: onOpenEntity,
                                onShowEntityMenu: onShowEntityMenu,
                                selectedEntityIds: selectedEntityIds,
                                onToggleEntitySelection:
                                    onToggleEntitySelection,
                                onStartEntitySelection: onStartEntitySelection),
                          BrowserGridLayout.square => _SquareEntityGridSliver(
                              entities: entities,
                              immersive: immersiveBrowsing,
                              selectionMode: selectionMode,
                              selectionRegistry: selectionRegistry,
                              onOpenEntity: onOpenEntity,
                              onShowEntityMenu: onShowEntityMenu,
                              selectedEntityIds: selectedEntityIds,
                              onToggleEntitySelection: onToggleEntitySelection,
                              onStartEntitySelection: onStartEntitySelection),
                        }
                      : _EntityListSliver(
                          entities: entities,
                          selectedEntityIds: selectedEntityIds,
                          selectionMode: selectionMode,
                          onOpenEntity: onOpenEntity,
                          onShowEntityMenu: onShowEntityMenu,
                          onToggleEntitySelection: onToggleEntitySelection,
                          onStartEntitySelection: onStartEntitySelection,
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
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : TextButton(
                                onPressed: onLoadMoreEntities,
                                child: const Text('加载更多'),
                              ),
                      ),
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 28)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

List<Widget> _rootIndexGroupSlivers(
  List<IndexNode> roots, {
  required Map<String, IndexNodeSummary> summaries,
  required Map<String, IndexNodePreview> previews,
  required ValueChanged<IndexNode> onOpenNode,
  required Set<String> selectedNodeIds,
  required bool selectionMode,
  required ValueChanged<IndexNode> onToggleNodeSelection,
  required ValueChanged<IndexNode> onStartNodeSelection,
}) {
  final groups = <({String label, NodeType type})>[
    (label: '目录索引', type: NodeType.directoryIndexRoot),
    (label: '自定义索引', type: NodeType.categoryIndexRoot),
    (label: '图索引', type: NodeType.graphIndexRoot),
  ];
  final visibleGroups = groups
      .map(
        (group) => (
          label: group.label,
          nodes: roots
              .where((node) => node.nodeType == group.type)
              .toList(growable: false),
        ),
      )
      .where((group) => group.nodes.isNotEmpty)
      .toList(growable: false);
  final slivers = <Widget>[];
  for (var index = 0; index < visibleGroups.length; index++) {
    final group = visibleGroups[index];
    slivers.add(
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
        sliver: SliverToBoxAdapter(
          child: Text(
            group.label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
    slivers.add(
      _NodeGridSliver(
        nodes: group.nodes,
        summaries: summaries,
        previews: previews,
        onOpenNode: onOpenNode,
        selectedNodeIds: selectedNodeIds,
        selectionMode: selectionMode,
        onToggleNodeSelection: onToggleNodeSelection,
        onStartNodeSelection: onStartNodeSelection,
      ),
    );
    if (index < visibleGroups.length - 1) {
      slivers.add(
        const SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          sliver: SliverToBoxAdapter(
            child: Divider(height: 1),
          ),
        ),
      );
    }
  }
  return slivers;
}

class _BrowserScrollShell extends StatefulWidget {
  const _BrowserScrollShell({
    required this.entities,
    required this.hasMore,
    required this.onLoadMore,
    required this.selectionMode,
    required this.onSelectEntitiesByDrag,
    required this.child,
  });

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
  String _entitySignature = '';
  int _lastForwardPrefetchStart = -1;
  final _EntitySelectionRegistry _selectionRegistry =
      _EntitySelectionRegistry();
  final Map<int, Map<String, EntityListItem>> _dragEntitiesByPointer =
      <int, Map<String, EntityListItem>>{};
  final Set<int> _activeDragPointers = <int>{};

  @override
  void initState() {
    super.initState();
    _entitySignature = _signatureFor(widget.entities);
    _scrollController.addListener(_handleScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _prefetchWindow(0));
  }

  @override
  void didUpdateWidget(covariant _BrowserScrollShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final signature = _signatureFor(widget.entities);
    if (signature == _entitySignature) return;
    _entitySignature = signature;
    _lastForwardPrefetchStart = -1;
    WidgetsBinding.instance.addPostFrameCallback((_) => _prefetchWindow(0));
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    final width = MediaQuery.sizeOf(context).width;
    final columns = (width / 240).floor().clamp(1, 6).toInt();
    final estimatedVisibleStart =
        ((_scrollController.position.pixels / 250).floor() * columns).toInt();
    _prefetchWindow(estimatedVisibleStart + columns * 2);
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

  void _prefetchWindow(int start) {
    if (!mounted || start <= _lastForwardPrefetchStart) return;
    _lastForwardPrefetchStart = start;
    final end = (start + 18).clamp(0, widget.entities.length).toInt();
    final first = start.clamp(0, widget.entities.length).toInt();
    for (var index = first; index < end; index++) {
      final path = widget.entities[index].thumbnailPath;
      if (path == null || path.isEmpty) continue;
      precacheImage(FileImage(File(path)), context, onError: (_, __) {});
    }
  }

  String _signatureFor(List<EntityListItem> entities) {
    if (entities.isEmpty) return '';
    return '${entities.length}:${entities.first.id}:${entities.last.id}';
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
    required this.currentNode,
    required this.path,
    required this.onOpenRootIndex,
    required this.onPathNodeSelected,
    required this.browserState,
    required this.onSortChanged,
    required this.onDisplayModeChanged,
    required this.onGridLayoutChanged,
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
  final VoidCallback onOpenRootIndex;
  final ValueChanged<IndexNode> onPathNodeSelected;
  final BrowserState browserState;
  final ValueChanged<EntitySortMode> onSortChanged;
  final ValueChanged<BrowserDisplayMode> onDisplayModeChanged;
  final ValueChanged<BrowserGridLayout> onGridLayoutChanged;
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
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: _IndexPathRail(
            currentNode: currentNode,
            path: path,
            onOpenRootIndex: onOpenRootIndex,
            onPathNodeSelected: onPathNodeSelected,
          ),
        ),
        IconButton(
          tooltip: immersiveBrowsing ? '退出沉浸式浏览' : '沉浸式浏览',
          onPressed: currentNode == null ? null : onToggleImmersiveBrowsing,
          icon: Icon(
            immersiveBrowsing
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
          ),
        ),
        IconButton(
          tooltip: selectionMode ? '退出选择模式' : '选择模式',
          onPressed: onToggleSelectionMode,
          icon: Icon(
            selectionMode ? Icons.checklist_rounded : Icons.checklist_outlined,
          ),
        ),
        if (canUpdateDirectoryNode)
          IconButton(
            tooltip: '递归更新当前目录节点',
            onPressed: onUpdateDirectoryNode,
            icon: const Icon(Icons.refresh_rounded),
          ),
        const SizedBox(width: 4),
        MenuAnchor(
          menuChildren: [
            if (currentNode != null)
              MenuItemButton(
                onPressed: onCloneCurrentNodeTree,
                child: const Text('复制节点树到自定义索引'),
              ),
            if (canCreateNode)
              MenuItemButton(
                onPressed: onCreateNode,
                child: const Text('新建索引节点'),
              ),
            if (canDeleteCurrentNode)
              MenuItemButton(
                onPressed: onDeleteCurrentNode,
                child: const Text('从当前节点树删除'),
              ),
            if (currentNode != null && (canCreateNode || canDeleteCurrentNode))
              const Divider(height: 1),
            SizedBox(
              width: 260,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('设置', style: theme.textTheme.labelLarge),
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
                            value: EntitySortMode.sizeDesc, label: Text('体积')),
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
                            icon: Icon(Icons.grid_view_rounded)),
                        ButtonSegment(
                            value: BrowserDisplayMode.list,
                            icon: Icon(Icons.view_agenda_rounded)),
                      ],
                      selected: {browserState.displayMode},
                      onSelectionChanged: (value) =>
                          onDisplayModeChanged(value.first),
                    ),
                    const SizedBox(height: 6),
                    Text('实体布局', style: theme.textTheme.labelMedium),
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
                ),
              ),
            ),
          ],
          builder: (context, controller, child) => IconButton(
            tooltip: '设置',
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.tune_rounded),
          ),
        ),
      ],
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
    required this.selectedEntityIds,
    required this.onToggleEntitySelection,
    required this.onStartEntitySelection,
  });

  final List<EntityListItem> entities;
  final bool immersive;
  final bool selectionMode;
  final _EntitySelectionRegistry selectionRegistry;
  final ValueChanged<EntityListItem> onOpenEntity;
  final ValueChanged<EntityListItem> onShowEntityMenu;
  final Set<String> selectedEntityIds;
  final ValueChanged<EntityListItem> onToggleEntitySelection;
  final ValueChanged<EntityListItem> onStartEntitySelection;

  @override
  Widget build(BuildContext context) {
    return JustifiedEntityGallerySliver(
      entities: entities,
      immersive: immersive,
      selectionMode: selectionMode,
      keyFor: selectionRegistry.keyFor,
      onOpenEntity: onOpenEntity,
      onShowEntityMenu: onShowEntityMenu,
      selectedEntityIds: selectedEntityIds,
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
    required this.selectedEntityIds,
    required this.onToggleEntitySelection,
    required this.onStartEntitySelection,
  });

  final List<EntityListItem> entities;
  final bool immersive;
  final bool selectionMode;
  final _EntitySelectionRegistry selectionRegistry;
  final ValueChanged<EntityListItem> onOpenEntity;
  final ValueChanged<EntityListItem> onShowEntityMenu;
  final Set<String> selectedEntityIds;
  final ValueChanged<EntityListItem> onToggleEntitySelection;
  final ValueChanged<EntityListItem> onStartEntitySelection;

  @override
  Widget build(BuildContext context) {
    final gap = immersive ? 2.0 : 4.0;
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final layout = CollectionGridLayout.calculate(
          availableWidth: constraints.crossAxisExtent,
          gap: gap,
        );
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(
            immersive ? 2 : 8,
            immersive ? 2 : 12,
            immersive ? 2 : 8,
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
              selectionMode: selectionMode,
              onToggleSelection: () => onToggleEntitySelection(entities[index]),
              onShowMenu: () => onShowEntityMenu(entities[index]),
              onStartSelection: () => onStartEntitySelection(entities[index]),
            ),
          ),
        );
      },
    );
  }
}

class _SpanningEntityGridSliver extends StatelessWidget {
  const _SpanningEntityGridSliver(
      {required this.entities,
      required this.immersive,
      required this.selectionMode,
      required this.selectionRegistry,
      required this.onOpenEntity,
      required this.onShowEntityMenu,
      required this.selectedEntityIds,
      required this.onToggleEntitySelection,
      required this.onStartEntitySelection});
  final List<EntityListItem> entities;
  final bool immersive;
  final bool selectionMode;
  final _EntitySelectionRegistry selectionRegistry;
  final ValueChanged<EntityListItem> onOpenEntity;
  final ValueChanged<EntityListItem> onShowEntityMenu;
  final Set<String> selectedEntityIds;
  final ValueChanged<EntityListItem> onToggleEntitySelection;
  final ValueChanged<EntityListItem> onStartEntitySelection;
  @override
  Widget build(BuildContext context) => SpanningGridSliver<EntityListItem>(
        items: entities,
        targetCellWidth: GalleryMetrics.cardWidth,
        targetRowHeight: GalleryMetrics.cardHeight,
        crossRowMode: false,
        gap: immersive ? 2 : 4,
        horizontalPadding: immersive ? 2 : 8,
        aspectRatio: _entityAspectRatio,
        itemBuilder: (context, entity) => EntityCard(
            key: selectionRegistry.keyFor(entity),
            entity: entity,
            onOpen: () => onOpenEntity(entity),
            selected: selectedEntityIds.contains(entity.id),
            immersive: immersive,
            selectionMode: selectionMode,
            onToggleSelection: () => onToggleEntitySelection(entity),
            onShowMenu: () => onShowEntityMenu(entity),
            onStartSelection: () => onStartEntitySelection(entity)),
      );
}

class _SquareEntityGridSliver extends StatelessWidget {
  const _SquareEntityGridSliver(
      {required this.entities,
      required this.immersive,
      required this.selectionMode,
      required this.selectionRegistry,
      required this.onOpenEntity,
      required this.onShowEntityMenu,
      required this.selectedEntityIds,
      required this.onToggleEntitySelection,
      required this.onStartEntitySelection});
  final List<EntityListItem> entities;
  final bool immersive;
  final bool selectionMode;
  final _EntitySelectionRegistry selectionRegistry;
  final ValueChanged<EntityListItem> onOpenEntity;
  final ValueChanged<EntityListItem> onShowEntityMenu;
  final Set<String> selectedEntityIds;
  final ValueChanged<EntityListItem> onToggleEntitySelection;
  final ValueChanged<EntityListItem> onStartEntitySelection;
  @override
  Widget build(BuildContext context) =>
      SliverLayoutBuilder(builder: (context, constraints) {
        final layout = CollectionGridLayout.calculate(
            availableWidth: constraints.crossAxisExtent,
            gap: immersive ? 2 : 4,
            targetItemWidth: GalleryMetrics.squareSize);
        return SliverPadding(
            padding: EdgeInsets.fromLTRB(
                immersive ? 2 : 8, immersive ? 2 : 12, immersive ? 2 : 8, 0),
            sliver: SliverGrid(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final entity = entities[index];
                  return EntityCard(
                      key: selectionRegistry.keyFor(entity),
                      entity: entity,
                      onOpen: () => onOpenEntity(entity),
                      selected: selectedEntityIds.contains(entity.id),
                      immersive: immersive,
                      selectionMode: selectionMode,
                      onToggleSelection: () => onToggleEntitySelection(entity),
                      onShowMenu: () => onShowEntityMenu(entity),
                      onStartSelection: () => onStartEntitySelection(entity));
                }, childCount: entities.length),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: layout.columnCount,
                    mainAxisSpacing: immersive ? 2 : 4,
                    crossAxisSpacing: immersive ? 2 : 4,
                    childAspectRatio: 1)));
      });
}

double _entityAspectRatio(EntityListItem entity) {
  final width = entity.thumbnailWidth;
  final height = entity.thumbnailHeight;
  return width != null && height != null && width > 0 && height > 0
      ? width / height
      : 4 / 3;
}

String _gridLayoutLabel(BrowserGridLayout mode) => switch (mode) {
      BrowserGridLayout.equalHeight => '等高',
      BrowserGridLayout.equalWidth => '等宽',
      BrowserGridLayout.adaptive => '自适应',
      BrowserGridLayout.square => '方格',
    };

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
      width: 115,
      height: 54,
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

IconData _gridLayoutIcon(BrowserGridLayout mode) => switch (mode) {
      BrowserGridLayout.equalHeight => Icons.view_stream_outlined,
      BrowserGridLayout.equalWidth => Icons.view_column_outlined,
      BrowserGridLayout.adaptive => Icons.auto_awesome_mosaic_outlined,
      BrowserGridLayout.square => Icons.grid_on_outlined,
    };

class _EntityListSliver extends StatelessWidget {
  const _EntityListSliver({
    required this.entities,
    required this.selectionMode,
    required this.onOpenEntity,
    required this.onShowEntityMenu,
    required this.selectedEntityIds,
    required this.onToggleEntitySelection,
    required this.onStartEntitySelection,
  });

  final List<EntityListItem> entities;
  final bool selectionMode;
  final ValueChanged<EntityListItem> onOpenEntity;
  final ValueChanged<EntityListItem> onShowEntityMenu;
  final Set<String> selectedEntityIds;
  final ValueChanged<EntityListItem> onToggleEntitySelection;
  final ValueChanged<EntityListItem> onStartEntitySelection;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      sliver: SliverList.separated(
        itemCount: entities.length,
        itemBuilder: (context, index) {
          final entity = entities[index];
          return ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            leading: SizedBox(
              width: 56,
              height: 56,
              child: EntityArtwork(
                entityType: entity.entityType,
                format: entity.format,
                thumbnailPath: entity.thumbnailPath,
              ),
            ),
            title: Text(entity.title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
                '${entity.format.toUpperCase()} · ${formatTime(entity.modifiedAtMs)}'),
            trailing: selectedEntityIds.contains(entity.id)
                ? const Icon(Icons.check_circle_rounded)
                : const Icon(Icons.chevron_right_rounded),
            onTap: selectionMode
                ? () => onToggleEntitySelection(entity)
                : () => onOpenEntity(entity),
            onLongPress: () => onStartEntitySelection(entity),
          );
        },
        separatorBuilder: (context, index) =>
            Divider(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    );
  }
}

class _SelectionActionBar extends StatelessWidget {
  const _SelectionActionBar({
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
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('已选 $entityCount 个实体 | $nodeCount 个节点'),
            TextButton(onPressed: onExit, child: const Text('退出')),
            TextButton(onPressed: onSelectAll, child: const Text('全选')),
            TextButton(onPressed: onInvert, child: const Text('反选')),
            TextButton(onPressed: onSelectRange, child: const Text('区间选择')),
            if (entityCount == 0 && nodeCount == 1)
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
            OutlinedButton(
              onPressed:
                  entityCount == 0 && nodeCount == 0 ? null : onAddToCollection,
              child: const Text('加入索引'),
            ),
            if (canRemoveFromCurrentNode)
              OutlinedButton(
                onPressed: entityCount == 0 && nodeCount == 0
                    ? null
                    : onRemoveFromCurrentNode,
                child: Text(nodeCount > 0 && entityCount == 0 ? '删除节点' : '删除'),
              ),
          ],
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
          label: '根索引',
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

class _NodeGridSliver extends StatelessWidget {
  const _NodeGridSliver({
    required this.nodes,
    required this.summaries,
    required this.previews,
    required this.onOpenNode,
    required this.selectedNodeIds,
    required this.selectionMode,
    required this.onToggleNodeSelection,
    required this.onStartNodeSelection,
  });

  final List<IndexNode> nodes;
  final Map<String, IndexNodeSummary> summaries;
  final Map<String, IndexNodePreview> previews;
  final ValueChanged<IndexNode> onOpenNode;
  final Set<String> selectedNodeIds;
  final bool selectionMode;
  final ValueChanged<IndexNode> onToggleNodeSelection;
  final ValueChanged<IndexNode> onStartNodeSelection;

  @override
  Widget build(BuildContext context) => _JustifiedNodeGridSliver(
        nodes: nodes,
        summaries: summaries,
        previews: previews,
        onOpenNode: onOpenNode,
        selectedNodeIds: selectedNodeIds,
        selectionMode: selectionMode,
        onToggleNodeSelection: onToggleNodeSelection,
        onStartNodeSelection: onStartNodeSelection,
      );
}

class _JustifiedNodeGridSliver extends StatelessWidget {
  const _JustifiedNodeGridSliver({
    required this.nodes,
    required this.summaries,
    required this.previews,
    required this.onOpenNode,
    required this.selectedNodeIds,
    required this.selectionMode,
    required this.onToggleNodeSelection,
    required this.onStartNodeSelection,
  });

  final List<IndexNode> nodes;
  final Map<String, IndexNodeSummary> summaries;
  final Map<String, IndexNodePreview> previews;
  final ValueChanged<IndexNode> onOpenNode;
  final Set<String> selectedNodeIds;
  final bool selectionMode;
  final ValueChanged<IndexNode> onToggleNodeSelection;
  final ValueChanged<IndexNode> onStartNodeSelection;

  @override
  Widget build(BuildContext context) {
    const gap = 4.0;
    final targetHeight = GalleryMetrics.cardHeight;
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final rows = JustifiedGalleryLayout.calculate(
          items: nodes,
          availableWidth: constraints.crossAxisExtent - 16,
          targetHeight: targetHeight,
          gap: gap,
          aspectRatio: (node) => indexNodePreviewAspectRatio(previews[node.id]),
        );
        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          sliver: SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (context, rowIndex) {
              final row = rows[rowIndex];
              return Padding(
                padding: const EdgeInsets.only(bottom: gap),
                child: SizedBox(
                  height: row.height,
                  child: Row(
                    children: [
                      for (var index = 0; index < row.items.length; index++)
                        Padding(
                          padding: EdgeInsets.only(
                            right: index == row.items.length - 1 ? 0 : gap,
                          ),
                          child: SizedBox(
                            width: row.widths[index],
                            height: row.height,
                            child: _nodeCard(row.items[index]),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _nodeCard(IndexNode node) {
    return IndexNodePreviewCard(
      node: node,
      preview: previews[node.id],
      summary: summaries[node.id],
      selected: selectedNodeIds.contains(node.id),
      onTap: selectionMode
          ? () => onToggleNodeSelection(node)
          : () => onOpenNode(node),
      onLongPress: () => onStartNodeSelection(node),
    );
  }
}

class IndexNodePreviewCard extends StatelessWidget {
  const IndexNodePreviewCard({
    super.key,
    required this.node,
    required this.preview,
    required this.summary,
    required this.onTap,
    this.selected = false,
    this.onLongPress,
  });

  final IndexNode node;
  final IndexNodePreview? preview;
  final IndexNodeSummary? summary;
  final VoidCallback onTap;
  final bool selected;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: indexNodePreviewAspectRatio(preview),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    IndexNodeThumbnail(
                      preview: preview,
                      nodeName: node.name,
                      hasContent: (summary?.childNodeCount ?? 0) > 0 ||
                          (summary?.directEntityCount ?? 0) > 0,
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
