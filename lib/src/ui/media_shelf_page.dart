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
    required this.onThumbnailNeeded,
    this.onImmersiveChanged,
  });

  final MediaShelfKind kind;
  final LibraryRepository repository;
  final ValueChanged<EntityListItem> onOpenEntity;
  final ValueChanged<EntityListItem> onThumbnailNeeded;
  final ValueChanged<bool>? onImmersiveChanged;

  @override
  State<MediaShelfPage> createState() => _MediaShelfPageState();
}

class _MediaShelfPageState extends State<MediaShelfPage> {
  List<EntityListItem> _items = const [];
  bool _immersive = false;

  bool get _supportsImmersive =>
      widget.kind == MediaShelfKind.video ||
      widget.kind == MediaShelfKind.gallery;

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
      if (_immersive) {
        _immersive = false;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => widget.onImmersiveChanged?.call(false),
        );
      }
      _reload();
    }
  }

  void _toggleImmersive() {
    if (!_supportsImmersive) return;
    final next = !_immersive;
    setState(() => _immersive = next);
    widget.onImmersiveChanged?.call(next);
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
    return Stack(
      children: [
        CustomScrollView(
          slivers: [
            if (!_immersive)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 16, 12, 10),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      Text(_title,
                          style: Theme.of(context).textTheme.titleLarge),
                      const Spacer(),
                      if (_supportsImmersive)
                        IconButton(
                          tooltip: '沉浸式浏览',
                          onPressed: _toggleImmersive,
                          icon: const Icon(Icons.fullscreen_rounded),
                        ),
                    ],
                  ),
                ),
              ),
            if (_items.isEmpty)
              SliverFillRemaining(
                child: Center(child: Text('暂无$_title内容')),
              )
            else ...[
              JustifiedEntityGallerySliver(
                entities: _items,
                immersive: _immersive,
                selectionMode: false,
                keyFor: (entity) => ValueKey('shelf-${entity.id}'),
                onOpenEntity: widget.onOpenEntity,
                onThumbnailNeeded: widget.onThumbnailNeeded,
                selectedEntityIds: const <String>{},
              ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 92)),
            ],
          ],
        ),
        if (_immersive)
          Positioned(
            top: 8,
            right: 8,
            child: Material(
              color:
                  Theme.of(context).colorScheme.surface.withValues(alpha: .72),
              borderRadius: BorderRadius.circular(16),
              child: IconButton(
                tooltip: '退出沉浸式浏览',
                onPressed: _toggleImmersive,
                icon: const Icon(Icons.fullscreen_exit_rounded),
              ),
            ),
          ),
      ],
    );
  }
}
