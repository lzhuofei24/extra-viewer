import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/modules/viewer/reading_position.dart';

void main() {
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
