import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/modules/viewer/reading_position.dart';

void main() {
  test('repagination restores the fragment containing the saved anchor', () {
    expect(
        pageForReadingAnchor([
          [(0, 0.0)],
          [(0, .4)],
          [(0, .8), (1, 0.0)]
        ], 0, .6),
        1);
    expect(
        pageForReadingAnchor([
          [(0, 0.0), (0, .5)],
          [(1, 0.0)]
        ], 0, .6),
        0);
    expect(pageForReadingAnchor([], 2, .5), 0);
  });
  test('content anchors survive inserted blocks and choose nearest duplicate',
      () {
    final key = readingBlockKey('paragraph:original');
    final position = ReadingPosition(
        sourceRevision: 1, block: 2, blockKey: key, blockFraction: .3);
    expect(position.resolveBlock(['new', 'a', 'b', key]), 3);
    expect(position.resolveBlock([key, 'a', 'b', key]), 3);
    expect(position.resolveBlock(['only']), 0);
    final restored = ReadingPosition.fromJson(
        jsonEncode({'readingPosition': position.toMap()}))!;
    expect(restored.blockFraction, .3);
    expect(restored.blockKey, key);
  });
  test('page and scroll coordinates round-trip independently', () {
    const position = ReadingPosition(
        sourceRevision: 4,
        chapter: 2,
        chapterTitle: 'chapter',
        scrollOffset: 1200,
        page: 8,
        mode: 'book');
    final restored = ReadingPosition.fromJson(
        jsonEncode({'readingPosition': position.toMap()}))!;
    expect(restored.page, 8);
    expect(restored.scrollOffset, 1200);
    expect(restored.sourceRevision, 4);
  });
  test('chapter title survives inserted chapters with bounded fallback', () {
    const position =
        ReadingPosition(sourceRevision: 1, chapter: 1, chapterTitle: 'target');
    expect(position.resolveChapter(['new', 'first', 'target']), 2);
    expect(position.resolveChapter(['only']), 0);
    expect(position.resolveChapter([]), 0);
  });
  test('malformed and unrelated position records do not prevent opening', () {
    expect(ReadingPosition.fromJson('{bad'), isNull);
    expect(
        ReadingPosition.fromJson(
            '{"readingPosition":{"kind":"pdf","version":1}}'),
        isNull);
    expect(
        ReadingPosition.fromJson(
            '{"readingPosition":{"kind":"reflow","version":2}}'),
        isNull);
  });
}
