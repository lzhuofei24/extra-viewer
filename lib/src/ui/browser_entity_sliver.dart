import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../core/domain/models.dart';
import '../modules/browser/thumbnail_warmup.dart';
import 'browser_state.dart';
import 'browser_list.dart';
import 'collection_grid_layout.dart';
import 'gallery_layout_settings.dart';
import 'justified_entity_gallery.dart';
import 'library_widgets.dart';

class BrowserEntitySliver extends StatelessWidget {
  const BrowserEntitySliver(
      {super.key,
      required this.entities,
      required this.browserState,
      required this.layoutSettings,
      required this.immersive,
      required this.selectionMode,
      required this.selectionRegistry,
      required this.selectedEntityIds,
      required this.onOpenEntity,
      required this.onShowEntityMenu,
      required this.onThumbnailNeeded,
      required this.onToggleEntitySelection,
      required this.onStartEntitySelection});
  final List<EntityListItem> entities;
  final BrowserState browserState;
  final GalleryLayoutSettings layoutSettings;
  final bool immersive, selectionMode;
  final BrowserSelectionRegistry selectionRegistry;
  final Set<String> selectedEntityIds;
  final ValueChanged<EntityListItem> onOpenEntity,
      onShowEntityMenu,
      onThumbnailNeeded,
      onToggleEntitySelection,
      onStartEntitySelection;
  @override
  Widget build(BuildContext context) =>
      immersive || browserState.displayMode == BrowserDisplayMode.grid
          ? switch (browserState.gridLayout) {
              BrowserGridLayout.equalHeight => _EntityGridSliver(
                  entities: entities,
                  immersive: immersive,
                  selectedEntityIds: selectedEntityIds,
                  selectionMode: selectionMode,
                  selectionRegistry: selectionRegistry,
                  onOpenEntity: onOpenEntity,
                  onShowEntityMenu: onShowEntityMenu,
                  onThumbnailNeeded: onThumbnailNeeded,
                  onToggleEntitySelection: onToggleEntitySelection,
                  onStartEntitySelection: onStartEntitySelection,
                  layoutSettings: layoutSettings,
                ),
              BrowserGridLayout.equalWidth => _EntityMasonryGridSliver(
                  entities: entities,
                  immersive: immersive,
                  selectedEntityIds: selectedEntityIds,
                  selectionMode: selectionMode,
                  selectionRegistry: selectionRegistry,
                  onOpenEntity: onOpenEntity,
                  onShowEntityMenu: onShowEntityMenu,
                  onThumbnailNeeded: onThumbnailNeeded,
                  onToggleEntitySelection: onToggleEntitySelection,
                  onStartEntitySelection: onStartEntitySelection,
                  layoutSettings: layoutSettings,
                ),
              BrowserGridLayout.square => _SquareEntityGridSliver(
                  entities: entities,
                  immersive: immersive,
                  selectionMode: selectionMode,
                  selectionRegistry: selectionRegistry,
                  onOpenEntity: onOpenEntity,
                  onShowEntityMenu: onShowEntityMenu,
                  onThumbnailNeeded: onThumbnailNeeded,
                  selectedEntityIds: selectedEntityIds,
                  onToggleEntitySelection: onToggleEntitySelection,
                  onStartEntitySelection: onStartEntitySelection,
                  layoutSettings: layoutSettings),
            }
          : _EntityListSliver(
              style: browserState.listStyle,
              entities: entities,
              selectedEntityIds: selectedEntityIds,
              selectionMode: selectionMode,
              onOpenEntity: onOpenEntity,
              onShowEntityMenu: onShowEntityMenu,
              onThumbnailNeeded: onThumbnailNeeded,
              onToggleEntitySelection: onToggleEntitySelection,
              onStartEntitySelection: onStartEntitySelection,
              horizontalPadding: layoutSettings.pageMargin,
            );
}

class BrowserScrollShell extends StatefulWidget {
  const BrowserScrollShell({
    super.key,
    required this.warmupEnabled,
    required this.preloadScopeKey,
    required this.entities,
    required this.hasMore,
    required this.onLoadMore,
    required this.selectionMode,
    required this.onSelectEntitiesByDrag,
    required this.child,
  });

