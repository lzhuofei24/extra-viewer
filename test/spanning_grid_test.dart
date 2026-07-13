import 'package:best_viewer/src/ui/spanning_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('adaptive grid keeps continuous placements in bounds',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const aspects = [0.58, 1.0, 2.2, 1.45, 0.72, 3.0, 0.9, 1.8];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          scrollCacheExtent: const ScrollCacheExtent.pixels(10000),
          slivers: [
            SpanningGridSliver<int>(
              items: List<int>.generate(aspects.length, (index) => index),
              targetCellWidth: 210,
              targetRowHeight: 280,
              crossRowMode: false,
              aspectRatio: (item) => aspects[item],
              itemBuilder: (context, item) => Container(
                key: ValueKey('tile-$item'),
              ),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    final rects = [
      for (var item = 0; item < aspects.length; item++)
        tester.getRect(find.byKey(ValueKey('tile-$item'))),
    ];
    for (final rect in rects) {
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(1440));
      expect(rect.top, greaterThanOrEqualTo(0));
    }
    for (var left = 0; left < rects.length; left++) {
      for (var right = left + 1; right < rects.length; right++) {
        expect(rects[left].overlaps(rects[right]), isFalse);
      }
    }
  });
}
