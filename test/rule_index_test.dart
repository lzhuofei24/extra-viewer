import 'dart:io';

import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_read_worker.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('system favorites and built-in rules reject rename and delete', () {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final repository = LibraryRepository(database);
    final favorites = database.db
        .select("SELECT id FROM index_nodes WHERE system_key = 'favorites'")
        .single['id'] as String;
    final builtIn = database.db
        .select("SELECT id FROM index_nodes WHERE system_key = 'rule.frequent'")
        .single['id'] as String;

    expect(() => repository.renameIndexNode(favorites, '其它'), throwsStateError);
    expect(() => repository.deleteIndexNode(favorites), throwsStateError);
    expect(() => repository.renameIndexNode(builtIn, '其它'), throwsStateError);
    expect(() => repository.deleteRule(builtIn), throwsStateError);
  });

  test('opening an entity increments access count atomically', () {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final repository = LibraryRepository(database);
    final entity = _entity(repository, 'opened.jpg', EntityType.image, 10);

    repository.markOpened(entity.id);
    repository.markOpened(entity.id);

    final opened = repository.getEntity(entity.id)!;
    expect(opened.openCount, 2);
    expect(opened.lastOpenedAtMs, isNotNull);
  });

  test('built-in and custom rules filter, sort and paginate dynamically',
      () async {
    final temp = await Directory.systemTemp.createTemp('rule_index_test_');
    addTearDown(() => temp.delete(recursive: true));
    final database =
        AppDatabase.openAtPathForTesting(p.join(temp.path, 'library.db'));
    addTearDown(database.close);
    final repository = LibraryRepository(database);
    final image = _entity(repository, 'image.jpg', EntityType.image, 10);
    final text = _entity(repository, 'note.md', EntityType.text, 20);
    final document = _entity(repository, 'book.epub', EntityType.document, 30);
    final audio = _entity(repository, 'song.mp3', EntityType.audio, 40);
    for (var i = 0; i < 3; i++) {
      repository.markOpened(image.id);
    }
    repository.markOpened(text.id);
    repository.markOpened(document.id);
    repository.markOpened(audio.id);

    final custom = repository.createRule(
      name: '小型文本',
      entityTypes: const [EntityType.text, EntityType.document],
      extensions: const ['md', 'epub'],
      minSize: 15,
      maxSize: 35,
      defaultSort: RuleSortMode.size,
    );
    final worker = await LibraryReadWorker.start(
      databasePath: database.databasePath!,
      storageDirectoryPath: database.storageDirectoryPath,
    );
    addTearDown(worker.close);
    final rules = await worker.listRules();
    expect(rules.take(5).map((rule) => rule.node.name), [
      '常用',
      '最近图片',
      '最近视频',
      '最近文本',
      '最近音乐',
    ]);

    final frequent = await worker.loadRulePage(
      ruleNodeId: rules.first.node.id,
      limit: 2,
    );
    expect(frequent.items.first.id, image.id);
    expect(frequent.hasMore, isTrue);
    final frequentNext = await worker.loadRulePage(
      ruleNodeId: rules.first.node.id,
      after: frequent.cursor,
      limit: 2,
    );
    expect(
      frequent.items
          .followedBy(frequentNext.items)
          .map((item) => item.id)
          .toSet(),
      hasLength(4),
    );

    final recentText = rules.firstWhere(
      (rule) => rule.builtInKind == BuiltInRuleKind.recentText,
    );
    final textPage = await worker.loadRulePage(ruleNodeId: recentText.node.id);
    expect(
        textPage.items.map((item) => item.id).toSet(), {text.id, document.id});

    final customPage = await worker.loadRulePage(ruleNodeId: custom.node.id);
    expect(customPage.items.map((item) => item.id), [document.id, text.id]);
    expect(() => repository.createRule(name: '嵌套', scopeNodeId: custom.node.id),
        throwsArgumentError);
  });

  test('rule scope is recursive and relative time filters combine with AND',
      () async {
    final temp = await Directory.systemTemp.createTemp('rule_scope_test_');
    addTearDown(() => temp.delete(recursive: true));
    final database =
        AppDatabase.openAtPathForTesting(p.join(temp.path, 'library.db'));
    addTearDown(database.close);
    final repository = LibraryRepository(database);
    final root = repository.ensureDirectoryIndexRoot('/scope');
    final child = repository.ensureIndexNode(
      parentId: root.id,
      name: 'child',
      nodeType: NodeType.folder,
      viewType: ViewType.tree,
    );
    final inside = _entity(repository, 'inside.jpg', EntityType.image, 10);
    final outside = _entity(repository, 'outside.jpg', EntityType.image, 10);
    repository.linkEntityToIndexNode(
        entityId: inside.id, indexNodeId: child.id);
    repository.linkEntityToIndexNode(
        entityId: outside.id, indexNodeId: root.id);
    repository.markOpened(inside.id);
    repository.markOpened(outside.id);
    final now = DateTime.now().millisecondsSinceEpoch;
    database.db.execute(
      'UPDATE entities SET source_modified_at_ms = ? WHERE id = ?',
      [now - const Duration(days: 40).inMilliseconds, outside.id],
    );
    final scoped = repository.createRule(
      name: '范围和时间',
      entityTypes: const [EntityType.image],
      scopeNodeId: child.id,
      modifiedWithinDays: 7,
      openedWithinDays: 7,
    );
    final worker = await LibraryReadWorker.start(
      databasePath: database.databasePath!,
      storageDirectoryPath: database.storageDirectoryPath,
    );
    addTearDown(worker.close);

    final page = await worker.loadRulePage(ruleNodeId: scoped.node.id);
    expect(page.items.map((item) => item.id), [inside.id]);
  });

  test('built-in rules enforce the 1000 result cap across pages', () async {
    final temp = await Directory.systemTemp.createTemp('rule_cap_test_');
    addTearDown(() => temp.delete(recursive: true));
    final database =
        AppDatabase.openAtPathForTesting(p.join(temp.path, 'library.db'));
    addTearDown(database.close);
    final repository = LibraryRepository(database);
    for (var index = 0; index < 1005; index++) {
      final entity = _entity(
        repository,
        'cap-$index.jpg',
        EntityType.image,
        index + 1,
      );
      repository.markOpened(entity.id);
    }
    final worker = await LibraryReadWorker.start(
      databasePath: database.databasePath!,
      storageDirectoryPath: database.storageDirectoryPath,
    );
    addTearDown(worker.close);
    final frequent = (await worker.listRules()).firstWhere(
      (rule) => rule.builtInKind == BuiltInRuleKind.frequent,
    );
    final ids = <String>{};
    RulePageCursor? cursor;
    do {
      final page = await worker.loadRulePage(
        ruleNodeId: frequent.node.id,
        after: cursor,
      );
      ids.addAll(page.items.map((item) => item.id));
      cursor = page.hasMore ? page.cursor : null;
    } while (cursor != null);

    expect(ids, hasLength(1000));
  });
}

Entity _entity(
  LibraryRepository repository,
  String name,
  EntityType type,
  int size,
) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return repository
      .upsertEntity(
        path: '/source/$name',
        name: name,
        format: name.split('.').last,
        entityType: type,
        hash: name,
        size: size,
        sourceCreatedAtMs: now,
        sourceModifiedAtMs: now,
      )
      .entity;
}
