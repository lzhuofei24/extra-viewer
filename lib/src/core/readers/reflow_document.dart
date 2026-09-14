import 'dart:typed_data';
import 'dart:async';

import 'archive_session.dart';

enum ReflowBlockKind { heading, paragraph, quote, bullet, code, image, divider }

class ReflowBlock {
  const ReflowBlock({
    required this.kind,
    this.text,
    this.level = 0,
    this.imageBytes,
    this.imageEpubPath,
    this.imageArchivePath,
    this.archiveSession,
    this.altText,
  });

  final ReflowBlockKind kind;
  final String? text;
  final int level;
  final Uint8List? imageBytes;
  final String? imageEpubPath;
  final String? imageArchivePath;
  final ArchiveSession? archiveSession;
  final String? altText;
}

class ReflowChapter {
  const ReflowChapter({required this.title, required this.blocks});

  final String title;
  final List<ReflowBlock> blocks;
}

class ReflowDocument {
  const ReflowDocument({
    required this.title,
    required this.chapters,
    this.archiveSession,
    this.releaseSource,
  });

  final String title;
  final List<ReflowChapter> chapters;
  final ArchiveSession? archiveSession;
  final Future<void> Function()? releaseSource;

  Future<void> close() async {
    archiveSession?.close();
    await releaseSource?.call();
  }

  String get plainText => chapters
      .expand((chapter) => chapter.blocks)
      .map((block) => block.text)
      .whereType<String>()
      .join('\n\n');
}
