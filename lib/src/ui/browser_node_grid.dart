import 'aspect_ratio_grid.dart';
import 'package:flutter/material.dart';
import '../core/domain/models.dart';
import 'gallery_layout_settings.dart';
import 'browser_state.dart';
import 'justified_entity_gallery.dart';
import 'index_node_thumbnail.dart';

class BrowserNodeGridSliver extends StatelessWidget {
  const BrowserNodeGridSliver({
    super.key,
    this.folderCoverStyle = FolderCoverStyle.automatic,
    this.coverBuilder,
    this.coverAspectRatio,
    this.countLabel,
    this.description,
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

  final FolderCoverStyle folderCoverStyle;
  final Widget Function(IndexNode, bool)? coverBuilder;
  final double Function(IndexNode)? coverAspectRatio;
  final String Function(IndexNode)? countLabel, description;
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
        folderCoverStyle: folderCoverStyle,
        coverBuilder: coverBuilder,
        coverAspectRatio: coverAspectRatio,
        countLabel: countLabel,
        description: description,
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
    this.folderCoverStyle = FolderCoverStyle.automatic,
    this.coverBuilder,
    this.coverAspectRatio,
    this.countLabel,
    this.description,
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

  final FolderCoverStyle folderCoverStyle;
  final Widget Function(IndexNode, bool)? coverBuilder;
  final double Function(IndexNode)? coverAspectRatio;
  final String Function(IndexNode)? countLabel, description;
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
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final settings = layoutSettings.folders(isPortrait: portrait);
    final square = settings.usesSquarePreview;
    double ratio(IndexNode node) =>
        coverAspectRatio?.call(node) ??
        (square ? 1 : indexNodePreviewAspectRatio(previews[node.id]));
    if (settings.cardLayout == FolderCardLayout.equalHeight) {
      return SliverLayoutBuilder(builder: (context, constraints) {
        final columns = 9 - settings.heightLevel;
        final height =
            ((constraints.crossAxisExtent - 2 * margin - (columns - 1) * gap) /
                    columns)
                .clamp(1.0, double.infinity);
        final rows = JustifiedGalleryLayout.calculate(
            items: nodes,
            availableWidth: constraints.crossAxisExtent - 2 * margin,
            targetHeight: height,
            gap: gap,
            aspectRatio: ratio);
        return SliverPadding(
            padding: EdgeInsets.fromLTRB(margin, 0, margin, margin),
            sliver: SliverList.builder(
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final row = rows[index];
                  return Padding(
                      padding: EdgeInsets.only(bottom: gap),
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (var i = 0; i < row.items.length; i++)
                              Padding(
                                  padding: EdgeInsets.only(
                                      right:
                                          i == row.items.length - 1 ? 0 : gap),
                                  child: SizedBox(
                                      width: row.widths[i],
                                      child: _nodeCard(row.items[i],
                                          portrait: square,
                                          fixedHeight: height))),
                          ]));
                }));
      });
    }
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(margin, 0, margin, margin),
      sliver: SliverGrid.builder(
        gridDelegate: AspectRatioGridDelegate(
            columns: settings.columns,
            gap: gap,
            ratios: [for (final node in nodes) ratio(node)]),
        itemCount: nodes.length,
        itemBuilder: (context, index) =>
            _nodeCard(nodes[index], portrait: square),
      ),
    );
  }

  Widget _nodeCard(IndexNode node,
      {bool portrait = false, double? fixedHeight}) {
    return IndexNodePreviewCard(
      fixedHeight: fixedHeight,
      cover: coverBuilder?.call(node, portrait),
      coverAspectRatio: coverAspectRatio?.call(node),
      countLabel: countLabel?.call(node),
      description: description?.call(node),
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

class IndexNodePreviewCard extends StatelessWidget {
  const IndexNodePreviewCard({
    super.key,
    this.cover,
    this.fixedHeight,
    this.coverAspectRatio,
    this.countLabel,
    this.description,
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

  final Widget? cover;
  final double? fixedHeight;
  final double? coverAspectRatio;
  final String? countLabel, description;
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
            _NodeCardSize(
              height: fixedHeight,
              aspectRatio: coverAspectRatio ??
                  (portrait ? 1 : indexNodePreviewAspectRatio(preview)),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(cardRadius),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    cover ??
                        IndexNodeThumbnail(
                          preview: preview,
                          nodeName: node.name,
                          hasContent: summary == null ||
                              (summary?.childNodeCount ?? 0) > 0 ||
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
                            countLabel ??
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
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  node.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w500,
                                    shadows: const [
                                      Shadow(
                                          blurRadius: 3, color: Colors.black54),
                                    ],
                                  ),
                                ),
                                if (description != null)
                                  Text(description!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(color: Colors.white70)),
                              ]),
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

class _NodeCardSize extends StatelessWidget {
  const _NodeCardSize(
      {required this.height, required this.aspectRatio, required this.child});
  final double? height;
  final double aspectRatio;
  final Widget child;
  @override
  Widget build(BuildContext context) => height == null
      ? AspectRatio(aspectRatio: aspectRatio, child: child)
      : SizedBox(height: height, child: child);
}
