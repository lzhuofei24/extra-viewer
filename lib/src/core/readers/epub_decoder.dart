import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'archive_session.dart';
import 'reflow_document.dart';

class EpubBook {
  const EpubBook({required this.title, required this.chapters});

  final String title;
  final List<EpubChapter> chapters;
}

class EpubChapter {
  const EpubChapter({required this.title, required this.text});

  final String title;
  final String text;
}

/// Isolate-friendly entry point used by callers that do not need a live
/// resource session after parsing.
Future<ReflowDocument> readEpubDocumentAtPath(String path) =>
    readEpubDocument(File(path));

Future<ReflowDocument> readEpubDocument(File file) async {
  final session = await ArchiveSession.open(file);
  try {
    return _parseEpub(file, session, keepSession: false);
  } finally {
    session.close();
  }
}

/// Opens an EPUB for the reader. The returned document owns the session and
/// must close [ReflowDocument.archiveSession] when the reader is disposed.
Future<ReflowDocument> openEpubDocumentSession(File file) async {
  final session = await ArchiveSession.open(file);
  try {
    return _parseEpub(file, session, keepSession: true);
  } catch (_) {
    session.close();
    rethrow;
  }
}

ReflowDocument _parseEpub(
  File file,
  ArchiveSession session, {
  required bool keepSession,
}) {
  final containerXml = XmlDocument.parse(
    _decodeArchiveEntry(session, 'META-INF/container.xml'),
  );
  final packagePath =
      _firstElement(containerXml, 'rootfile')?.getAttribute('full-path');
  if (packagePath == null || packagePath.trim().isEmpty) {
    throw const FormatException('EPUB container.xml 中缺少 OPF 路径。');
  }
  final normalizedPackagePath = _normalizeArchivePath(packagePath);
  final packageXml = XmlDocument.parse(
    _decodeArchiveEntry(session, normalizedPackagePath),
  );
  final manifest = <String, String>{};
  for (final item
      in _elements(packageXml).where((node) => node.name.local == 'item')) {
    final id = item.getAttribute('id');
    final href = item.getAttribute('href');
    if (id != null && href != null) manifest[id] = href;
  }
  final packageDir = p.posix.dirname(normalizedPackagePath);
  final chapters = <ReflowChapter>[];
  for (final itemRef
      in _elements(packageXml).where((node) => node.name.local == 'itemref')) {
    final href = manifest[itemRef.getAttribute('idref')];
    if (href == null) continue;
    final chapterPath = _resolveArchivePath(packageDir, href);
    if (session.entry(chapterPath) == null) continue;
    final blocks = _xhtmlBlocks(
      _decodeArchiveEntry(session, chapterPath),
      chapterPath: chapterPath,
      session: session,
      retainedSession: keepSession ? session : null,
      epubPath: file.path,
    );
    if (blocks.isEmpty) continue;
    final headings = blocks
        .where((block) => block.kind == ReflowBlockKind.heading)
        .map((block) => block.text)
        .whereType<String>();
    final heading = headings.isEmpty ? null : headings.first;
    chapters.add(ReflowChapter(
      title: heading ?? _chapterTitle(chapterPath),
      blocks: blocks,
    ));
  }
  if (chapters.isEmpty) throw const FormatException('EPUB 中没有可读取的章节。');
  return ReflowDocument(
    title: _bookTitle(packageXml) ?? p.basenameWithoutExtension(file.path),
    chapters: chapters,
    archiveSession: keepSession ? session : null,
  );
}

List<ReflowBlock> _xhtmlBlocks(
  String source, {
  required String chapterPath,
  required ArchiveSession session,
  required ArchiveSession? retainedSession,
  required String epubPath,
}) {
  try {
    final document = XmlDocument.parse(source);
    final body = _firstElement(document, 'body');
    if (body == null) return const [];
    final result = <ReflowBlock>[];
    void visit(XmlElement element) {
      final name = element.name.local.toLowerCase();
      if (name == 'img') {
        final src = element.getAttribute('src');
        final imagePath = src == null
            ? null
            : _resolveArchivePath(p.posix.dirname(chapterPath), src);
        if (imagePath != null && session.entry(imagePath) != null) {
          result.add(ReflowBlock(
            kind: ReflowBlockKind.image,
            imageEpubPath: epubPath,
            imageArchivePath: imagePath,
            archiveSession: retainedSession,
            altText: element.getAttribute('alt'),
          ));
        }
        return;
      }
      final text = element.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (RegExp(r'^h[1-6]$').hasMatch(name) && text.isNotEmpty) {
        result.add(ReflowBlock(
          kind: ReflowBlockKind.heading,
          level: int.parse(name.substring(1)),
          text: text,
        ));
        return;
      }
      if (name == 'p' && text.isNotEmpty) {
        result.add(ReflowBlock(kind: ReflowBlockKind.paragraph, text: text));
        return;
      }
      if (name == 'blockquote' && text.isNotEmpty) {
        result.add(ReflowBlock(kind: ReflowBlockKind.quote, text: text));
        return;
      }
      if (name == 'li' && text.isNotEmpty) {
        result.add(ReflowBlock(kind: ReflowBlockKind.bullet, text: text));
        return;
      }
      if (name == 'pre' && text.isNotEmpty) {
        result.add(
            ReflowBlock(kind: ReflowBlockKind.code, text: element.innerText));
        return;
      }
      for (final child in element.childElements) {
        visit(child);
      }
    }

    for (final element in body.childElements) {
      visit(element);
    }
    return result;
  } on XmlParserException {
    final text = source
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return text.isEmpty
        ? const []
        : [ReflowBlock(kind: ReflowBlockKind.paragraph, text: text)];
  }
}

