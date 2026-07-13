import 'package:flutter/material.dart';

import '../core/database/library_repository.dart';
import '../core/domain/models.dart';
import 'justified_entity_gallery.dart';

enum MediaShelfKind { video, gallery, reading }

class MediaShelfPage extends StatefulWidget {
  const MediaShelfPage({
    super.key,
    required this.kind,
    required this.repository,
    required this.onOpenEntity,
  });

  final MediaShelfKind kind;
  final LibraryRepository repository;
  final ValueChanged<EntityListItem> onOpenEntity;

  @override
  State<MediaShelfPage> createState() => _MediaShelfPageState();
}

class _MediaShelfPageState extends State<MediaShelfPage> {
  List<EntityListItem> _items = const [];

  Iterable<EntityType> get _types => switch (widget.kind) {
        MediaShelfKind.video => const [EntityType.video],
        MediaShelfKind.gallery => const [EntityType.image],
        MediaShelfKind.reading => const [EntityType.text],
      };

  String get _title => switch (widget.kind) {
        MediaShelfKind.video => '最近视频',
        MediaShelfKind.gallery => '最近图片',
        MediaShelfKind.reading => '最近阅读',
      };

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant MediaShelfPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind) {
      _reload();
    }
  }

  void _reload() {
    final items = widget.repository.listRecentOpenedEntities(
      limit: 1000,
      entityTypes: _types,
    );
    if (!mounted) return;
    setState(() => _items = items);
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 10),
          sliver: SliverToBoxAdapter(
            child: Text(_title, style: Theme.of(context).textTheme.titleLarge),
          ),
        ),
        if (_items.isEmpty)
          SliverFillRemaining(
            child: Center(child: Text('暂无$_title内容')),
          )
        else ...[
          JustifiedEntityGallerySliver(
            entities: _items,
            immersive: false,
            selectionMode: false,
            keyFor: (entity) => ValueKey('shelf-${entity.id}'),
            onOpenEntity: widget.onOpenEntity,
            selectedEntityIds: const <String>{},
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 92)),
        ],
      ],
    );
  }
}
