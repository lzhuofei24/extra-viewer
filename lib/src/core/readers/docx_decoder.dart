import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'reflow_document.dart';

Future<String> readDocxText(File file) async {
  return (await readDocxDocument(file)).plainText;
}

Future<ReflowDocument> readDocxDocument(File file) async {
  final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
  final files = <String, ArchiveFile>{
    for (final entry in archive.files)
      if (entry.isFile) entry.name.toLowerCase(): entry,
  };
  final documentFile = files['word/document.xml'];
  if (documentFile == null) {
    throw const FormatException('DOCX 中缺少 word/document.xml。');
  }
  final document = XmlDocument.parse(_decodeArchiveFile(documentFile));
  final relationships =
      _docxRelationships(files['word/_rels/document.xml.rels']);
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
      final image = target == null ? null : files[target.toLowerCase()];
      final bytes = image?.readBytes();
      if (bytes != null) {
        blocks.add(ReflowBlock(
          kind: ReflowBlockKind.image,
          imageBytes: Uint8List.fromList(bytes),
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
  );
}

Map<String, String> _docxRelationships(ArchiveFile? file) {
  if (file == null) return const {};
  final document = XmlDocument.parse(_decodeArchiveFile(file));
  final relationships = <String, String>{};
  for (final relation in _elements(document)
      .where((node) => node.name.local == 'Relationship')) {
    final id = relation.getAttribute('Id');
    final target = relation.getAttribute('Target');
    if (id != null && target != null) {
      relationships[id] = 'word/$target'.replaceAll('\\', '/');
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

String _decodeArchiveFile(ArchiveFile file) {
  final bytes = file.readBytes();
  if (bytes == null) throw const FormatException('无法读取 DOCX 内部文件。');
  return utf8.decode(bytes, allowMalformed: true);
}

Iterable<XmlElement> _elements(XmlNode node) sync* {
  for (final descendant in node.descendants) {
    if (descendant is XmlElement) yield descendant;
  }
}
