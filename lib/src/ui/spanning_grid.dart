import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show SliverConstraints, SliverGridGeometry, SliverGridLayout;

class SpanningGridSliver<T> extends StatelessWidget {
  const SpanningGridSliver({
    super.key,
    required this.items,
    required this.columnCount,
    required this.targetRowHeight,
    required this.crossRowMode,
    this.gap = 4,
    this.horizontalPadding = 8,
    required this.aspectRatio,
    required this.itemBuilder,
  });

  final List<T> items;
  final int columnCount;
  final double targetRowHeight;
  final bool crossRowMode;
  final double gap;
  final double horizontalPadding;
  final double Function(T item) aspectRatio;
  final Widget Function(BuildContext context, T item) itemBuilder;

  @override
  Widget build(BuildContext context) {
    if (crossRowMode) {
      return _RowHeightSpanningSliver<T>(
        items: items,
        rowHeight: targetRowHeight,
        gap: gap,
        horizontalPadding: horizontalPadding,
        aspectRatio: aspectRatio,
        itemBuilder: itemBuilder,
      );
    }
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = math
            .max(
              1.0,
              constraints.crossAxisExtent - horizontalPadding * 2,
            )
            .toDouble();
        final physicalColumns = columnCount.clamp(1, 8);
        final physicalCellWidth =
            (availableWidth - gap * (physicalColumns - 1)) / physicalColumns;
        final aspects = [
          for (final item in items) aspectRatio(item),
        ];
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            0,
            horizontalPadding,
            gap,
          ),
          sliver: SliverGrid(
            gridDelegate: _SpanningGridDelegate(
              availableWidth: availableWidth,
              baseCardWidth: physicalCellWidth,
              rowHeight: targetRowHeight,
              gap: gap,
              aspects: aspects,
              crossRowMode: crossRowMode,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) => itemBuilder(context, items[index]),
              childCount: items.length,
            ),
          ),
        );
      },
    );
  }
}

class _RowHeightSpanningSliver<T> extends StatelessWidget {
  const _RowHeightSpanningSliver({
    required this.items,
    required this.rowHeight,
    required this.gap,
    required this.horizontalPadding,
    required this.aspectRatio,
    required this.itemBuilder,
  });

