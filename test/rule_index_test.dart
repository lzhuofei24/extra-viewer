import 'dart:io';

import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_read_worker.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('access rule covers use visited visual results and configured order',
      () async {
    final temp = await Directory.systemTemp.createTemp('rule_covers_');
    addTearDown(() => temp.delete(recursive: true));
    final database =
        AppDatabase.openAtPathForTesting(p.join(temp.path, 'library.db'));
    addTearDown(database.close);
    final repository = LibraryRepository(database);
    final oldLarge = _entity(repository, 'large.jpg', EntityType.image, 100);
    final newSmall = _entity(repository, 'small.mp4', EntityType.video, 10);
    final outside = _entity(repository, 'outside.jpg', EntityType.image, 1000);
    final note = _entity(repository, 'note.txt', EntityType.text, 200);
    database.db.execute(
        'UPDATE entities SET source_modified_at_ms = 1 WHERE id = ?',
        [oldLarge.id]);
    database.db.execute(
        'UPDATE entities SET source_modified_at_ms = 2 WHERE id = ?',
        [newSmall.id]);
    database.db.execute(
        'UPDATE entities SET source_modified_at_ms = 999 WHERE id = ?',
        [outside.id]);
    final capped = repository.createRule(
        name: '限制',
        entityTypes: [EntityType.image, EntityType.video],
        maxSize: 100,
        defaultSort: RuleSortMode.size,
        maxResults: 1);
    final all = repository.createRule(name: '全部视觉');
    final text =
        repository.createRule(name: '文本', entityTypes: [EntityType.text]);
    repository.markOpened(newSmall.id);
    repository.markOpened(outside.id);
    repository.markOpened(note.id);
    repository.markOpened(oldLarge.id);
    final worker = await LibraryReadWorker.start(
        databasePath: database.databasePath!,
        storageDirectoryPath: database.storageDirectoryPath);
    addTearDown(worker.close);
    final covers = await worker
        .loadRuleCovers([capped.node.id, all.node.id, text.node.id, 'deleted']);
    expect(covers[capped.node.id]!.id, oldLarge.id);
    expect(covers[all.node.id]!.id, oldLarge.id);
    expect(covers.containsKey(text.node.id), isFalse);
    expect(covers.containsKey('deleted'), isFalse);
    await worker.loadRulePage(
        ruleNodeId: all.node.id, sortMode: RuleSortMode.name);
    expect((await worker.loadRuleCovers([all.node.id]))[all.node.id]!.id,
        oldLarge.id);
    expect((await worker.loadRuleCovers([all.node.id]))[all.node.id]!.id,
        oldLarge.id);
  });

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

  test('built-in and custom access rules filter, sort and paginate visits',
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
    final custom = repository.createRule(
      name: '小型文本',
      entityTypes: const [EntityType.text, EntityType.document],
      extensions: const ['md', 'epub'],
      minSize: 15,
      maxSize: 35,
      defaultSort: RuleSortMode.size,
    );
    for (var i = 0; i < 3; i++) {
      repository.markOpened(image.id);
    }
    repository.markOpened(text.id);
    repository.markOpened(document.id);
    repository.markOpened(audio.id);
    final worker = await LibraryReadWorker.start(
      databasePath: database.databasePath!,
      storageDirectoryPath: database.storageDirectoryPath,
    );
    addTearDown(worker.close);
    final rules = await worker.listRules();
    expect(rules.take(3).map((rule) => rule.node.name), [
      '常用',
      '最近图片',
      '最近视频',
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

    final customPage = await worker.loadRulePage(ruleNodeId: custom.node.id);
    expect(customPage.items.map((item) => item.id), [document.id, text.id]);
  });

  test('access rules reject directory and relative-time conditions', () {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final repository = LibraryRepository(database);
    final root = repository.ensureDirectoryIndexRoot('/scope');
    expect(() => repository.createRule(name: '范围', scopeNodeId: root.id),
        throwsArgumentError);
    expect(() => repository.createRule(name: '时间', openedWithinDays: 7),
        throwsArgumentError);
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

  test('custom rules only accumulate matching files after they are visited',
      () async {
    final temp = await Directory.systemTemp.createTemp('access_rule_test_');
    addTearDown(() => temp.delete(recursive: true));
    final database =
        AppDatabase.openAtPathForTesting(p.join(temp.path, 'library.db'));
    addTearDown(database.close);
    final repository = LibraryRepository(database);
    final first = _entity(repository, 'first.jpg', EntityType.image, 10);
    final text = _entity(repository, 'note.txt', EntityType.text, 20);
    final newest = _entity(repository, 'newest.mp4', EntityType.video, 30);
    final rule = repository.createRule(
      name: '访问过的视觉文件',
      entityTypes: const [EntityType.image, EntityType.video],
    );

    final worker = await LibraryReadWorker.start(
      databasePath: database.databasePath!,
      storageDirectoryPath: database.storageDirectoryPath,
    );
    addTearDown(worker.close);
    expect(
        (await worker.loadRulePage(ruleNodeId: rule.node.id)).items, isEmpty);
    repository.markOpened(first.id);
    repository.markOpened(text.id);
    repository.markOpened(newest.id);
    final summaries = await worker.loadRuleSummaries([rule.node.id]);
    expect(summaries[rule.node.id]!.count, 2);
    expect(summaries[rule.node.id]!.cover!.id, newest.id);
    final page = await worker.loadRulePage(ruleNodeId: rule.node.id);
    expect(page.items.map((item) => item.id), [newest.id, first.id]);
    repository.markOpened(first.id);
    final covers = await worker.loadRuleCovers([rule.node.id]);
    expect(covers[rule.node.id]!.id, first.id);

    repository.updateRule(
      nodeId: rule.node.id,
      name: rule.node.name,
      entityTypes: const [EntityType.video],
    );
    expect(
        (await worker.loadRulePage(ruleNodeId: rule.node.id)).items, isEmpty);
    repository.markOpened(first.id);
    repository.markOpened(newest.id);
    expect(
      (await worker.loadRulePage(ruleNodeId: rule.node.id))
          .items
          .map((item) => item.id),
      [newest.id],
    );
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
