import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/core/formats/thumbnail_spec.dart';
import 'package:best_viewer/src/core/scanner/library_scanner.dart';

void main() {
  test('entity upsert skips same path hash and updates changed hash', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    final path = p.normalize(r'D:\virtual\a.txt');
    final inserted = repository.upsertEntity(
      path: '  $path  ',
      name: '  a.txt  ',
      format: ' TXT ',
      entityType: EntityType.text,
      hash: ' hash-a ',
      size: 3,
      sourceCreatedAtMs: 1000,
      sourceModifiedAtMs: 1000,
      metadataPreview: 'hello',
    );

    final skipped = repository.upsertEntity(
      path: path,
      name: 'a-renamed.txt',
      format: 'txt',
      entityType: EntityType.text,
      hash: ' hash-a ',
      size: 99,
      sourceCreatedAtMs: 2000,
      sourceModifiedAtMs: 2000,
      metadataPreview: 'hello',
    );

    final updated = repository.upsertEntity(
      path: path,
      name: 'a-renamed.txt',
      format: 'txt',
      entityType: EntityType.text,
      hash: 'hash-b',
      size: 99,
      sourceCreatedAtMs: 2000,
      sourceModifiedAtMs: 2000,
      metadataPreview: 'changed',
    );

    expect(inserted.status, EntityUpsertStatus.inserted);
    expect(inserted.entity.path, path);
    expect(inserted.entity.name, 'a.txt');
    expect(inserted.entity.format, 'txt');
    expect(inserted.entity.hash, 'hash-a');
    expect(repository.getEntityByPath('  $path  ')!.id, inserted.entity.id);
    expect(repository.hasEntityForPath('  $path  '), isTrue);
    expect(skipped.status, EntityUpsertStatus.updated);
    expect(updated.status, EntityUpsertStatus.updated);
    expect(updated.entity.id, inserted.entity.id);
    expect(updated.entity.name, 'a-renamed.txt');
    expect(updated.entity.hash, 'hash-b');
    expect(updated.entity.metadataPreview, 'changed');
    expect(repository.getEntity(inserted.entity.id), isNotNull);
    expect(inserted.entity.createdAtMs, greaterThan(1000000000000));
    expect(updated.entity.updatedAtMs, greaterThan(1000000000000));

    repository.markOpened(inserted.entity.id);
    expect(
      repository.getEntity(inserted.entity.id)!.lastOpenedAtMs,
      greaterThan(1000000000000),
    );

    repository.savePlaybackState(
      entityId: inserted.entity.id,
      positionMs: 1234,
      durationMs: 9876,
    );
    repository.saveReaderState(
      entityId: inserted.entity.id,
      scrollOffset: 56.5,
      zoomScale: 1.75,
      extraStateJson: '{"fontSize":18}',
    );
    final statefulEntity = repository.getEntity(inserted.entity.id)!;
    expect(statefulEntity.lastPositionMs, 1234);
    expect(statefulEntity.durationMs, 9876);
    expect(statefulEntity.readerScrollOffset, 56.5);
    expect(statefulEntity.zoomScale, 1.75);
    expect(statefulEntity.extraStateJson, '{"fontSize":18}');

    repository.savePlaybackState(
      entityId: inserted.entity.id,
      positionMs: 20000,
      durationMs: 10000,
    );
    repository.saveReaderState(
      entityId: inserted.entity.id,
      scrollOffset: -12,
      zoomScale: -1,
    );
    final normalizedState = repository.getEntity(inserted.entity.id)!;
    expect(normalizedState.lastPositionMs, 10000);
    expect(normalizedState.durationMs, 10000);
    expect(normalizedState.readerScrollOffset, 0);
    expect(normalizedState.zoomScale, 1.75);

    repository.savePlaybackState(
      entityId: inserted.entity.id,
      positionMs: -5,
      durationMs: -1,
    );
    final zeroState = repository.getEntity(inserted.entity.id)!;
    expect(zeroState.lastPositionMs, 0);
    expect(zeroState.durationMs, 0);

    for (final invalid in [
      (
        name: 'empty path',
        path: '   ',
        entityName: 'bad.txt',
        format: 'txt',
        hash: 'bad-hash',
        size: 3,
        createdAt: 1000,
        modifiedAt: 1000,
      ),
      (
        name: 'empty name',
        path: p.normalize(r'D:\virtual\bad-name.txt'),
        entityName: '   ',
        format: 'txt',
        hash: 'bad-hash',
        size: 3,
        createdAt: 1000,
        modifiedAt: 1000,
      ),
      (
        name: 'empty format',
        path: p.normalize(r'D:\virtual\bad-format.txt'),
        entityName: 'bad.txt',
        format: '   ',
        hash: 'bad-hash',
        size: 3,
        createdAt: 1000,
        modifiedAt: 1000,
      ),
      (
        name: 'empty hash',
        path: p.normalize(r'D:\virtual\bad-hash.txt'),
        entityName: 'bad.txt',
        format: 'txt',
        hash: '   ',
        size: 3,
        createdAt: 1000,
        modifiedAt: 1000,
      ),
      (
        name: 'negative size',
        path: p.normalize(r'D:\virtual\bad-size.txt'),
        entityName: 'bad.txt',
        format: 'txt',
        hash: 'bad-hash',
        size: -1,
        createdAt: 1000,
        modifiedAt: 1000,
      ),
      (
        name: 'negative created time',
        path: p.normalize(r'D:\virtual\bad-created.txt'),
        entityName: 'bad.txt',
        format: 'txt',
        hash: 'bad-hash',
        size: 3,
        createdAt: -1,
        modifiedAt: 1000,
      ),
      (
        name: 'negative modified time',
        path: p.normalize(r'D:\virtual\bad-modified.txt'),
        entityName: 'bad.txt',
        format: 'txt',
        hash: 'bad-hash',
        size: 3,
        createdAt: 1000,
        modifiedAt: -1,
      ),
    ]) {
      expect(
        () => repository.upsertEntity(
          path: invalid.path,
          name: invalid.entityName,
          format: invalid.format,
          entityType: EntityType.text,
          hash: invalid.hash,
          size: invalid.size,
          sourceCreatedAtMs: invalid.createdAt,
          sourceModifiedAtMs: invalid.modifiedAt,
        ),
        throwsA(isA<ArgumentError>()),
        reason: invalid.name,
      );
    }

    expect(
      () => repository.markOpened('missing-entity'),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => repository.savePlaybackState(
        entityId: 'missing-entity',
        positionMs: 1,
        durationMs: 2,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => repository.saveReaderState(
        entityId: 'missing-entity',
        scrollOffset: 1,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => repository.cloneIndexNodeTree(
        sourceNodeId: 'missing-node',
        targetParentId: 'missing-target',
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => repository.setArchived('missing-entity', true),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('entity upsert preserves URI identity and its materialized local path',
      () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    const source = 'content://provider/document/primary%3AMedia%2Fsample.mp4';
    final result = repository.upsertEntity(
      path: source,
      localPath: r'C:\app-data\saf\sample.mp4',
      name: 'sample.mp4',
      format: 'mp4',
      entityType: EntityType.video,
      hash: 'source-fingerprint',
      size: 100,
      sourceCreatedAtMs: 1,
      sourceModifiedAtMs: 2,
    );

    expect(result.entity.path, source);
    expect(result.entity.localPath, r'C:\app-data\saf\sample.mp4');
    expect(
        repository.getEntityByPath(source)!.localPath, result.entity.localPath);
  });

  test('scanner rejects an empty root path', () async {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);

    expect(
      () => LibraryScanner(repository).scanPath('   '),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('scanner imports supported files and builds a path-named index',
      () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_scan_');
    addTearDown(() => temp.delete(recursive: true));

    await File('${temp.path}/a.png').writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
      ),
    );
    await File('${temp.path}/b.mp3').writeAsBytes([1, 2, 3]);
    await File('${temp.path}/d.txt').writeAsString('hello');
    await File('${temp.path}/ignore.bin').writeAsBytes([1]);

    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);

    final summary =
        await LibraryScanner(repository).scanPath('  ${temp.path}  ');

    expect(summary.scanned, 3);
    expect(summary.imported, 3);
    expect(summary.updated, 0);
    expect(summary.skipped, 0);
    expect(summary.thumbnailsBuilt, 1);
    final directoryRoot = _directoryRoot(repository);
    expect(repository.listEntitiesUnderNode(directoryRoot.id), hasLength(3));
    expect(repository.listEntitiesUnderNode(null), isEmpty);
    final indexNames = repository.listIndexRoots().map((i) => i.name).toList();
    expect(indexNames, contains(p.basename(temp.path)));
    expect(indexNames, isNot(contains('媒体类型索引')));
    expect(indexNames, isNot(contains('目录索引')));

    final entities = repository.listEntitiesUnderNode(directoryRoot.id);
    final imageEntity =
        entities.singleWhere((item) => item.entityType == EntityType.image);
    final textEntity =
        entities.singleWhere((item) => item.entityType == EntityType.text);
    final scannedEntity = repository.getEntity(imageEntity.id)!;
    expect(imageEntity.modifiedAtMs, scannedEntity.sourceModifiedAtMs);
    expect(scannedEntity.hash, isNotEmpty);
    expect(scannedEntity.thumbnailStatus, ThumbnailStatus.success);
    expect(textEntity.metadataPreview, 'hello');

    final secondSummary = await LibraryScanner(repository).scanPath(temp.path);
    expect(secondSummary.imported, 0);
    expect(secondSummary.updated, 0);
    expect(secondSummary.skipped, 3);
    expect(secondSummary.thumbnailsBuilt, 0);
    expect(
      repository
          .listIndexRoots()
          .where((node) => node.nodeType == NodeType.directoryIndexRoot),
      hasLength(1),
    );
    expect(
      repository.listEntitiesUnderNode(_directoryRoot(repository).id),
      hasLength(3),
    );

    repository.renameIndexNode(directoryRoot.id, '我的资料');

    await File('${temp.path}/d.txt').writeAsString('changed');
    final thirdSummary = await LibraryScanner(repository).scanPath(temp.path);
    expect(thirdSummary.imported, 0);
    expect(thirdSummary.updated, 1);
    expect(thirdSummary.skipped, 2);
    expect(thirdSummary.thumbnailsBuilt, 0);
    expect(repository.getIndexNode(directoryRoot.id)!.name, '我的资料');
    expect(
      repository.listEntitiesUnderNode(_directoryRoot(repository).id),
      hasLength(3),
    );

    final removedPath = p.join(temp.path, 'b.mp3');
    await File(removedPath).delete();
    final fourthSummary = await LibraryScanner(repository).scanPath(temp.path);
    expect(fourthSummary.scanned, 2);
    expect(fourthSummary.imported, 0);
    expect(fourthSummary.updated, 0);
    expect(fourthSummary.skipped, 2);
    expect(fourthSummary.thumbnailsBuilt, 0);
    expect(
      repository.listEntitiesUnderNode(_directoryRoot(repository).id),
      hasLength(2),
    );
    expect(repository.hasEntityForPath(removedPath), isFalse);

    expect(
      repository.countEntitiesUnderIndexNode(_directoryRoot(repository).id),
      2,
    );

    final currentEntity =
        repository.listEntitiesUnderNode(_directoryRoot(repository).id).first;
    repository.setArchived(currentEntity.id, true);
    expect(
      repository
          .listEntitiesUnderNode(_directoryRoot(repository).id)
          .any((item) => item.id == currentEntity.id),
      isFalse,
    );
    expect(
      repository.countEntitiesUnderIndexNode(_directoryRoot(repository).id),
      1,
    );

    repository.setArchived(currentEntity.id, false);
    final index = repository.listIndexRoots().first;
    repository.unlinkEntityFromIndexNode(
        entityId: currentEntity.id, indexNodeId: index.id);
    expect(
      repository
          .listEntitiesUnderNode(index.id)
          .any((item) => item.id == currentEntity.id),
      isFalse,
    );

    final path = currentEntity.path;
    repository.removeEntityFromLibrary(currentEntity.id);
    expect(File(path).existsSync(), isTrue);
  });

  test('deleting category index keeps entities', () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_delete_');
    addTearDown(() => temp.delete(recursive: true));
    await File('${temp.path}/d.txt').writeAsString('hello');

    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    await LibraryScanner(repository).scanPath(temp.path);

    final entity =
        repository.listEntitiesUnderNode(_directoryRoot(repository).id).single;
    final category = repository.ensureCategoryIndexRoot('收藏视图');
    repository.linkEntityToIndexNode(
      entityId: entity.id,
      indexNodeId: category.id,
    );

    expect(
      repository.willDeleteEntitiesWhenDeletingNode(category.id),
      isFalse,
    );
    repository.deleteIndexNode(category.id);

    expect(
      repository.listEntitiesUnderNode(_directoryRoot(repository).id),
      hasLength(1),
    );
    expect(repository.getEntity(entity.id), isNotNull);
  });

  test('deleting system root index node is ignored', () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_root_');
    addTearDown(() => temp.delete(recursive: true));
    await File('${temp.path}/d.txt').writeAsString('hello');

    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    await LibraryScanner(repository).scanPath(temp.path);

    final rootRow = db.db.select(
      'SELECT id FROM index_nodes WHERE node_type = ? LIMIT 1',
      [NodeType.root.value],
    ).single;
    final rootId = rootRow['id'] as String;
    final directoryRoot = _directoryRoot(repository);
    final entity = repository.listEntitiesUnderNode(directoryRoot.id).single;

    repository.deleteIndexNode(rootId);

    expect(repository.listIndexRoots(), hasLength(1));
    expect(repository.getEntity(entity.id), isNotNull);
    expect(
      repository.listEntitiesUnderNode(directoryRoot.id).map((item) => item.id),
      contains(entity.id),
    );
  });

  test('system root index node is managed internally', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);

    expect(
      () => repository.ensureIndexNode(
        name: 'Root',
        nodeType: NodeType.root,
        viewType: ViewType.tree,
      ),
      throwsA(isA<ArgumentError>()),
    );

    expect(repository.listIndexRoots(), isEmpty);
    expect(
      db.db.select("SELECT id FROM index_nodes WHERE node_type = 'root'"),
      hasLength(1),
    );
  });

  test('index root nodes must be direct children of the system root', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);

    final categoryRoot = repository.ensureCategoryIndexRoot('分类根');
    final graphRoot = repository.ensureGraphIndexRoot('图根');

    expect(categoryRoot.nodeType, NodeType.categoryIndexRoot);
    expect(graphRoot.nodeType, NodeType.graphIndexRoot);
    expect(
        repository.listIndexRoots().map((node) => node.id),
        containsAll([
          categoryRoot.id,
          graphRoot.id,
        ]));

    expect(
      () => repository.ensureIndexNode(
        name: '孤儿分类根',
        nodeType: NodeType.categoryIndexRoot,
        viewType: ViewType.tree,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => repository.ensureIndexNode(
        parentId: categoryRoot.id,
        name: '嵌套图根',
        nodeType: NodeType.graphIndexRoot,
        viewType: ViewType.graph,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('child node types must stay inside matching index roots', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);

    final directoryRoot =
        repository.ensureDirectoryIndexRoot(p.normalize(r'D:\virtual\media'));
    final categoryRoot = repository.ensureCategoryIndexRoot('分类根');
    final graphRoot = repository.ensureGraphIndexRoot('图根');

    final folder = repository.ensureIndexNode(
      parentId: directoryRoot.id,
      name: '目录节点',
      nodeType: NodeType.folder,
      viewType: ViewType.tree,
    );
    final category = repository.ensureIndexNode(
      parentId: categoryRoot.id,
      name: '分类节点',
      nodeType: NodeType.category,
      viewType: ViewType.tree,
    );
    final graphNode = repository.ensureGraphNode(
      parentId: graphRoot.id,
      name: '图节点',
    );

    expect(folder.nodeType, NodeType.folder);
    expect(category.nodeType, NodeType.category);
    expect(graphNode.nodeType, NodeType.graphNode);

    for (final invalid in [
      (
        parentId: categoryRoot.id,
        nodeType: NodeType.folder,
        viewType: ViewType.tree,
        name: '分类里的目录节点',
      ),
      (
        parentId: directoryRoot.id,
        nodeType: NodeType.category,
        viewType: ViewType.tree,
        name: '目录里的分类节点',
      ),
      (
        parentId: categoryRoot.id,
        nodeType: NodeType.graphNode,
        viewType: ViewType.graph,
        name: '分类里的图节点',
      ),
    ]) {
      expect(
        () => repository.ensureIndexNode(
          parentId: invalid.parentId,
          name: invalid.name,
          nodeType: invalid.nodeType,
          viewType: invalid.viewType,
        ),
        throwsA(isA<ArgumentError>()),
        reason: invalid.name,
      );
    }

    expect(
      () => repository.ensureGraphNode(
        parentId: categoryRoot.id,
        name: '错误图节点',
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('node view type must match node type', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);

    final categoryRoot = repository.ensureCategoryIndexRoot('分类根');
    final graphRoot = repository.ensureGraphIndexRoot('图根');
    final systemRootId = db.db
        .select("SELECT id FROM index_nodes WHERE node_type = 'root'")
        .single['id'] as String;

    expect(
      () => repository.ensureIndexNode(
        parentId: categoryRoot.id,
        name: '错误分类视图',
        nodeType: NodeType.category,
        viewType: ViewType.graph,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => repository.ensureIndexNode(
        parentId: graphRoot.id,
        name: '错误图视图',
        nodeType: NodeType.graphNode,
        viewType: ViewType.tree,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => repository.ensureIndexNode(
        parentId: systemRootId,
        name: '错误图根视图',
        nodeType: NodeType.graphIndexRoot,
        viewType: ViewType.tree,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('unlinking entity from index root keeps entity record', () async {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    final root = repository.ensureCategoryIndexRoot('根节点移除测试');
    final inserted = repository.upsertEntity(
      path: p.normalize(r'D:\virtual\root.txt'),
      name: 'root.txt',
      format: 'txt',
      entityType: EntityType.text,
      hash: 'hash-root',
      size: 3,
      sourceCreatedAtMs: 1000,
      sourceModifiedAtMs: 1000,
    );
    repository.linkEntityToIndexNode(
      entityId: inserted.entity.id,
      indexNodeId: root.id,
    );

    expect(repository.listEntitiesUnderNode(root.id), hasLength(1));

    repository.unlinkEntityFromIndexNode(
      entityId: inserted.entity.id,
      indexNodeId: root.id,
    );

    expect(repository.listEntitiesUnderNode(root.id), isEmpty);
    expect(repository.getEntity(inserted.entity.id), isNotNull);
  });

  test('entity links require an existing entity and non-root index node', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    final root = repository.ensureCategoryIndexRoot('挂接测试');
    final inserted = repository.upsertEntity(
      path: p.normalize(r'D:\virtual\link.txt'),
      name: 'link.txt',
      format: 'txt',
      entityType: EntityType.text,
      hash: 'hash-link',
      size: 3,
      sourceCreatedAtMs: 1000,
      sourceModifiedAtMs: 1000,
    );

    repository.linkEntityToIndexNode(
      entityId: inserted.entity.id,
      indexNodeId: root.id,
    );
    repository.linkEntityToIndexNode(
      entityId: inserted.entity.id,
      indexNodeId: root.id,
    );
    expect(repository.listEntitiesUnderNode(root.id), hasLength(1));

    expect(
      () => repository.linkEntityToIndexNode(
        entityId: 'missing-entity',
        indexNodeId: root.id,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => repository.linkEntityToIndexNode(
        entityId: inserted.entity.id,
        indexNodeId: 'missing-node',
      ),
      throwsA(isA<ArgumentError>()),
    );

    final systemRootId = db.db
        .select("SELECT id FROM index_nodes WHERE node_type = 'root'")
        .single['id'] as String;
    expect(
      () => repository.linkEntityToIndexNode(
        entityId: inserted.entity.id,
        indexNodeId: systemRootId,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('entity type sort uses stored file format then name', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    final root = repository.ensureCategoryIndexRoot('排序测试');

    for (final item in [
      ('video.mp4', 'mp4', EntityType.video),
      ('audio.mp3', 'mp3', EntityType.audio),
      ('book.txt', 'txt', EntityType.text),
      ('another.mp3', 'mp3', EntityType.audio),
    ]) {
      final result = repository.upsertEntity(
        path: p.normalize(p.join(r'D:\virtual', item.$1)),
        name: item.$1,
        format: item.$2,
        entityType: item.$3,
        hash: 'hash-${item.$1}',
        size: 3,
        sourceCreatedAtMs: 1000,
        sourceModifiedAtMs: 1000,
      );
      repository.linkEntityToIndexNode(
        entityId: result.entity.id,
        indexNodeId: root.id,
      );
    }

    final sorted = repository
        .listEntitiesUnderNode(root.id, sortMode: EntitySortMode.typeAsc)
        .map((entity) => entity.title)
        .toList();

    expect(sorted, ['another.mp3', 'audio.mp3', 'video.mp4', 'book.txt']);
  });

  test('index node siblings are unique by parent name and type', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    final root = repository.ensureCategoryIndexRoot('分类');

    final first = repository.ensureIndexNode(
      parentId: root.id,
      name: '同名节点',
      nodeType: NodeType.category,
      viewType: ViewType.tree,
    );
    final second = repository.ensureIndexNode(
      parentId: root.id,
      name: '同名节点',
      nodeType: NodeType.category,
      viewType: ViewType.tree,
    );
    final trimmed = repository.ensureIndexNode(
      parentId: root.id,
      name: '  同名节点  ',
      nodeType: NodeType.category,
      viewType: ViewType.tree,
    );

    expect(second.id, first.id);
    expect(trimmed.id, first.id);
    expect(first.name, '同名节点');
    expect(
      () => db.db.execute(
        '''
        INSERT INTO index_nodes
        (id, parent_id, name, node_type, view_type, sort_order, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, 0, 1, 1)
        ''',
        [
          'duplicate-node',
          root.id,
          '同名节点',
          NodeType.category.value,
          ViewType.tree.value
        ],
      ),
      throwsA(anything),
    );

    repository.renameIndexNode(first.id, '新名称');
    expect(repository.listChildNodes(root.id).single.name, '新名称');

    final other = repository.ensureIndexNode(
      parentId: root.id,
      name: '另一个节点',
      nodeType: NodeType.category,
      viewType: ViewType.tree,
    );
    expect(
      () => repository.renameIndexNode(other.id, '新名称'),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => repository.renameIndexNode(other.id, '   '),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => repository.ensureIndexNode(
        parentId: root.id,
        name: '   ',
        nodeType: NodeType.category,
        viewType: ViewType.tree,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('source path is reserved for directory index roots', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    final root = repository.ensureCategoryIndexRoot('分类');

    expect(
      () => repository.ensureIndexNode(
        parentId: root.id,
        name: '带来源的分类',
        nodeType: NodeType.category,
        viewType: ViewType.tree,
        sourcePath: p.normalize(r'D:\virtual\source'),
      ),
      throwsA(isA<ArgumentError>()),
    );

    final directory = repository.ensureDirectoryIndexRoot(
      '  ${p.normalize(r'D:\virtual\source')}  ',
    );
    expect(directory.nodeType, NodeType.directoryIndexRoot);
    expect(directory.sourcePath, p.normalize(r'D:\virtual\source'));
    expect(
      () => repository.ensureDirectoryIndexRoot('   '),
      throwsA(isA<ArgumentError>()),
    );
    for (final sourcePath in [null, p.normalize(r'D:\virtual\generic')]) {
      expect(
        () => repository.ensureIndexNode(
          name: '泛型目录根',
          nodeType: NodeType.directoryIndexRoot,
          viewType: ViewType.tree,
          sourcePath: sourcePath,
        ),
        throwsA(isA<ArgumentError>()),
      );
    }
  });

  test('v5+ migrations dedupe index nodes and graph edges before constraints',
      () {
    final raw = sqlite3.openInMemory();
    raw.userVersion = 4;
    addTearDown(raw.dispose);
    raw.execute('''
CREATE TABLE index_nodes (
  id TEXT PRIMARY KEY,
  parent_id TEXT,
  name TEXT NOT NULL,
  node_type TEXT NOT NULL,
  view_type TEXT NOT NULL,
  source_path TEXT,
  thumbnail_png BLOB,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_built_at_ms INTEGER
);
CREATE TABLE entities (
  id TEXT PRIMARY KEY,
  path TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  format TEXT NOT NULL,
  media_type TEXT NOT NULL,
  hash TEXT NOT NULL,
  thumbnail_png BLOB NOT NULL,
  size INTEGER NOT NULL,
  source_created_at_ms INTEGER NOT NULL,
  source_modified_at_ms INTEGER NOT NULL,
  favorite INTEGER NOT NULL DEFAULT 0,
  archived INTEGER NOT NULL DEFAULT 0,
  last_opened_at INTEGER,
  last_position_ms INTEGER,
  duration_ms INTEGER,
  reader_scroll_offset REAL,
  zoom_scale REAL,
  extra_state_json TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE index_node_entities (
  index_node_id TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY(index_node_id, entity_id)
);
CREATE TABLE index_node_edges (
  id TEXT PRIMARY KEY,
  from_node_id TEXT NOT NULL,
  to_node_id TEXT NOT NULL,
  edge_type TEXT NOT NULL,
  label TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0
);
''');
    raw.execute(
      '''
      INSERT INTO index_nodes
      (id, parent_id, name, node_type, view_type, sort_order, created_at, updated_at)
      VALUES
      ('root', NULL, 'Root', 'root', 'tree', 0, 1, 1),
      ('a', 'root', '重复', 'category', 'tree', 0, 1, 1),
      ('b', 'root', '重复', 'category', 'tree', 0, 1, 1),
      ('child', 'b', '子节点', 'category', 'tree', 0, 1, 1)
      ''',
    );
    raw.execute(
      '''
      INSERT INTO index_node_edges
      (id, from_node_id, to_node_id, edge_type, label, sort_order)
      VALUES
      ('edge-a', 'a', 'child', 'next', 'next', 0),
      ('edge-b', 'b', 'child', 'next', 'next duplicate', 1)
      ''',
    );

    final db = AppDatabase.openForTesting(raw);
    final repository = LibraryRepository(db);

    expect(db.db.userVersion, 30);
    expect(repository.listIndexTree('root'), hasLength(1));
    final merged = repository.listIndexTree('root').single;
    expect(merged.item.id, 'a');
    expect(merged.children.single.item.id, 'child');
    expect(repository.listOutgoingEdges('a'), hasLength(1));
    expect(
      () => db.db.execute(
        '''
        INSERT INTO index_nodes
        (id, parent_id, name, node_type, view_type, sort_order, created_at, updated_at)
        VALUES ('duplicate-after-migration', 'root', '重复', 'category', 'tree', 0, 1, 1)
        ''',
      ),
      throwsA(anything),
    );
    expect(
      () => db.db.execute(
        '''
        INSERT INTO index_node_edges
        (id, from_node_id, to_node_id, edge_type, label, sort_order)
        VALUES ('duplicate-edge-after-migration', 'a', 'child', 'next', 'x', 0)
        ''',
      ),
      throwsA(anything),
    );
  });

  test('v6 migration dedupes global root nodes before root constraint', () {
    final raw = sqlite3.openInMemory();
    raw.userVersion = 5;
    addTearDown(raw.dispose);
    raw.execute('''
CREATE TABLE index_nodes (
  id TEXT PRIMARY KEY,
  parent_id TEXT,
  name TEXT NOT NULL,
  node_type TEXT NOT NULL,
  view_type TEXT NOT NULL,
  source_path TEXT,
  thumbnail_png BLOB,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_built_at_ms INTEGER
);
CREATE TABLE entities (
  id TEXT PRIMARY KEY,
  path TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  format TEXT NOT NULL,
  media_type TEXT NOT NULL,
  hash TEXT NOT NULL,
  thumbnail_png BLOB NOT NULL,
  size INTEGER NOT NULL,
  source_created_at_ms INTEGER NOT NULL,
  source_modified_at_ms INTEGER NOT NULL,
  favorite INTEGER NOT NULL DEFAULT 0,
  archived INTEGER NOT NULL DEFAULT 0,
  last_opened_at INTEGER,
  last_position_ms INTEGER,
  duration_ms INTEGER,
  reader_scroll_offset REAL,
  zoom_scale REAL,
  extra_state_json TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE index_node_entities (
  index_node_id TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY(index_node_id, entity_id)
);
CREATE TABLE index_node_edges (
  id TEXT PRIMARY KEY,
  from_node_id TEXT NOT NULL,
  to_node_id TEXT NOT NULL,
  edge_type TEXT NOT NULL,
  label TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0
);
''');
    raw.execute(
      '''
      INSERT INTO index_nodes
      (id, parent_id, name, node_type, view_type, sort_order, created_at, updated_at)
      VALUES
      ('root-a', NULL, 'Root A', 'root', 'tree', 0, 1, 1),
      ('root-b', NULL, 'Root B', 'root', 'tree', 0, 1, 1),
      ('category', 'root-b', '分类', 'category_index_root', 'tree', 0, 1, 1)
      ''',
    );

    final db = AppDatabase.openForTesting(raw);
    final repository = LibraryRepository(db);

    expect(db.db.userVersion, 30);
    expect(
      db.db.select("SELECT id FROM index_nodes WHERE node_type = 'root'"),
      hasLength(1),
    );
    final roots = repository.listIndexRoots();
    expect(roots, hasLength(1));
    expect(roots.single.id, 'category');
    expect(
      () => db.db.execute(
        '''
        INSERT INTO index_nodes
        (id, name, node_type, view_type, sort_order, created_at, updated_at)
        VALUES ('duplicate-root', 'Root C', 'root', 'tree', 0, 1, 1)
        ''',
      ),
      throwsA(anything),
    );
  });

  test('schema creates indexes for common browse queries', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);

    final indexNames = db.db
        .select(
          '''
          SELECT name FROM sqlite_master
          WHERE type = 'index'
          ''',
        )
        .map((row) => row['name'] as String)
        .toSet();

    expect(indexNames, contains('idx_index_nodes_parent_sort_name'));
    expect(indexNames, contains('idx_entities_visible_name'));
    expect(indexNames, contains('idx_entities_visible_modified'));
    expect(indexNames, contains('idx_entities_visible_size'));
    expect(indexNames, contains('idx_entities_visible_format_name'));
    expect(indexNames, contains('idx_index_node_edges_to'));
  });

  test('index node thumbnail can be stored and read back', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    final category = repository.ensureCategoryIndexRoot('封面测试');
    final thumbnail = _testThumbnailPng();

    repository.setIndexNodeThumbnailPng(category.id, thumbnail);

    final reloaded = repository.listIndexRoots().single;
    expect(reloaded.thumbnailPng, thumbnail);
    expect(
      () => repository.setIndexNodeThumbnailPng(
        category.id,
        Uint8List.fromList([137, 80, 78, 71]),
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('scanner exposes non-recursive directory node preview descriptions',
      () async {
    final temp =
        await Directory.systemTemp.createTemp('best_viewer_node_thumb_');
    addTearDown(() => temp.delete(recursive: true));
    final leaf = Directory(p.join(temp.path, 'child', 'leaf'));
    await leaf.create(recursive: true);
    await File(p.join(leaf.path, 'a.png')).writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
      ),
    );

    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);

    await LibraryScanner(repository).scanPath(temp.path);

    final root = _directoryRoot(repository);
    final childTree = repository.listIndexTree(root.id).single;
    final childNode = childTree.item;
    final leafNode = childTree.children.single.item;
    final previews = repository.listIndexNodePreviews([
      root.id,
      childNode.id,
      leafNode.id,
    ]);
    expect(previews[root.id]!.kind, IndexNodePreviewKind.visualGrid);
    expect(
      previews[root.id]!.tiles.single.kind,
      IndexNodePreviewTileKind.visual,
    );
    expect(previews[childNode.id]!.kind, IndexNodePreviewKind.visualGrid);
    expect(previews[childNode.id]!.tiles.single.kind,
        IndexNodePreviewTileKind.visual);
    expect(previews[leafNode.id]!.kind, IndexNodePreviewKind.singleVisual);
    expect(previews[leafNode.id]!.tiles.single.thumbnailPath, isNotNull);
  });

  test('direct entity listing only returns entities linked to current node',
      () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_direct_');
    addTearDown(() => temp.delete(recursive: true));
    final leaf = Directory(p.join(temp.path, 'child', 'leaf'));
    await leaf.create(recursive: true);
    await File(p.join(leaf.path, 'a.txt')).writeAsString('hello');

    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);

    await LibraryScanner(repository).scanPath(temp.path);

    final root = _directoryRoot(repository);
    final childTree = repository.listIndexTree(root.id).single;
    final childNode = childTree.item;
    final leafNode = childTree.children.single.item;

    expect(repository.listEntitiesUnderNode(root.id), hasLength(1));
    expect(repository.listEntitiesUnderNode(childNode.id), hasLength(1));
    expect(repository.listEntitiesDirectlyUnderNode(root.id), isEmpty);
    expect(repository.listEntitiesDirectlyUnderNode(childNode.id), isEmpty);
    expect(repository.listEntitiesDirectlyUnderNode(leafNode.id), hasLength(1));
    expect(
      repository.listEntitiesDirectlyUnderNode(leafNode.id).single.title,
      'a.txt',
    );
  });

  test('scan does not decode image thumbnails eagerly', () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_fail_');
    addTearDown(() => temp.delete(recursive: true));
    final badImage = File(p.join(temp.path, 'bad.png'))
      ..writeAsBytesSync([1, 2, 3]);

    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);

    final summary = await LibraryScanner(repository).scanPath(temp.path);
    expect(summary.scanned, 1);
    expect(repository.listIndexRoots(), hasLength(1));
    expect(repository.hasEntityForPath(badImage.path), isTrue);
  });

  test('scan keeps an epub entity when its preview parser fails', () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_epub_');
    addTearDown(() => temp.delete(recursive: true));
    final epub = File(p.join(temp.path, 'broken.epub'));
    await epub.writeAsBytes(const [0x00, 0x01, 0x02]);

    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);

    await LibraryScanner(repository).scanPath(temp.path);

    expect(repository.hasEntityForPath(epub.path), isTrue);
    expect(
      repository
          .listEntitiesUnderNode(_directoryRoot(repository).id)
          .single
          .format,
      'epub',
    );
  });

  test('scan write failure persists a recoverable job', () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_rollback_');
    addTearDown(() => temp.delete(recursive: true));
    final first = File(p.join(temp.path, 'a.txt'))..writeAsStringSync('a');
    final second = File(p.join(temp.path, 'b.txt'))..writeAsStringSync('b');

    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    await LibraryScanner(repository).scanPath(temp.path);
    final rootBefore = _directoryRoot(repository);
    final entitiesBefore = repository.listEntitiesUnderNode(rootBefore.id);
    expect(entitiesBefore.map((entity) => entity.title),
        containsAll(['a.txt', 'b.txt']));

    first.writeAsStringSync('a changed');
    second.writeAsStringSync('b changed');

    await expectLater(
      LibraryScanner(repository).scanPath(
        temp.path,
        onProgress: (progress) {
          if (progress.message.startsWith('正在写入索引：')) {
            throw StateError('forced scan write failure');
          }
        },
      ),
      throwsA(isA<StateError>()),
    );

    final failedJob = repository.listRecoverableIndexJobs().single;
    expect(failedJob.status, IndexJobStatus.failed);
    expect(failedJob.phase, IndexJobPhase.writing);

    final resumed = await LibraryScanner(repository).scanPath(temp.path);
    expect(resumed.scanned, 2);
    expect(repository.listRecoverableIndexJobs(), isEmpty);
    final rootAfter = _directoryRoot(repository);
    final entitiesAfter = repository.listEntitiesUnderNode(rootAfter.id);
    expect(rootAfter.id, rootBefore.id);
    expect(entitiesAfter.map((entity) => entity.title),
        containsAll(['a.txt', 'b.txt']));
    expect(entitiesAfter, hasLength(2));
  });

  test('scan can pause and resume from its persisted manifest', () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_pause_');
    addTearDown(() => temp.delete(recursive: true));
    for (var index = 0; index < 12; index++) {
      File(p.join(temp.path, '$index.txt')).writeAsStringSync('item $index');
    }
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    final control = IndexScanControl();

    await expectLater(
      LibraryScanner(repository).scanPath(
        temp.path,
        control: control,
        onProgress: (progress) {
          if (progress.message.startsWith('正在检查文件变化：6/')) {
            control.pause();
          }
        },
      ),
      throwsA(isA<IndexScanPausedException>()),
    );
    final paused = repository.listRecoverableIndexJobs().single;
    expect(paused.status, IndexJobStatus.paused);
    expect(repository.listIndexJobCandidates(paused.id), hasLength(12));
    expect(
      repository.listIndexJobCandidates(paused.id).every(
          (candidate) => candidate.state == IndexJobCandidateState.prepared),
      isTrue,
    );

    final resumed = await LibraryScanner(repository).scanPath(temp.path);
    expect(resumed.scanned, 12);
    expect(repository.listRecoverableIndexJobs(), isEmpty);
    expect(repository.listIndexJobCandidates(paused.id), isEmpty);
    expect(repository.listEntitiesUnderNode(_directoryRoot(repository).id),
        hasLength(12));
  });

  test('cancelling a scan discards its non-recoverable manifest', () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_cancel_');
    addTearDown(() => temp.delete(recursive: true));
    for (var index = 0; index < 12; index++) {
      File(p.join(temp.path, '$index.txt')).writeAsStringSync('item $index');
    }
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    final control = IndexScanControl();

    await expectLater(
      LibraryScanner(repository).scanPath(
        temp.path,
        control: control,
        onProgress: (progress) {
          if (progress.message.startsWith('正在检查文件变化：6/')) {
            control.cancel();
          }
        },
      ),
      throwsA(isA<IndexScanCanceledException>()),
    );

    expect(repository.listRecoverableIndexJobs(), isEmpty);
    expect(
      db.db.select('SELECT COUNT(*) AS value FROM index_jobs').single['value'],
      0,
    );
    expect(
      db.db
          .select('SELECT COUNT(*) AS value FROM index_job_candidates')
          .single['value'],
      0,
    );
  });

  test('scan resume reuses a partial preparation manifest', () async {
    final temp =
        await Directory.systemTemp.createTemp('best_viewer_partial_pause_');
    addTearDown(() => temp.delete(recursive: true));
    for (var index = 0; index < 240; index++) {
      File(p.join(temp.path, '$index.txt')).writeAsStringSync('item $index');
    }
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    final control = IndexScanControl();

    await expectLater(
      LibraryScanner(repository).scanPath(
        temp.path,
        control: control,
        onProgress: (progress) {
          if (progress.message.startsWith('正在检查文件变化：6/')) {
            control.pause();
          }
        },
      ),
      throwsA(isA<IndexScanPausedException>()),
    );
    final paused = repository.listRecoverableIndexJobs().single;
    expect(repository.listIndexJobCandidates(paused.id), hasLength(200));

    var reusedPartialManifest = false;
    await LibraryScanner(repository).scanPath(
      temp.path,
      onProgress: (progress) {
        reusedPartialManifest |= progress.message.startsWith('正在恢复元数据：200/');
      },
    );

    expect(reusedPartialManifest, isTrue);
    expect(repository.listEntitiesUnderNode(_directoryRoot(repository).id),
        hasLength(240));
  });

  test('deleting directory index preserves externally referenced entities',
      () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_delete_');
    addTearDown(() => temp.delete(recursive: true));
    await File('${temp.path}/d.txt').writeAsString('hello');

    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    await LibraryScanner(repository).scanPath(temp.path);

    final entity =
        repository.listEntitiesUnderNode(_directoryRoot(repository).id).single;
    final category = repository.ensureCategoryIndexRoot('收藏视图');
    repository.linkEntityToIndexNode(
      entityId: entity.id,
      indexNodeId: category.id,
    );

    final directoryIndex = repository
        .listIndexRoots()
        .singleWhere((node) => node.nodeType == NodeType.directoryIndexRoot);
    expect(
      repository.willDeleteEntitiesWhenDeletingNode(directoryIndex.id),
      isFalse,
    );
    repository.deleteIndexNode(directoryIndex.id);

    expect(repository.listEntitiesUnderNode(directoryIndex.id), isEmpty);
    expect(repository.getEntity(entity.id), isNotNull);
    expect(File(entity.path).existsSync(), isTrue);
    expect(repository.listEntitiesUnderNode(category.id), hasLength(1));
  });

  test(
      'directory deletion reports references and force deletion keeps source files',
      () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_delete_');
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}/d.txt');
    await source.writeAsString('hello');

    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    await LibraryScanner(repository).scanPath(temp.path);

    final directoryRoot = _directoryRoot(repository);
    final entity = repository.listEntitiesUnderNode(directoryRoot.id).single;
    expect(repository.getEntity(entity.id)!.directoryRootId, directoryRoot.id);

    final collection = repository.ensureCategoryIndexRoot('其它索引');
    repository.linkEntityToIndexNode(
      entityId: entity.id,
      indexNodeId: collection.id,
    );

    final report = repository.inspectDirectoryIndexDeletion(directoryRoot.id);
    expect(report.entityCount, 1);
    expect(report.conflicts, hasLength(1));
    expect(report.conflicts.single.indexNames, ['其它索引']);
    expect(
      () => repository.deleteDirectoryIndex(directoryRoot.id, force: false),
      throwsStateError,
    );

    final result =
        repository.deleteDirectoryIndex(directoryRoot.id, force: true);
    expect(result.deletedEntityCount, 1);
    expect(repository.getEntity(entity.id), isNull);
    expect(repository.listEntitiesUnderNode(collection.id), isEmpty);
    expect(source.existsSync(), isTrue);
  });

  test('directory deletion does not depend on SQLite parameter count', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    final root = repository.ensureDirectoryIndexRoot(r'D:\bulk-delete');

    for (var index = 0; index < 1100; index++) {
      repository.upsertEntity(
        path: 'D:\\bulk-delete\\file-$index.txt',
        name: 'file-$index.txt',
        format: 'txt',
        entityType: EntityType.text,
        hash: 'hash-$index',
        size: 1,
        sourceCreatedAtMs: 1,
        sourceModifiedAtMs: 1,
        directoryRootId: root.id,
      );
    }

    final result = repository.deleteDirectoryIndex(root.id, force: false);
    expect(result.deletedEntityCount, 1100);
    expect(repository.listIndexRoots(), isEmpty);
  });

  test('rescan preserves cloned entity references for missing source files',
      () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_clone_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/chapter.txt');
    await file.writeAsString('hello');

    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    await LibraryScanner(repository).scanPath(temp.path);
    final sourceRoot = _directoryRoot(repository);
    final collection = repository.ensureCollectionIndexRoot('收藏');
    final clonedRoot = repository.cloneIndexNodeTree(
      sourceNodeId: sourceRoot.id,
      targetParentId: collection.id,
    );
    final entity = repository.listEntitiesUnderNode(sourceRoot.id).single;

    await file.delete();
    await LibraryScanner(repository).scanPath(temp.path);

    expect(repository.getEntity(entity.id), isNotNull);
    expect(repository.listEntitiesUnderNode(clonedRoot.id), hasLength(1));
  });

  test('deleting directory child node removes only subtree entities', () async {
    final temp =
        await Directory.systemTemp.createTemp('best_viewer_child_delete_');
    addTearDown(() => temp.delete(recursive: true));
    final left = Directory(p.join(temp.path, 'left'));
    final right = Directory(p.join(temp.path, 'right'));
    await left.create(recursive: true);
    await right.create(recursive: true);
    await File(p.join(left.path, 'left.txt')).writeAsString('left');
    await File(p.join(right.path, 'right.txt')).writeAsString('right');

    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    await LibraryScanner(repository).scanPath(temp.path);

    final root = _directoryRoot(repository);
    final tree = repository.listIndexTree(root.id);
    final leftNode = tree.singleWhere((node) => node.item.name == 'left').item;
    final rightNode =
        tree.singleWhere((node) => node.item.name == 'right').item;
    final leftEntity = repository.listEntitiesUnderNode(leftNode.id).single;
    final rightEntity = repository.listEntitiesUnderNode(rightNode.id).single;

    expect(repository.willDeleteEntitiesWhenDeletingNode(leftNode.id), isTrue);
    repository.deleteIndexNode(leftNode.id);

    expect(repository.getEntity(leftEntity.id), isNull);
    expect(repository.getEntity(rightEntity.id), isNotNull);
    expect(repository.listEntitiesUnderNode(root.id), hasLength(1));
    expect(repository.listEntitiesUnderNode(root.id).single.title, 'right.txt');
    expect(File(leftEntity.path).existsSync(), isTrue);
    expect(File(rightEntity.path).existsSync(), isTrue);
  });

  test('updating a directory node only reconciles its own subtree', () async {
    final temp =
        await Directory.systemTemp.createTemp('best_viewer_targeted_update_');
    addTearDown(() => temp.delete(recursive: true));
    final left = Directory(p.join(temp.path, 'left'));
    final right = Directory(p.join(temp.path, 'right'));
    await left.create(recursive: true);
    await right.create(recursive: true);
    final stale = File(p.join(left.path, 'stale.txt'));
    await stale.writeAsString('stale');
    await File(p.join(right.path, 'right.txt')).writeAsString('right');

    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    final scanner = LibraryScanner(repository);
    await scanner.scanPath(temp.path);

    final root = _directoryRoot(repository);
    final leftNode = repository
        .listChildNodes(root.id)
        .singleWhere((node) => node.name == 'left');
    final rightNode = repository
        .listChildNodes(root.id)
        .singleWhere((node) => node.name == 'right');
    await stale.delete();
    await File(p.join(left.path, 'new.txt')).writeAsString('new');

    await scanner.scanDirectoryNode(leftNode.id);

    expect(
      repository
          .listEntitiesUnderNode(leftNode.id)
          .map((entity) => entity.title),
      ['new.txt'],
    );
    expect(
      repository
          .listEntitiesUnderNode(rightNode.id)
          .map((entity) => entity.title),
      ['right.txt'],
    );
  });

  test('directory reconciliation removes empty generated folders', () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_prune_');
    addTearDown(() => temp.delete(recursive: true));
    final nested = Directory(p.join(temp.path, 'nested'))..createSync();
    final source = File(p.join(nested.path, 'only.txt'));
    await source.writeAsString('only file');

    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    await LibraryScanner(repository).scanPath(temp.path);
    final root = _directoryRoot(repository);
    expect(repository.listChildNodes(root.id), hasLength(1));

    await source.delete();
    await LibraryScanner(repository).scanPath(temp.path);

    expect(repository.getIndexNode(root.id), isNotNull);
    expect(repository.listChildNodes(root.id), isEmpty);
    expect(repository.listEntitiesUnderNode(root.id), isEmpty);
  });

  test('scanning parent path replaces existing child directory index',
      () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_parent_');
    addTearDown(() => temp.delete(recursive: true));
    final child = Directory(p.join(temp.path, 'child'));
    await child.create(recursive: true);
    await File(p.join(child.path, 'child.txt')).writeAsString('child');
    await File(p.join(temp.path, 'root.txt')).writeAsString('root');

    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);

    await LibraryScanner(repository).scanPath(child.path);
    expect(
        repository.listIndexRoots().single.sourcePath, p.normalize(child.path));
    expect(
      repository.listEntitiesUnderNode(_directoryRoot(repository).id),
      hasLength(1),
    );

    await LibraryScanner(repository).scanPath(temp.path);

    final indexRoots = repository
        .listIndexRoots()
        .where((node) => node.nodeType == NodeType.directoryIndexRoot)
        .toList();
    expect(indexRoots, hasLength(1));
    expect(indexRoots.single.sourcePath, p.normalize(temp.path));
    final parentRoot = _directoryRoot(repository);
    expect(repository.listEntitiesUnderNode(parentRoot.id), hasLength(2));
    expect(
      repository
          .listEntitiesUnderNode(parentRoot.id)
          .map((entity) => entity.title),
      containsAll(['child.txt', 'root.txt']),
    );
  });

  test('scanning child path replaces existing parent directory index',
      () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_child_');
    addTearDown(() => temp.delete(recursive: true));
    final child = Directory(p.join(temp.path, 'child'));
    await child.create(recursive: true);
    await File(p.join(temp.path, 'root.txt')).writeAsString('root');
    await File(p.join(child.path, 'child.txt')).writeAsString('child');

    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);

    await LibraryScanner(repository).scanPath(temp.path);
    expect(repository.listEntitiesUnderNode(_directoryRoot(repository).id),
        hasLength(2));

    await LibraryScanner(repository).scanPath(child.path);

    final indexRoots = repository
        .listIndexRoots()
        .where((node) => node.nodeType == NodeType.directoryIndexRoot)
        .toList();
    expect(indexRoots, hasLength(1));
    expect(indexRoots.single.sourcePath, p.normalize(child.path));
    final childRoot = _directoryRoot(repository);
    final entities = repository.listEntitiesUnderNode(childRoot.id);
    expect(entities, hasLength(1));
    expect(entities.single.title, 'child.txt');
    expect(repository.hasEntityForPath(p.join(temp.path, 'root.txt')), isFalse);
  });

  test('failed overlapping scan keeps the existing directory index', () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_overlap_');
    addTearDown(() => temp.delete(recursive: true));
    final child = Directory(p.join(temp.path, 'child'))..createSync();
    await File(p.join(temp.path, 'root.txt')).writeAsString('root');
    await File(p.join(child.path, 'child.txt')).writeAsString('child');

    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    await LibraryScanner(repository).scanPath(temp.path);
    final original = _directoryRoot(repository);

    await expectLater(
      LibraryScanner(repository).scanPath(
        child.path,
        onProgress: (progress) {
          if (progress.message.startsWith('正在写入索引：')) {
            throw StateError('force overlapping scan failure');
          }
        },
      ),
      throwsA(isA<StateError>()),
    );

    expect(repository.getIndexNode(original.id), isNotNull);
    expect(repository.listEntitiesUnderNode(original.id), hasLength(2));
  });

  test('graph node edges are stored and cascade on node delete', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);

    final graph = repository.ensureGraphIndexRoot('关系图');
    final a = repository.ensureGraphNode(parentId: graph.id, name: 'A');
    final b = repository.ensureGraphNode(parentId: graph.id, name: 'B');
    final otherGraph = repository.ensureGraphIndexRoot('另一个关系图');
    final otherGraphNode = repository.ensureGraphNode(
      parentId: otherGraph.id,
      name: 'C',
    );
    final categoryRoot = repository.ensureCategoryIndexRoot('分类图边测试');
    final category = repository.ensureIndexNode(
      parentId: categoryRoot.id,
      name: '分类节点',
      nodeType: NodeType.category,
      viewType: ViewType.tree,
    );

    final edge = repository.linkIndexNodes(
      fromNodeId: a.id,
      toNodeId: b.id,
      edgeType: ' next ',
      label: ' 下一项 ',
    );

    expect(edge.edgeType, 'next');
    expect(edge.label, '下一项');
    final sameEdge = repository.linkIndexNodes(
      fromNodeId: a.id,
      toNodeId: b.id,
      edgeType: 'next',
      label: '重复下一项',
    );
    expect(sameEdge.id, edge.id);
    final unlabeled = repository.linkIndexNodes(
      fromNodeId: b.id,
      toNodeId: a.id,
      edgeType: ' reference ',
      label: '   ',
    );
    expect(unlabeled.edgeType, 'reference');
    expect(unlabeled.label, isNull);
    expect(
      () => repository.linkIndexNodes(
        fromNodeId: a.id,
        toNodeId: b.id,
        edgeType: '   ',
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => repository.linkIndexNodes(
        fromNodeId: 'missing-node',
        toNodeId: b.id,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => repository.linkIndexNodes(
        fromNodeId: category.id,
        toNodeId: b.id,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => repository.linkIndexNodes(
        fromNodeId: a.id,
        toNodeId: category.id,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => repository.linkIndexNodes(
        fromNodeId: a.id,
        toNodeId: otherGraphNode.id,
      ),
      throwsA(isA<ArgumentError>()),
    );
    final systemRootId = db.db
        .select("SELECT id FROM index_nodes WHERE node_type = 'root'")
        .single['id'] as String;
    expect(
      () => repository.linkIndexNodes(
        fromNodeId: systemRootId,
        toNodeId: b.id,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => db.db.execute(
        '''
        INSERT INTO index_node_edges
        (id, from_node_id, to_node_id, edge_type, label, sort_order)
        VALUES (?, ?, ?, ?, ?, 0)
        ''',
        ['duplicate-edge', a.id, b.id, 'next', '重复下一项'],
      ),
      throwsA(anything),
    );
    expect(repository.listOutgoingEdges(a.id), hasLength(1));
    expect(repository.listIncomingEdges(b.id), hasLength(1));
    expect(repository.listIncomingEdges(b.id).single.fromNodeId, a.id);

    repository.deleteIndexNode(b.id);

    expect(repository.listOutgoingEdges(a.id), isEmpty);
    expect(repository.listIncomingEdges(b.id), isEmpty);
    expect(repository.listIncomingEdges(a.id), isEmpty);
  });

  test('graph node positions are persisted and isolated by graph root', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);

    final graph = repository.ensureGraphIndexRoot('布局图');
    final node = repository.ensureGraphNode(parentId: graph.id, name: 'A');
    final otherGraph = repository.ensureGraphIndexRoot('另一张布局图');
    final otherNode = repository.ensureGraphNode(
      parentId: otherGraph.id,
      name: 'B',
    );

    repository.setGraphNodePosition(nodeId: node.id, x: 120, y: 240);
    repository.setGraphNodePosition(nodeId: otherNode.id, x: 8, y: 16);
    repository.setGraphNodePosition(nodeId: node.id, x: 360, y: 480);

    final positions = repository.listGraphNodePositions(graph.id);
    expect(positions, hasLength(1));
    expect(positions[node.id]!.x, 360);
    expect(positions[node.id]!.y, 480);
    expect(
        repository.listGraphNodePositions(otherGraph.id)[otherNode.id]!.x, 8);
  });

  test('graph nodes can contain nested graph nodes and entity references', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    final graph = repository.ensureGraphIndexRoot('内容图');
    final parent = repository.ensureGraphNode(parentId: graph.id, name: '主题');
    final child = repository.ensureGraphNode(parentId: parent.id, name: '子主题');
    final entity = repository
        .upsertEntity(
          path: r'D:\\virtual\\graph-content.txt',
          name: 'graph-content.txt',
          format: 'txt',
          entityType: EntityType.text,
          hash: 'graph-content',
          size: 10,
          sourceCreatedAtMs: 1,
          sourceModifiedAtMs: 1,
        )
        .entity;

    repository.linkEntityToIndexNode(
        entityId: entity.id, indexNodeId: parent.id);

    expect(repository.listGraphNodes(graph.id).map((node) => node.id),
        containsAll([parent.id, child.id]));
    expect(repository.listChildNodes(graph.id, parentId: parent.id).single.id,
        child.id);
    expect(repository.listEntitiesDirectlyUnderNode(parent.id).single.id,
        entity.id);
    expect(
      repository
          .listEntitiesForNodeLinkPicker(query: 'graph-content')
          .single
          .id,
      entity.id,
    );

    repository.deleteIndexNode(parent.id);

    expect(repository.listGraphNodes(graph.id), isEmpty);
    expect(repository.getEntity(entity.id), isNotNull);
  });

  test('graph node trees can be copied into a custom index', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    final graph = repository.ensureGraphIndexRoot('图源');
    final graphNode = repository.ensureGraphNode(
      parentId: graph.id,
      name: '关系节点',
    );
    final child = repository.ensureGraphNode(
      parentId: graphNode.id,
      name: '关系子节点',
    );
    final entity = repository
        .upsertEntity(
          path: r'D:\\virtual\\graph-copy.txt',
          name: 'graph-copy.txt',
          format: 'txt',
          entityType: EntityType.text,
          hash: 'graph-copy',
          size: 10,
          sourceCreatedAtMs: 1,
          sourceModifiedAtMs: 1,
        )
        .entity;
    repository.linkEntityToIndexNode(
      entityId: entity.id,
      indexNodeId: graphNode.id,
    );
    final collection = repository.ensureCollectionIndexRoot('目标');

    final copied = repository.cloneIndexNodeTree(
      sourceNodeId: graphNode.id,
      targetParentId: collection.id,
    );

    expect(copied.nodeType, NodeType.category);
    expect(repository.listEntitiesDirectlyUnderNode(copied.id).single.id,
        entity.id);
    expect(
        repository
            .listChildNodes(collection.id, parentId: copied.id)
            .single
            .name,
        child.name);
  });
}

IndexNode _directoryRoot(LibraryRepository repository) {
  return repository
      .listIndexRoots()
      .singleWhere((node) => node.nodeType == NodeType.directoryIndexRoot);
}

Uint8List _testThumbnailPng({int red = 12}) {
  final image = img.Image(
    width: indexThumbnailWidth,
    height: indexThumbnailHeight,
    numChannels: 4,
  );
  img.fill(image, color: img.ColorRgba8(red, 34, 56, 255));
  return Uint8List.fromList(img.encodePng(image));
}
