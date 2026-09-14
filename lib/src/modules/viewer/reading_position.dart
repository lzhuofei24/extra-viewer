import 'dart:convert';
import 'package:crypto/crypto.dart';

String readingBlockKey(String content) =>
    sha256.convert(utf8.encode(content.trim())).toString();

int pageForReadingAnchor(
    List<List<(int, double)>> pages, int block, double fraction) {
  var selected = 0;
  for (var i = 0; i < pages.length; i++) {
    for (final anchor in pages[i]) {
      if (anchor.$1 < block || (anchor.$1 == block && anchor.$2 <= fraction)) {
        selected = i;
      }
    }
  }
  return selected;
}

/// Separate page and scroll coordinates; neither is interpreted as the other.
class ReadingPosition {
  const ReadingPosition(
      {required this.sourceRevision,
      this.chapter = 0,
      this.chapterTitle = '',
      this.scrollOffset = 0,
      this.page = 0,
      this.block = 0,
      this.blockKey = '',
      this.blockFraction = 0,
      this.mode = 'scroll'});
  final int sourceRevision;
  final int chapter;
  final String chapterTitle;
  final double scrollOffset;
  final int page;
  final String mode;
  final int block;
  final String blockKey;
  final double blockFraction;

  Map<String, Object> toMap() => {
        'version': 1,
        'kind': 'reflow',
        'sourceRevision': sourceRevision,
        'chapter': chapter,
        'chapterTitle': chapterTitle,
        'scrollOffset': scrollOffset,
        'page': page,
        'block': block,
        'blockKey': blockKey,
        'blockFraction': blockFraction,
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
          block: integer('block'),
          blockKey: value['blockKey'] as String? ?? '',
          blockFraction:
              ((value['blockFraction'] as num?)?.toDouble() ?? 0).clamp(0, 1),
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

  int resolveBlock(List<String> keys) {
    if (keys.isEmpty) return 0;
    if (block < keys.length && keys[block] == blockKey) return block;
    if (blockKey.isNotEmpty) {
      var best = -1;
      for (var i = 0; i < keys.length; i++) {
        if (keys[i] == blockKey &&
            (best < 0 || (i - block).abs() < (best - block).abs())) {
          best = i;
        }
      }
      if (best >= 0) return best;
    }
    return block.clamp(0, keys.length - 1);
  }
}