  final String preloadScopeKey;
  final bool warmupEnabled;
  final List<EntityListItem> entities;
  final bool hasMore;
  final VoidCallback onLoadMore;
  final bool selectionMode;
  final ValueChanged<Iterable<EntityListItem>> onSelectEntitiesByDrag;
  final Widget Function(
    ScrollController controller,
    BrowserSelectionRegistry selectionRegistry,
  ) child;

  @override
  State<BrowserScrollShell> createState() => BrowserScrollShellState();
}

class BrowserScrollShellState extends State<BrowserScrollShell> {
  final ScrollController _scrollController = ScrollController();
  final Map<String, int> _warmPaths = {};
  Map<String, int> _entityPositions = {};
  Timer? _warmTimer;
  bool _warmRunning = false;
  String _activePreloadScope = '';
  int _thumbnailPreloadGeneration = 0;
  final BrowserSelectionRegistry _selectionRegistry =
      BrowserSelectionRegistry();
  final Map<int, Map<String, EntityListItem>> _dragEntitiesByPointer =
      <int, Map<String, EntityListItem>>{};
  final Set<int> _activeDragPointers = <int>{};
  final Map<int, Offset> _pointerOrigins = {};

  @override
  void initState() {
    super.initState();
    _activePreloadScope = widget.preloadScopeKey;
    _indexEntities();
    _scrollController.addListener(_handleScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleWarmup());
  }

