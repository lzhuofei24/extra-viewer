import 'dart:io';

import 'package:path/path.dart' as p;

import '../formats/text_decoder.dart';
import 'reflow_document.dart';

Future<ReflowDocument> readReflowTextDocument(File file) async {
  final text = await readTextFile(file);
  final isMarkdown = p.extension(file.path).toLowerCase() == '.md';
  return ReflowDocument(
    title: p.basenameWithoutExtension(file.path),
    chapters: [
      ReflowChapter(
        title: p.basenameWithoutExtension(file.path),
        blocks: isMarkdown ? _parseMarkdown(text) : _parsePlainText(text),
      ),
    ],
  );
}

List<ReflowBlock> _parsePlainText(String text) {
  final blocks = <ReflowBlock>[];
  for (final paragraph in text.split(RegExp(r'\r?\n\s*\r?\n'))) {
    final value = paragraph.replaceAll(RegExp(r'\s*\r?\n\s*'), '\n').trim();
    if (value.isNotEmpty) {
      blocks.add(ReflowBlock(kind: ReflowBlockKind.paragraph, text: value));
    }
  }
  return blocks.isEmpty
      ? const [ReflowBlock(kind: ReflowBlockKind.paragraph, text: '')]
      : blocks;
}

List<ReflowBlock> _parseMarkdown(String source) {
  final blocks = <ReflowBlock>[];
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final paragraph = <String>[];
  final code = <String>[];
  var inCode = false;

  void flushParagraph() {
    final text = paragraph.join('\n').trim();
    paragraph.clear();
    if (text.isNotEmpty) {
      blocks.add(ReflowBlock(kind: ReflowBlockKind.paragraph, text: text));
    }
  }

  for (final line in lines) {
    if (line.trimLeft().startsWith('```')) {
      flushParagraph();
      if (inCode) {
        blocks.add(
            ReflowBlock(kind: ReflowBlockKind.code, text: code.join('\n')));
        code.clear();
      }
      inCode = !inCode;
      continue;
    }
    if (inCode) {
      code.add(line);
      continue;
    }
    final heading = RegExp(r'^(#{1,6})\s+(.+)$').firstMatch(line);
    if (heading != null) {
      flushParagraph();
      blocks.add(ReflowBlock(
        kind: ReflowBlockKind.heading,
        level: heading.group(1)!.length,
        text: heading.group(2)!.trim(),
      ));
      continue;
    }
    if (line.trim() == '---' || line.trim() == '***') {
      flushParagraph();
      blocks.add(const ReflowBlock(kind: ReflowBlockKind.divider));
      continue;
    }
    if (line.startsWith('>')) {
      flushParagraph();
      blocks.add(ReflowBlock(
        kind: ReflowBlockKind.quote,
        text: line.replaceFirst(RegExp(r'^>\s?'), ''),
      ));
      continue;
    }
    final bullet = RegExp(r'^\s*(?:[-*+] |\d+\. )(.+)$').firstMatch(line);
    if (bullet != null) {
      flushParagraph();
      blocks.add(
          ReflowBlock(kind: ReflowBlockKind.bullet, text: bullet.group(1)!));
      continue;
    }
    if (line.trim().isEmpty) {
      flushParagraph();
    } else {
      paragraph.add(line);
    }
  }
  flushParagraph();
  if (inCode && code.isNotEmpty) {
    blocks.add(ReflowBlock(kind: ReflowBlockKind.code, text: code.join('\n')));
  }
  return blocks.isEmpty
      ? const [ReflowBlock(kind: ReflowBlockKind.paragraph, text: '')]
      : blocks;
}
