import 'dart:convert';

import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:best_viewer/src/core/formats/text_decoder.dart';

void main() {
  test('decodes utf8 with and without bom', () {
    expect(decodeTextBytes(utf8.encode('你好，Best Viewer')), '你好，Best Viewer');
    expect(
      decodeTextBytes([0xef, 0xbb, 0xbf, ...utf8.encode('带 BOM')]),
      '带 BOM',
    );
  });

  test('decodes utf16 bom text', () {
    expect(decodeTextBytes(utf16.encode('上善若水')), '上善若水');
  });

  test('falls back to gbk when strict utf8 fails', () {
    expect(decodeTextBytes(gbk.encode('中文小说第一章')), '中文小说第一章');
  });
}
