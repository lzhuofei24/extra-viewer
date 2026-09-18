import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../modules/library/library_access.dart';
import '../core/domain/models.dart';
import 'justified_entity_gallery.dart';
import 'app_sidebar.dart';
import 'browser_state.dart';
import 'browser_toolbar.dart';
import 'collection_grid_layout.dart';
import 'gallery_layout_settings.dart';
import 'library_widgets.dart';
import 'spanning_grid.dart';

enum MediaShelfKind { video, gallery, reading }

class MediaShelfPage extends StatefulWidget {
  const MediaShelfPage({
    super.key,
    required this.kind,
    required this.repository,
    required this.onOpenEntity,
    required this.onThumbnailNeeded,
    required this.browserState,
    required this.layoutSettings,
    required this.onSortChanged,
    required this.onDisplayModeChanged,
    required this.onGridLayoutChanged,
    this.onImmersiveChanged,
  });

  final MediaShelfKind kind;
  final LibraryAccess repository;
  final ValueChanged<EntityListItem> onOpenEntity;
  final ValueChanged<EntityListItem> onThumbnailNeeded;
  final BrowserState browserState;
  final GalleryLayoutSettings layoutSettings;
  final ValueChanged<EntitySortMode> onSortChanged;
  final ValueChanged<BrowserDisplayMode> onDisplayModeChanged;
  final ValueChanged<BrowserGridLayout> onGridLayoutChanged;
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

  Future<void> _reload() async {
    final items = (await widget.repository.listRecentOpenedEntities(
      limit: 1000,
      entityTypes: _types,
    ));
    if (!mounted) return;
    setState(() => _items = items);
  }

