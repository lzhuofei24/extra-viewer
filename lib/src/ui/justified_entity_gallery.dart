import 'package:flutter/material.dart';

import '../core/domain/models.dart';
import 'gallery_layout_settings.dart';
import 'library_widgets.dart';

/// Packs media by aspect ratio into rows that fill the available width.
/// Completed rows vary slightly around the target height without cropping.
class JustifiedEntityGallerySliver extends StatelessWidget {
  const JustifiedEntityGallerySliver({
    super.key,
    required this.entities,
    required this.immersive,
    required this.selectionMode,
    required this.keyFor,
    required this.onOpenEntity,
    this.onShowEntityMenu,
    required this.onThumbnailNeeded,
    required this.selectedEntityIds,
    required this.layoutSettings,
    this.onToggleEntitySelection,
    this.onStartEntitySelection,
  });

  final List<EntityListItem> entities;
  final bool immersive;
  final bool selectionMode;
  final Key Function(EntityListItem entity) keyFor;
  final ValueChanged<EntityListItem> onOpenEntity;
  final ValueChanged<EntityListItem>? onShowEntityMenu;
  final ValueChanged<EntityListItem> onThumbnailNeeded;
  final Set<String> selectedEntityIds;
  final GalleryLayoutSettings layoutSettings;
  final ValueChanged<EntityListItem>? onToggleEntitySelection;
  final ValueChanged<EntityListItem>? onStartEntitySelection;

  @override
  Widget build(BuildContext context) {
    final gap =
        immersive ? GalleryLayoutSettings.immersiveGap : layoutSettings.cardGap;
    final horizontalPadding = immersive
        ? GalleryLayoutSettings.immersiveMargin
        : layoutSettings.pageMargin;
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final targetHeight = layoutSettings.equalHeight(
          isPortrait: MediaQuery.orientationOf(context) == Orientation.portrait,
          viewportHeight: constraints.viewportMainAxisExtent,
          immersive: immersive,
        );
        final rows = JustifiedGalleryLayout.calculate(
          items: entities,
          availableWidth: constraints.crossAxisExtent - horizontalPadding * 2,
          targetHeight: targetHeight,
          gap: gap,
          aspectRatio: _entityAspectRatio,
        );
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            immersive ? 2 : 12,
            horizontalPadding,
            0,
          ),
          sliver: SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (context, rowIndex) {
              final row = rows[rowIndex];
              return Padding(
                padding: EdgeInsets.only(bottom: gap),
                child: SizedBox(
                  height: row.height,
                  child: Row(
                    children: [
                      for (var index = 0; index < row.items.length; index++)
                        Padding(
                          padding: EdgeInsets.only(
                            right: index == row.items.length - 1 ? 0 : gap,
                          ),
                          child: SizedBox(
                            width: row.widths[index],
                            height: row.height,
                            child: EntityCard(
                              key: keyFor(row.items[index]),
                              entity: row.items[index],
                              onOpen: () => onOpenEntity(row.items[index]),
                              selected: selectedEntityIds
                                  .contains(row.items[index].id),
                              immersive: immersive,
                              cardRadius: layoutSettings.cardRadius,
                              selectionMode: selectionMode,
                              onToggleSelection: onToggleEntitySelection == null
                                  ? null
                                  : () => onToggleEntitySelection!(
                                      row.items[index]),
                              onShowMenu: onShowEntityMenu == null
                                  ? null
                                  : () => onShowEntityMenu!(row.items[index]),
                              onThumbnailNeeded: () =>
                                  onThumbnailNeeded(row.items[index]),
                              onStartSelection: onStartEntitySelection == null
                                  ? null
                                  : () =>
                                      onStartEntitySelection!(row.items[index]),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class JustifiedGalleryLayout {
  const JustifiedGalleryLayout._();

  static List<JustifiedGalleryRow<T>> calculate<T>({
    required List<T> items,
    required double availableWidth,
    required double targetHeight,
    required double gap,
    required double Function(T item) aspectRatio,
  }) {
    if (items.isEmpty || availableWidth <= 0) return const [];
    final rows = <JustifiedGalleryRow<T>>[];
    final pending = <T>[];
    var aspectSum = 0.0;

    void commit({required bool fillWidth}) {
      if (pending.isEmpty) return;
      final rowHeight = fillWidth
          ? (availableWidth - gap * (pending.length - 1)) / aspectSum
          : targetHeight;
      rows.add(JustifiedGalleryRow<T>(
        items: List.unmodifiable(pending),
        height: rowHeight,
        widths: List.unmodifiable([
          for (final item in pending) aspectRatio(item) * rowHeight,
        ]),
      ));
      pending.clear();
      aspectSum = 0;
    }

    for (final item in items) {
      pending.add(item);
      aspectSum += aspectRatio(item);
      final targetWidth = aspectSum * targetHeight + gap * (pending.length - 1);
      if (targetWidth >= availableWidth) commit(fillWidth: true);
    }
    // A partial final row keeps its intended visual density instead of stretching.
    commit(fillWidth: false);
    return rows;
  }
}

class JustifiedGalleryRow<T> {
  const JustifiedGalleryRow({
    required this.items,
    required this.height,
    required this.widths,
  });

  final List<T> items;
  final double height;
  final List<double> widths;
}

double _entityAspectRatio(EntityListItem entity) {
  final width = entity.thumbnailWidth;
  final height = entity.thumbnailHeight;
  if (width != null && height != null && width > 0 && height > 0) {
    return width / height;
  }
  return switch (entity.entityType) {
    EntityType.audio || EntityType.text || EntityType.document => 1,
    _ => 4 / 3,
  };
}
