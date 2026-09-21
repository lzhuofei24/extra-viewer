import 'dart:io';
import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('task tables hot patch a current library without touching user records',
      () {
    final dir = Directory.systemTemp.createTempSync('task_hot_patch_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/library.db';
    final first = AppDatabase.openAtPath(path);
    final root = LibraryRepository(first).ensureCollectionIndexRoot('Keep');
    first.db.execute('DROP TRIGGER task_created; DROP TRIGGER task_transition');
    for (final table in [
      'library_task_dirty',
      'library_task_changes',
      'library_task_failures',
      'library_task_events',
      'library_task_details'
    ]) {
      first.db.execute('DROP TABLE $table');
    }
    first.close();
    final next = AppDatabase.openAtPath(path);
    expect(LibraryRepository(next).getIndexNode(root.id)?.name, 'Keep');
    expect(next.db.select('SELECT * FROM library_task_events'), isEmpty);
    expect(next.db.select('PRAGMA foreign_key_check'), isEmpty);
    next.close();
  });
  test('legacy reset marker never removes preview assets on opening', () {
    final dir = Directory.systemTemp.createTempSync('interrupted_reset_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/library.db';
    File('$path.reset-pending').writeAsStringSync('14');
    Directory('${dir.path}/thumbnails').createSync();
    File('${dir.path}/thumbnails/old.webp').writeAsStringSync('stale');
    final db = AppDatabase.openAtPath(path);
    addTearDown(db.close);
    expect(File('$path.reset-pending').existsSync(), isTrue);
    expect(File('${dir.path}/thumbnails/old.webp').readAsStringSync(), 'stale');
    expect(db.db.select('SELECT * FROM entities'), isEmpty);
  });

  test('fresh database directly creates constrained current tables', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    expect(db.db.userVersion, AppDatabase.currentSchemaVersion);
    expect(db.db.select('PRAGMA foreign_key_check'), isEmpty);
    expect(db.db.select('PRAGMA integrity_check').single.values.single, 'ok');
    expect(
        db.db
            .select('PRAGMA table_info(index_nodes)')
            .any((r) => r['name'] == 'view_type'),
        isFalse);
    expect(
        db.db
            .select('PRAGMA table_info(entity_progress)')
            .any((r) => r['name'] == 'document_revision'),
        isTrue);
    expect(
        db.db.select(
            "SELECT name FROM sqlite_master WHERE name IN ('index_node_edges','graph_node_positions')"),
        isEmpty);
    expect(db.db.select('SELECT * FROM index_rules'), hasLength(3));
    expect(
      db.db
          .select('SELECT built_in_kind FROM index_rules')
          .map((row) => row['built_in_kind']),
      containsAll(['frequent', 'recentImages', 'recentVideos']),
    );
    final root = LibraryRepository(db).ensureCollectionIndexRoot('Books');
    expect(
        () => db.db.execute(
            'UPDATE index_nodes SET is_staging=2 WHERE id=?', [root.id]),
        throwsA(isA<SqliteException>()));
    expect(
        () => db.db.execute(
            "UPDATE index_nodes SET parent_id='system-rules' WHERE id=?",
            [root.id]),
        throwsA(isA<SqliteException>()));
    expect(() => db.db.execute('UPDATE index_rules SET max_results=0'),
        throwsA(isA<SqliteException>()));
  });

  test('unsupported old library retains all records and preview assets', () {
    final dir = Directory.systemTemp.createTempSync('library_reset_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/library.db';
    final old = sqlite3.open(path);
    old.execute(
        "CREATE TABLE entities(id TEXT); CREATE TABLE index_nodes(id TEXT); INSERT INTO entities VALUES('old')");
    old.userVersion = 13;
    old.dispose();
    final backup = File('$path.schema13.123.backup')
      ..writeAsStringSync('backup');
    final original = File('${dir.path}/photo.jpg')
      ..writeAsStringSync('original');
    final key = File('${dir.path}/release.jks')..writeAsStringSync('signing');
    Directory('${dir.path}/node_previews').createSync();
    File('${dir.path}/node_previews/old.webp').writeAsStringSync('preview');
    expect(() => AppDatabase.openAtPath(path),
        throwsA(isA<AppDatabaseResetRequired>()));
    final retained = sqlite3.open(path);
    addTearDown(retained.dispose);
    expect(retained.select('SELECT id FROM entities').single['id'], 'old');
    expect(backup.existsSync(), isTrue);
    expect(File('${dir.path}/node_previews/old.webp').readAsStringSync(),
        'preview');
    expect(original.readAsStringSync(), 'original');
    expect(key.readAsStringSync(), 'signing');
  });

  test('current library is retained on repeated open', () {
    final dir = Directory.systemTemp.createTempSync('library_reopen_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/library.db';
    final first = AppDatabase.openAtPath(path);
    final root = LibraryRepository(first).ensureCollectionIndexRoot('Keep');
    first.close();
    final next = AppDatabase.openAtPath(path);
    addTearDown(next.close);
    expect(LibraryRepository(next).getIndexNode(root.id)?.name, 'Keep');
    expect(
        next.db
            .select("SELECT * FROM index_nodes WHERE system_key='favorites'"),
        hasLength(1));
  });

  test('access-rule migration removes legacy rules once and preserves data',
      () {
    final dir = Directory.systemTemp.createTempSync('access_rule_migration_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/library.db';
    final first = AppDatabase.openAtPath(path);
    final repository = LibraryRepository(first);
    final custom = repository.createRule(name: '旧自定义规则');
    final entity = repository
        .upsertEntity(
          path: '/keep.jpg',
          name: 'keep.jpg',
          format: 'jpg',
          entityType: EntityType.image,
          hash: 'keep',
          size: 1,
          sourceCreatedAtMs: 1,
          sourceModifiedAtMs: 1,
        )
        .entity;
    final now = DateTime.now().millisecondsSinceEpoch;
    first.db.execute('''
      INSERT INTO index_nodes(
        id,parent_id,name,node_type,system_key,is_protected,
        sort_order,created_at,updated_at
      ) VALUES('system-rule-recentText','system-rules','最近文本','rule',
        'rule.recentText',1,3,?,?)
    ''', [now, now]);
    first.db.execute('''
      INSERT INTO index_rules(
        node_id,entity_types_json,extensions_json,default_sort,
        max_results,built_in_kind,updated_at
      ) VALUES('system-rule-recentText','["text","external_link"]','[]',
        'lastOpened',1000,'recentText',?)
    ''', [now]);
    first.db.execute('''
      DELETE FROM app_compatibility_migrations
      WHERE migration_key = 'access_rules_only_v1'
    ''');
    first.close();

    final migrated = AppDatabase.openAtPath(path);
    expect(
      migrated.db.select('SELECT id FROM entities WHERE id = ?', [entity.id]),
      hasLength(1),
    );
    expect(
      migrated.db
          .select('SELECT id FROM index_nodes WHERE id = ?', [custom.node.id]),
      isEmpty,
    );
    expect(
      migrated.db.select(
        "SELECT node_id FROM index_rules WHERE built_in_kind IN ('recentText','recentMusic')",
      ),
      isEmpty,
    );
    final replacement = LibraryRepository(migrated).createRule(name: '新访问规则');
    migrated.close();

    final reopened = AppDatabase.openAtPath(path);
    addTearDown(reopened.close);
    expect(
      reopened.db.select(
          'SELECT id FROM index_nodes WHERE id = ?', [replacement.node.id]),
      hasLength(1),
    );
  });

  test('current library adds the manifest reconciliation index on reopen', () {
    final dir = Directory.systemTemp.createTempSync('library_index_hotfix_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/library.db';
    final first = AppDatabase.openAtPath(path);
    first.db.execute('DROP INDEX idx_library_build_manifest_source_path');
    first.close();

    final reopened = AppDatabase.openAtPath(path);
    addTearDown(reopened.close);
    expect(
      reopened.db.select('''
        SELECT 1 FROM sqlite_master
        WHERE type = 'index'
          AND name = 'idx_library_build_manifest_source_path'
      '''),
      hasLength(1),
    );
  });

  test('unrecognized databases are rejected without deletion', () {
    final dir = Directory.systemTemp.createTempSync('unknown_library_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/unrelated.db';
    final raw = sqlite3.open(path);
    raw.execute(
        "CREATE TABLE notes(body TEXT); INSERT INTO notes VALUES('keep')");
    raw.userVersion = 1;
    raw.dispose();
    expect(() => AppDatabase.openAtPath(path),
        throwsA(isA<AppDatabaseResetRequired>()));
    final check = sqlite3.open(path);
    addTearDown(check.dispose);
    expect(check.select('SELECT body FROM notes').single['body'], 'keep');
  });
}