  List<EntityListItem> get _sortedItems {
    final items = [..._items];
    items.sort(switch (widget.browserState.sortMode) {
      EntitySortMode.nameAsc => (a, b) =>
          a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      EntitySortMode.nameDesc => (a, b) =>
          b.title.toLowerCase().compareTo(a.title.toLowerCase()),
      EntitySortMode.modifiedDesc => (a, b) =>
          b.modifiedAtMs.compareTo(a.modifiedAtMs),
      EntitySortMode.modifiedAsc => (a, b) =>
          a.modifiedAtMs.compareTo(b.modifiedAtMs),
      EntitySortMode.sizeDesc => (a, b) => b.size.compareTo(a.size),
      EntitySortMode.sizeAsc => (a, b) => a.size.compareTo(b.size),
      EntitySortMode.typeAsc => (a, b) => a.format.compareTo(b.format),
    });
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final items = _sortedItems;
    final obstruction = AppNavigationObstruction.of(context);
    final toolbarHeight =
        MediaQuery.sizeOf(context).width - obstruction.left < 600
            ? 108.0
            : 64.0;
    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.only(left: obstruction.left),
          child: Stack(
            children: [
              CustomScrollView(
                slivers: [
                  if (!_immersive)
                    SliverToBoxAdapter(
                        child: SizedBox(height: toolbarHeight + 16)),
                  if (items.isEmpty)
                    SliverFillRemaining(
                      child: Center(child: Text('暂无$_title内容')),
                    )
                  else ...[
                    _ShelfContentSliver(
                      items: items,
                      browserState: widget.browserState,
                      layoutSettings: widget.layoutSettings,
                      immersive: _immersive,
                      onOpenEntity: widget.onOpenEntity,
                      onThumbnailNeeded: widget.onThumbnailNeeded,
                    ),
                    SliverPadding(
                      padding: EdgeInsets.only(bottom: 92 + obstruction.bottom),
                    ),
                  ],
                ],
              ),
              if (_immersive)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Material(
                    color: Theme.of(context)
                        .colorScheme
                        .surface
                        .withValues(alpha: .72),
                    borderRadius: BorderRadius.circular(16),
                    child: IconButton(
                      tooltip: '退出沉浸式浏览',
                      onPressed: _toggleImmersive,
                      icon: const Icon(Icons.fullscreen_exit_rounded),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (!_immersive)
          Positioned(
            top: 8,
            left: obstruction.left + 12,
            right: 12,
            child: BrowserToolbar(
              leading: Text(
                _title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              browserState: widget.browserState,
              onSortChanged: widget.onSortChanged,
              onDisplayModeChanged: widget.onDisplayModeChanged,
              onGridLayoutChanged: widget.onGridLayoutChanged,
              onToggleImmersive: _supportsImmersive ? _toggleImmersive : null,
            ),
          ),
      ],
    );
  }
}

class _ShelfContentSliver extends StatelessWidget {
  const _ShelfContentSliver(
      {required this.items,
      required this.browserState,
      required this.layoutSettings,
      required this.immersive,
      required this.onOpenEntity,
      required this.onThumbnailNeeded});

  final List<EntityListItem> items;
  final BrowserState browserState;
  final GalleryLayoutSettings layoutSettings;
  final bool immersive;
  final ValueChanged<EntityListItem> onOpenEntity;
  final ValueChanged<EntityListItem> onThumbnailNeeded;

  @override
  Widget build(BuildContext context) {
    if (!immersive && browserState.displayMode == BrowserDisplayMode.list) {
      return _ShelfList(
          items: items,
          onOpen: onOpenEntity,
          onThumbnailNeeded: onThumbnailNeeded,
          horizontalPadding: layoutSettings.pageMargin);
    }
    return switch (browserState.gridLayout) {
      BrowserGridLayout.equalHeight => JustifiedEntityGallerySliver(
          entities: items,
          immersive: immersive,
          selectionMode: false,
          keyFor: (entity) => ValueKey('shelf-${entity.id}'),
          onOpenEntity: onOpenEntity,
          onThumbnailNeeded: onThumbnailNeeded,
          selectedEntityIds: const {},
          layoutSettings: layoutSettings),
      BrowserGridLayout.equalWidth => _ShelfMasonry(
          items: items,
          immersive: immersive,
          layout: layoutSettings,
          onOpen: onOpenEntity,
          onThumbnailNeeded: onThumbnailNeeded),
      BrowserGridLayout.adaptive => _ShelfAdaptive(
          items: items,
          immersive: immersive,
          layout: layoutSettings,
          onOpen: onOpenEntity,
          onThumbnailNeeded: onThumbnailNeeded),
      BrowserGridLayout.square => _ShelfSquare(
          items: items,
          immersive: immersive,
          layout: layoutSettings,
          onOpen: onOpenEntity,
          onThumbnailNeeded: onThumbnailNeeded),
    };
  }
}

class _ShelfMasonry extends StatelessWidget {
  const _ShelfMasonry(
      {required this.items,
      required this.immersive,
      required this.layout,
      required this.onOpen,
      required this.onThumbnailNeeded});
  final List<EntityListItem> items;
  final bool immersive;
  final GalleryLayoutSettings layout;
  final ValueChanged<EntityListItem> onOpen;
  final ValueChanged<EntityListItem> onThumbnailNeeded;

  @override
  Widget build(BuildContext context) =>
      SliverLayoutBuilder(builder: (context, constraints) {
        final gap =
            immersive ? GalleryLayoutSettings.immersiveGap : layout.cardGap;
        final margin = immersive
            ? GalleryLayoutSettings.immersiveMargin
            : layout.pageMargin;
        final grid = CollectionGridLayout.calculate(
            availableWidth: constraints.crossAxisExtent,
            horizontalPadding: margin,
            gap: gap,
            columnCount: layout.equalWidthColumns(
                isPortrait:
                    MediaQuery.orientationOf(context) == Orientation.portrait));
        return SliverPadding(
            padding: EdgeInsets.fromLTRB(margin, margin, margin, 0),
            sliver: SliverMasonryGrid.count(
                crossAxisCount: grid.columnCount,
                mainAxisSpacing: gap,
                crossAxisSpacing: gap,
                childCount: items.length,
                itemBuilder: (context, index) => _card(items[index])));
      });

  Widget _card(EntityListItem entity) => EntityCard(
      entity: entity,
      onOpen: () => onOpen(entity),
      immersive: immersive,
      cardRadius: layout.cardRadius,
      onThumbnailNeeded: () => onThumbnailNeeded(entity));
}

class _ShelfAdaptive extends StatelessWidget {
  const _ShelfAdaptive(
      {required this.items,
      required this.immersive,
      required this.layout,
      required this.onOpen,
      required this.onThumbnailNeeded});
  final List<EntityListItem> items;
  final bool immersive;
  final GalleryLayoutSettings layout;
  final ValueChanged<EntityListItem> onOpen;
  final ValueChanged<EntityListItem> onThumbnailNeeded;

  @override
  Widget build(BuildContext context) {
    final isPortrait =
        MediaQuery.orientationOf(context) == Orientation.portrait;
    return SpanningGridSliver<EntityListItem>(
      items: items,
      columnCount: layout.equalWidthColumns(isPortrait: isPortrait),
      targetRowHeight: layout.equalHeightTarget,
      crossRowMode: false,
      gap: immersive ? GalleryLayoutSettings.immersiveGap : layout.cardGap,
      horizontalPadding:
          immersive ? GalleryLayoutSettings.immersiveMargin : layout.pageMargin,
      aspectRatio: _aspectRatio,
      itemBuilder: (context, entity) => EntityCard(
          entity: entity,
          onOpen: () => onOpen(entity),
          immersive: immersive,
          cardRadius: layout.cardRadius,
          onThumbnailNeeded: () => onThumbnailNeeded(entity)),
    );
  }
}

class _ShelfSquare extends StatelessWidget {
  const _ShelfSquare(
      {required this.items,
      required this.immersive,
      required this.layout,
      required this.onOpen,
      required this.onThumbnailNeeded});
  final List<EntityListItem> items;
  final bool immersive;
  final GalleryLayoutSettings layout;
  final ValueChanged<EntityListItem> onOpen;
  final ValueChanged<EntityListItem> onThumbnailNeeded;

  @override
  Widget build(BuildContext context) =>
      SliverLayoutBuilder(builder: (context, constraints) {
        final gap =
            immersive ? GalleryLayoutSettings.immersiveGap : layout.cardGap;
        final margin = immersive
            ? GalleryLayoutSettings.immersiveMargin
            : layout.pageMargin;
        final grid = CollectionGridLayout.calculate(
            availableWidth: constraints.crossAxisExtent,
            horizontalPadding: margin,
            gap: gap,
            columnCount: layout.squareColumns(
                isPortrait:
                    MediaQuery.orientationOf(context) == Orientation.portrait));
        return SliverPadding(
            padding: EdgeInsets.fromLTRB(margin, margin, margin, 0),
            sliver: SliverGrid(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final entity = items[index];
                  return EntityCard(
                      entity: entity,
                      onOpen: () => onOpen(entity),
                      immersive: immersive,
                      cardRadius: layout.cardRadius,
                      onThumbnailNeeded: () => onThumbnailNeeded(entity));
                }, childCount: items.length),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: grid.columnCount,
                    mainAxisSpacing: gap,
                    crossAxisSpacing: gap,
                    childAspectRatio: 1)));
      });
}

