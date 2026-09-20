import 'dart:math' as math;
import 'package:flutter/rendering.dart';

/// Exact geometry keeps restored scroll offsets stable before cards are built.
class AspectRatioGridDelegate extends SliverGridDelegate {
  AspectRatioGridDelegate(
      {required this.columns, required this.gap, required List<double> ratios})
      : ratios = List.unmodifiable(ratios);
  SliverGridLayout? _cachedLayout;
  double? _cachedWidth;
  AxisDirection? _cachedDirection;
  final int columns;
  final double gap;
  final List<double> ratios;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    if (_cachedLayout != null &&
        _cachedWidth == constraints.crossAxisExtent &&
        _cachedDirection == constraints.crossAxisDirection) {
      return _cachedLayout!;
    }
    _cachedWidth = constraints.crossAxisExtent;
    _cachedDirection = constraints.crossAxisDirection;
    final width =
        ((constraints.crossAxisExtent - (columns - 1) * gap) / columns)
            .clamp(1.0, double.infinity);
    final bottoms = List<double>.filled(columns, 0);
    final geometry = <SliverGridGeometry>[];
    final trailing = <double>[];
    var maximum = 0.0;
    for (final ratio in ratios) {
      var column = 0;
      for (var i = 1; i < columns; i++) {
        if (bottoms[i] < bottoms[column]) column = i;
      }
      final height = width / (ratio.isFinite && ratio > 0 ? ratio : 1);
      final cross = column * (width + gap);
      geometry.add(SliverGridGeometry(
        scrollOffset: bottoms[column],
        crossAxisOffset: axisDirectionIsReversed(constraints.crossAxisDirection)
            ? constraints.crossAxisExtent - width - cross
            : cross,
        mainAxisExtent: height,
        crossAxisExtent: width,
      ));
      maximum = math.max(maximum, bottoms[column] + height);
      trailing.add(maximum);
      bottoms[column] += height + gap;
    }
    return _cachedLayout = _AspectRatioGridLayout(geometry, trailing);
  }

  @override
  bool shouldRelayout(AspectRatioGridDelegate oldDelegate) =>
      columns != oldDelegate.columns ||
      gap != oldDelegate.gap ||
      ratios != oldDelegate.ratios;
}

class _AspectRatioGridLayout extends SliverGridLayout {
  const _AspectRatioGridLayout(this.geometry, this.trailing);
  final List<SliverGridGeometry> geometry;
  final List<double> trailing;
  int _firstAfter(double offset, double Function(int) value) {
    var low = 0, high = geometry.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (value(mid) <= offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) => geometry.isEmpty
      ? 0
      : _firstAfter(scrollOffset, (i) => trailing[i])
          .clamp(0, geometry.length - 1);
  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) => geometry.isEmpty
      ? 0
      : (_firstAfter(scrollOffset, (i) => geometry[i].scrollOffset) - 1)
          .clamp(0, geometry.length - 1);
  @override
  SliverGridGeometry getGeometryForChildIndex(int index) => geometry[index];
  @override
  double computeMaxScrollOffset(int childCount) =>
      childCount == 0 || trailing.isEmpty
          ? 0
          : trailing[math.min(childCount, trailing.length) - 1];
}