  final List<T> items;
  final double rowHeight;
  final double gap;
  final double horizontalPadding;
  final double Function(T item) aspectRatio;
  final Widget Function(BuildContext context, T item) itemBuilder;

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
        builder: (context, constraints) {
          final rows = _RowHeightLayout.calculate(
            items: items,
            availableWidth: constraints.crossAxisExtent - horizontalPadding * 2,
            baseHeight: rowHeight,
            gap: gap,
            aspectRatio: aspectRatio,
          );
          return SliverPadding(
            padding: EdgeInsets.fromLTRB(
                horizontalPadding, 0, horizontalPadding, gap),
            sliver: SliverList.builder(
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                return Padding(
                  padding: EdgeInsets.only(bottom: gap),
                  child: SizedBox(
                    height: row.height,
                    child: Stack(
                      children: [
                        for (final tile in row.tiles)
                          Positioned(
                            left: tile.left,
                            top: 0,
                            width: tile.width,
                            height: tile.height,
                            child: itemBuilder(context, tile.item),
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

class _RowHeightLayout {
  const _RowHeightLayout._();

  static List<_Row<T>> calculate<T>({
    required List<T> items,
    required double availableWidth,
    required double baseHeight,
    required double gap,
    required double Function(T item) aspectRatio,
  }) {
    final rows = <_Row<T>>[];
    var tiles = <_RowTile<T>>[];
    var usedWidth = 0.0;
    var currentHeight = baseHeight;
    var logScaleSum = 0.0;
    var logScaleSquaredSum = 0.0;
    var scaleCount = 0;

    void commit() {
      if (tiles.isEmpty) return;
      rows.add(_Row(height: currentHeight, tiles: List.unmodifiable(tiles)));
      tiles = <_RowTile<T>>[];
      usedWidth = 0;
      currentHeight = baseHeight;
    }

    for (final item in items) {
      final aspect = aspectRatio(item).clamp(.1, 10.0);
      const desiredSpan = 10;
      _RowTile<T>? best;
      for (var span = 10; span <= 20; span++) {
        final height = baseHeight * span / 10;
        final width = height * aspect;
        if (width > availableWidth) continue;
        final left = tiles.isEmpty ? 0.0 : usedWidth + gap;
        if (left + width > availableWidth) continue;
        final score = (availableWidth - (left + width)).abs() +
            (span - desiredSpan).abs() * baseHeight * 1.5 +
            _varianceAfter(
                    sum: logScaleSum,
                    squaredSum: logScaleSquaredSum,
                    count: scaleCount,
                    next: math.log(span / 10)) *
                baseHeight *
                180;
        final candidate = _RowTile(
            item: item, left: left, width: width, height: height, score: score);
        if (best == null || candidate.score < best.score) best = candidate;
      }
      if (best == null) {
        commit();
        final height = baseHeight * desiredSpan / 10;
        best = _RowTile(
          item: item,
          left: 0,
          width: (height * aspect).clamp(1.0, availableWidth),
          height: height,
          score: 0,
        );
      }
      tiles.add(best);
      usedWidth = best.left + best.width;
      currentHeight = currentHeight > best.height ? currentHeight : best.height;
      final logScale = math.log(best.height / baseHeight);
      logScaleSum += logScale;
      logScaleSquaredSum += logScale * logScale;
      scaleCount++;
    }
    commit();
    return rows;
  }
}

class _Row<T> {
  const _Row({required this.height, required this.tiles});
  final double height;
  final List<_RowTile<T>> tiles;
}

class _RowTile<T> {
  const _RowTile(
      {required this.item,
      required this.left,
      required this.width,
      required this.height,
      required this.score});
  final T item;
  final double left;
  final double width;
  final double height;
  final double score;
}

class _SpanningGridDelegate extends SliverGridDelegate {
  const _SpanningGridDelegate({
    required this.availableWidth,
    required this.baseCardWidth,
    required this.rowHeight,
    required this.gap,
    required this.aspects,
    required this.crossRowMode,
  });

  final double availableWidth;
  final double baseCardWidth;
  final double rowHeight;
  final double gap;
  final List<double> aspects;
  final bool crossRowMode;

  static final _geometryCache = <String, List<SliverGridGeometry>>{};
  static const _maxCachedLayouts = 24;
  static const _layoutVersion = 8;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final signature = Object.hashAll(
      aspects.map((aspect) => (aspect * 10000).round()),
    );
    final key = 'v$_layoutVersion|${availableWidth.toStringAsFixed(3)}|'
        '${baseCardWidth.toStringAsFixed(3)}|'
        '${rowHeight.toStringAsFixed(3)}|${gap.toStringAsFixed(3)}|'
        '${aspects.length}|$signature';
    final cached = _geometryCache.remove(key);
    if (cached != null) {
      _geometryCache[key] = cached;
      return _SpanningGridLayout(cached);
    }
    final geometries = _buildGeometries();
    _geometryCache[key] = geometries;
    if (_geometryCache.length > _maxCachedLayouts) {
      _geometryCache.remove(_geometryCache.keys.first);
    }
    return _SpanningGridLayout(geometries);
  }

  List<SliverGridGeometry> _buildGeometries() {
    final targetArea = baseCardWidth * rowHeight;
    final estimatedHeight = aspects.fold<double>(gap, (sum, aspect) {
      final safeAspect = aspect.clamp(.1, 10.0);
      final naturalWidth = math.sqrt(targetArea * safeAspect);
      return sum + math.min(naturalWidth, availableWidth) / safeAspect + gap;
    });
    final packing = _MaxRectsPacker(
      availableWidth: availableWidth,
      availableHeight: estimatedHeight,
      gap: gap,
    );
    final geometries = <SliverGridGeometry>[];
    for (final aspect in aspects) {
      final safeAspect = aspect.clamp(.1, 10.0);
      final width =
          math.min(math.sqrt(targetArea * safeAspect), availableWidth);
      final placement = packing.place(width: width, height: width / safeAspect);
      geometries.add(SliverGridGeometry(
        scrollOffset: placement.top,
        crossAxisOffset: placement.left,
        mainAxisExtent: placement.height,
        crossAxisExtent: placement.width,
      ));
    }
    return geometries;
  }

  @override
  bool shouldRelayout(covariant _SpanningGridDelegate oldDelegate) =>
      oldDelegate.availableWidth != availableWidth ||
      oldDelegate.baseCardWidth != baseCardWidth ||
      oldDelegate.rowHeight != rowHeight ||
      oldDelegate.gap != gap ||
      oldDelegate.aspects != aspects ||
      oldDelegate.crossRowMode != crossRowMode;
}

class _MaxRectsPacker {
  _MaxRectsPacker({
    required this.availableWidth,
    required this.availableHeight,
    required this.gap,
  }) : _freeRects = [_FreeRect(0, 0, availableWidth, availableHeight)];

  final double availableWidth;
  final double availableHeight;
  final double gap;
  final List<_FreeRect> _freeRects;

  _ContinuousPlacement place({
    required double width,
    required double height,
  }) {
    _ContinuousPlacement? best;
    for (final free in _freeRects) {
      if (width > free.width || height > free.height) continue;
      final candidate = _ContinuousPlacement(
        left: free.left,
        top: free.top,
        width: width,
        height: height,
        wasteArea: free.area - width * height,
        shortSideFit: math.min(free.width - width, free.height - height),
      );
      if (best == null || candidate.isPreferredTo(best)) best = candidate;
    }
    if (best == null) throw StateError('MaxRects could not find a placement.');

    final reserved = _FreeRect(
      best.left,
      best.top,
      math.min(availableWidth - best.left, best.width + gap),
      math.min(availableHeight - best.top, best.height + gap),
    );
    final next = <_FreeRect>[];
    for (final free in _freeRects) {
      if (!free.intersects(reserved)) {
        _addPruned(next, free);
        continue;
      }
      if (reserved.left > free.left) {
        _addPruned(
            next,
            _FreeRect(
              free.left,
              free.top,
              reserved.left - free.left,
              free.height,
            ));
      }
      if (reserved.right < free.right) {
        _addPruned(
            next,
            _FreeRect(
              reserved.right,
              free.top,
              free.right - reserved.right,
              free.height,
            ));
      }
      if (reserved.top > free.top) {
        _addPruned(
            next,
            _FreeRect(
              free.left,
              free.top,
              free.width,
              reserved.top - free.top,
            ));
      }
      if (reserved.bottom < free.bottom) {
        _addPruned(
            next,
            _FreeRect(
              free.left,
              reserved.bottom,
              free.width,
              free.bottom - reserved.bottom,
            ));
      }
    }
    _freeRects
      ..clear()
      ..addAll(next);
    _trimFreeRects(_freeRects);
    return best;
  }

  static void _addPruned(List<_FreeRect> rects, _FreeRect candidate) {
    if (candidate.width <= .01 || candidate.height <= .01) return;
    for (var index = rects.length - 1; index >= 0; index--) {
      final existing = rects[index];
      if (existing.contains(candidate)) return;
      if (candidate.contains(existing)) rects.removeAt(index);
    }
    rects.add(candidate);
  }

  static void _trimFreeRects(List<_FreeRect> rects) {
    const maxFreeRects = 512;
    if (rects.length <= maxFreeRects) return;
    final deepest = rects
        .reduce((left, right) => left.bottom > right.bottom ? left : right);
    rects.sort((left, right) {
      final top = left.top.compareTo(right.top);
      if (top != 0) return top;
      return left.area.compareTo(right.area);
    });
    rects.removeRange(maxFreeRects - 1, rects.length);
    if (!rects.contains(deepest)) rects.add(deepest);
  }
}

class _FreeRect {
  const _FreeRect(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;
  double get area => width * height;

  bool contains(_FreeRect other) =>
      left <= other.left &&
      top <= other.top &&
      right >= other.right &&
      bottom >= other.bottom;

  bool intersects(_FreeRect other) =>
      left < other.right &&
      right > other.left &&
      top < other.bottom &&
      bottom > other.top;
}

class _ContinuousPlacement {
  const _ContinuousPlacement({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.wasteArea,
    required this.shortSideFit,
  });

  final double left;
  final double top;
  final double width;
  final double height;
  final double wasteArea;
  final double shortSideFit;

  double get right => left + width;
  double get bottom => top + height;

  bool isPreferredTo(_ContinuousPlacement other) {
    final topDelta = top - other.top;
    if (topDelta.abs() > .01) return topDelta < 0;
    final leftDelta = left - other.left;
    if (leftDelta.abs() > .01) return leftDelta < 0;
    final wasteDelta = wasteArea - other.wasteArea;
    if (wasteDelta.abs() > .01) return wasteDelta < 0;
    final shortSideDelta = shortSideFit - other.shortSideFit;
    if (shortSideDelta.abs() > .01) return shortSideDelta < 0;
    return false;
  }
}

double _varianceAfter({
  required double sum,
  required double squaredSum,
  required int count,
  required double next,
}) {
  final nextCount = count + 1;
  final nextSum = sum + next;
  final mean = nextSum / nextCount;
  return math.max(
    0,
    (squaredSum + next * next) / nextCount - mean * mean,
  );
}

class _SpanningGridLayout extends SliverGridLayout {
  const _SpanningGridLayout(this.geometries);
  final List<SliverGridGeometry> geometries;

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) {
    if (geometries.isEmpty) return 0;
    for (var index = 0; index < geometries.length; index++) {
      if (geometries[index].trailingScrollOffset > scrollOffset) return index;
    }
    // RenderSliverGrid may ask for the min/max pair even beyond the final
    // child. Returning childCount here makes it request an invalid geometry.
    return geometries.length - 1;
  }

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    if (geometries.isEmpty) return 0;
    var result = 0;
    for (var index = 0; index < geometries.length; index++) {
      if (geometries[index].scrollOffset <= scrollOffset) result = index;
    }
    return result;
  }

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) => geometries[index];

  @override
  double computeMaxScrollOffset(int childCount) => geometries.fold<double>(
      0,
      (max, geometry) => max > geometry.trailingScrollOffset
          ? max
          : geometry.trailingScrollOffset);
}
