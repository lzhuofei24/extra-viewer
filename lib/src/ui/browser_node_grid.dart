import 'package:flutter/material.dart';
import '../core/domain/models.dart';
import 'gallery_layout_settings.dart';
import 'browser_state.dart';
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
    final targetHeight = layoutSettings.folderHeight;
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final square = folderCoverStyle == FolderCoverStyle.square ||
        (folderCoverStyle == FolderCoverStyle.automatic && portrait);
    if (square) {
      return SliverPadding(
        padding: EdgeInsets.fromLTRB(margin, 0, margin, margin),
        sliver: SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: portrait
                ? layoutSettings.portraitFolderColumns
                : layoutSettings.landscapeSquareColumns,
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
          aspectRatio: (node) =>
              coverAspectRatio?.call(node) ??
              indexNodePreviewAspectRatio(previews[node.id]),
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
    this.cover,
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
            AspectRatio(
              aspectRatio: portrait
                  ? 1
                  : coverAspectRatio ?? indexNodePreviewAspectRatio(preview),
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
