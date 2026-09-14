import 'dart:convert';
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

  test('read worker loads persisted node previews without filesystem probes',
      () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_preview_');
    addTearDown(() => temp.delete(recursive: true));
    final database = AppDatabase.openAtPathForTesting(
      p.join(temp.path, 'library.db'),
    );
    addTearDown(database.close);
    final repository = LibraryRepository(database);
    final root = repository.ensureCollectionIndexRoot('阅读');
    final child = repository.createCustomNode(parentId: root.id, name: '章节');

    database.db.execute(
      'UPDATE index_nodes SET preview_json = ? WHERE id = ?',
      [
        jsonEncode({
          'kind': 'visual',
          'title': 'cover.jpg',
          'thumbnailKey': 'ab123',
          'thumbnailFormat': 'webp',
          'entityId': 'entity-1',
          'aspectRatio': 1.4,
        }),
        child.id,
      ],
    );
    // A legacy pointer with a missing file must remain readable without IO.
    database.db.execute(
        'INSERT INTO node_preview_assets VALUES (?, ?, ?, ?, ?, ?, ?)',
        [child.id, 'signature', 'node-asset', 'webp', 420, 300, 0]);

    final worker = await LibraryReadWorker.start(
      databasePath: database.databasePath!,
      storageDirectoryPath: database.storageDirectoryPath,
    );
    addTearDown(worker.close);

    final previews = await worker.loadNodePreviews([child.id]);
    final preview = previews[child.id]!;
    expect(preview.kind, IndexNodePreviewKind.singleVisual);
    expect(preview.visualAssetAspectRatio, 1.4);
    expect(
      preview.visualAssetPath,
      p.join(database.storageDirectoryPath, 'node_previews', 'node-asset.webp'),
    );
    expect(
        preview.tiles.single.thumbnailPath,
        p.join(
            database.storageDirectoryPath, 'thumbnails', 'ab', 'ab123.webp'));

    repository.setNodePreviewOverride(
      child.id,
      jsonEncode([
        {
          'kind': 'visual',
          'title': 'custom.jpg',
          'thumbnailKey': 'cd456',
          'thumbnailFormat': 'webp',
          'aspectRatio': 1.1,
        },
      ]),
    );
    final custom = (await worker.loadNodePreviews([child.id]))[child.id]!;
    expect(custom.kind, IndexNodePreviewKind.visualGrid);
    expect(custom.customOrderTopToBottom, isTrue);
    expect(custom.tiles.single.title, 'custom.jpg');
  });

  test('read worker pages recursive results without blocking the UI isolate',
      () async {
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
    final first = repository
        .upsertEntity(
          path: p.join(temp.path, 'first.jpg'),
          name: 'first.jpg',
          format: 'jpg',
          entityType: EntityType.image,
          hash: 'first',
          size: 1,
          sourceCreatedAtMs: 1,
          sourceModifiedAtMs: 1,
        )
        .entity;
    final second = repository
        .upsertEntity(
          path: p.join(temp.path, 'second.jpg'),
          name: 'second.jpg',
          format: 'jpg',
          entityType: EntityType.image,
          hash: 'second',
          size: 1,
          sourceCreatedAtMs: 1,
          sourceModifiedAtMs: 1,
        )
        .entity;
    repository.linkEntityToIndexNode(entityId: first.id, indexNodeId: root.id);
    repository.linkEntityToIndexNode(
        entityId: second.id, indexNodeId: child.id);

    final worker = await LibraryReadWorker.start(
      databasePath: database.databasePath!,
      storageDirectoryPath: database.storageDirectoryPath,
    );
    addTearDown(worker.close);
    final firstPage = await worker.loadRecursivePage(
      nodeId: root.id,
      sortMode: EntitySortMode.nameAsc,
      limit: 1,
    );

    expect(firstPage.entities.single.title, 'first.jpg');
    expect(firstPage.hasMore, isTrue);
    expect(firstPage.recursiveCursor, isNotNull);

    final secondPage = await worker.loadRecursivePage(
      nodeId: root.id,
      sortMode: EntitySortMode.nameAsc,
      after: firstPage.recursiveCursor,
      limit: 1,
    );
    expect(secondPage.entities.single.title, 'second.jpg');
    expect(secondPage.hasMore, isFalse);
  });

  test('read worker close is idempotent and releases the database handle',
      () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_worker_');
    addTearDown(() => temp.delete(recursive: true));
    final database = AppDatabase.openAtPathForTesting(
      p.join(temp.path, 'library.db'),
    );
    addTearDown(database.close);
    final worker = await LibraryReadWorker.start(
      databasePath: database.databasePath!,
      storageDirectoryPath: database.storageDirectoryPath,
    );

    await Future.wait([worker.close(), worker.close()]);

    await expectLater(
      worker.loadDirectPage(
        parentNodeId: 'missing',
        sortMode: EntitySortMode.nameAsc,
      ),
      throwsStateError,
    );
  });

  test('read worker serves navigation data without the caller database',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('best_viewer_read_');
    final databasePath = '${directory.path}${Platform.pathSeparator}library.db';
    final database = AppDatabase.openAtPathForTesting(databasePath);
    addTearDown(() async {
      database.close();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    final repository = LibraryRepository(database);
    final entity = repository
        .upsertEntity(
          path: '/library/book.txt',
          name: 'book.txt',
          format: 'txt',
          entityType: EntityType.text,
          hash: 'book-fingerprint',
          size: 12,
          sourceCreatedAtMs: 1,
          sourceModifiedAtMs: 2,
        )
        .entity;
    final root = repository.ensureCollectionIndexRoot('阅读');
    final child = repository.createCustomNode(parentId: root.id, name: '第一章');
    repository.linkEntityToIndexNode(
      entityId: entity.id,
      indexNodeId: child.id,
    );

    final worker = await LibraryReadWorker.start(
      databasePath: databasePath,
      storageDirectoryPath: database.storageDirectoryPath,
    );
    addTearDown(worker.close);

    final roots = await worker.loadIndexRoots();
    expect(roots.map((item) => item.id), contains(root.id));

    final path = await worker.loadNodePath(
      indexRootId: root.id,
      currentNodeId: child.id,
    );
    expect(path.map((item) => item.id), [root.id, child.id]);

    final page = await worker.loadDirectPage(
      parentNodeId: child.id,
      sortMode: EntitySortMode.nameAsc,
      limit: 20,
    );
    expect(page.entities.single.id, entity.id);

    final detail = await worker.loadEntity(entity.id);
    expect(detail?.name, 'book.txt');
    expect(detail?.hash, 'book-fingerprint');
  });
}