  @override
  void didUpdateWidget(covariant BrowserScrollShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.entities, oldWidget.entities)) _indexEntities();
    if (widget.preloadScopeKey == _activePreloadScope) {
      _scheduleWarmup();
      return;
    }
    _activePreloadScope = widget.preloadScopeKey;
    _thumbnailPreloadGeneration++;
    _clearWarmup();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleWarmup());
  }

  @override
  void dispose() {
    _thumbnailPreloadGeneration++;
    _warmTimer?.cancel();
    _clearWarmup();
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _handleScroll() {
    _scheduleWarmup();
    if (!_scrollController.hasClients) return;
    if (widget.hasMore && _scrollController.position.extentAfter < 640) {
      widget.onLoadMore();
    }
  }

  void _beginPointerSelection(PointerDownEvent event) {
    if (!widget.selectionMode) return;
    final entity = _selectionRegistry.entityAt(event.position);
    if (entity == null) return;
    _dragEntitiesByPointer[event.pointer] = {entity.id: entity};
    _pointerOrigins[event.pointer] = event.position;
  }

  void _extendPointerSelection(PointerMoveEvent event) {
    if (!widget.selectionMode) return;
    final dragged = _dragEntitiesByPointer[event.pointer];
    if (dragged == null) return;
    // Touch jitter still belongs to the child's tap gesture, not drag selection.
    if (!_activeDragPointers.contains(event.pointer) &&
        (event.position - _pointerOrigins[event.pointer]!).distance <=
            computeHitSlop(event.kind, MediaQuery.gestureSettingsOf(context))) {
      return;
    }
    final entity = _selectionRegistry.entityAt(event.position);
    if (entity == null) return;
    if (_activeDragPointers.add(event.pointer)) {
      dragged[entity.id] = entity;
      widget.onSelectEntitiesByDrag(dragged.values);
      return;
    }
    if (dragged.containsKey(entity.id)) return;
    dragged[entity.id] = entity;
    widget.onSelectEntitiesByDrag([entity]);
  }

  void _indexEntities() {
    _entityPositions = {
      for (var i = 0; i < widget.entities.length; i++) widget.entities[i].id: i,
    };
  }

  void _clearWarmup() {
    for (final path in _warmPaths.keys) {
      PaintingBinding.instance.imageCache.evict(FileImage(File(path)));
    }
    _warmPaths.clear();
  }

  void _scheduleWarmup() {
    if (!mounted) return;
    _thumbnailPreloadGeneration++;
    _warmTimer?.cancel();
    _warmTimer = Timer(const Duration(milliseconds: 150), () {
      unawaited(_warmVisibleNeighbors(_thumbnailPreloadGeneration));
    });
  }

  Future<void> _warmVisibleNeighbors(int generation) async {
    if (!widget.warmupEnabled) return;
    if (_warmRunning) return;
    _warmRunning = true;
    try {
      await _performWarmup(generation);
    } finally {
      _warmRunning = false;
      if (mounted && generation != _thumbnailPreloadGeneration) {
        _scheduleWarmup();
      }
    }
  }

  Future<void> _performWarmup(int generation) async {
    if (!mounted || generation != _thumbnailPreloadGeneration) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    final viewport = box.localToGlobal(Offset.zero) & box.size;
    final visible = _selectionRegistry.entitiesIn(viewport).toList();
    final positions = visible
        .map((e) => _entityPositions[e.id])
        .whereType<int>()
        .toList()
      ..sort();
    final visiblePaths = visible.map((e) => e.thumbnailPath).toSet();
    // Once displayed, an image belongs to the normal LRU cache, not preheating.
    _warmPaths.removeWhere((path, _) => visiblePaths.contains(path));
    final candidates = positions.isEmpty
        ? const <EntityListItem>[]
        : thumbnailWarmupWindow(widget.entities,
            firstVisible: positions.first,
            lastVisible: positions.last,
            cacheBytes: PaintingBinding.instance.imageCache.maximumSizeBytes);
    final nextPaths = candidates.map((e) => e.thumbnailPath).toSet();
    for (final path in _warmPaths.keys.toList()) {
      if (!nextPaths.contains(path)) {
        PaintingBinding.instance.imageCache.evict(FileImage(File(path)));
        _warmPaths.remove(path);
      }
    }
    for (final entity in candidates) {
      if (!mounted || generation != _thumbnailPreloadGeneration) return;
      final path = entity.thumbnailPath!;
      if (_warmPaths.containsKey(path)) continue;
      final provider = FileImage(File(path));
      final status = PaintingBinding.instance.imageCache.statusForKey(provider);
      if (status.keepAlive || status.live || status.pending) continue;
      _warmPaths[path] = thumbnailDecodedBytes(entity);
      await precacheImage(provider, context, onError: (_, __) {});
      if (!mounted || generation != _thumbnailPreloadGeneration) {
        PaintingBinding.instance.imageCache.evict(provider);
        _warmPaths.remove(path);
        return;
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _beginPointerSelection,
        onPointerMove: _extendPointerSelection,
        onPointerUp: (event) {
          _pointerOrigins.remove(event.pointer);
          _dragEntitiesByPointer.remove(event.pointer);
          _activeDragPointers.remove(event.pointer);
        },
        onPointerCancel: (event) {
          _pointerOrigins.remove(event.pointer);
          _dragEntitiesByPointer.remove(event.pointer);
          _activeDragPointers.remove(event.pointer);
        },
        child: widget.child(_scrollController, _selectionRegistry),
      );
}

class BrowserSelectionRegistry {
  final Map<String, GlobalKey> _keys = <String, GlobalKey>{};
  final Map<String, EntityListItem> _entities = <String, EntityListItem>{};

  GlobalKey keyFor(EntityListItem entity) {
    _entities[entity.id] = entity;
    return _keys.putIfAbsent(entity.id, GlobalKey.new);
  }

  Iterable<EntityListItem> entitiesIn(Rect viewport) sync* {
    for (final id in _keys.keys.toList()) {
      final context = _keys[id]!.currentContext;
      if (context == null) {
        _keys.remove(id);
        _entities.remove(id);
        continue;
      }
      final box = context.findRenderObject();
      if (box is RenderBox &&
          box.attached &&
          viewport.overlaps(box.localToGlobal(Offset.zero) & box.size)) {
        yield _entities[id]!;
      }
    }
  }

  EntityListItem? entityAt(Offset globalPosition) {
    for (final entry in _keys.entries) {
      final renderObject = entry.value.currentContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.attached) continue;
      final origin = renderObject.localToGlobal(Offset.zero);
      if ((origin & renderObject.size).contains(globalPosition)) {
        return _entities[entry.key];
      }
    }
    return null;
  }
}

class _EntityGridSliver extends StatelessWidget {
  const _EntityGridSliver({
    required this.entities,
    required this.immersive,
    required this.selectionMode,
    required this.selectionRegistry,
    required this.onOpenEntity,
    required this.onShowEntityMenu,
    required this.onThumbnailNeeded,
    required this.selectedEntityIds,
    required this.onToggleEntitySelection,
    required this.onStartEntitySelection,
    required this.layoutSettings,
  });

  final List<EntityListItem> entities;
  final bool immersive;
  final bool selectionMode;
  final BrowserSelectionRegistry selectionRegistry;
  final ValueChanged<EntityListItem> onOpenEntity;
  final ValueChanged<EntityListItem> onShowEntityMenu;
  final ValueChanged<EntityListItem> onThumbnailNeeded;
  final Set<String> selectedEntityIds;
  final ValueChanged<EntityListItem> onToggleEntitySelection;
  final ValueChanged<EntityListItem> onStartEntitySelection;
  final GalleryLayoutSettings layoutSettings;

  @override
  Widget build(BuildContext context) {
    return JustifiedEntityGallerySliver(
      entities: entities,
      immersive: immersive,
      selectionMode: selectionMode,
      keyFor: selectionRegistry.keyFor,
      onOpenEntity: onOpenEntity,
      onShowEntityMenu: onShowEntityMenu,
      onThumbnailNeeded: onThumbnailNeeded,
      selectedEntityIds: selectedEntityIds,
      layoutSettings: layoutSettings,
      onToggleEntitySelection: onToggleEntitySelection,
      onStartEntitySelection: onStartEntitySelection,
    );
  }
}

class _EntityMasonryGridSliver extends StatelessWidget {
  const _EntityMasonryGridSliver({
    required this.entities,
    required this.immersive,
    required this.selectionMode,
    required this.selectionRegistry,
    required this.onOpenEntity,
    required this.onShowEntityMenu,
    required this.onThumbnailNeeded,
    required this.selectedEntityIds,
    required this.onToggleEntitySelection,
    required this.onStartEntitySelection,
    required this.layoutSettings,
  });

  final List<EntityListItem> entities;
  final bool immersive;
  final bool selectionMode;
  final BrowserSelectionRegistry selectionRegistry;
  final ValueChanged<EntityListItem> onOpenEntity;
  final ValueChanged<EntityListItem> onShowEntityMenu;
  final ValueChanged<EntityListItem> onThumbnailNeeded;
  final Set<String> selectedEntityIds;
  final ValueChanged<EntityListItem> onToggleEntitySelection;
  final ValueChanged<EntityListItem> onStartEntitySelection;
  final GalleryLayoutSettings layoutSettings;

  @override
  Widget build(BuildContext context) {
    final gap =
        immersive ? GalleryLayoutSettings.immersiveGap : layoutSettings.cardGap;
    final margin = immersive
        ? GalleryLayoutSettings.immersiveMargin
        : layoutSettings.pageMargin;
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final layout = CollectionGridLayout.calculate(
          availableWidth: constraints.crossAxisExtent,
          horizontalPadding: margin,
          gap: gap,
          columnCount: layoutSettings.equalWidthColumns(
            isPortrait:
                MediaQuery.orientationOf(context) == Orientation.portrait,
          ),
        );
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(
            margin,
            immersive ? GalleryLayoutSettings.immersiveMargin : margin,
            margin,
            0,
          ),
          sliver: SliverMasonryGrid.count(
            crossAxisCount: layout.columnCount,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
            childCount: entities.length,
            itemBuilder: (context, index) => EntityCard(
              key: selectionRegistry.keyFor(entities[index]),
              entity: entities[index],
              onOpen: () => onOpenEntity(entities[index]),
              selected: selectedEntityIds.contains(entities[index].id),
              immersive: immersive,
              cardRadius: layoutSettings.cardRadius,
              selectionMode: selectionMode,
              onToggleSelection: () => onToggleEntitySelection(entities[index]),
              onShowMenu: () => onShowEntityMenu(entities[index]),
              onThumbnailNeeded: () => onThumbnailNeeded(entities[index]),
              onStartSelection: () => onStartEntitySelection(entities[index]),
            ),
          ),
        );
      },
    );
  }
}

