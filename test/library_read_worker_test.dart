import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_read_worker.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';

void main() {
  test('read worker returns direct page data and honors pagination', () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_worker_');
    addTearDown(() => temp.delete(recursive: true));
    final database = AppDatabase.openAtPathForTesting(
      p.join(temp.path, 'library.db'),
    );
    addTearDown(database.close);
    final repository = LibraryRepository(database);
    final root = repository.ensureDirectoryIndexRoot(p.join(temp.path, 'root'));
    final child = repository.ensureIndexNode(
      parentId: root.id,
      name: 'child',
      nodeType: NodeType.folder,
      viewType: ViewType.tree,
    );
    for (final name in ['alpha.jpg', 'beta.jpg']) {
      final entity = repository
          .upsertEntity(
            path: p.join(temp.path, name),
            name: name,
            format: 'jpg',
            entityType: EntityType.image,
            hash: name,
            size: 1,
            sourceCreatedAtMs: 1,
            sourceModifiedAtMs: 1,
          )
          .entity;
      repository.linkEntityToIndexNode(
        entityId: entity.id,
        indexNodeId: root.id,
      );
    }

    final worker = await LibraryReadWorker.start(
      databasePath: database.databasePath!,
      storageDirectoryPath: database.storageDirectoryPath,
    );
    addTearDown(worker.close);
    final page = await worker.loadDirectPage(
      parentNodeId: root.id,
      sortMode: EntitySortMode.nameAsc,
      limit: 1,
    );

    expect(page.childNodes.single.id, child.id);
    expect(page.entities.single.title, 'alpha.jpg');
    expect(page.hasMore, isTrue);

    final nextPage = await worker.loadDirectPage(
      parentNodeId: root.id,
      sortMode: EntitySortMode.nameAsc,
      after: EntityPageCursor.fromEntity(
        page.entities.single,
        EntitySortMode.nameAsc,
      ),
      limit: 1,
    );
    expect(nextPage.entities.single.title, 'beta.jpg');
    expect(nextPage.hasMore, isFalse);
  });
}
