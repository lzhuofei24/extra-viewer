import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/ui/gallery_layout_settings.dart';
import 'package:best_viewer/src/ui/justified_entity_gallery.dart';

void main() {
  test('height levels match equivalent column widths and grow monotonically',
      () {
    var previous = 0.0;
    for (var level = 1; level <= 8; level++) {
      final layout = GalleryLayoutSettings(portraitEqualHeightLevel: level);
      final height = layout.equalHeight(isPortrait: true, viewportWidth: 400);
      final columns = 9 - level;
      expect(height, (400 - 16 - (columns - 1) * 8) / columns);
      expect(height, greaterThan(previous));
      previous = height;
    }
    expect(
        GalleryLayoutSettings.fromMap(const {'portraitEqualHeightRows': 1})
            .portraitEqualHeightLevel,
        6);
  });

  test('rows preserve height and trailing whitespace, panoramas never overflow',
      () {
    final rows = JustifiedGalleryLayout.calculate<double>(
        items: [1, 1.5, 2, 20, 1],
        availableWidth: 350,
        targetHeight: 100,
        gap: 8,
        aspectRatio: (value) => value);
    expect(rows.map((r) => r.items.length), [2, 1, 1, 1]);
    expect(rows.first.widths, [100, 150]);
    for (final row in rows) {
      expect(row.height, 100);
      expect(row.widths.reduce((a, b) => a + b) + (row.items.length - 1) * 8,
          lessThanOrEqualTo(350));
    }
  });
}
