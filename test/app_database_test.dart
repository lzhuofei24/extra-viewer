import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';
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
    raw.userVersion = 10;
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
      CREATE TABLE index_nodes(id TEXT PRIMARY KEY, source_path TEXT,
        name TEXT NOT NULL, node_type TEXT NOT NULL DEFAULT 'folder',
        view_type TEXT NOT NULL DEFAULT 'tree');
      CREATE TABLE node_preview_assets(node_id TEXT PRIMARY KEY,
        asset_key TEXT, format TEXT);
      CREATE TABLE library_build_jobs(id TEXT PRIMARY KEY, target_node_id TEXT,
        index_root_id TEXT, source_path TEXT, stage TEXT, status TEXT,
        indexed_total INTEGER, error TEXT);
      CREATE TABLE library_build_manifest(job_id TEXT, sequence INTEGER);
      INSERT INTO entities(id, name) VALUES ('original', 'keep');
      INSERT INTO index_nodes(id, source_path, name)
        VALUES ('root', '/original', 'original');
      INSERT INTO library_build_jobs
        (id, target_node_id, source_path, stage, status, indexed_total, error)
        VALUES ('job', 'root', '/original', 'manifest', 'paused', 0, NULL);
    ''');
    raw.userVersion = 5;
    final database = AppDatabase.openForTesting(raw);
    addTearDown(database.close);
    expect(raw.userVersion, AppDatabase.currentSchemaVersion);
    expect(raw.select('SELECT name FROM entities').single['name'], 'keep');
    final job = raw.select('SELECT * FROM library_build_jobs').single;
    expect(job['scope_node_id'], 'root');
    expect(job['status'], 'blocked');
    expect(raw.select('PRAGMA foreign_key_check'), isEmpty);
  });

  test('schema 6 migration creates and backfills node search index', () {
    final raw = sqlite3.openInMemory();
    final database = AppDatabase.openForTesting(raw);
    final now = DateTime.now().millisecondsSinceEpoch;
    raw.execute('''INSERT INTO index_nodes(id, name, node_type, view_type,
      sort_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)''',
        ['search-root', '目录索引', 'directory_index_root', 'tree', 0, now, now]);
    raw.execute('''INSERT INTO index_nodes(id, parent_id, name, node_type,
      view_type, sort_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
        ['search-child', 'search-root', '银狼资料', 'folder', 'tree', 0, now, now]);
    raw.execute('DROP TRIGGER index_node_search_insert');
    raw.execute('DROP TRIGGER index_node_search_delete');
    raw.execute('DROP TRIGGER index_node_search_update');
    raw.execute('DROP TABLE index_node_search');
    raw.userVersion = 6;
    database.migrate();
    addTearDown(database.close);

    expect(raw.userVersion, AppDatabase.currentSchemaVersion);
    expect(
      raw.select(
          "SELECT rowid FROM index_node_search WHERE index_node_search MATCH '银狼资'"),
      isNotEmpty,
    );
    raw.execute(
        "UPDATE index_nodes SET name = '星穹资料' WHERE id = 'search-child'");
    expect(
      raw.select(
          "SELECT rowid FROM index_node_search WHERE index_node_search MATCH '星穹资'"),
      isNotEmpty,
    );
  });

  test('schema 7 migration removes graph data and preserves library data', () {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final raw = database.db;
    final repository = LibraryRepository(database);
    final now = DateTime.now().millisecondsSinceEpoch;
    final directory = repository.ensureDirectoryIndexRoot('/media');
    final collection = repository.ensureCollectionIndexRoot('收藏');
    final category =
        repository.createCustomNode(parentId: collection.id, name: '银狼');
    final entity = repository
        .upsertEntity(
          path: '/media/image.jpg',
          name: 'image.jpg',
          format: 'jpg',
          entityType: EntityType.image,
          hash: 'hash',
          size: 1024,
          sourceCreatedAtMs: now,
          sourceModifiedAtMs: now,
          directoryRootId: directory.id,
        )
        .entity;
    repository.linkEntityToIndexNode(
      entityId: entity.id,
      indexNodeId: category.id,
    );
    final systemRoot = raw
        .select("SELECT id FROM index_nodes WHERE node_type = 'root'")
        .single['id'] as String;
    raw.execute('''
      CREATE TABLE index_node_edges (
        id TEXT PRIMARY KEY,
        from_node_id TEXT NOT NULL REFERENCES index_nodes(id) ON DELETE CASCADE,
        to_node_id TEXT NOT NULL REFERENCES index_nodes(id) ON DELETE CASCADE,
        edge_type TEXT NOT NULL,
        label TEXT,
        sort_order INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE graph_node_positions (
        node_id TEXT PRIMARY KEY REFERENCES index_nodes(id) ON DELETE CASCADE,
        x REAL NOT NULL,
        y REAL NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    raw.execute('''
      INSERT INTO index_nodes
      (id, parent_id, name, node_type, view_type, sort_order, created_at, updated_at)
      VALUES ('graph-root', ?, '旧图', 'graph_index_root', 'graph', 0, ?, ?)
    ''', [systemRoot, now, now]);
    raw.execute('''
      INSERT INTO index_nodes
      (id, parent_id, name, node_type, view_type, sort_order, created_at, updated_at)
      VALUES ('graph-node', 'graph-root', '旧节点', 'graph_node', 'graph', 0, ?, ?)
    ''', [now, now]);
    raw.execute('''
      INSERT INTO index_node_entities(index_node_id, entity_id, sort_name, created_at)
      VALUES ('graph-node', ?, 'image.jpg', ?)
    ''', [entity.id, now]);
    raw.execute('''
      INSERT INTO index_node_edges VALUES
      ('edge', 'graph-node', 'graph-node', 'related', NULL, 0)
    ''');
    raw.execute(
      "INSERT INTO graph_node_positions VALUES ('graph-node', 10, 20, ?)",
      [now],
    );
    raw.execute('''
      INSERT INTO node_preview_assets
      VALUES ('graph-node', 'signature', 'graph-cover', 'webp', 100, 100, ?)
    ''', [now]);
    raw.execute('''
      INSERT INTO library_build_jobs
      (id, source_path, operation_type, target_node_id, index_root_id,
       stage, status, created_at, updated_at)
      VALUES ('graph-job', 'index://graph-root', 'subtreeRefresh',
              'graph-node', 'graph-root', 'nodePreviews', 'paused', ?, ?)
    ''', [now, now]);
    raw.userVersion = 7;

    database.migrate();

    expect(raw.userVersion, AppDatabase.currentSchemaVersion);
    expect(
      raw.select('SELECT id FROM index_nodes WHERE id = ?', [directory.id]),
      isNotEmpty,
    );
    expect(
      raw.select('SELECT id FROM index_nodes WHERE id = ?', [category.id]),
      isNotEmpty,
    );
    expect(raw.select('SELECT id FROM entities WHERE id = ?', [entity.id]),
        isNotEmpty);
    expect(
      raw.select('''
        SELECT 1 FROM index_node_entities
        WHERE index_node_id = ? AND entity_id = ?
      ''', [category.id, entity.id]),
      isNotEmpty,
    );
    expect(
      raw.select("SELECT 1 FROM index_nodes WHERE node_type LIKE 'graph_%'"),
      isEmpty,
    );
    expect(
        raw.select("SELECT 1 FROM library_build_jobs WHERE id = 'graph-job'"),
        isEmpty);
    expect(
      raw.select(
        "SELECT name FROM sqlite_master WHERE name IN ('index_node_edges', 'graph_node_positions')",
      ),
      isEmpty,
    );
    expect(
      raw.select(
        "SELECT 1 FROM retired_preview_assets WHERE kind = 'node' AND asset_key = 'graph-cover'",
      ),
      isNotEmpty,
    );
    expect(raw.select('PRAGMA foreign_key_check'), isEmpty);
    expect(
      raw
          .select('SELECT COUNT(*) AS count FROM index_node_search')
          .single['count'],
      raw.select('SELECT COUNT(*) AS count FROM index_nodes').single['count'],
    );
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

  test('schema 9 adopts an existing favorites root and is idempotent', () {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final raw = database.db;
    final favorite = raw
        .select("SELECT * FROM index_nodes WHERE system_key = 'favorites'")
        .single;
    final favoriteId = favorite['id'] as String;
    raw.execute('DROP TRIGGER protect_system_node_update');
    raw.execute(
      'UPDATE index_nodes SET system_key = NULL, is_protected = 0, sort_order = 0 WHERE id = ?',
      [favoriteId],
    );
    raw.userVersion = 8;

    database.migrate();
    database.migrate();

    final favorites = raw.select(
      "SELECT * FROM index_nodes WHERE system_key = 'favorites'",
    );
    expect(favorites, hasLength(1));
    expect(favorites.single['id'], favoriteId);
    expect(favorites.single['is_protected'], 1);
    expect(
      raw.select("SELECT * FROM index_nodes WHERE node_type = 'rule'"),
      hasLength(5),
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
