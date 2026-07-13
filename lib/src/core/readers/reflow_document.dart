import 'dart:typed_data';

enum ReflowBlockKind { heading, paragraph, quote, bullet, code, image, divider }

class ReflowBlock {
  const ReflowBlock({
    required this.kind,
    this.text,
    this.level = 0,
    this.imageBytes,
    this.imageEpubPath,
    this.imageArchivePath,
    this.altText,
  });

  final ReflowBlockKind kind;
  final String? text;
  final int level;
  final Uint8List? imageBytes;
  final String? imageEpubPath;
  final String? imageArchivePath;
  final String? altText;
}

class ReflowChapter {
  const ReflowChapter({required this.title, required this.blocks});

  final String title;
  final List<ReflowBlock> blocks;
}

class ReflowDocument {
  const ReflowDocument({required this.title, required this.chapters});

  final String title;
  final List<ReflowChapter> chapters;

  String get plainText => chapters
      .expand((chapter) => chapter.blocks)
      .map((block) => block.text)
      .whereType<String>()
      .join('\n\n');
}
