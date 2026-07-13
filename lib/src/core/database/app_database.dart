import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

class AppDatabase {
  AppDatabase._(this.db, this.storageDirectoryPath, this.databasePath);

  final Database db;
  final String storageDirectoryPath;
  final String? databasePath;

  static Future<AppDatabase> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final dbPath = p.join(dir.path, 'best_viewer.db');
    final database = sqlite3.open(dbPath);
    final appDb = AppDatabase._(database, dir.path, dbPath);
    appDb.migrate();
    return appDb;
  }

  static AppDatabase openInMemory() {
    final dir = Directory.systemTemp.createTempSync('best_viewer_test_');
    final appDb = AppDatabase._(sqlite3.openInMemory(), dir.path, null);
    appDb.migrate();
    return appDb;
  }

  static AppDatabase openForTesting(Database database) {
    final dir = Directory.systemTemp.createTempSync('best_viewer_test_');
    final appDb = AppDatabase._(database, dir.path, null);
    appDb.migrate();
    return appDb;
  }

  static AppDatabase openAtPathForTesting(String dbPath) {
    final file = File(dbPath);
    file.parent.createSync(recursive: true);
    final appDb = AppDatabase._(
      sqlite3.open(dbPath),
      file.parent.path,
      dbPath,
    );
    appDb.migrate();
    return appDb;
  }

  void close() => db.dispose();

  void migrate() {
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA busy_timeout = 3000;');
    db.execute('PRAGMA synchronous = NORMAL;');
    final version = db.userVersion;
    if (version < 2) {
      _rebuildV2();
      db.userVersion = 24;
      return;
    }
    if (version < 3) {
      _migrateV3();
      db.userVersion = 3;
    }
    if (version < 4) {
      _migrateV4();
      db.userVersion = 4;
    }
    if (version < 5) {
      _migrateV5();
      db.userVersion = 5;
    }
    if (version < 6) {
      _migrateV6();
      db.userVersion = 6;
    }
    if (version < 7) {
      _migrateV7();
      db.userVersion = 7;
    }
    if (version < 8) {
      _migrateV8();
      db.userVersion = 8;
    }
    if (version < 9) {
      _migrateV9();
      db.userVersion = 9;
    }
    if (version < 10) {
      _migrateV10();
      db.userVersion = 10;
    }
    if (version < 11) {
      _migrateV11();
      db.userVersion = 11;
    }
    if (version < 12) {
      _migrateV12();
      db.userVersion = 12;
    }
    if (version < 13) {
      _migrateV13();
      db.userVersion = 13;
    }
    if (version < 14) {
      _migrateV14();
      db.userVersion = 14;
    }
    if (version < 15) {
      _migrateV15();
      db.userVersion = 15;
    }
    if (version < 16) {
      _migrateV16();
      db.userVersion = 16;
    }
    if (version < 17) {
      _migrateV17();
      db.userVersion = 17;
    }
    if (version < 19) {
      _migrateV19();
      db.userVersion = 19;
    }
    if (version < 20) {
      _migrateV20();
      db.userVersion = 20;
    }
    if (version < 21) {
      _migrateV21();
      db.userVersion = 21;
    }
    if (version < 22) {
      _migrateV22();
      db.userVersion = 22;
    }
    if (version < 23) {
      _migrateV23();
      db.userVersion = 23;
    }
    if (version < 24) {
      _migrateV24();
      db.userVersion = 24;
    }
    if (version < 25) {
      _migrateV25();
      db.userVersion = 25;
    }
    if (version < 26) {
      _migrateV26();
      db.userVersion = 26;
    }
    if (version < 27) {
      _migrateV27();
      db.userVersion = 27;
    }
    if (version < 28) {
      _migrateV28();
      db.userVersion = 28;
    }
    if (version < 29) {
      _migrateV29();
      db.userVersion = 29;
    }
    if (version < 30) {
      _migrateV30();
      db.userVersion = 30;
    }
    // Hot restart and older development builds can leave a version marker
    // ahead of the physical schema. These checks are idempotent self-healing.
    _addColumnIfMissing('entities', 'directory_root_id', 'TEXT');
    _addColumnIfMissing('entities', 'local_path', 'TEXT');
    _addColumnIfMissing('index_nodes', 'preview_json', 'TEXT');
    _addColumnIfMissing('index_nodes', 'relative_source_path', 'TEXT');
    _addColumnIfMissing(
      'index_jobs',
      'scan_completed',
      'INTEGER NOT NULL DEFAULT 0',
    );
    _addColumnIfMissing('index_jobs', 'target_node_id', 'TEXT');
    _addColumnIfMissing('index_jobs', 'staging_root_id', 'TEXT');
    _addColumnIfMissing(
      'index_nodes',
      'is_staging',
      'INTEGER NOT NULL DEFAULT 0',
    );
    _addColumnIfMissing(
      'index_node_entities',
      'sort_name',
      "TEXT NOT NULL DEFAULT ''",
    );
    db.execute(_schema);
    db.execute(_indexJobEntitySnapshotSchema);
    db.execute("""
      UPDATE index_jobs
      SET status = 'paused', updated_at =
        CAST(strftime('%s', 'now') AS INTEGER) * 1000
      WHERE status = 'running'
    """);
    db.execute('PRAGMA optimize;');
  }

  void _rebuildV2() {
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute('BEGIN IMMEDIATE;');
    try {
      for (final table in _legacyTables) {
        db.execute('DROP TABLE IF EXISTS $table;');
      }
      db.execute(_schema);
      db.execute(_indexJobCandidateSchema);
      db.execute(_indexJobEntitySnapshotSchema);
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    } finally {
      db.execute('PRAGMA foreign_keys = ON;');
    }
  }

  void _migrateV3() {
    db.execute('BEGIN IMMEDIATE;');
    try {
      _addColumnIfMissing('entities', 'last_position_ms', 'INTEGER');
      _addColumnIfMissing('entities', 'duration_ms', 'INTEGER');
      _addColumnIfMissing('entities', 'reader_scroll_offset', 'REAL');
      _addColumnIfMissing('entities', 'zoom_scale', 'REAL');
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _migrateV4() {
    db.execute('BEGIN IMMEDIATE;');
    try {
      _addColumnIfMissing('entities', 'extra_state_json', 'TEXT');
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _migrateV5() {
    db.execute('BEGIN IMMEDIATE;');
    try {
      _dedupeIndexNodeSiblings();
      _dedupeIndexNodeEdges();
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _migrateV6() {
    db.execute('BEGIN IMMEDIATE;');
    try {
      _dedupeRootNodes();
      _dedupeIndexNodeSiblings();
      _dedupeIndexNodeEdges();
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _migrateV7() {
    db.execute('BEGIN IMMEDIATE;');
    try {
      _addColumnIfMissing('entities', 'metadata_preview', 'TEXT');
      _addColumnIfMissing(
        'entities',
        'thumbnail_status',
        "TEXT NOT NULL DEFAULT 'none'",
      );
      _addColumnIfMissing('entities', 'thumbnail_key', 'TEXT');
      _addColumnIfMissing('entities', 'thumbnail_format', 'TEXT');
      _addColumnIfMissing('entities', 'thumbnail_width', 'INTEGER');
      _addColumnIfMissing('entities', 'thumbnail_height', 'INTEGER');
      _addColumnIfMissing('entities', 'thumbnail_error', 'TEXT');
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _migrateV8() {
    db.execute('BEGIN IMMEDIATE;');
    try {
      db.execute('DROP TABLE IF EXISTS entities_v8_new;');
      db.execute('''
CREATE TABLE entities_v8_new (
  id TEXT PRIMARY KEY,
  path TEXT NOT NULL UNIQUE,
  local_path TEXT,
  name TEXT NOT NULL,
  format TEXT NOT NULL,
  media_type TEXT NOT NULL,
  hash TEXT NOT NULL,
  metadata_preview TEXT,
  thumbnail_status TEXT NOT NULL DEFAULT 'none',
  thumbnail_key TEXT,
  thumbnail_format TEXT,
  thumbnail_width INTEGER,
  thumbnail_height INTEGER,
  thumbnail_error TEXT,
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
''');
      db.execute('''
INSERT INTO entities_v8_new (
  id, path, name, format, media_type, hash, metadata_preview,
  thumbnail_status, thumbnail_key, thumbnail_format, thumbnail_width,
  thumbnail_height, thumbnail_error, size, source_created_at_ms,
  source_modified_at_ms, favorite, archived, last_opened_at,
  last_position_ms, duration_ms, reader_scroll_offset, zoom_scale,
  extra_state_json, created_at, updated_at
)
SELECT
  id, path, name, format, media_type, hash, metadata_preview,
  thumbnail_status, thumbnail_key, thumbnail_format, thumbnail_width,
  thumbnail_height, thumbnail_error, size, source_created_at_ms,
  source_modified_at_ms, favorite, archived, last_opened_at,
  last_position_ms, duration_ms, reader_scroll_offset, zoom_scale,
  extra_state_json, created_at, updated_at
FROM entities;
''');
      db.execute('DROP TABLE entities;');
      db.execute('ALTER TABLE entities_v8_new RENAME TO entities;');
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _migrateV19() {
    db.execute('DROP TABLE IF EXISTS node_favorites;');
  }

  void _migrateV20() {
    db.execute('BEGIN IMMEDIATE;');
    try {
      _addColumnIfMissing('entities', 'directory_root_id', 'TEXT');
      db.execute('''
        WITH RECURSIVE node_roots(node_id, root_id) AS (
          SELECT id, id
          FROM index_nodes
          WHERE node_type = 'directory_index_root'
          UNION ALL
          SELECT child.id, node_roots.root_id
          FROM index_nodes child
          JOIN node_roots ON child.parent_id = node_roots.node_id
        )
        UPDATE entities
        SET directory_root_id = (
          SELECT node_roots.root_id
          FROM index_node_entities link
          JOIN node_roots ON node_roots.node_id = link.index_node_id
          WHERE link.entity_id = entities.id
          LIMIT 1
        )
        WHERE directory_root_id IS NULL
          AND EXISTS (
            SELECT 1
            FROM index_node_entities link
            JOIN node_roots ON node_roots.node_id = link.index_node_id
            WHERE link.entity_id = entities.id
          )
      ''');
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _migrateV21() {
    _addColumnIfMissing('index_nodes', 'preview_json', 'TEXT');
  }

  void _migrateV22() => db.execute(_graphNodePositionSchema);

  void _migrateV23() => _addColumnIfMissing('entities', 'local_path', 'TEXT');

  void _migrateV24() {
    db.execute('BEGIN IMMEDIATE;');
    try {
      _addColumnIfMissing(
        'index_node_entities',
        'sort_name',
        "TEXT NOT NULL DEFAULT ''",
      );
      db.execute('''
        UPDATE index_node_entities
        SET sort_name = lower(COALESCE((
          SELECT name FROM entities
          WHERE entities.id = index_node_entities.entity_id
        ), ''))
      ''');
      db.execute('''
        CREATE INDEX IF NOT EXISTS idx_index_node_entities_node_sort_name
        ON index_node_entities(index_node_id, sort_name COLLATE NOCASE, entity_id)
      ''');
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _migrateV9() {
    // FTS search was removed in schema version 17.
  }

  void _migrateV10() {
    db.execute('BEGIN IMMEDIATE;');
    try {
      _addColumnIfMissing('index_nodes', 'rule_json', 'TEXT');
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _migrateV11() {
    db.execute('BEGIN IMMEDIATE;');
    try {
      // Rules are no longer a supported index model. Their links and nodes
      // cascade away while source entities stay intact.
      db.execute(
        "DELETE FROM index_nodes WHERE node_type = 'smart_index_root'",
      );
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _migrateV12() {
    db.execute('BEGIN IMMEDIATE;');
    try {
      db.execute(_indexNodeStatsSchema);
      _rebuildIndexNodeStats();
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _migrateV13() {
    db.execute('BEGIN IMMEDIATE;');
    try {
      db.execute(_indexJobSchema);
      // A terminated process leaves running jobs recoverable, not active.
      db.execute("""
        UPDATE index_jobs
        SET status = 'paused', updated_at =
          CAST(strftime('%s', 'now') AS INTEGER) * 1000
        WHERE status = 'running'
      """);
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _migrateV14() {
    db.execute('BEGIN IMMEDIATE;');
    try {
      db.execute(_audioPlaybackSessionSchema);
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _migrateV15() {
    _addColumnIfMissing('audio_playback_sessions', 'shuffle_remaining_json',
        "TEXT NOT NULL DEFAULT '[]'");
    _addColumnIfMissing('audio_playback_sessions', 'history_json',
        "TEXT NOT NULL DEFAULT '[]'");
  }

  void _migrateV16() {
    // Index-node BLOB previews were replaced by lightweight, non-recursive
    // render descriptions. Keep the legacy column for compatible databases,
    // but release all stored binary data.
    db.execute('UPDATE index_nodes SET thumbnail_png = NULL;');
  }

  void _migrateV17() {
    db.execute('BEGIN IMMEDIATE;');
    try {
      db.execute('DROP TRIGGER IF EXISTS entity_search_insert;');
      db.execute('DROP TRIGGER IF EXISTS entity_search_delete;');
      db.execute('DROP TRIGGER IF EXISTS entity_search_update;');
      db.execute('DROP TABLE IF EXISTS entity_search;');
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _rebuildIndexNodeStats() {
    db.execute('DELETE FROM index_node_stats;');
    db.execute('''
WITH RECURSIVE closure(ancestor_id, id) AS (
  SELECT id, id FROM index_nodes
  UNION ALL
  SELECT closure.ancestor_id, child.id
  FROM closure
  JOIN index_nodes child ON child.parent_id = closure.id
),
direct_counts AS (
  SELECT link.index_node_id AS id, COUNT(DISTINCT entity.id) AS count
  FROM index_node_entities link
  JOIN entities entity ON entity.id = link.entity_id AND entity.archived = 0
  GROUP BY link.index_node_id
),
descendant_counts AS (
  SELECT closure.ancestor_id AS id, COUNT(DISTINCT entity.id) AS count
  FROM closure
  LEFT JOIN index_node_entities link ON link.index_node_id = closure.id
  LEFT JOIN entities entity
    ON entity.id = link.entity_id AND entity.archived = 0
  GROUP BY closure.ancestor_id
),
child_counts AS (
  SELECT parent_id AS id, COUNT(*) AS count
  FROM index_nodes
  WHERE parent_id IS NOT NULL
  GROUP BY parent_id
)
INSERT INTO index_node_stats (
  node_id, direct_entity_count, descendant_entity_count,
  child_node_count, updated_at
)
SELECT node.id,
       COALESCE(direct_counts.count, 0),
       COALESCE(descendant_counts.count, 0),
       COALESCE(child_counts.count, 0),
       0
FROM index_nodes node
LEFT JOIN direct_counts ON direct_counts.id = node.id
LEFT JOIN descendant_counts ON descendant_counts.id = node.id
LEFT JOIN child_counts ON child_counts.id = node.id;
''');
  }

  void _dedupeRootNodes() {
    final roots = db.select(
      '''
      SELECT id FROM index_nodes
      WHERE node_type = 'root'
      ORDER BY rowid
      ''',
    );
    if (roots.length <= 1) return;
    final keeper = roots.first['id'] as String;
    for (final root in roots.skip(1)) {
      final duplicateId = root['id'] as String;
      db.execute(
        'UPDATE index_nodes SET parent_id = ? WHERE parent_id = ?',
        [keeper, duplicateId],
      );
      db.execute(
        'UPDATE index_node_edges SET from_node_id = ? WHERE from_node_id = ?',
        [keeper, duplicateId],
      );
      db.execute(
        'UPDATE index_node_edges SET to_node_id = ? WHERE to_node_id = ?',
        [keeper, duplicateId],
      );
      db.execute('DELETE FROM index_nodes WHERE id = ?', [duplicateId]);
    }
  }

  void _dedupeIndexNodeSiblings() {
    while (true) {
      final duplicates = db.select(
        '''
        SELECT parent_id, name, node_type, MIN(rowid) AS keeper_rowid
        FROM index_nodes
        WHERE parent_id IS NOT NULL
        GROUP BY parent_id, name, node_type
        HAVING COUNT(*) > 1
        LIMIT 1
        ''',
      );
      if (duplicates.isEmpty) return;
      final duplicate = duplicates.first;
      final keeper = db.select(
        'SELECT id FROM index_nodes WHERE rowid = ? LIMIT 1',
        [duplicate['keeper_rowid']],
      ).single['id'] as String;
      final nodes = db.select(
        '''
        SELECT id FROM index_nodes
        WHERE parent_id = ? AND name = ? AND node_type = ? AND id <> ?
        ''',
        [
          duplicate['parent_id'],
          duplicate['name'],
          duplicate['node_type'],
          keeper,
        ],
      );
      for (final node in nodes) {
        final duplicateId = node['id'] as String;
        db.execute(
          '''
          INSERT OR IGNORE INTO index_node_entities
          (index_node_id, entity_id, created_at)
          SELECT ?, entity_id, created_at
          FROM index_node_entities
          WHERE index_node_id = ?
          ''',
          [keeper, duplicateId],
        );
        db.execute(
          'UPDATE index_node_edges SET from_node_id = ? WHERE from_node_id = ?',
          [keeper, duplicateId],
        );
        db.execute(
          'UPDATE index_node_edges SET to_node_id = ? WHERE to_node_id = ?',
          [keeper, duplicateId],
        );
        db.execute(
          'UPDATE index_nodes SET parent_id = ? WHERE parent_id = ?',
          [keeper, duplicateId],
        );
        db.execute('DELETE FROM index_nodes WHERE id = ?', [duplicateId]);
      }
      _dedupeIndexNodeEdges();
    }
  }

  void _dedupeIndexNodeEdges() {
    final duplicates = db.select(
      '''
      SELECT MIN(rowid) AS keeper_rowid, from_node_id, to_node_id, edge_type
      FROM index_node_edges
      GROUP BY from_node_id, to_node_id, edge_type
      HAVING COUNT(*) > 1
      ''',
    );
    for (final duplicate in duplicates) {
      db.execute(
        '''
        DELETE FROM index_node_edges
        WHERE from_node_id = ?
          AND to_node_id = ?
          AND edge_type = ?
          AND rowid <> ?
        ''',
        [
          duplicate['from_node_id'],
          duplicate['to_node_id'],
          duplicate['edge_type'],
          duplicate['keeper_rowid'],
        ],
      );
    }
  }

  void _addColumnIfMissing(String table, String column, String definition) {
    final rows = db.select('PRAGMA table_info($table);');
    final exists = rows.any((row) => row['name'] == column);
    if (!exists) {
      db.execute('ALTER TABLE $table ADD COLUMN $column $definition;');
    }
  }

  void _migrateV25() {
    _addColumnIfMissing('index_nodes', 'relative_source_path', 'TEXT');
    db.execute(_indexJobCandidateSchema);
  }

  void _migrateV26() {
    _addColumnIfMissing(
      'index_job_candidates',
      'source_created_at_ms',
      'INTEGER',
    );
    _addColumnIfMissing(
      'index_job_candidates',
      'source_modified_at_ms',
      'INTEGER',
    );
  }

  void _migrateV27() {
    _addColumnIfMissing(
      'index_jobs',
      'scan_completed',
      'INTEGER NOT NULL DEFAULT 0',
    );
    _addColumnIfMissing('index_jobs', 'target_node_id', 'TEXT');
  }

  void _migrateV28() {
    final legacy = db.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'index_job_files'",
    );
    if (legacy.isEmpty) return;
    // Preserve resumable tasks created by older versions before retiring the
    // parallel manifest table. New scans exclusively use candidates.
    db.execute('''
      INSERT OR IGNORE INTO index_job_candidates (
        job_id, source_path, relative_path, sequence, state, format,
        media_type, fingerprint, size, metadata_preview, duration_ms,
        source_created_at_ms, source_modified_at_ms, error, updated_at
      )
      SELECT file.job_id, file.path, '', file.rowid, 'prepared', file.format,
             file.media_type, file.hash, file.size, file.metadata_preview,
             file.duration_ms, file.source_created_at_ms,
             file.source_modified_at_ms, NULL,
             COALESCE(job.updated_at, CAST(strftime('%s', 'now') AS INTEGER) * 1000)
      FROM index_job_files file
      LEFT JOIN index_jobs job ON job.id = file.job_id
    ''');
    db.execute('DROP TABLE index_job_files');
  }

  void _migrateV29() =>
      _addColumnIfMissing('index_jobs', 'staging_root_id', 'TEXT');

  void _migrateV30() {
    _addColumnIfMissing(
      'index_nodes',
      'is_staging',
      'INTEGER NOT NULL DEFAULT 0',
    );
    db.execute(_indexJobEntitySnapshotSchema);
  }
}

const _legacyTables = [
  'index_job_files',
  'index_jobs',
  'index_node_stats',
  'entity_index_links',
  'index_items',
  'indexes',
  'entity_thumbnails',
  'entity_states',
  'media_profiles',
  'resources',
  'library_roots',
  'index_node_edges',
  'index_node_entities',
  'index_nodes',
  'entities',
];

// Time columns named created_at / updated_at / last_opened_at store
// millisecond timestamps. Column names are kept stable to avoid migration churn.
const _schema = '''
CREATE TABLE IF NOT EXISTS entities (
  id TEXT PRIMARY KEY,
  path TEXT NOT NULL UNIQUE,
  local_path TEXT,
  name TEXT NOT NULL,
  format TEXT NOT NULL,
  media_type TEXT NOT NULL,
  hash TEXT NOT NULL,
  metadata_preview TEXT,
  thumbnail_status TEXT NOT NULL DEFAULT 'none',
  thumbnail_key TEXT,
  thumbnail_format TEXT,
  thumbnail_width INTEGER,
  thumbnail_height INTEGER,
  thumbnail_error TEXT,
  size INTEGER NOT NULL,
  source_created_at_ms INTEGER NOT NULL,
  source_modified_at_ms INTEGER NOT NULL,
  archived INTEGER NOT NULL DEFAULT 0,
  last_opened_at INTEGER,
  last_position_ms INTEGER,
  duration_ms INTEGER,
  reader_scroll_offset REAL,
  zoom_scale REAL,
  extra_state_json TEXT,
  directory_root_id TEXT REFERENCES index_nodes(id) ON DELETE SET NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS index_nodes (
  id TEXT PRIMARY KEY,
  parent_id TEXT,
  name TEXT NOT NULL,
  node_type TEXT NOT NULL,
  view_type TEXT NOT NULL,
  source_path TEXT,
  rule_json TEXT,
  thumbnail_png BLOB,
  preview_json TEXT,
  relative_source_path TEXT,
  is_staging INTEGER NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_built_at_ms INTEGER,
  FOREIGN KEY(parent_id) REFERENCES index_nodes(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS index_node_entities (
  index_node_id TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  sort_name TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  PRIMARY KEY(index_node_id, entity_id),
  FOREIGN KEY(index_node_id) REFERENCES index_nodes(id) ON DELETE CASCADE,
  FOREIGN KEY(entity_id) REFERENCES entities(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS index_node_edges (
  id TEXT PRIMARY KEY,
  from_node_id TEXT NOT NULL,
  to_node_id TEXT NOT NULL,
  edge_type TEXT NOT NULL,
  label TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY(from_node_id) REFERENCES index_nodes(id) ON DELETE CASCADE,
  FOREIGN KEY(to_node_id) REFERENCES index_nodes(id) ON DELETE CASCADE
);

$_indexNodeStatsSchema

$_indexJobSchema

$_indexJobCandidateSchema

$_audioPlaybackSessionSchema

$_graphNodePositionSchema

CREATE UNIQUE INDEX IF NOT EXISTS idx_index_nodes_root_source
ON index_nodes(source_path)
WHERE source_path IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_index_nodes_single_root
ON index_nodes(node_type)
WHERE node_type = 'root';

CREATE UNIQUE INDEX IF NOT EXISTS idx_index_nodes_sibling_name_type
ON index_nodes(parent_id, name, node_type)
WHERE parent_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_index_node_edges_unique
ON index_node_edges(from_node_id, to_node_id, edge_type);

CREATE INDEX IF NOT EXISTS idx_index_nodes_parent_id ON index_nodes(parent_id);
CREATE INDEX IF NOT EXISTS idx_index_nodes_parent_sort_name
ON index_nodes(parent_id, sort_order, name COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_index_nodes_parent_name
ON index_nodes(parent_id, name COLLATE NOCASE, id);
CREATE INDEX IF NOT EXISTS idx_index_nodes_parent_updated
ON index_nodes(parent_id, updated_at DESC, name COLLATE NOCASE, id);
CREATE INDEX IF NOT EXISTS idx_index_nodes_node_type ON index_nodes(node_type);
CREATE INDEX IF NOT EXISTS idx_entities_path ON entities(path);
CREATE INDEX IF NOT EXISTS idx_entities_directory_root_id
ON entities(directory_root_id);
CREATE INDEX IF NOT EXISTS idx_entities_media_type ON entities(media_type);
CREATE INDEX IF NOT EXISTS idx_entities_visible_name
ON entities(archived, name COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_entities_visible_modified
ON entities(archived, source_modified_at_ms);
CREATE INDEX IF NOT EXISTS idx_entities_visible_size
ON entities(archived, size);
CREATE INDEX IF NOT EXISTS idx_entities_visible_format_name
ON entities(archived, format COLLATE NOCASE, name COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_index_node_entities_node ON index_node_entities(index_node_id);
CREATE INDEX IF NOT EXISTS idx_index_node_entities_entity ON index_node_entities(entity_id);
CREATE INDEX IF NOT EXISTS idx_index_node_entities_node_sort_name
ON index_node_entities(index_node_id, sort_name COLLATE NOCASE, entity_id);
CREATE INDEX IF NOT EXISTS idx_index_node_edges_from ON index_node_edges(from_node_id);
CREATE INDEX IF NOT EXISTS idx_index_node_edges_to ON index_node_edges(to_node_id);
''';

const _indexNodeStatsSchema = '''
CREATE TABLE IF NOT EXISTS index_node_stats (
  node_id TEXT PRIMARY KEY,
  direct_entity_count INTEGER NOT NULL DEFAULT 0,
  descendant_entity_count INTEGER NOT NULL DEFAULT 0,
  child_node_count INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY(node_id) REFERENCES index_nodes(id) ON DELETE CASCADE
);
''';

const _indexJobSchema = '''
CREATE TABLE IF NOT EXISTS index_jobs (
  id TEXT PRIMARY KEY,
  source_path TEXT NOT NULL,
  index_root_id TEXT,
  status TEXT NOT NULL,
  phase TEXT NOT NULL,
  discovered INTEGER NOT NULL DEFAULT 0,
  total INTEGER NOT NULL DEFAULT 0,
  processed INTEGER NOT NULL DEFAULT 0,
  preview_total INTEGER NOT NULL DEFAULT 0,
  preview_processed INTEGER NOT NULL DEFAULT 0,
  scan_completed INTEGER NOT NULL DEFAULT 0,
  target_node_id TEXT,
  staging_root_id TEXT,
  error TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY(index_root_id) REFERENCES index_nodes(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_index_jobs_source_status
ON index_jobs(source_path, status, updated_at DESC);
''';

const _indexJobCandidateSchema = '''
CREATE TABLE IF NOT EXISTS index_job_candidates (
  job_id TEXT NOT NULL,
  source_path TEXT NOT NULL,
  relative_path TEXT NOT NULL DEFAULT '',
  sequence INTEGER NOT NULL DEFAULT 0,
  state TEXT NOT NULL DEFAULT 'pending',
  format TEXT,
  media_type TEXT,
  fingerprint TEXT,
  size INTEGER,
  metadata_preview TEXT,
  duration_ms INTEGER,
  source_created_at_ms INTEGER,
  source_modified_at_ms INTEGER,
  error TEXT,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY(job_id, source_path),
  FOREIGN KEY(job_id) REFERENCES index_jobs(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_index_job_candidates_state
ON index_job_candidates(job_id, state, sequence);
CREATE TABLE IF NOT EXISTS node_preview_overrides (
  node_id TEXT PRIMARY KEY,
  items_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY(node_id) REFERENCES index_nodes(id) ON DELETE CASCADE
);
''';

const _indexJobEntitySnapshotSchema = '''
CREATE TABLE IF NOT EXISTS index_job_entity_snapshots (
  job_id TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  entity_json TEXT NOT NULL,
  PRIMARY KEY(job_id, entity_id),
  FOREIGN KEY(job_id) REFERENCES index_jobs(id) ON DELETE CASCADE
);
''';

const _audioPlaybackSessionSchema = '''
CREATE TABLE IF NOT EXISTS audio_playback_sessions (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  source_node_id TEXT,
  source_node_name TEXT,
  mode TEXT NOT NULL,
  current_index INTEGER NOT NULL DEFAULT 0,
  position_ms INTEGER NOT NULL DEFAULT 0,
  shuffle_remaining_json TEXT NOT NULL DEFAULT '[]',
  history_json TEXT NOT NULL DEFAULT '[]',
  active INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS audio_playback_session_entries (
  session_id TEXT NOT NULL,
  sort_order INTEGER NOT NULL,
  entity_id TEXT NOT NULL,
  title TEXT NOT NULL,
  path TEXT NOT NULL,
  format TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  size INTEGER NOT NULL,
  modified_at_ms INTEGER NOT NULL,
  duration_ms INTEGER,
  PRIMARY KEY(session_id, sort_order),
  FOREIGN KEY(session_id) REFERENCES audio_playback_sessions(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_audio_playback_sessions_active
ON audio_playback_sessions(active, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_audio_playback_session_entries_session
ON audio_playback_session_entries(session_id, sort_order);
''';

const _graphNodePositionSchema = '''
CREATE TABLE IF NOT EXISTS graph_node_positions (
  node_id TEXT PRIMARY KEY,
  x REAL NOT NULL,
  y REAL NOT NULL,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY(node_id) REFERENCES index_nodes(id) ON DELETE CASCADE
);
''';
