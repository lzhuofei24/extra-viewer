import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

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

/// Isolate-friendly entry point used by the viewer to keep archive parsing off
/// the Flutter UI isolate.
Future<ReflowDocument> readEpubDocumentAtPath(String path) =>
    readEpubDocument(File(path));

Future<ReflowDocument> readEpubDocument(File file) async {
  final input = InputFileStream(file.path);
  final archive = ZipDecoder().decodeStream(input);
  final files = <String, ArchiveFile>{
    for (final entry in archive.files)
      if (entry.isFile) _normalizeArchivePath(entry.name): entry,
  };
  final container = _requireFile(files, 'META-INF/container.xml');
  final containerXml = XmlDocument.parse(_decodeArchiveFile(container));
  final packagePath =
      _firstElement(containerXml, 'rootfile')?.getAttribute('full-path');
  if (packagePath == null || packagePath.trim().isEmpty) {
    throw const FormatException('EPUB container.xml 中缺少 OPF 路径。');
  }
  final normalizedPackagePath = _normalizeArchivePath(packagePath);
  final packageXml = XmlDocument.parse(
    _decodeArchiveFile(_requireFile(files, normalizedPackagePath)),
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
    final chapterFile = files[chapterPath];
    if (chapterFile == null) continue;
    final blocks = _xhtmlBlocks(
      _decodeArchiveFile(chapterFile),
      chapterPath: chapterPath,
      files: files,
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
  final document = ReflowDocument(
    title: _bookTitle(packageXml) ?? p.basenameWithoutExtension(file.path),
    chapters: chapters,
  );
  input.closeSync();
  return document;
}

List<ReflowBlock> _xhtmlBlocks(
  String source, {
  required String chapterPath,
  required Map<String, ArchiveFile> files,
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
        if (imagePath != null && files.containsKey(imagePath)) {
          result.add(ReflowBlock(
            kind: ReflowBlockKind.image,
            imageEpubPath: epubPath,
            imageArchivePath: imagePath,
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

/// Reads one embedded image on demand. Used from an isolate by the renderer.
Future<Uint8List?> readEpubImageAtPath(
    String epubPath, String archivePath) async {
  final input = InputFileStream(epubPath);
  try {
    final archive = ZipDecoder().decodeStream(input);
    final normalized = _normalizeArchivePath(archivePath);
    final entry = archive.files
        .where(
          (file) =>
              file.isFile && _normalizeArchivePath(file.name) == normalized,
        )
        .cast<ArchiveFile?>()
        .firstWhere(
          (file) => file != null,
          orElse: () => null,
        );
    if (entry == null) {
      throw FormatException('EPUB 内部不存在图片条目：$normalized');
    }
    final bytes = entry.readBytes();
    if (bytes == null || bytes.isEmpty) {
      throw FormatException('EPUB 图片条目为空或无法解压：$normalized');
    }
    return Uint8List.fromList(bytes);
  } finally {
    input.closeSync();
  }
}

Future<EpubBook> readEpubBook(File file) async {
  final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
  final files = <String, ArchiveFile>{
    for (final entry in archive.files)
      if (entry.isFile) _normalizeArchivePath(entry.name): entry,
  };
  final container = _requireFile(files, 'META-INF/container.xml');
  final containerXml = XmlDocument.parse(_decodeArchiveFile(container));
  final rootfile = _firstElement(containerXml, 'rootfile');
  final packagePath = rootfile?.getAttribute('full-path');
  if (packagePath == null || packagePath.trim().isEmpty) {
    throw const FormatException('EPUB container.xml 中缺少 OPF 路径。');
  }

  final normalizedPackagePath = _normalizeArchivePath(packagePath);
  final packageXml = XmlDocument.parse(
    _decodeArchiveFile(_requireFile(files, normalizedPackagePath)),
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
  for (final itemRef
      in _elements(packageXml).where((node) => node.name.local == 'itemref')) {
    final href = manifest[itemRef.getAttribute('idref')];
    if (href == null) continue;
    final chapterPath = _resolveArchivePath(packageDir, href);
    final chapterFile = files[chapterPath];
    if (chapterFile == null) continue;
    final text = _xhtmlText(_decodeArchiveFile(chapterFile));
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
}

ArchiveFile _requireFile(Map<String, ArchiveFile> files, String path) {
  final file = files[_normalizeArchivePath(path)];
  if (file == null) throw FormatException('EPUB 中缺少 $path。');
  return file;
}

String _decodeArchiveFile(ArchiveFile file) {
  final bytes = file.readBytes();
  if (bytes == null) throw FormatException('无法读取 EPUB 内部文件 ${file.name}。');
  return utf8.decode(bytes, allowMalformed: true);
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