class _SquareEntityGridSliver extends StatelessWidget {
  const _SquareEntityGridSliver(
      {required this.entities,
      required this.immersive,
      required this.selectionMode,
      required this.selectionRegistry,
      required this.onOpenEntity,
      required this.onShowEntityMenu,
      required this.onThumbnailNeeded,
      required this.selectedEntityIds,
      required this.onToggleEntitySelection,
      required this.onStartEntitySelection,
      required this.layoutSettings});
  final List<EntityListItem> entities;
  final bool immersive;
  final bool selectionMode;
  final BrowserSelectionRegistry selectionRegistry;
  final ValueChanged<EntityListItem> onOpenEntity;
  final ValueChanged<EntityListItem> onShowEntityMenu;
  final ValueChanged<EntityListItem> onThumbnailNeeded;
  final Set<String> selectedEntityIds;
  final ValueChanged<EntityListItem> onToggleEntitySelection;
  final ValueChanged<EntityListItem> onStartEntitySelection;
  final GalleryLayoutSettings layoutSettings;
  @override
  Widget build(BuildContext context) =>
      SliverLayoutBuilder(builder: (context, constraints) {
        final gap = immersive
            ? GalleryLayoutSettings.immersiveGap
            : layoutSettings.cardGap;
        final margin = immersive
            ? GalleryLayoutSettings.immersiveMargin
            : layoutSettings.pageMargin;
        final layout = CollectionGridLayout.calculate(
            availableWidth: constraints.crossAxisExtent,
            horizontalPadding: margin,
            gap: gap,
            columnCount: layoutSettings.squareColumns(
                isPortrait:
                    MediaQuery.orientationOf(context) == Orientation.portrait));
        return SliverPadding(
            padding: EdgeInsets.fromLTRB(margin, margin, margin, 0),
            sliver: SliverGrid(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final entity = entities[index];
                  return EntityCard(
                      key: selectionRegistry.keyFor(entity),
                      entity: entity,
                      onOpen: () => onOpenEntity(entity),
                      selected: selectedEntityIds.contains(entity.id),
                      immersive: immersive,
                      cardRadius: layoutSettings.cardRadius,
                      selectionMode: selectionMode,
                      onToggleSelection: () => onToggleEntitySelection(entity),
                      onShowMenu: () => onShowEntityMenu(entity),
                      onThumbnailNeeded: () => onThumbnailNeeded(entity),
                      onStartSelection: () => onStartEntitySelection(entity));
                }, childCount: entities.length),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: layout.columnCount,
                    mainAxisSpacing: gap,
                    crossAxisSpacing: gap,
                    childAspectRatio: 1)));
      });
}

