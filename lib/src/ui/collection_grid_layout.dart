import 'gallery_layout_settings.dart';

class CollectionGridLayout {
  const CollectionGridLayout({
    required this.columnCount,
    required this.itemWidth,
    required this.contentWidth,
  });

  final int columnCount;
  final double itemWidth;
  final double contentWidth;

  /// Uses the actual sliver width, not the full window width.
  ///
  /// `targetItemWidth` selects density. The computed width fills the row
  /// exactly, so a sidebar or window resize cannot create a trailing overflow.
  factory CollectionGridLayout.calculate({
    required double availableWidth,
    double horizontalPadding = 8,
    double gap = 4,
    double? targetItemWidth,
    int maxColumns = 8,
  }) {
    final resolvedTargetItemWidth =
        targetItemWidth ?? GalleryLayoutSettings.defaultEqualWidthTarget;
    final contentWidth =
        (availableWidth - horizontalPadding * 2).clamp(1.0, double.infinity);
    final rawColumns =
        ((contentWidth + gap) / (resolvedTargetItemWidth + gap)).floor();
    final columnCount = rawColumns.clamp(1, maxColumns);
    final itemWidth = (contentWidth - gap * (columnCount - 1)) / columnCount;
    return CollectionGridLayout(
      columnCount: columnCount,
      itemWidth: itemWidth,
      contentWidth: contentWidth,
    );
  }
}
