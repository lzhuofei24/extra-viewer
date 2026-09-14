import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/modules/browser/thumbnail_warmup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  EntityListItem item(int index, {int? width = 600, int? height = 600}) =>
      EntityListItem(
        id: '$index',
        title: '$index',
        entityType: EntityType.image,
        path: '/source/$index.jpg',
        format: 'jpg',
        size: 1,
        modifiedAtMs: 0,
        thumbnailPath: '/derived/$index.webp',
        thumbnailWidth: width,
        thumbnailHeight: height,
      );

  test('large nodes warm only neighbors within one quarter of the cache', () {
    final entries = List.generate(130000, item);
    final window = thumbnailWarmupWindow(entries,
        firstVisible: 500, lastVisible: 510, cacheBytes: 16 * 1024 * 1024);
    expect(window.map((e) => e.id), ['511', '499']);
    expect(window.fold<int>(0, (bytes, e) => bytes + thumbnailDecodedBytes(e)),
        lessThanOrEqualTo(4 * 1024 * 1024));
    expect(window.every((e) => (int.parse(e.id) - 505).abs() <= 21), isTrue);
  });

  test('no visible entities means no preheat; unknown sizes reserve capacity',
      () {
    final entries =
        List.generate(10, (i) => item(i, width: null, height: null));
    expect(
        thumbnailWarmupWindow(entries,
            firstVisible: -1, lastVisible: -1, cacheBytes: 1024 * 1024),
        isEmpty);
    expect(
        thumbnailWarmupWindow(entries,
            firstVisible: 0, lastVisible: 0, cacheBytes: 4 * 1024 * 1024),
        isEmpty);
    expect(thumbnailDecodedBytes(entries.first), 480000 * 4);
  });

  test('warmup has a fixed count cap even with a very large budget', () {
    final entries = List.generate(1000, item);
    final window = thumbnailWarmupWindow(entries,
        firstVisible: 100, lastVisible: 110, cacheBytes: 1024 * 1024 * 1024);
    expect(window.length, 32);
    expect(window.any((e) => int.parse(e.id) >= 100 && int.parse(e.id) <= 110),
        isFalse);
  });
}
