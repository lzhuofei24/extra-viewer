import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/database/library_build_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/modules/previews/archive_document_preview.dart';
import 'package:best_viewer/src/modules/previews/archive_preview_pipeline.dart';

Future<File> book(Directory directory, String format,
    {bool image = false, String? text, bool corruptImage = false}) async {
  final body = text ?? List.filled(600, '文').join();
  final entries = format == 'docx'
      ? {
          'word/document.xml':
              '<w:document xmlns:w="w"><w:body><w:p><w:r><w:t>$body</w:t></w:r></w:p></w:body></w:document>',
        }
      : {
          'META-INF/container.xml':
              '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
          'OPS/book.opf':
              '<package><manifest><item id="a" href="a.xhtml"/></manifest><spine><itemref idref="a"/></spine></package>',
          'OPS/a.xhtml': '<html><body><div>$body</div></body></html>',
        };
  final archive = Archive();
  for (final entry in entries.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  if (image || corruptImage) {
    final bytes = corruptImage
        ? [1, 2, 3]
        : img.encodePng(img.Image(width: 1000, height: 1500));
    archive.addFile(ArchiveFile('images/first.png', bytes.length, bytes));
  }
  return File('${directory.path}/book.$format')
    ..writeAsBytesSync(ZipEncoder().encode(archive));
}

void main() {
  for (final format in ['epub', 'docx']) {
    test('$format extracts a bounded excerpt and proportional illustration',
        () async {
      final dir = await Directory.systemTemp.createTemp('archive_preview_');
      addTearDown(() => dir.delete(recursive: true));
      final file = await book(dir, format, image: true);
      final preview = await readArchiveDocumentPreview(file.path, format);
      expect(preview.excerpt.runes.length, 501);
      expect(preview.excerpt.endsWith('…'), isTrue);
      expect(preview.pixels, isNotNull);
      expect(preview.width * preview.height, closeTo(360000, 1200));
      expect(preview.width / preview.height, closeTo(2 / 3, 0.003));
    });

    test(
        '$format no-cover publication is durable and does not enter entity work',
        () async {
      final db = AppDatabase.openInMemory();
      addTearDown(() async {
        db.close();
        await Directory(db.storageDirectoryPath).delete(recursive: true);
      });
      final file = await book(Directory(db.storageDirectoryPath), format);
      final library = LibraryRepository(db);
      final builds = LibraryBuildRepository(library);
      final root = library.ensureDirectoryIndexRoot(db.storageDirectoryPath);
      final entity = library
          .upsertEntity(
              path: file.path,
              name: 'book.$format',
              format: format,
              entityType: EntityType.document,
              hash: 'original',
              size: 1,
              sourceCreatedAtMs: 0,
              sourceModifiedAtMs: 0)
          .entity;
      library.linkEntityToIndexNode(entityId: entity.id, indexNodeId: root.id);
      final job = builds.create(
          sourcePath: db.storageDirectoryPath,
          operation: LibraryBuildOperation.rootScan);
      builds.prepareDocumentPreviewWork(job.id, root.id);
      final attempts = builds.claimDocumentPreviewWork(job.id);
      final prepared =
          await ArchivePreviewPipeline(library).prepare(entity, file);
      expect(library.getEntity(entity.id)!.contentExcerpt, isNull);
      await file.delete(); // Publication must not reopen the source.
      builds.completeDocumentPreviewWork(job.id,
          {entity.id: (state: LibraryBuildWorkState.completed, error: null)},
          attempts: attempts, metadata: {entity.id: prepared});
      expect(
          library.getEntity(entity.id)!.thumbnailStatus, ThumbnailStatus.none);
      expect(library.getEntity(entity.id)!.contentExcerpt, prepared.excerpt);
      builds.prepareEntityPreviewWork(job.id, root.id);
      expect(builds.claimEntityPreviewWork(job.id), isEmpty);
      final next = builds.create(
          sourcePath: db.storageDirectoryPath,
          operation: LibraryBuildOperation.rootScan);
      builds.prepareDocumentPreviewWork(next.id, root.id);
      expect(builds.claimDocumentPreviewWork(next.id), isEmpty);
    });
  }

  test('corrupt illustrations are retryable errors, not a no-cover result',
      () async {
    final dir = await Directory.systemTemp.createTemp('archive_corrupt_');
    addTearDown(() => dir.delete(recursive: true));
    final file = await book(dir, 'docx', corruptImage: true);
    await expectLater(
        readArchiveDocumentPreview(file.path, 'docx'), throwsFormatException);
  });

  test('a newer preview revision rejects prepared text and cover together',
      () async {
    final db = AppDatabase.openInMemory();
    addTearDown(() async {
      db.close();
      await Directory(db.storageDirectoryPath).delete(recursive: true);
    });
    final file = await book(Directory(db.storageDirectoryPath), 'epub');
    final library = LibraryRepository(db);
    final builds = LibraryBuildRepository(library);
    final root = library.ensureDirectoryIndexRoot(db.storageDirectoryPath);
    final entity = library
        .upsertEntity(
            path: file.path,
            name: 'book.epub',
            format: 'epub',
            entityType: EntityType.document,
            hash: 'original',
            size: 1,
            sourceCreatedAtMs: 0,
            sourceModifiedAtMs: 0)
        .entity;
    library.linkEntityToIndexNode(entityId: entity.id, indexNodeId: root.id);
    final job = builds.create(
        sourcePath: db.storageDirectoryPath,
        operation: LibraryBuildOperation.rootScan);
    builds.prepareDocumentPreviewWork(job.id, root.id);
    final attempts = builds.claimDocumentPreviewWork(job.id);
    final prepared =
        await ArchivePreviewPipeline(library).prepare(entity, file);
    db.db.execute(
        'UPDATE entity_previews SET preview_revision = preview_revision + 1 WHERE entity_id = ?',
        [entity.id]);
    builds.completeDocumentPreviewWork(job.id,
        {entity.id: (state: LibraryBuildWorkState.completed, error: null)},
        attempts: attempts, metadata: {entity.id: prepared});
    expect(library.getEntity(entity.id)!.contentExcerpt, isNull);
    expect(db.db.select('SELECT * FROM document_preview_versions'), isEmpty);
    expect(builds.get(job.id)!.documentPreviewFailed, 1);
    expect(builds.get(job.id)!.documentPreviewDone, 0);
  });
}