class _ShelfList extends StatelessWidget {
  const _ShelfList(
      {required this.items,
      required this.onOpen,
      required this.onThumbnailNeeded,
      required this.horizontalPadding});
  final List<EntityListItem> items;
  final ValueChanged<EntityListItem> onOpen;
  final ValueChanged<EntityListItem> onThumbnailNeeded;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) => SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        sliver: SliverList.builder(
            itemCount: (items.length + 2) ~/ 3,
            itemBuilder: (context, rowIndex) {
              final start = rowIndex * 3;
              return Column(children: [
                SizedBox(
                    height: 76,
                    child: Row(children: [
                      for (var slot = 0; slot < 3; slot++)
                        Expanded(
                            child: start + slot < items.length
                                ? _ShelfListCell(
                                    entity: items[start + slot],
                                    onOpen: onOpen,
                                    onThumbnailNeeded: onThumbnailNeeded)
                                : const SizedBox.shrink()),
                    ])),
                if (start + 3 < items.length)
                  Divider(
                      height: 1,
                      color: Theme.of(context).colorScheme.outlineVariant),
              ]);
            }),
      );
}

class _ShelfListCell extends StatelessWidget {
  const _ShelfListCell(
      {required this.entity,
      required this.onOpen,
      required this.onThumbnailNeeded});
  final EntityListItem entity;
  final ValueChanged<EntityListItem> onOpen;
  final ValueChanged<EntityListItem> onThumbnailNeeded;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => onOpen(entity),
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              SizedBox.square(
                  dimension: 48,
                  child: EntityArtwork(
                      entityType: entity.entityType,
                      format: entity.format,
                      title: entity.title,
                      contentExcerpt: entity.contentExcerpt,
                      thumbnailStatus: entity.thumbnailStatus,
                      thumbnailPath: entity.thumbnailPath,
                      onThumbnailNeeded: () => onThumbnailNeeded(entity))),
              const SizedBox(width: 8),
              Expanded(
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(entity.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(entity.format.toUpperCase(),
                        style: Theme.of(context).textTheme.labelSmall),
                  ])),
            ])),
      );
}

double _aspectRatio(EntityListItem entity) {
  final width = entity.thumbnailWidth;
  final height = entity.thumbnailHeight;
  return width != null && height != null && width > 0 && height > 0
      ? width / height
      : 1;
}
