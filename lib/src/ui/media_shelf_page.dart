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
import 'recent_media_switcher.dart';
import 'browser_list.dart';
import 'design_tokens.dart';

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
    required this.onListStyleChanged,
    required this.themeChoice,
    required this.onThemeChanged,
    required this.layoutPreset,
    required this.onLayoutPresetChanged,
    required this.currentSection,
    required this.onSectionChanged,
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
  final ValueChanged<BrowserListStyle> onListStyleChanged;
  final ViewerThemeChoice themeChoice;
  final ValueChanged<ViewerThemeChoice> onThemeChanged;
  final GalleryLayoutPreset layoutPreset;
  final ValueChanged<GalleryLayoutPreset> onLayoutPresetChanged;
  final AppSection currentSection;
  final ValueChanged<AppSection> onSectionChanged;

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
      }
      _reload();
    }
  }

  void _toggleImmersive() {
    if (!_supportsImmersive) return;
    final next = !_immersive;
    setState(() => _immersive = next);
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
    final topChromeInset =
        MediaQuery.sizeOf(context).width < 600 ? 116.0 : 76.0;
    return Stack(
      children: [
        Stack(
          children: [
            CustomScrollView(
              slivers: [
                if (!_immersive)
                  SliverToBoxAdapter(
                    child: SizedBox(height: topChromeInset),
                  ),
                if (items.isEmpty)
                  const SliverFillRemaining(
                    child: Center(child: Text('暂无最近内容')),
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
                child: FloatingGlassSurface(
                  borderRadius: 24,
                  child: Material(
                    color: Colors.transparent,
                    child: IconButton(
                      tooltip: '退出沉浸式浏览',
                      onPressed: _toggleImmersive,
                      icon: const Icon(Icons.fullscreen_exit_rounded),
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (!_immersive)
          Positioned(
            top: 8,
            left: 12,
            right: 12,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: BrowserToolbar(
                  leading: RecentMediaSwitcher(
                    current: widget.currentSection,
                    onChanged: widget.onSectionChanged,
                    embedded: true,
                  ),
                  browserState: widget.browserState,
                  onSortChanged: widget.onSortChanged,
                  onDisplayModeChanged: widget.onDisplayModeChanged,
                  onGridLayoutChanged: widget.onGridLayoutChanged,
                  onListStyleChanged: widget.onListStyleChanged,
                  themeChoice: widget.themeChoice,
                  onThemeChanged: widget.onThemeChanged,
                  layoutPreset: widget.layoutPreset,
                  onLayoutPresetChanged: widget.onLayoutPresetChanged,
                  onToggleImmersive:
                      _supportsImmersive ? _toggleImmersive : null,
                ),
              ),
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
          style: browserState.listStyle,
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
      required this.horizontalPadding,
      required this.style});
  final List<EntityListItem> items;
  final ValueChanged<EntityListItem> onOpen, onThumbnailNeeded;
  final double horizontalPadding;
  final BrowserListStyle style;
  @override
  Widget build(BuildContext context) => BrowserListSliver(
      count: items.length,
      style: style,
      padding: horizontalPadding,
      itemBuilder: (context, index) {
        final entity = items[index];
        return BrowserListTile(
            style: style,
            title: entity.title,
            subtitle: entity.format.toUpperCase(),
            onTap: () => onOpen(entity),
            previewBuilder: (_) => EntityArtwork(
                entityType: entity.entityType,
                format: entity.format,
                title: entity.title,
                contentExcerpt: entity.contentExcerpt,
                thumbnailStatus: entity.thumbnailStatus,
                thumbnailPath: entity.thumbnailPath,
                onThumbnailNeeded: () => onThumbnailNeeded(entity)));
      });
}
