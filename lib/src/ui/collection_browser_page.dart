import 'browser_node_grid.dart';
export 'browser_node_grid.dart' show IndexNodePreviewCard;
import 'browser_entity_sliver.dart';
import 'browser_page_scaffold.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../core/domain/models.dart';
import 'browser_state.dart';
import 'browser_toolbar.dart';
import 'browser_path_rail.dart';
import 'design_tokens.dart';
import 'index_node_thumbnail.dart';
import 'gallery_layout_settings.dart';
import 'library_widgets.dart';
import 'browser_list.dart';

class CollectionBrowserPage extends StatelessWidget {
  const CollectionBrowserPage({
    super.key,
    this.loading = false,
    this.loadError,
    this.onRetry,
    this.onSearchNodes,
    this.onFolderCoverChanged,
    this.onAdd,
    this.addLabel = '添加',
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
    required this.themeChoice,
    required this.onThemeChanged,
    required this.layoutPreset,
    required this.onLayoutPresetChanged,
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

  final bool loading;
  final Object? loadError;
  final VoidCallback? onRetry;
  final IndexNode? currentNode;
  final VoidCallback? onSearchNodes;
  final ValueChanged<FolderCoverStyle>? onFolderCoverChanged;
  final VoidCallback? onAdd;
  final String addLabel;
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
  final ViewerThemeChoice themeChoice;
  final ValueChanged<ViewerThemeChoice> onThemeChanged;
  final GalleryLayoutPreset layoutPreset;
  final ValueChanged<GalleryLayoutPreset> onLayoutPresetChanged;
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
        ? (childNodes
            .where((node) => _rootTabMatchesNode(browserState.rootTab, node))
            .toList(growable: false)
          ..sort((a, b) {
            if (a.systemKey == 'favorites') return -1;
            if (b.systemKey == 'favorites') return 1;
            return 0;
          }))
        : childNodes;
    final hasNodes = visibleNodes.isNotEmpty && !immersiveBrowsing && !loading;
    final hasEntities = entities.isNotEmpty && !loading;
    final listMode = !immersiveBrowsing &&
        browserState.displayMode == BrowserDisplayMode.list;
    final topChromeInset = BrowserPageScaffold.topInset(context);
    return BrowserPageScaffold(
      body: Padding(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            Expanded(
              child: BrowserScrollShell(
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
                          : BrowserNodeGridSliver(
                              folderCoverStyle: browserState.folderCoverStyle,
                              nodes: visibleNodes,
                              summaries: nodeSummaries,
                              previews: nodePreviews,
                              onOpenNode: onOpenNode,
                              onThumbnailEntityNeeded: onThumbnailEntityNeeded,
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
                          : BrowserNodeGridSliver(
                              folderCoverStyle: browserState.folderCoverStyle,
                              nodes: childNodes,
                              summaries: nodeSummaries,
                              previews: nodePreviews,
                              onOpenNode: onOpenNode,
                              onThumbnailEntityNeeded: onThumbnailEntityNeeded,
                              selectedNodeIds: selectedNodeIds,
                              selectionMode: selectionMode,
                              onToggleNodeSelection: onToggleNodeSelection,
                              onStartNodeSelection: onStartNodeSelection,
                              layoutSettings: layoutSettings,
                            ),
                    if (loading)
                      const SliverFillRemaining(
                          child: Center(child: CircularProgressIndicator()))
                    else if (loadError != null)
                      SliverFillRemaining(
                          child: Center(
                              child: TextButton(
                                  onPressed: onRetry,
                                  child: const Text('加载失败，点击重试'))))
                    else if (!hasNodes && !hasEntities)
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
                              color:
                                  Theme.of(context).colorScheme.outlineVariant),
                        ),
                      ),
                    if (hasEntities)
                      BrowserEntitySliver(
                          entities: entities,
                          browserState: browserState,
                          layoutSettings: layoutSettings,
                          immersive: immersiveBrowsing,
                          selectionMode: selectionMode,
                          selectionRegistry: selectionRegistry,
                          selectedEntityIds: selectedEntityIds,
                          onOpenEntity: onOpenEntity,
                          onShowEntityMenu: onShowEntityMenu,
                          onThumbnailNeeded: onThumbnailNeeded,
                          onToggleEntitySelection: onToggleEntitySelection,
                          onStartEntitySelection: onStartEntitySelection),
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
                        height: BrowserPageScaffold.bottomInset(context,
                            selecting: selectionMode),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      toolbar: _PathBar(
        onAdd: onAdd,
        onFolderCoverChanged: onFolderCoverChanged,
        addLabel: addLabel,
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
        themeChoice: themeChoice,
        onThemeChanged: onThemeChanged,
        layoutPreset: layoutPreset,
        onLayoutPresetChanged: onLayoutPresetChanged,
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
      immersive: immersiveBrowsing,
      onExitImmersive: onToggleImmersiveBrowsing,
      selectionBar: selectionMode
          ? _SelectionActionBar(
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
              onCustomizeSelectedNodePreview: onCustomizeSelectedNodePreview,
              onClearSelectedNodePreviewOverride:
                  onClearSelectedNodePreviewOverride,
            )
          : null,
    );
  }
}

class _PathBar extends StatelessWidget {
  const _PathBar({
    this.onSearchNodes,
    this.onFolderCoverChanged,
    this.onAdd,
    this.addLabel = '添加',
    required this.currentNode,
    required this.path,
    required this.onOpenRootIndex,
    required this.onPathNodeSelected,
    required this.browserState,
    required this.onSortChanged,
    required this.onDisplayModeChanged,
    required this.onGridLayoutChanged,
    required this.onListStyleChanged,
    required this.themeChoice,
    required this.onThemeChanged,
    required this.layoutPreset,
    required this.onLayoutPresetChanged,
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
  final ValueChanged<FolderCoverStyle>? onFolderCoverChanged;
  final VoidCallback? onAdd;
  final String addLabel;
  final VoidCallback onOpenRootIndex;
  final ValueChanged<IndexNode> onPathNodeSelected;
  final BrowserState browserState;
  final ValueChanged<EntitySortMode> onSortChanged;
  final ValueChanged<BrowserDisplayMode> onDisplayModeChanged;
  final ValueChanged<BrowserGridLayout> onGridLayoutChanged;
  final ValueChanged<BrowserListStyle> onListStyleChanged;
  final ViewerThemeChoice themeChoice;
  final ValueChanged<ViewerThemeChoice> onThemeChanged;
  final GalleryLayoutPreset layoutPreset;
  final ValueChanged<GalleryLayoutPreset> onLayoutPresetChanged;
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
      leading: BrowserPathRail(
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
      themeChoice: themeChoice,
      onThemeChanged: onThemeChanged,
      layoutPreset: layoutPreset,
      onLayoutPresetChanged: onLayoutPresetChanged,
      onSearch: onSearchNodes,
      onAdd: onAdd,
      onFolderCoverChanged: onFolderCoverChanged,
      addLabel: addLabel,
      immersive: immersiveBrowsing,
      onToggleImmersive: onToggleImmersiveBrowsing,
      selectionMode: selectionMode,
      onToggleSelection: onToggleSelectionMode,
    );
  }
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
    final hasSelection = entityCount + nodeCount > 0;
    final previewOnly = entityCount == 0 && nodeCount == 1;
    return BrowserSelectionBar(
        count: entityCount + nodeCount,
        onExit: onExit,
        onSelectAll: onSelectAll,
        onInvert: onInvert,
        actions: [
          TextButton(onPressed: onSelectRange, child: const Text('区间选择')),
          if (managementActions.isNotEmpty)
            PopupMenuButton<int>(
                tooltip: '管理',
                onSelected: (index) => managementActions[index].onPressed(),
                itemBuilder: (_) => [
                      for (var i = 0; i < managementActions.length; i++)
                        PopupMenuItem(
                            value: i, child: Text(managementActions[i].label)),
                    ],
                child: const Padding(
                    padding: EdgeInsets.all(12), child: Text('管理'))),
          if (previewOnly)
            PopupMenuButton<int>(
                tooltip: '预览',
                onSelected: (index) => [
                      onRebuildSelectedNodePreview,
                      onCustomizeSelectedNodePreview,
                      onClearSelectedNodePreviewOverride
                    ][index](),
                itemBuilder: (_) => const [
                      PopupMenuItem(value: 0, child: Text('重新生成预览')),
                      PopupMenuItem(value: 1, child: Text('自定义生成预览')),
                      PopupMenuItem(value: 2, child: Text('恢复自动预览')),
                    ],
                child: const Padding(
                    padding: EdgeInsets.all(12), child: Text('预览'))),
          TextButton(
              onPressed: hasSelection ? onAddToCollection : null,
              child: const Text('加入分类')),
          if (canRemoveFromCurrentNode)
            TextButton(
                onPressed: hasSelection ? onRemoveFromCurrentNode : null,
                child: Text(nodeCount > 0 && entityCount == 0 ? '删除分组' : '删除')),
        ]);
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
                hasContent: summary == null ||
                    summary.childNodeCount > 0 ||
                    summary.directEntityCount > 0,
                portrait: true,
                borderRadius: 6));
      });
}