class _EntityListSliver extends StatelessWidget {
  const _EntityListSliver(
      {required this.entities,
      required this.style,
      required this.selectionMode,
      required this.onOpenEntity,
      required this.onShowEntityMenu,
      required this.onThumbnailNeeded,
      required this.selectedEntityIds,
      required this.onToggleEntitySelection,
      required this.onStartEntitySelection,
      required this.horizontalPadding});
  final List<EntityListItem> entities;
  final BrowserListStyle style;
  final bool selectionMode;
  final ValueChanged<EntityListItem> onOpenEntity,
      onShowEntityMenu,
      onThumbnailNeeded,
      onToggleEntitySelection,
      onStartEntitySelection;
  final Set<String> selectedEntityIds;
  final double horizontalPadding;
  @override
  Widget build(BuildContext context) => BrowserListSliver(
      count: entities.length,
      style: style,
      padding: horizontalPadding,
      itemBuilder: (context, index) {
        final entity = entities[index];
        return BrowserListTile(
            style: style,
            title: entity.title,
            subtitle:
                '${entity.format.toUpperCase()} · ${formatTime(entity.modifiedAtMs)}',
            selected: selectedEntityIds.contains(entity.id),
            onTap: () => selectionMode
                ? onToggleEntitySelection(entity)
                : onOpenEntity(entity),
            onLongPress: () => onStartEntitySelection(entity),
            onSecondaryTap: () => onShowEntityMenu(entity),
            previewBuilder: (_) => EntityArtwork(
                entityType: entity.entityType,
                format: entity.format,
                title: entity.title,
                contentExcerpt: entity.contentExcerpt,
                thumbnailPath: entity.thumbnailPath,
                onThumbnailNeeded: () => onThumbnailNeeded(entity)));
      });
}
