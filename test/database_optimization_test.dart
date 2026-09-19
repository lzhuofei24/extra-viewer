import 'dart:io';
import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/database/library_read_worker.dart';
import 'package:best_viewer/src/core/database/schema_v10.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
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
    expect(backups, hasLength(1));
    final snapshot = sqlite3.open(backups.single.path, mode: OpenMode.readOnly);
    expect(snapshot.userVersion, 9);
    expect(
        snapshot.select('PRAGMA integrity_check').single.values.single, 'ok');
    snapshot.dispose();
    dir.deleteSync(recursive: true);
  });
}
