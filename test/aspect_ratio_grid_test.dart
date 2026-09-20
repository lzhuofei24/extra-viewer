import 'package:best_viewer/src/ui/aspect_ratio_grid.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

SliverConstraints constraints({AxisDirection cross = AxisDirection.right}) =>
    SliverConstraints(
      axisDirection: AxisDirection.down,
      growthDirection: GrowthDirection.forward,
      userScrollDirection: ScrollDirection.idle,
      scrollOffset: 0,
      precedingScrollExtent: 0,
      overlap: 0,
      remainingPaintExtent: 300,
      crossAxisExtent: 300,
      crossAxisDirection: cross,
      viewportMainAxisExtent: 300,
      remainingCacheExtent: 300,
      cacheOrigin: 0,
    );

void main() {
  test('culling retains tall earlier cards and reports exact restored extent',
      () {
    final layout = AspectRatioGridDelegate(
      columns: 2,
      gap: 8,
      ratios: [.2, 2, 2, 2],
    ).getLayout(constraints());
    expect(layout.computeMaxScrollOffset(4), 730);
    expect(layout.getMinChildIndexForScrollOffset(300), 0);
    expect(layout.getMaxChildIndexForScrollOffset(300), 3);
    expect(layout.getGeometryForChildIndex(2).scrollOffset, 81);
    expect(layout.getGeometryForChildIndex(0).crossAxisExtent, 146);
  });

  test('RTL mirrors columns and empty grids have no extent', () {
    final layout = AspectRatioGridDelegate(
      columns: 2,
      gap: 8,
      ratios: [1, 1],
    ).getLayout(constraints(cross: AxisDirection.left));
    expect(layout.getGeometryForChildIndex(0).crossAxisOffset, 154);
    expect(layout.getGeometryForChildIndex(1).crossAxisOffset, 0);
    final empty = AspectRatioGridDelegate(
      columns: 3,
      gap: 8,
      ratios: [],
    ).getLayout(constraints());
    expect(empty.computeMaxScrollOffset(0), 0);
    expect(empty.getMinChildIndexForScrollOffset(200), 0);
    expect(empty.getMaxChildIndexForScrollOffset(200), 0);
  });
}
