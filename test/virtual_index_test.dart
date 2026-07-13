import 'package:flutter_test/flutter_test.dart';

import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';

void main() {
  late AppDatabase database;
  late LibraryRepository repository;

  setUp(() {
    database = AppDatabase.openInMemory();
    repository = LibraryRepository(database);
  });

  tearDown(() => database.close());

  Entity addEntity({
    required String name,
    required String format,
    EntityType type = EntityType.text,
  }) {
    final entity = repository
        .upsertEntity(
          path: r'D:\library\' + name,
          name: name,
          format: format,
          entityType: type,
          hash: '$name:1',
          size: 100,
          sourceCreatedAtMs: 1000,
          sourceModifiedAtMs: 2000,
        )
        .entity;
    return entity;
  }

  test('one entity can be referenced by several manual collections', () {
    final entity = addEntity(name: 'silver-wolf.epub', format: 'epub');
    final reading = repository.createCollectionWithEntities(
      name: '待读',
      entityIds: [entity.id],
    );
    final favorite = repository.createCollectionWithEntities(
      name: '银狼相关',
      entityIds: [entity.id],
    );

    expect(repository.listEntitiesDirectlyUnderNode(reading.id), hasLength(1));
    expect(repository.listEntitiesDirectlyUnderNode(favorite.id), hasLength(1));

    repository.deleteIndexNode(reading.id);
    expect(repository.getEntity(entity.id), isNotNull);
    expect(repository.listEntitiesDirectlyUnderNode(favorite.id), hasLength(1));
  });

  test('custom index nodes own references without owning entities', () {
    final entity = addEntity(name: 'chapter-one.txt', format: 'txt');
    final custom = repository.ensureCollectionIndexRoot('待读');
    final node = repository.createCustomNode(parentId: custom.id, name: '小说');
    repository.linkEntitiesToIndexNode(
      entityIds: [entity.id],
      indexNodeId: node.id,
    );

    final summaries = repository.listIndexNodeSummaries([custom.id, node.id]);
    expect(summaries[custom.id]!.childNodeCount, 1);
    expect(summaries[custom.id]!.descendantEntityCount, 1);
    expect(summaries[node.id]!.directEntityCount, 1);

    repository.deleteIndexNode(node.id);
    expect(repository.getEntity(entity.id), isNotNull);
    expect(repository.listChildNodes(custom.id), isEmpty);
  });

  test('cloning a node tree creates new nodes and reuses entity references',
      () {
    final entity = addEntity(name: 'chapter.txt', format: 'txt');
    final sourceRoot = repository.ensureCollectionIndexRoot('原始');
    final sourceChild =
        repository.createCustomNode(parentId: sourceRoot.id, name: '第一章');
    repository.linkEntityToIndexNode(
      entityId: entity.id,
      indexNodeId: sourceChild.id,
    );
    final targetRoot = repository.ensureCollectionIndexRoot('收藏');

    final clonedRoot = repository.cloneIndexNodeTree(
      sourceNodeId: sourceRoot.id,
      targetParentId: targetRoot.id,
    );
    final clonedChild = repository
        .listChildNodes(
          targetRoot.id,
          parentId: clonedRoot.id,
        )
        .single;

    expect(clonedRoot.id, isNot(sourceRoot.id));
    expect(clonedChild.id, isNot(sourceChild.id));
    expect(clonedChild.name, sourceChild.name);
    expect(
      repository.listEntitiesDirectlyUnderNode(clonedChild.id).single.id,
      entity.id,
    );
  });

  test('recursive entity page keeps node groups and de-duplicates references',
      () {
    final rootEntity = addEntity(name: 'root.txt', format: 'txt');
    final childZ = addEntity(name: 'zeta.txt', format: 'txt');
    final childA = addEntity(name: 'alpha.txt', format: 'txt');
    final collection = repository.ensureCollectionIndexRoot('沉浸浏览');
    final child =
        repository.createCustomNode(parentId: collection.id, name: '子节点');
    repository.linkEntitiesToIndexNode(
      entityIds: [rootEntity.id, childA.id],
      indexNodeId: collection.id,
    );
    repository.linkEntitiesToIndexNode(
      entityIds: [childZ.id, childA.id],
      indexNodeId: child.id,
    );

    final firstPage = repository.listEntityPageRecursivelyUnderNode(
      collection.id,
      sortMode: EntitySortMode.nameAsc,
      limit: 1,
    );
    final secondPage = repository.listEntityPageRecursivelyUnderNode(
      collection.id,
      sortMode: EntitySortMode.nameAsc,
      after: firstPage.recursiveCursor,
      limit: 1,
    );
    final thirdPage = repository.listEntityPageRecursivelyUnderNode(
      collection.id,
      sortMode: EntitySortMode.nameAsc,
      after: secondPage.recursiveCursor,
      limit: 1,
    );

    expect(firstPage.items.single.title, 'alpha.txt');
    expect(secondPage.items.single.title, 'root.txt');
    expect(thirdPage.items.single.title, 'zeta.txt');
    expect(thirdPage.hasMore, isFalse);
  });
}
