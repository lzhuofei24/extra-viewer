import 'dart:io';

import 'package:flutter/material.dart';

import '../core/database/library_repository.dart';
import '../core/domain/models.dart';

/// Database-paged picker for manually composing an index-node preview.
class NodePreviewPicker extends StatefulWidget {
  const NodePreviewPicker({
    super.key,
    required this.repository,
    required this.nodeId,
  });

  final LibraryRepository repository;
  final String nodeId;

  static Future<List<IndexNodePreviewTile>?> show(
    BuildContext context, {
    required LibraryRepository repository,
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

  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  final _items = <NodePreviewCandidate>[];
  final _selected = <String, NodePreviewCandidate>{};
  var _hasMore = true;
  var _loading = false;
  var _query = '';
  var _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_loadMoreOnScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPage(reset: true));
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_loadMoreOnScroll)
      ..dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _loadMoreOnScroll() {
    if (_scrollController.position.extentAfter < 240) _loadPage();
  }

  Future<void> _loadPage({bool reset = false}) async {
    if (!reset && (_loading || !_hasMore)) return;
    final version = ++_requestVersion;
    setState(() => _loading = true);
    // Yield so the dialog's loading frame is painted before SQLite walks a
    // large subtree for the first page.
    await Future<void>.delayed(Duration.zero);
    final page = widget.repository.listNodePreviewCandidates(
      widget.nodeId,
      query: _query,
      offset: reset ? 0 : _items.length,
      limit: _pageSize,
    );
    if (!mounted || version != _requestVersion) return;
    setState(() {
      if (reset) _items.clear();
      _items.addAll(page.items);
      _hasMore = page.hasMore;
      _loading = false;
    });
  }

  void _updateQuery(String value) {
    _query = value;
    _hasMore = true;
    _loadPage(reset: true);
  }

  String _idFor(NodePreviewCandidate candidate) =>
      candidate.entityId ?? candidate.nodeId!;

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

  @override
  Widget build(BuildContext context) {
    final selectedCount = _selected.length;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('自定义节点预览', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('可从当前节点的全部下级节点和实体中选择，最多 4 项。',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          TextField(
            controller: _searchController,
            onChanged: _updateQuery,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded),
              hintText: '筛选名称',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _items.isEmpty && _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: _items.length + (_hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == _items.length) {
                        return const Padding(
                          padding: EdgeInsets.all(12),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final candidate = _items[index];
                      final id = _idFor(candidate);
                      return CheckboxListTile(
                        dense: true,
                        value: _selected.containsKey(id),
                        onChanged:
                            selectedCount >= 4 && !_selected.containsKey(id)
                                ? null
                                : (selected) =>
                                    _toggle(candidate, selected ?? false),
                        secondary: _CandidateArtwork(candidate: candidate),
                        title: Text(candidate.title,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(_candidateKindLabel(candidate.kind)),
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

class _CandidateArtwork extends StatelessWidget {
  const _CandidateArtwork({required this.candidate});

  final NodePreviewCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final path = candidate.thumbnailPath;
    if (path != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.file(
          File(path),
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallback(context),
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
      IndexNodePreviewTileKind.node => '下级节点',
    };
