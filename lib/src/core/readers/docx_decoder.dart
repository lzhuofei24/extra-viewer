import 'dart:io';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'archive_session.dart';
import 'reflow_document.dart';

Future<String> readDocxText(File file) async {
  return (await readDocxDocument(file)).plainText;
}

Future<ReflowDocument> readDocxDocument(File file) async {
  final session = await ArchiveSession.open(file);
  try {
    return _parseDocx(file, session, keepSession: false);
  } finally {
    session.close();
  }
}

/// Opens a DOCX while retaining its archive session for the reader. DOCX
/// images are loaded from this same session instead of reopening the ZIP.
Future<ReflowDocument> openDocxDocumentSession(File file) async {
  final session = await ArchiveSession.open(file);
  try {
    return _parseDocx(file, session, keepSession: true);
  } catch (_) {
    session.close();
    rethrow;
  }
}

ReflowDocument _parseDocx(
  File file,
  ArchiveSession session, {
  required bool keepSession,
}) {
  final documentText = session.readText('word/document.xml');
  if (documentText == null) {
    throw const FormatException('DOCX 中缺少 word/document.xml。');
  }
  final document = XmlDocument.parse(documentText);
  final relationships = _docxRelationships(session);
  final blocks = <ReflowBlock>[];
  for (final element in _elements(document)) {
    if (element.name.local != 'p') continue;
    final text = _paragraphText(element);
    if (text.isNotEmpty) {
      final style = _paragraphStyle(element);
      final heading = RegExp(r'heading\s*([1-6])', caseSensitive: false)
          .firstMatch(style ?? '');
      blocks.add(ReflowBlock(
        kind: heading != null
            ? ReflowBlockKind.heading
            : _isListParagraph(element)
                ? ReflowBlockKind.bullet
                : ReflowBlockKind.paragraph,
        level: heading == null ? 0 : int.parse(heading.group(1)!),
        text: text,
      ));
    }
    for (final blip
        in _elements(element).where((node) => node.name.local == 'blip')) {
      String? relationshipId;
      for (final attribute in blip.attributes) {
        if (attribute.name.local == 'embed') relationshipId = attribute.value;
      }
      if (relationshipId == null) continue;
      final target = relationships[relationshipId];
      final bytes = target == null ? null : session.readBytes(target);
      if (bytes != null && bytes.isNotEmpty) {
        blocks.add(ReflowBlock(
          kind: ReflowBlockKind.image,
          imageBytes: Uint8List.fromList(bytes),
          archiveSession: keepSession ? session : null,
          altText: '文档图片',
        ));
      }
    }
  }
  if (blocks.isEmpty) {
    throw const FormatException('DOCX 中没有可读取的文本段落。');
  }
  return ReflowDocument(
    title: file.uri.pathSegments.last
        .replaceFirst(RegExp(r'\.docx$', caseSensitive: false), ''),
    chapters: [ReflowChapter(title: '正文', blocks: blocks)],
    archiveSession: keepSession ? session : null,
  );
}

Map<String, String> _docxRelationships(ArchiveSession session) {
  final source = session.readText('word/_rels/document.xml.rels');
  if (source == null) return const {};
  final document = XmlDocument.parse(source);
  final relationships = <String, String>{};
  for (final relation in _elements(document)
      .where((node) => node.name.local == 'Relationship')) {
    final id = relation.getAttribute('Id');
    final target = relation.getAttribute('Target');
    if (id != null && target != null) {
      relationships[id] = _normalizeDocxPath(target);
    }
  }
  return relationships;
}

String _paragraphText(XmlElement paragraph) => _elements(paragraph)
    .where((node) => node.name.local == 't')
    .map((node) => node.innerText)
    .join()
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String? _paragraphStyle(XmlElement paragraph) {
  for (final node in _elements(paragraph)) {
    if (node.name.local != 'pStyle') continue;
    for (final attribute in node.attributes) {
      if (attribute.name.local == 'val') return attribute.value;
    }
  }
  return null;
}

bool _isListParagraph(XmlElement paragraph) =>
    _elements(paragraph).any((node) => node.name.local == 'numPr');

String _normalizeDocxPath(String target) {
  final normalized = target.replaceAll('\\', '/');
  if (normalized.startsWith('/')) return normalized.substring(1);
  final parts = <String>['word'];
  for (final segment in normalized.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (parts.length > 1) parts.removeLast();
    } else {
      parts.add(segment);
    }
  }
  return parts.join('/');
}

Iterable<XmlElement> _elements(XmlNode node) sync* {
  for (final descendant in node.descendants) {
    if (descendant is XmlElement) yield descendant;
  }
}
