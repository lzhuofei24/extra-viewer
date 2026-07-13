import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/core/portability/index_package_service.dart';
import 'package:best_viewer/src/core/scanner/library_scanner.dart';

void main() {
  test('portable index package round-trips with source path mapping', () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_package_');
    addTearDown(() => temp.delete(recursive: true));
    final source = Directory(p.join(temp.path, 'desktop', 'books'));
    final chapter = File(p.join(source.path, 'novel', 'chapter.txt'));
    await chapter.parent.create(recursive: true);
    await chapter.writeAsString('chapter content');

    final sourceDb = AppDatabase.openInMemory();
    addTearDown(sourceDb.close);
    final sourceRepository = LibraryRepository(sourceDb);
    await LibraryScanner(sourceRepository).scanPath(source.path);
    final entity = sourceRepository.getEntityByPath(chapter.path)!;
    final custom = sourceRepository.ensureCollectionIndexRoot('待读');
    final customNode = sourceRepository.createCustomNode(
      parentId: custom.id,
      name: '本月',
    );
    sourceRepository.linkEntitiesToIndexNode(
      entityIds: [entity.id],
      indexNodeId: customNode.id,
    );
    final packagePath = p.join(temp.path, 'library.bvi');
    final exported =
        await IndexPackageService(sourceRepository).exportPackage(packagePath);
    expect(exported.rootCount, 2);
    expect(exported.entityCount, 1);
    expect(File(packagePath).existsSync(), isTrue);

    final targetDb = AppDatabase.openInMemory();
    addTearDown(targetDb.close);
    final targetRepository = LibraryRepository(targetDb);
    final mobileRoot = p.join(temp.path, 'mobile', 'books');
    final imported = await IndexPackageService(targetRepository).importPackage(
      packagePath,
      sourcePathMappings: {source.path: mobileRoot},
    );
    expect(imported.rootCount, 2);
    final importedPath = p.join(mobileRoot, 'novel', 'chapter.txt');
    final importedEntity = targetRepository.getEntityByPath(importedPath);
    expect(importedEntity, isNotNull);
    final importedCustom = targetRepository.listIndexRoots().singleWhere(
          (root) => root.nodeType == NodeType.categoryIndexRoot,
        );
    final importedNode =
        targetRepository.listChildNodes(importedCustom.id).single;
    expect(
      targetRepository.listEntitiesDirectlyUnderNode(importedNode.id).single.id,
      importedEntity!.id,
    );
  });
}
