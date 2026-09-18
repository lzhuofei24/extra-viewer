import 'dart:io';

import 'package:flutter/material.dart';

import '../modules/library/library_access.dart';
import '../core/domain/models.dart';

/// Lazily expanded tree picker for manually composing an index-node preview.
class NodePreviewPicker extends StatefulWidget {
  const NodePreviewPicker({
    super.key,
    required this.repository,
    required this.nodeId,
  });

  final LibraryAccess repository;
  final String nodeId;

  static Future<List<IndexNodePreviewTile>?> show(
    BuildContext context, {
    required LibraryAccess repository,
    required String nodeId,
  }) {
    return showDialog<List<IndexNodePreviewTile>>(
      context: context,
      builder: (context) => Dialog(
        child: SizedBox(
          width: 540,
          height: 620,
          child: NodePreviewPicker(repository: repository, nodeId: nodeId),
        ),
      ),
    );
  }

  @override
  State<NodePreviewPicker> createState() => _NodePreviewPickerState();
}

class _NodePreviewPickerState extends State<NodePreviewPicker> {
  static const _pageSize = 80;

  final _selected = <String, NodePreviewCandidate>{};
  final _expandedNodeIds = <String>{};
  final _loadingNodeIds = <String>{};
  final _childrenByNodeId = <String, _PreviewTreeChildren>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _loadNodeChildren(widget.nodeId),
    );
  }

  Future<void> _loadNodeChildren(String nodeId, {bool loadMore = false}) async {
    final existing = _childrenByNodeId[nodeId];
    if (_loadingNodeIds.contains(nodeId) ||
        (loadMore && (existing == null || !existing.hasMoreEntities))) {
      return;
    }
    setState(() => _loadingNodeIds.add(nodeId));
    await Future<void>.delayed(Duration.zero);
    final childNodes = loadMore
        ? existing!.nodes
        : (await widget.repository
            .listChildNodes(widget.nodeId, parentId: nodeId));
    final page = (await widget.repository.listEntityPageDirectlyUnderNode(
      nodeId,
      after: loadMore && existing!.entities.isNotEmpty
          ? EntityPageCursor.fromEntity(
              existing.entities.last,
              EntitySortMode.nameAsc,
            )
          : null,
      limit: _pageSize,
    ));
    if (!mounted) return;
    setState(() {
      _childrenByNodeId[nodeId] = _PreviewTreeChildren(
        nodes: childNodes,
        entities: [if (loadMore) ...existing!.entities, ...page.items],
        hasMoreEntities: page.hasMore,
      );
      _loadingNodeIds.remove(nodeId);
    });
  }

  void _toggleExpanded(IndexNode node) {
    setState(() {
      if (_expandedNodeIds.contains(node.id)) {
        _expandedNodeIds.remove(node.id);
      } else {
        _expandedNodeIds.add(node.id);
      }
    });
    if (!_childrenByNodeId.containsKey(node.id)) {
      _loadNodeChildren(node.id);
    }
  }

  String _idFor(NodePreviewCandidate candidate) => candidate.entityId == null
      ? 'node:${candidate.nodeId}'
      : 'entity:${candidate.entityId}';

  void _toggle(NodePreviewCandidate candidate, bool selected) {
    final id = _idFor(candidate);
    setState(() {
      if (!selected) {
        _selected.remove(id);
      } else if (_selected.length < 4) {
        _selected[id] = candidate;
      }
    });
  }

  List<_PreviewTreeRow> _visibleRows() {
    final rows = <_PreviewTreeRow>[];
    void addChildren(String parentId, int depth) {
      final children = _childrenByNodeId[parentId];
      if (children == null) return;
      for (final node in children.nodes) {
        rows.add(_PreviewTreeRow.node(node: node, depth: depth));
        if (_expandedNodeIds.contains(node.id)) {
          addChildren(node.id, depth + 1);
        }
      }
      for (final entity in children.entities) {
        rows.add(_PreviewTreeRow.entity(entity: entity, depth: depth));
      }
      if (children.hasMoreEntities) {
        rows.add(_PreviewTreeRow.loadMore(nodeId: parentId, depth: depth));
      }
    }

    addChildren(widget.nodeId, 0);
    return rows;
  }

  NodePreviewCandidate _candidateForNode(IndexNode node) =>
      NodePreviewCandidate(
        kind: IndexNodePreviewTileKind.node,
        title: node.name,
        nodeId: node.id,
      );

  NodePreviewCandidate _candidateForEntity(EntityListItem entity) {
    final kind = switch (entity.entityType) {
      EntityType.image || EntityType.video => IndexNodePreviewTileKind.visual,
      EntityType.audio => IndexNodePreviewTileKind.audio,
      EntityType.text ||
      EntityType.document =>
        IndexNodePreviewTileKind.document,
    };
    return NodePreviewCandidate(
      kind: kind,
      title: entity.title,
      entityId: entity.id,
      thumbnailPath: entity.thumbnailPath,
      thumbnailKey: entity.thumbnailKey,
      thumbnailFormat: entity.thumbnailFormat,
      aspectRatio: entity.thumbnailWidth != null &&
              entity.thumbnailHeight != null &&
              entity.thumbnailHeight! > 0
          ? entity.thumbnailWidth! / entity.thumbnailHeight!
          : 1,
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedCount = _selected.length;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('自定义封面', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('展开分组，按顺序选择最多 4 个下级分组或文件。',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 10),
          Expanded(
            child: _childrenByNodeId.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: _visibleRows().length,
                    itemBuilder: (context, index) {
                      final row = _visibleRows()[index];
                      if (row.loadMoreNodeId != null) {
                        return Padding(
                          padding: EdgeInsets.only(left: row.depth * 20.0),
                          child: TextButton.icon(
                            onPressed: () => _loadNodeChildren(
                              row.loadMoreNodeId!,
                              loadMore: true,
                            ),
                            icon: const Icon(Icons.expand_more_rounded),
                            label: const Text('加载更多文件'),
                          ),
                        );
                      }
                      final node = row.node;
                      final candidate = node == null
                          ? _candidateForEntity(row.entity!)
                          : _candidateForNode(node);
                      final id = _idFor(candidate);
                      final isExpanded =
                          node != null && _expandedNodeIds.contains(node.id);
                      final isLoading =
                          node != null && _loadingNodeIds.contains(node.id);
                      return Padding(
                        padding: EdgeInsets.only(left: row.depth * 20.0),
                        child: Row(
                          children: [
                            if (node != null)
                              IconButton(
                                tooltip: isExpanded ? '收起分组' : '展开分组',
                                onPressed: () => _toggleExpanded(node),
                                icon: isLoading
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2),
                                      )
                                    : Icon(isExpanded
                                        ? Icons.expand_more_rounded
                                        : Icons.chevron_right_rounded),
                              )
                            else
                              const SizedBox(width: 48),
                            Checkbox(
                              value: _selected.containsKey(id),
                              onChanged: selectedCount >= 4 &&
                                      !_selected.containsKey(id)
                                  ? null
                                  : (selected) =>
                                      _toggle(candidate, selected ?? false),
                            ),
                            _CandidateArtwork(candidate: candidate),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(candidate.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis),
                                  Text(_candidateKindLabel(candidate.kind),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('已选 $selectedCount / 4'),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: selectedCount == 0
                    ? null
                    : () => Navigator.of(context).pop(
                          _selected.values
                              .map((candidate) => candidate.toPreviewTile())
                              .toList(growable: false),
                        ),
                child: const Text('保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PreviewTreeChildren {
  const _PreviewTreeChildren({
    required this.nodes,
    required this.entities,
    required this.hasMoreEntities,
  });

  final List<IndexNode> nodes;
  final List<EntityListItem> entities;
  final bool hasMoreEntities;
}

class _PreviewTreeRow {
  const _PreviewTreeRow._({
    required this.depth,
    this.node,
    this.entity,
    this.loadMoreNodeId,
  });

  const _PreviewTreeRow.node({required IndexNode node, required int depth})
      : this._(depth: depth, node: node);

  const _PreviewTreeRow.entity({
    required EntityListItem entity,
    required int depth,
  }) : this._(depth: depth, entity: entity);

  const _PreviewTreeRow.loadMore({
    required String nodeId,
    required int depth,
  }) : this._(depth: depth, loadMoreNodeId: nodeId);

  final int depth;
  final IndexNode? node;
  final EntityListItem? entity;
  final String? loadMoreNodeId;
}

class _CandidateArtwork extends StatelessWidget {
  const _CandidateArtwork({required this.candidate});

  final NodePreviewCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final path = candidate.thumbnailPath;
    if (path != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: ColoredBox(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: Image.file(
            File(path),
            width: 40,
            height: 40,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _fallback(context),
          ),
        ),
      );
    }
    return _fallback(context);
  }

  Widget _fallback(BuildContext context) => SizedBox(
        width: 40,
        height: 40,
        child: Icon(switch (candidate.kind) {
          IndexNodePreviewTileKind.audio => Icons.graphic_eq_rounded,
          IndexNodePreviewTileKind.document => Icons.article_outlined,
          IndexNodePreviewTileKind.visual => Icons.image_outlined,
          _ => Icons.account_tree_outlined,
        }),
      );
}

String _candidateKindLabel(IndexNodePreviewTileKind kind) => switch (kind) {
      IndexNodePreviewTileKind.visual => '图片或视频',
      IndexNodePreviewTileKind.audio => '音频',
      IndexNodePreviewTileKind.document => '文档',
      IndexNodePreviewTileKind.mixedData => '数据',
      IndexNodePreviewTileKind.node => '下级分组',
    };
