import 'dart:io';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:best_viewer/src/core/readers/docx_decoder.dart';
import 'package:best_viewer/src/core/readers/epub_decoder.dart';
import 'package:best_viewer/src/core/readers/reflow_document.dart';
import 'package:best_viewer/src/core/readers/reflow_text_decoder.dart';

void main() {
  test('markdown is split into reflow blocks', () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_md_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/notes.md');
    await file.writeAsString('# 标题\n\n> 引用\n\n- 项目\n\n```\ncode\n```');

    final document = await readReflowTextDocument(file);

    expect(document.chapters.single.blocks.map((block) => block.kind), [
      ReflowBlockKind.heading,
      ReflowBlockKind.quote,
      ReflowBlockKind.bullet,
      ReflowBlockKind.code,
    ]);
  });

  test('DOCX preserves heading and list semantics', () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_docx_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/book.docx');
    await file.writeAsBytes(_zip({
      'word/document.xml': '''
        <w:document xmlns:w="w"><w:body>
          <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>第一章</w:t></w:r></w:p>
          <w:p><w:pPr><w:numPr/></w:pPr><w:r><w:t>列表项</w:t></w:r></w:p>
        </w:body></w:document>
      ''',
    }));

    final document = await readDocxDocument(file);

    expect(document.chapters.single.blocks[0].kind, ReflowBlockKind.heading);
    expect(document.chapters.single.blocks[1].kind, ReflowBlockKind.bullet);
  });

  test('EPUB preserves chapter blocks', () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_epub_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/book.epub');
    await file.writeAsBytes(_zip({
      'META-INF/container.xml': '''
        <container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>
      ''',
      'OPS/book.opf': '''
        <package><metadata><title>示例书</title></metadata><manifest>
          <item id="chapter" href="chapter.xhtml"/>
        </manifest><spine><itemref idref="chapter"/></spine></package>
      ''',
      'OPS/chapter.xhtml': '''
        <html><body><h1>章节标题</h1><p>正文段落</p><ul><li>列表内容</li></ul></body></html>
      ''',
    }));

    final document = await readEpubDocument(file);

    expect(document.title, '示例书');
    expect(document.chapters.single.blocks.map((block) => block.kind), [
      ReflowBlockKind.heading,
      ReflowBlockKind.paragraph,
      ReflowBlockKind.bullet,
    ]);
  });

  test('EPUB document can be decoded in a background isolate', () async {
    final temp =
        await Directory.systemTemp.createTemp('best_viewer_epub_isolate_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/book.epub');
    await file.writeAsBytes(_zip({
      'META-INF/container.xml':
          '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
      'OPS/book.opf':
          '<package><metadata><title>示例</title></metadata><manifest><item id="a" href="a.xhtml"/><item id="b" href="b.xhtml"/></manifest><spine><itemref idref="a"/><itemref idref="b"/></spine></package>',
      'OPS/a.xhtml': '<html><body><p>封面后的正文</p></body></html>',
      'OPS/b.xhtml': '<html><body><p>下一章节正文</p></body></html>',
    }));

    final document = await Isolate.run(() => readEpubDocumentAtPath(file.path));

    expect(document.chapters, hasLength(2));
    expect(document.chapters.last.blocks.single.text, '下一章节正文');
  });

  test('EPUB images stay as archive references until requested', () async {
    final temp =
        await Directory.systemTemp.createTemp('best_viewer_epub_image_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/book.epub');
    final archive = Archive()
      ..addFile(ArchiveFile(
          'META-INF/container.xml',
          72,
          utf8.encode(
              '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>')))
      ..addFile(ArchiveFile(
          'OPS/book.opf',
          160,
          utf8.encode(
              '<package><manifest><item id="a" href="a.xhtml"/></manifest><spine><itemref idref="a"/></spine></package>')))
      ..addFile(ArchiveFile('OPS/a.xhtml', 50,
          utf8.encode('<html><body><img src="images/a.bin"/></body></html>')))
      ..addFile(ArchiveFile('OPS/images/a.bin', 3, [1, 2, 3]));
    await file.writeAsBytes(ZipEncoder().encode(archive));

    final document = await readEpubDocument(file);
    final image = document.chapters.single.blocks.single;

    expect(image.imageBytes, isNull);
    expect(image.imageArchivePath, 'OPS/images/a.bin');
    expect(await readEpubImageAtPath(file.path, image.imageArchivePath!),
        [1, 2, 3]);
  });

  test('reader EPUB session is shared by chapters and embedded images',
      () async {
    final temp =
        await Directory.systemTemp.createTemp('best_viewer_epub_session_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/book.epub');
    await file.writeAsBytes(_zip({
      'META-INF/container.xml':
          '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
      'OPS/book.opf':
          '<package><metadata><title>会话书</title></metadata><manifest><item id="a" href="a.xhtml"/></manifest><spine><itemref idref="a"/></spine></package>',
      'OPS/a.xhtml':
          '<html><body><p>正文</p><img src="images/a.bin"/></body></html>',
      'OPS/images/a.bin': 'image-bytes',
    }));

    final document = await openEpubDocumentSession(file);
    addTearDown(() => document.archiveSession?.close());
    final image = document.chapters.single.blocks
        .firstWhere((block) => block.imageArchivePath != null);

    expect(document.archiveSession, isNotNull);
    expect(image.archiveSession, same(document.archiveSession));
    expect(
      document.archiveSession!.readBytes(image.imageArchivePath!),
      utf8.encode('image-bytes'),
    );
  });

  test('DOCX reader uses a retained archive session for its resources',
      () async {
    final temp =
        await Directory.systemTemp.createTemp('best_viewer_docx_session_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/book.docx');
    await file.writeAsBytes(_zip({
      'word/document.xml':
          '<w:document xmlns:w="w"><w:body><w:p><w:r><w:t>正文</w:t></w:r></w:p></w:body></w:document>',
    }));

    final document = await openDocxDocumentSession(file);
    addTearDown(() => document.archiveSession?.close());
    expect(document.archiveSession, isNotNull);
    expect(document.plainText, '正文');
  });

  test('attached illustrated EPUB image reference can be read', () async {
    const path = r'D:\AI\05_Data_Factory\电子书\精品\【插画版】崩铁昔涟「为你而在的故事」.epub';
    final file = File(path);
    if (!await file.exists()) return;
    final document = await readEpubDocument(file);
    final images = document.chapters
        .expand((chapter) => chapter.blocks)
        .where((block) => block.imageArchivePath != null)
        .toList();
    expect(images.length, greaterThan(10));
    for (final image in images) {
      final bytes = await Isolate.run(
        () => readEpubImageAtPath(file.path, image.imageArchivePath!),
      );
      expect(bytes, isNotNull);
      expect(bytes!.length, greaterThan(1000));
      final codec = await ui.instantiateImageCodec(bytes);
      final decoded = (await codec.getNextFrame()).image;
      expect(decoded.width, greaterThan(0));
      decoded.dispose();
      codec.dispose();
    }
  });
}

List<int> _zip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive);
}
