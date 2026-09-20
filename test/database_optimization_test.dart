import 'dart:io';
import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/database/library_read_worker.dart';
import 'package:best_viewer/src/core/database/schema_v10.dart';
import 'package:best_viewer/src/core/database/schema_v12.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/modules/sources/source_identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
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
  test('rule sessions keep membership and order while visits and files change',
      () async {
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
      final first = await reader.loadRulePage(
          ruleNodeId: 'system-rule-frequent', limit: 2);
      expect(first.items.map((e) => e.id), ['e0', 'e1']);
      db.db.execute("UPDATE entities SET open_count=100 WHERE id='e4'");
      db.db.execute("DELETE FROM entities WHERE id='e2'");
      final second = await reader.loadRulePage(
          ruleNodeId: 'system-rule-frequent', after: first.cursor, limit: 2);
      expect(second.items.map((e) => e.id), ['e3', 'e4']);
      expect(second.hasMore, isFalse);
      repo.markOpened('e3');
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
  test('deleting a scope cannot turn a rule into an unrestricted query',
      () async {
    final dir = Directory.systemTemp.createTempSync('rule_scope_');
    final db = AppDatabase.openAtPath('${dir.path}/library.db');
    final repo = LibraryRepository(db);
    final scope = repo.ensureCollectionIndexRoot('scope');
    final rule = repo.createRule(name: 'scoped', scopeNodeId: scope.id);
    db.db.execute('DELETE FROM index_nodes WHERE id = ?', [scope.id]);
    expect(repo.getRule(rule.node.id)!.scopeMissing, isTrue);
    final reader = await LibraryReadWorker.start(
        databasePath: db.databasePath!, storageDirectoryPath: dir.path);
    try {
      expect(
          (await reader.loadRulePage(ruleNodeId: rule.node.id)).items, isEmpty);
      expect(
          (await reader.listRules())
              .singleWhere((r) => r.node.id == rule.node.id)
              .scopeMissing,
          isTrue);
      repo.updateRule(nodeId: rule.node.id, name: 'all');
      expect(repo.getRule(rule.node.id)!.scopeMissing, isFalse);
    } finally {
      await reader.close();
      db.close();
      dir.deleteSync(recursive: true);
    }
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

  test('frequent ordering is entirely index backed', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final details = db.db
        .select('''EXPLAIN QUERY PLAN SELECT id FROM entities
      WHERE archived=0 AND open_count>0
      ORDER BY open_count DESC, COALESCE(last_opened_at,0) DESC, id LIMIT 61''')
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

  test('schema 9 upgrade creates a verified unique snapshot', () {
    final dir = Directory.systemTemp.createTempSync('migration_backup_');
    final path = '${dir.path}/library.db';
    final db = AppDatabase.openAtPath(path);
    db.db.userVersion = 9;
    db.close();
    final upgraded = AppDatabase.openAtPath(path);
    expect(upgraded.db.userVersion, AppDatabase.currentSchemaVersion);
    upgraded.close();
    final backups = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.backup'))
        .toList();
    expect(backups, hasLength(3));
    final snapshot = sqlite3.open(
        backups.firstWhere((f) => f.path.contains('.schema9.')).path,
        mode: OpenMode.readOnly);
    expect(snapshot.userVersion, 9);
    expect(
        snapshot.select('PRAGMA integrity_check').single.values.single, 'ok');
    snapshot.dispose();
    dir.deleteSync(recursive: true);
  });
}
