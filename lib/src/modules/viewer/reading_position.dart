import 'dart:convert';

/// Separate page and scroll coordinates; neither is interpreted as the other.
class ReadingPosition {
  const ReadingPosition(
      {required this.sourceRevision,
      this.chapter = 0,
      this.chapterTitle = '',
      this.scrollOffset = 0,
      this.page = 0,
      this.mode = 'scroll'});
  final int sourceRevision;
  final int chapter;
  final String chapterTitle;
  final double scrollOffset;
  final int page;
  final String mode;

  Map<String, Object> toMap() => {
        'version': 1,
        'kind': 'reflow',
        'sourceRevision': sourceRevision,
        'chapter': chapter,
        'chapterTitle': chapterTitle,
        'scrollOffset': scrollOffset,
        'page': page,
        'mode': mode
      };

  static ReadingPosition? fromJson(String? json) {
    try {
      final root = jsonDecode(json ?? '{}');
      if (root is! Map) return null;
      final value = root['readingPosition'];
      if (value is! Map || value['kind'] != 'reflow' || value['version'] != 1) {
        return null;
      }
      int integer(String key) =>
          (value[key] as num? ?? 0).toInt().clamp(0, 1 << 30);
      final offset = (value['scrollOffset'] as num? ?? 0).toDouble();
      return ReadingPosition(
          sourceRevision: integer('sourceRevision'),
          chapter: integer('chapter'),
          chapterTitle: value['chapterTitle'] as String? ?? '',
          page: integer('page'),
          mode: value['mode'] == 'book' ? 'book' : 'scroll',
          scrollOffset: offset.isFinite && offset > 0 ? offset : 0);
    } catch (_) {
      return null;
    }
  }

  int resolveChapter(List<String> titles) {
    if (titles.isEmpty) return 0;
    if (chapter < titles.length && titles[chapter] == chapterTitle) {
      return chapter;
    }
    final match = chapterTitle.isEmpty ? -1 : titles.indexOf(chapterTitle);
    return match >= 0 ? match : chapter.clamp(0, titles.length - 1);
  }
}
