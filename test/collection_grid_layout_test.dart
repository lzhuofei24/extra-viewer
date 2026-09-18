import 'package:flutter_test/flutter_test.dart';

import 'package:best_viewer/src/ui/collection_grid_layout.dart';

void main() {
  test('grid layout fills actual content width without overflow', () {
    for (final width in [320.0, 768.0, 956.0, 1280.0, 2048.0]) {
      final layout = CollectionGridLayout.calculate(availableWidth: width);
      final occupiedWidth =
          layout.columnCount * layout.itemWidth + (layout.columnCount - 1) * 4;
      expect(occupiedWidth, closeTo(layout.contentWidth, 0.001));
      expect(layout.columnCount, inInclusiveRange(1, 8));
      expect(layout.itemWidth, greaterThan(0));
    }
  });

  test('a content region narrowed by the sidebar gets narrower cards', () {
    final layout = CollectionGridLayout.calculate(availableWidth: 956);

    expect(layout.columnCount, 3);
    expect(layout.itemWidth, closeTo(310.666, 0.001));
  });

  test('configured card width controls density without overflow', () {
    final compact = CollectionGridLayout.calculate(
      availableWidth: 956,
      targetItemWidth: 200,
    );
    final spacious = CollectionGridLayout.calculate(
      availableWidth: 956,
      targetItemWidth: 400,
    );

    expect(compact.columnCount, 4);
    expect(spacious.columnCount, 2);
    expect(compact.contentWidth, spacious.contentWidth);
  });
}