/// Compatibility helper for callers that do not own a reader session.
Future<Uint8List?> readEpubImageAtPath(
    String epubPath, String archivePath) async {
  final session = await ArchiveSession.open(File(epubPath));
  try {
    final bytes = session.readBytes(archivePath);
    if (bytes == null || bytes.isEmpty) {
      throw FormatException('EPUB 图片条目为空或无法解压：$archivePath');
    }
    return bytes;
  } finally {
    session.close();
  }
}

Future<EpubBook> readEpubBook(File file) async {
  final session = await ArchiveSession.open(file);
  try {
    final containerXml = XmlDocument.parse(
      _decodeArchiveEntry(session, 'META-INF/container.xml'),
    );
    final packagePath =
        _firstElement(containerXml, 'rootfile')?.getAttribute('full-path');
    if (packagePath == null || packagePath.trim().isEmpty) {
      throw const FormatException('EPUB container.xml 中缺少 OPF 路径。');
    }
    final normalizedPackagePath = _normalizeArchivePath(packagePath);
    final packageXml = XmlDocument.parse(
      _decodeArchiveEntry(session, normalizedPackagePath),
    );
    final manifest = <String, String>{};
    for (final item
        in _elements(packageXml).where((node) => node.name.local == 'item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) manifest[id] = href;
    }
    final packageDir = p.posix.dirname(normalizedPackagePath);
    final chapters = <EpubChapter>[];
    for (final itemRef in _elements(packageXml)
        .where((node) => node.name.local == 'itemref')) {
      final href = manifest[itemRef.getAttribute('idref')];
      if (href == null) continue;
      final chapterPath = _resolveArchivePath(packageDir, href);
      if (session.entry(chapterPath) == null) continue;
      final text = _xhtmlText(_decodeArchiveEntry(session, chapterPath));
      if (text.isEmpty) continue;
      chapters.add(EpubChapter(title: _chapterTitle(chapterPath), text: text));
    }
    if (chapters.isEmpty) {
      throw const FormatException('EPUB 中没有可读取的章节。');
    }
    return EpubBook(
      title: _bookTitle(packageXml) ?? p.basenameWithoutExtension(file.path),
      chapters: chapters,
    );
  } finally {
    session.close();
  }
}

String _decodeArchiveEntry(ArchiveSession session, String path) {
  final text = session.readText(path);
  if (text == null) throw FormatException('EPUB 中缺少 $path。');
  return text;
}

String _normalizeArchivePath(String value) => p.posix
    .normalize(value.replaceAll('\\', '/'))
    .replaceFirst(RegExp(r'^\./'), '');

String _resolveArchivePath(String basePath, String href) {
  final pathOnly = href.split('#').first.split('?').first;
  return _normalizeArchivePath(p.posix.join(basePath, pathOnly));
}

String? _bookTitle(XmlDocument document) {
  for (final element in _elements(document)) {
    if (element.name.local != 'title') continue;
    final value = element.innerText.trim();
    if (value.isNotEmpty) return value;
  }
  return null;
}

String _chapterTitle(String path) => p.posix.basenameWithoutExtension(path);

String _xhtmlText(String source) {
  try {
    final document = XmlDocument.parse(source);
    final body = _firstElement(document, 'body');
    return (body?.innerText ?? document.innerText)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  } on XmlParserException {
    return source
        .replaceAll(
            RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

XmlElement? _firstElement(XmlNode node, String localName) {
  for (final element in _elements(node)) {
    if (element.name.local == localName) return element;
  }
  return null;
}

Iterable<XmlElement> _elements(XmlNode node) sync* {
  for (final descendant in node.descendants) {
    if (descendant is XmlElement) yield descendant;
  }
}
