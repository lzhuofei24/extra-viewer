import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('schema 6 adds cover revision without losing document versions', () {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final raw = database.db;
    raw.execute('DROP TABLE document_preview_versions');
    raw.execute(
        'CREATE TABLE document_preview_versions(entity_id TEXT PRIMARY KEY, source_revision INTEGER NOT NULL)');
    raw.execute(
        "INSERT INTO document_preview_versions VALUES ('preserved', 7)");
    database.migrate();
    final row = raw.select('SELECT * FROM document_preview_versions').single;
    expect(row['entity_id'], 'preserved');
    expect(row['source_revision'], 7);
    expect(row['cover_revision'], isNull);
  });

  test('schema 5 migration preserves records and captures immutable task scope',
      () {
    final raw = sqlite3.openInMemory();
    raw.execute('''
      CREATE TABLE entities(id TEXT PRIMARY KEY, name TEXT,
        thumbnail_key TEXT, thumbnail_format TEXT);
      CREATE TABLE index_nodes(id TEXT PRIMARY KEY, source_path TEXT);
      CREATE TABLE node_preview_assets(node_id TEXT PRIMARY KEY,
        asset_key TEXT, format TEXT);
      CREATE TABLE library_build_jobs(id TEXT PRIMARY KEY, target_node_id TEXT,
        source_path TEXT, stage TEXT, status TEXT, indexed_total INTEGER, error TEXT);
      CREATE TABLE library_build_manifest(job_id TEXT, sequence INTEGER);
      INSERT INTO entities(id, name) VALUES ('original', 'keep');
      INSERT INTO index_nodes VALUES ('root', '/original');
      INSERT INTO library_build_jobs VALUES ('job', 'root', '/original', 'manifest', 'paused', 0, NULL);
    ''');
    raw.userVersion = 5;
    final database = AppDatabase.openForTesting(raw);
    addTearDown(database.close);
    expect(raw.userVersion, 6);
    expect(raw.select('SELECT name FROM entities').single['name'], 'keep');
    final job = raw.select('SELECT * FROM library_build_jobs').single;
    expect(job['scope_node_id'], 'root');
    expect(job['status'], 'blocked');
    expect(raw.select('PRAGMA foreign_key_check'), isEmpty);
  });
  test('fresh database creates the current clean schema baseline', () {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);

    expect(database.db.userVersion, AppDatabase.currentSchemaVersion);
    expect(
      database.db
          .select("SELECT name FROM sqlite_master WHERE name = 'entities'"),
      isNotEmpty,
    );
    expect(
      database.db.select(
        "SELECT name FROM sqlite_master WHERE name = 'library_build_jobs'",
      ),
      isNotEmpty,
    );
    expect(
      database.db.select(
        "SELECT name FROM sqlite_master WHERE name = 'node_preview_assets'",
      ),
      isNotEmpty,
    );
  });

  test('existing historical database requires an explicit local reset', () {
    final raw = sqlite3.openInMemory();
    raw.userVersion = 34;

    expect(
      () => AppDatabase.openForTesting(raw),
      throwsA(isA<AppDatabaseResetRequired>()),
    );
  });
}
