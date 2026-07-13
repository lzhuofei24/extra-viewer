import 'dart:math';

import 'package:flutter/material.dart';

import '../core/database/library_repository.dart';
import '../core/domain/models.dart';
import 'index_node_thumbnail.dart';

class GraphIndexPage extends StatefulWidget {
  const GraphIndexPage({
    super.key,
    required this.repository,
    required this.graphRoot,
    required this.onOpenNode,
    required this.onReturnToRootIndex,
  });

  final LibraryRepository repository;
  final IndexNode graphRoot;
  final ValueChanged<IndexNode> onOpenNode;
  final VoidCallback onReturnToRootIndex;

  @override
  State<GraphIndexPage> createState() => _GraphIndexPageState();
}

class _GraphIndexPageState extends State<GraphIndexPage> {
  static const _nodeSize = Size(168, 126);
  List<IndexNode> _nodes = const [];
  List<IndexNodeEdge> _edges = const [];
  Map<String, Offset> _positions = const {};
  Map<String, IndexNodePreview> _previews = const {};
  Map<String, IndexNodeSummary> _summaries = const {};
  String? _selectedId;
  bool _linkMode = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final nodes = widget.repository.listGraphNodes(widget.graphRoot.id);
    final saved = widget.repository.listGraphNodePositions(widget.graphRoot.id);
    final positions = <String, Offset>{
      for (var index = 0; index < nodes.length; index++)
        nodes[index].id: saved[nodes[index].id] == null
            ? _defaultPosition(index)
            : Offset(saved[nodes[index].id]!.x, saved[nodes[index].id]!.y),
    };
    setState(() {
      _nodes = nodes;
      _edges = widget.repository.listGraphEdges(widget.graphRoot.id);
      _positions = positions;
      _previews = widget.repository.listIndexNodePreviews(
        nodes.map((node) => node.id),
      );
      _summaries = widget.repository.listIndexNodeSummaries(
        nodes.map((node) => node.id),
      );
    });
  }

  Offset _defaultPosition(int index) {
    const columns = 4;
    return Offset(
        80.0 + (index % columns) * 250, 100.0 + (index ~/ columns) * 190);
  }

  Future<void> _createNode() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_selectedId == null ? '新建图节点' : '新建下级图节点'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '节点名称'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('创建')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    final node = widget.repository.ensureGraphNode(
      parentId: _selectedId ?? widget.graphRoot.id,
      name: name.trim(),
      sortOrder: _nodes.length,
    );
    final parentPosition =
        _selectedId == null ? null : _positions[_selectedId!];
    final position = parentPosition == null
        ? _defaultPosition(_nodes.length)
        : parentPosition + const Offset(230, 0);
    widget.repository
        .setGraphNodePosition(nodeId: node.id, x: position.dx, y: position.dy);
    _reload();
  }

  Future<void> _attachEntities(IndexNode node) async {
    final selectedIds = await showDialog<Set<String>>(
      context: context,
      builder: (context) => _GraphEntityPicker(repository: widget.repository),
    );
    if (selectedIds == null || selectedIds.isEmpty) return;
    widget.repository.linkEntitiesToIndexNode(
      entityIds: selectedIds,
      indexNodeId: node.id,
    );
    _reload();
  }

  Future<void> _deleteSelectedNode() async {
    final nodeId = _selectedId;
    if (nodeId == null) return;
    final node = _nodes.where((item) => item.id == nodeId).firstOrNull;
    if (node == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除图节点'),
        content: Text(
          '将递归删除“${node.name}”及其下级图节点、位置、连线和实体引用。\n\n实体记录和真实文件不会删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    widget.repository.deleteIndexNode(nodeId);
    setState(() {
      _selectedId = null;
      _linkMode = false;
    });
    _reload();
  }

  void _selectNode(IndexNode node) {
    final sourceId = _selectedId;
    if (_linkMode && sourceId != null && sourceId != node.id) {
      widget.repository.linkIndexNodes(fromNodeId: sourceId, toNodeId: node.id);
      setState(() {
        _linkMode = false;
        _selectedId = node.id;
      });
      _reload();
      return;
    }
    setState(() => _selectedId = node.id);
  }

  void _updatePosition(IndexNode node, Offset delta) {
    final next = _positions[node.id]! + delta;
    setState(() => _positions = {..._positions, node.id: next});
  }

  void _savePosition(IndexNode node) {
    final position = _positions[node.id]!;
    widget.repository
        .setGraphNodePosition(nodeId: node.id, x: position.dx, y: position.dy);
  }

  @override
  Widget build(BuildContext context) {
    IndexNode? selected;
    for (final node in _nodes) {
      if (node.id == _selectedId) {
        selected = node;
        break;
      }
    }
    final theme = Theme.of(context);
    final selectedChildren = selected == null
        ? const <IndexNode>[]
        : _nodes.where((node) => node.parentId == selected!.id).toList();
    final selectedEntities = selected == null
        ? const <EntityListItem>[]
        : widget.repository.listEntitiesDirectlyUnderNode(selected.id);
    return Stack(
      children: [
        InteractiveViewer(
          constrained: false,
          boundaryMargin: const EdgeInsets.all(280),
          minScale: .35,
          maxScale: 2.5,
          child: SizedBox(
            width: 1600,
            height: 1100,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _GraphEdgePainter(
                        edges: _edges,
                        positions: _positions,
                        nodeSize: _nodeSize,
                        color: theme.colorScheme.outlineVariant),
                  ),
                ),
                for (final node in _nodes)
                  Positioned(
                    left: _positions[node.id]!.dx,
                    top: _positions[node.id]!.dy,
                    width: _nodeSize.width,
                    height: _nodeSize.height,
                    child: GestureDetector(
                      onTap: () => _selectNode(node),
                      onDoubleTap: () => widget.onOpenNode(node),
                      onPanUpdate: (details) =>
                          _updatePosition(node, details.delta),
                      onPanEnd: (_) => _savePosition(node),
                      child: _GraphNodeCard(
                        node: node,
                        preview: _previews[node.id],
                        summary: _summaries[node.id],
                        selected: node.id == _selectedId,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 14,
          top: 12,
          child: Wrap(
            spacing: 8,
            children: [
              IconButton(
                tooltip: '返回根索引',
                onPressed: widget.onReturnToRootIndex,
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              FilledButton.icon(
                  onPressed: _createNode,
                  icon: const Icon(Icons.add),
                  label: const Text('图节点')),
              OutlinedButton.icon(
                onPressed: _selectedId == null
                    ? null
                    : () => setState(() => _linkMode = !_linkMode),
                icon: Icon(_linkMode
                    ? Icons.link_off_rounded
                    : Icons.add_link_rounded),
                label: Text(_linkMode ? '取消连线' : '创建连线'),
              ),
            ],
          ),
        ),
        if (selected != null)
          Positioned(
            right: 14,
            top: 12,
            width: 260,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(selected.name, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _createNode,
                          icon: const Icon(Icons.account_tree_outlined),
                          label: const Text('下级节点'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => widget.onOpenNode(selected!),
                          icon: const Icon(Icons.open_in_new_rounded),
                          label: const Text('进入节点'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _attachEntities(selected!),
                          icon: const Icon(Icons.attach_file_rounded),
                          label: const Text('添加实体'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _deleteSelectedNode,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: theme.colorScheme.error,
                          ),
                          icon: const Icon(Icons.delete_outline_rounded),
                          label: const Text('删除节点'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                        '出边 ${_edges.where((edge) => edge.fromNodeId == selected!.id).length}'),
                    Text(
                        '入边 ${_edges.where((edge) => edge.toNodeId == selected!.id).length}'),
                    const SizedBox(height: 10),
                    Text(
                        '直接内容 ${selectedChildren.length} 个节点 | ${selectedEntities.length} 个实体'),
                    if (selectedChildren.isNotEmpty ||
                        selectedEntities.isNotEmpty)
                      const SizedBox(height: 6),
                    for (final child in selectedChildren.take(3))
                      Text('节点: ${child.name}',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    for (final entity in selectedEntities.take(4))
                      Text('实体: ${entity.title}',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (selectedChildren.length + selectedEntities.length > 7)
                      const Text('...'),
                    const SizedBox(height: 10),
                    const Text('拖拽节点调整位置；选择“创建连线”后点击目标节点。'),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _GraphNodeCard extends StatelessWidget {
  const _GraphNodeCard(
      {required this.node,
      required this.preview,
      required this.summary,
      required this.selected});
  final IndexNode node;
  final IndexNodePreview? preview;
  final IndexNodeSummary? summary;
  final bool selected;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outlineVariant,
              width: selected ? 2 : 1),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(
            fit: StackFit.expand,
            children: [
              IndexNodeThumbnail(
                preview: preview,
                nodeName: node.name,
                hasContent: (summary?.childNodeCount ?? 0) > 0 ||
                    (summary?.directEntityCount ?? 0) > 0,
              ),
              if (summary != null &&
                  (summary!.childNodeCount > 0 ||
                      summary!.directEntityCount > 0))
                Positioned(
                  top: 6,
                  right: 6,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .5),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      child: Text(
                        '${summary!.childNodeCount} | ${summary!.directEntityCount}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(7),
                  color: Colors.black.withValues(alpha: .55),
                  child: Text(node.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center),
                ),
              ),
            ],
          ),
        ),
      );
}

class _GraphEdgePainter extends CustomPainter {
  const _GraphEdgePainter(
      {required this.edges,
      required this.positions,
      required this.nodeSize,
      required this.color});
  final List<IndexNodeEdge> edges;
  final Map<String, Offset> positions;
  final Size nodeSize;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final lanes = _edgeLanes();
    for (final edge in edges) {
      final from = positions[edge.fromNodeId];
      final to = positions[edge.toNodeId];
      if (from == null || to == null) continue;
      final geometry = _GraphCurve.fromNodes(
        from: from,
        to: to,
        nodeSize: nodeSize,
        lane: lanes[edge.id] ?? 0,
      );
      final path = Path()
        ..moveTo(geometry.start.dx, geometry.start.dy)
        ..cubicTo(
          geometry.control1.dx,
          geometry.control1.dy,
          geometry.control2.dx,
          geometry.control2.dy,
          geometry.end.dx,
          geometry.end.dy,
        );
      canvas.drawPath(path, paint);
      final tangent = geometry.end - geometry.control2;
      final angle = tangent.direction;
      final arrow = Path()
        ..moveTo(geometry.end.dx, geometry.end.dy)
        ..lineTo(
          geometry.end.dx - 10 * cos(angle - .48),
          geometry.end.dy - 10 * sin(angle - .48),
        )
        ..lineTo(
          geometry.end.dx - 10 * cos(angle + .48),
          geometry.end.dy - 10 * sin(angle + .48),
        )
        ..close();
      canvas.drawPath(arrow, paint..style = PaintingStyle.fill);
      paint.style = PaintingStyle.stroke;
    }
  }

  Map<String, double> _edgeLanes() {
    final groups = <String, List<IndexNodeEdge>>{};
    for (final edge in edges) {
      final pair = [edge.fromNodeId, edge.toNodeId]..sort();
      groups.putIfAbsent(pair.join('|'), () => []).add(edge);
    }
    final result = <String, double>{};
    for (final group in groups.values) {
      for (var index = 0; index < group.length; index++) {
        result[group[index].id] = (index - (group.length - 1) / 2) * 22;
      }
    }
    return result;
  }

  @override
  bool shouldRepaint(covariant _GraphEdgePainter old) =>
      old.edges != edges || old.positions != positions || old.color != color;
}

class _GraphCurve {
  const _GraphCurve({
    required this.start,
    required this.control1,
    required this.control2,
    required this.end,
  });

  final Offset start;
  final Offset control1;
  final Offset control2;
  final Offset end;

  factory _GraphCurve.fromNodes({
    required Offset from,
    required Offset to,
    required Size nodeSize,
    required double lane,
  }) {
    final fromCenter = from + Offset(nodeSize.width / 2, nodeSize.height / 2);
    final toCenter = to + Offset(nodeSize.width / 2, nodeSize.height / 2);
    final delta = toCenter - fromCenter;
    final horizontal = delta.dx.abs() >= delta.dy.abs();
    final direction = horizontal
        ? Offset(delta.dx.sign == 0 ? 1 : delta.dx.sign, 0)
        : Offset(0, delta.dy.sign == 0 ? 1 : delta.dy.sign);
    final start = fromCenter +
        Offset(direction.dx * nodeSize.width / 2,
            direction.dy * nodeSize.height / 2);
    final end = toCenter -
        Offset(direction.dx * nodeSize.width / 2,
            direction.dy * nodeSize.height / 2);
    final distance = (end - start).distance;
    final handle = (distance * .42).clamp(44, 170).toDouble();
    final normal = Offset(-direction.dy, direction.dx) * lane;
    return _GraphCurve(
      start: start,
      control1: start + direction * handle + normal,
      control2: end - direction * handle + normal,
      end: end,
    );
  }
}

class _GraphEntityPicker extends StatefulWidget {
  const _GraphEntityPicker({required this.repository});

  final LibraryRepository repository;

  @override
  State<_GraphEntityPicker> createState() => _GraphEntityPickerState();
}

class _GraphEntityPickerState extends State<_GraphEntityPicker> {
  final _queryController = TextEditingController();
  final Set<String> _selectedIds = <String>{};

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _queryController.text.trim().toLowerCase();
    final items = widget.repository.listEntitiesForNodeLinkPicker(
      query: query,
    );
    return AlertDialog(
      title: const Text('添加实体到图节点'),
      content: SizedBox(
        width: 620,
        height: 480,
        child: Column(
          children: [
            TextField(
              controller: _queryController,
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.filter_list_rounded),
                hintText: '按名称筛选',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return CheckboxListTile(
                    dense: true,
                    value: _selectedIds.contains(item.id),
                    title: Text(item.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(item.format),
                    onChanged: (selected) => setState(() {
                      if (selected ?? false) {
                        _selectedIds.add(item.id);
                      } else {
                        _selectedIds.remove(item.id);
                      }
                    }),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selectedIds),
          child: Text('加入 ${_selectedIds.length} 项'),
        ),
      ],
    );
  }
}
