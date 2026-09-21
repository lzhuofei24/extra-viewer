import 'dart:io';
import 'dart:convert';
import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/database/library_read_worker.dart';
import 'package:best_viewer/src/core/database/query_revisions.dart';
import 'package:best_viewer/src/core/database/source_locations.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/modules/sources/source_identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:best_viewer/src/core/database/local_statistics.dart';

void main() {
  test('reading anchors have one structured storage location', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repo = LibraryRepository(db);
    final entity = repo
        .upsertEntity(
            path: '/book.pdf',
            name: 'book.pdf',
            format: 'pdf',
            entityType: EntityType.document,
            hash: 'doc',
            size: 1,
            sourceCreatedAtMs: 0,
            sourceModifiedAtMs: 0)
        .entity;
    repo.saveReaderState(
        entityId: entity.id,
        extraStateJson: jsonEncode({
          'theme': 'dark',
          'readingPosition': {
            'version': 1,
            'kind': 'reflow',
            'sourceRevision': 1,
            'chapter': 2,
            'chapterTitle': 'Chapter',
            'page': 5,
            'block': 8,
            'blockKey': 'anchor',
            'blockFraction': 0.5,
            'mode': 'book',
            'scrollOffset': 20.0
          }
        }));
    final stored = db.db.select('SELECT * FROM entity_progress').single;
    expect(stored['document_revision'], 1);
    expect(stored['chapter_index'], 2);
    expect(stored['block_key'], 'anchor');
    expect(jsonDecode(stored['settings_json'] as String), {'theme': 'dark'});
    final restored =
        jsonDecode(repo.getEntity(entity.id)!.extraStateJson!) as Map;
    expect(restored['readingPosition']['blockFraction'], 0.5);
    repo.saveReaderState(entityId: entity.id, zoomScale: 2);
    expect(
        jsonDecode(repo.getEntity(entity.id)!.extraStateJson!)[
            'readingPosition']['page'],
        5);
    expect(() => db.db.execute('UPDATE entity_progress SET block_fraction=2'),
        throwsA(isA<SqliteException>()));
  });

  test('statistics reject stale results across publication generations', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repo = LibraryRepository(db)..deferStatistics = true;
    final root = repo.ensureCollectionIndexRoot('Statistics');
    final before = computeDirtyStatistics(db.db);
    repo.createCustomNode(parentId: root.id, name: 'First');
    publishStatistics(db.db, before);
    expect(
        db.db.select(
            'SELECT 1 FROM index_stats_dirty WHERE node_id=?', [root.id]),
        isNotEmpty);
    final current = computeDirtyStatistics(db.db);
    publishStatistics(db.db, current);
    repo.createCustomNode(parentId: root.id, name: 'Second');
    publishStatistics(db.db, current);
    expect(
        db.db.select(
            'SELECT child_node_count FROM index_node_stats WHERE node_id=?',
            [root.id]).single['child_node_count'],
        1);
    expect(
        db.db.select(
            'SELECT 1 FROM index_stats_dirty WHERE node_id=?', [root.id]),
        isNotEmpty);
    refreshDirtyStatistics(db.db);
    expect(
        db.db.select(
            'SELECT child_node_count FROM index_node_stats WHERE node_id=?',
            [root.id]).single['child_node_count'],
        2);
  });

  test(
      'dirty statistics deduplicate references and leave unrelated roots alone',
      () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repo = LibraryRepository(db);
    final root = repo.ensureCollectionIndexRoot('Shared');
    final unrelated = repo.ensureCollectionIndexRoot('Unrelated');
    final a = repo.createCustomNode(parentId: root.id, name: 'A');
    final b = repo.createCustomNode(parentId: root.id, name: 'B');
    final entity = repo
        .upsertEntity(
            path: '/shared.jpg',
            name: 'shared.jpg',
            format: 'jpg',
            entityType: EntityType.image,
            hash: 'h',
            size: 1,
            sourceCreatedAtMs: 0,
            sourceModifiedAtMs: 0)
        .entity;
    refreshDirtyStatistics(db.db);
    db.db.execute('UPDATE index_node_stats SET updated_at=123 WHERE node_id=?',
        [unrelated.id]);
    repo.linkEntityToIndexNode(entityId: entity.id, indexNodeId: a.id);
    repo.linkEntityToIndexNode(entityId: entity.id, indexNodeId: b.id);
    refreshDirtyStatistics(db.db);
    expect(
        db.db.select(
            'SELECT descendant_entity_count FROM index_node_stats WHERE node_id=?',
            [root.id]).single['descendant_entity_count'],
        1);
    expect(
        db.db.select('SELECT updated_at FROM index_node_stats WHERE node_id=?',
            [unrelated.id]).single['updated_at'],
        123);
    db.db.execute('UPDATE entities SET archived=1 WHERE id=?', [entity.id]);
    refreshDirtyStatistics(db.db);
    expect(
        db.db.select(
            'SELECT descendant_entity_count FROM index_node_stats WHERE node_id=?',
            [root.id]).single['descendant_entity_count'],
        0);
    expect(db.db.select('SELECT * FROM index_stats_dirty'), isEmpty);
  });

  test('source IDs remain opaque and URI aliases keep entity identity', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repo = LibraryRepository(db);
    const original =
        'content://provider/tree/Volume%3AStuff/document/Volume%3AStuff%2FA.jpg';
    const alias = '$original?authorization=renewed';
    final identity = SourceIdentity.parse(original)!;
    expect(identity.rootId, 'Volume:Stuff');
    expect(identity.documentId, 'Volume:Stuff/A.jpg');
    Entity save(String path) => repo
        .upsertEntity(
            path: path,
            name: 'A.jpg',
            format: 'jpg',
            entityType: EntityType.image,
            hash: 'fast',
            size: 10,
            sourceCreatedAtMs: 0,
            sourceModifiedAtMs: 0)
        .entity;
    final first = save(original);
    repo.saveReaderState(entityId: first.id, scrollOffset: 25);
    final second = save(alias);
    expect(second.id, first.id);
    expect(repo.getEntity(first.id)!.readerScrollOffset, 25);
    expect(db.db.select('SELECT * FROM entity_locations'), hasLength(1));
    final other =
        save('content://provider/tree/Other/document/Volume%3AStuff%2FA.jpg');
    expect(other.id, isNot(first.id));
    registerEntityLocation(db.db, other.id, alias);
    expect(
        db.db.select('SELECT state FROM entity_locations WHERE entity_id=?',
            [other.id]).single['state'],
        'conflict');
    expect(repo.getEntity(first.id), isNotNull);
    expect(repo.getEntity(other.id), isNotNull);
  });
  test('rule membership changes only when a file is visited', () async {
    final dir = Directory.systemTemp.createTempSync('stable_rule_');
    final db = AppDatabase.openAtPath('${dir.path}/library.db');
    final repo = LibraryRepository(db);
    for (var i = 0; i < 5; i++) {
      db.db.execute(
          '''INSERT INTO entities(id,path,name,format,media_type,hash,size,
        source_created_at_ms,source_modified_at_ms,created_at,updated_at,open_count)
        VALUES(?,?,?,'jpg','image','hash',1,0,0,0,0,?)''',
          ['e$i', '/e$i', 'e$i', 10 - i]);
    }
    final reader = await LibraryReadWorker.start(
        databasePath: db.databasePath!, storageDirectoryPath: dir.path);
    try {
      expect(
          (await reader.loadRulePage(
                  ruleNodeId: 'system-rule-frequent', limit: 2))
              .items,
          isEmpty);
      repo.markOpened('e0');
      repo.markOpened('e1');
      final visited = await reader.loadRulePage(
          ruleNodeId: 'system-rule-frequent', limit: 2);
      expect(visited.items.map((e) => e.id), ['e0', 'e1']);
      db.db.execute("UPDATE entities SET open_count=100 WHERE id='e4'");
      db.db.execute("DELETE FROM entities WHERE id='e2'");
      expect(
          (await reader.loadRulePage(
                  ruleNodeId: 'system-rule-frequent', limit: 5))
              .items
              .map((e) => e.id),
          ['e0', 'e1']);
      repo.markOpened('e4');
      final refreshed = await reader.loadRulePage(
          ruleNodeId: 'system-rule-frequent', limit: 2);
      expect(refreshed.items.first.id, 'e4');
    } finally {
      await reader.close();
      db.close();
      dir.deleteSync(recursive: true);
    }
  });
  test('progress is stored separately and does not invalidate metadata', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    db.db.execute(
        '''INSERT INTO entities(id,path,name,format,media_type,hash,size,
      source_created_at_ms,source_modified_at_ms,created_at,updated_at)
      VALUES('progress','/progress','progress','mp4','video','hash',1,0,0,0,0)''');
    flushQueryRevisions(db.db);
    final before = db.db
        .select("SELECT revision FROM query_revisions WHERE domain='metadata'")
        .single['revision'];
    final repo = LibraryRepository(db);
    repo.savePlaybackState(
        entityId: 'progress', positionMs: 42, durationMs: 100);
    repo.saveReaderState(
        entityId: 'progress',
        scrollOffset: 12,
        zoomScale: 2,
        extraStateJson: '{"anchor":"a"}');
    flushQueryRevisions(db.db);
    expect(
        db.db
            .select(
                "SELECT revision FROM query_revisions WHERE domain='metadata'")
            .single['revision'],
        before);
    expect(repo.getEntity('progress')!.lastPositionMs, 42);
    expect(repo.getEntity('progress')!.readerScrollOffset, 12);
    expect(db.db.select('PRAGMA table_info(entities)').map((r) => r['name']),
        isNot(contains('last_position_ms')));
    expect(db.db.select('SELECT * FROM entity_progress'), hasLength(1));
  });

  test('cover references preserve order and follow target deletion', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repo = LibraryRepository(db);
    final root = repo.ensureCollectionIndexRoot('cover');
    final first = repo.createCustomNode(parentId: root.id, name: 'first');
    final second = repo.createCustomNode(parentId: root.id, name: 'second');
    repo.setNodePreviewOverride(
        root.id, '[{"nodeId":"${second.id}"},{"nodeId":"${first.id}"}]');
    expect(repo.getNodePreviewOverride(root.id), contains(second.id));
    expect(
        db.db
            .select(
                'SELECT target_node_id FROM node_preview_override_items ORDER BY ordinal')
            .first['target_node_id'],
        second.id);
    db.db.execute('DELETE FROM index_nodes WHERE id=?', [second.id]);
    expect(repo.getNodePreviewOverride(root.id), isNot(contains(second.id)));
    expect(
        db.db.select(
            'SELECT * FROM node_preview_dirty WHERE node_id=?', [root.id]),
        isNotEmpty);
  });
  test('access rules reject directory scopes', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repo = LibraryRepository(db);
    final scope = repo.ensureCollectionIndexRoot('scope');
    expect(
      () => repo.createRule(name: 'scoped', scopeNodeId: scope.id),
      throwsArgumentError,
    );
  });

  test('SQL cannot bypass protected nodes or create ancestry cycles', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    for (final sql in [
      "DELETE FROM index_nodes WHERE system_key = 'favorites'",
      "UPDATE index_nodes SET name='renamed' WHERE system_key='favorites'",
      "UPDATE index_nodes SET is_protected=0 WHERE system_key='favorites'",
    ]) {
      expect(() => db.db.execute(sql), throwsA(isA<SqliteException>()));
    }
    final repo = LibraryRepository(db);
    final parent = repo.ensureCollectionIndexRoot('parent');
    final child = repo.createCustomNode(parentId: parent.id, name: 'child');
    expect(
        () => db.db.execute('UPDATE index_nodes SET parent_id=? WHERE id=?',
            [child.id, parent.id]),
        throwsA(isA<SqliteException>()));
  });

  test('access-rule membership lookup is index backed', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final details = db.db
        .select('''EXPLAIN QUERY PLAN SELECT entity_id FROM rule_access_items
      WHERE rule_id = 'system-rule-frequent' LIMIT 61''')
        .map((r) => r['detail'])
        .join('\n');
    expect(details, isNot(contains('TEMP B-TREE')));
  });

  test('query invalidations merge within a command and rollback with it', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    flushQueryRevisions(db.db);
    db.db.execute('BEGIN');
    final repo = LibraryRepository(db);
    repo.ensureCollectionIndexRoot('one');
    repo.ensureCollectionIndexRoot('two');
    expect(
        db.db.select(
            "SELECT * FROM query_revision_dirty WHERE domain='structure'"),
        hasLength(1));
    flushQueryRevisions(db.db);
    expect(
        db.db
            .select(
                "SELECT revision FROM query_revisions WHERE domain='structure'")
            .single['revision'],
        1);
    db.db.execute('ROLLBACK');
    expect(
        db.db.select("SELECT * FROM query_revisions WHERE domain='structure'"),
        isEmpty);
  });
}
