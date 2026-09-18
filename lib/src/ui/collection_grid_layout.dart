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
  /// The computed width fills the requested columns exactly, so a sidebar or
  /// window resize cannot create a trailing overflow.
  factory CollectionGridLayout.calculate({
    required double availableWidth,
    required int columnCount,
    double horizontalPadding = 8,
    double gap = 4,
    int maxColumns = 8,
  }) {
    final contentWidth =
        (availableWidth - horizontalPadding * 2).clamp(1.0, double.infinity);
    final resolvedColumns = columnCount.clamp(1, maxColumns);
    final itemWidth =
        (contentWidth - gap * (resolvedColumns - 1)) / resolvedColumns;
    return CollectionGridLayout(
      columnCount: resolvedColumns,
      itemWidth: itemWidth,
      contentWidth: contentWidth,
    );
  }
}
