import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'schema_v6.dart';
import 'schema_v7.dart';
import 'schema_v8.dart';

/// SQLite storage and additive migrations, owned by database workers.
class AppDatabase {
  AppDatabase._(this.db, this.storageDirectoryPath, this.databasePath);

  static const currentSchemaVersion = 8;

  final Database db;
  final String storageDirectoryPath;
  final String? databasePath;
  bool _closed = false;

  static Future<AppDatabase> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return _openAtPath(p.join(dir.path, 'best_viewer.db'), dir.path);
  }

  static AppDatabase openInMemory() {
    final dir = Directory.systemTemp.createTempSync('best_viewer_test_');
    return _openDatabase(sqlite3.openInMemory(), dir.path, null);
  }

  static AppDatabase openForTesting(Database database) {
    final dir = Directory.systemTemp.createTempSync('best_viewer_test_');
    return _openDatabase(database, dir.path, null);
  }

  static AppDatabase openAtPathForTesting(String dbPath) {
    return openAtPath(dbPath);
  }

  static AppDatabase openAtPath(String dbPath) {
    final file = File(dbPath);
    file.parent.createSync(recursive: true);
    return _openAtPathSync(file.path, file.parent.path);
  }

  static Future<AppDatabase> _openAtPath(
      String databasePath, String root) async {
    return _openAtPathSync(databasePath, root);
  }

  static AppDatabase _openAtPathSync(String databasePath, String root) {
    return _openDatabase(sqlite3.open(databasePath), root, databasePath);
  }

  static AppDatabase _openDatabase(
    Database database,
    String storageDirectoryPath,
    String? databasePath,
  ) {
    final appDb = AppDatabase._(database, storageDirectoryPath, databasePath);
    try {
      appDb.migrate();
      return appDb;
    } catch (_) {
      appDb.close();
      rethrow;
    }
  }

  /// Removes only app-owned database and generated cache files. It never
  /// touches user selected source folders, including removable storage.
  static Future<void> resetLocalIndexStorage() async {
    final dir = await getApplicationSupportDirectory();
    final databasePath = p.join(dir.path, 'best_viewer.db');
    final files = <File>[
      File(databasePath),
      File('$databasePath-wal'),
      File('$databasePath-shm'),
    ];
    for (final file in files) {
      if (await file.exists()) await file.delete();
    }
    for (final name in const [
      'thumbnails',
      'audio_waveforms',
      'reader_cache'
    ]) {
      final cache = Directory(p.join(dir.path, name));
      if (await cache.exists()) await cache.delete(recursive: true);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    db.dispose();
  }

  /// Flushes pages that are no longer needed by active readers without
  /// blocking them. Large index tasks call this at stable boundaries so WAL
  /// files do not keep growing until the next application restart.
  void checkpointWriteAheadLog() {
    db.select('PRAGMA wal_checkpoint(PASSIVE)');
  }

  void migrate() {
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA busy_timeout = 3000;');
    db.execute('PRAGMA synchronous = NORMAL;');

    final version = db.userVersion;
    if (version == currentSchemaVersion) {
      db.execute(_schema);
      _ensurePreviewSchema();
      _verifySchemaIntegrity();
      db.execute('PRAGMA optimize;');
      return;
    }
    if (version == 5 || version == 6 || version == 7) {
      final path = databasePath;
      if (path != null) {
        final backup = '$path.schema$version.backup';
        if (!File(backup).existsSync()) {
          db.execute('VACUUM INTO ?', [backup]);
        }
      }
      db.execute('BEGIN IMMEDIATE');
      try {
        if (version == 5) db.execute(schemaV6Upgrade);
        if (version <= 6) db.execute(schemaV7Upgrade);
        _ensurePreviewSchema();
        db.execute(schemaV8Upgrade);
        _verifySchemaIntegrity();
        db.userVersion = currentSchemaVersion;
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
      return;
    }
    if (version != 0 || _hasUserTables()) {
      throw AppDatabaseResetRequired(version);
    }

    db.execute('BEGIN IMMEDIATE;');
    try {
      db.execute(_schema);
      db.execute(schemaV6Upgrade);
      db.execute(schemaV7Upgrade);
      _ensurePreviewSchema();
      db.execute(schemaV8Upgrade);
      _verifySchemaIntegrity();
      db.userVersion = currentSchemaVersion;
      db.execute('COMMIT;');
      db.execute('PRAGMA optimize;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _ensurePreviewSchema() {
    db.execute(schemaV6PreviewAssets);
    final columns = db.select('PRAGMA table_info(document_preview_versions)');
    if (!columns.any((row) => row['name'] == 'cover_revision')) {
      db.execute(
          'ALTER TABLE document_preview_versions ADD COLUMN cover_revision INTEGER');
    }
  }

  void _verifySchemaIntegrity() {
    if (db.select('PRAGMA foreign_key_check').isNotEmpty) {
      throw StateError('Database migration left invalid foreign keys');
    }
    if (db.select('''
      SELECT 1 FROM index_nodes
      WHERE node_type IN ('graph_index_root', 'graph_node')
      LIMIT 1
    ''').isNotEmpty) {
      throw StateError('Database migration left graph nodes behind');
    }
    final nodeCount = db
        .select('SELECT COUNT(*) AS count FROM index_nodes')
        .single['count'] as int;
    final searchCount = db
        .select('SELECT COUNT(*) AS count FROM index_node_search')
        .single['count'] as int;
    if (nodeCount != searchCount) {
      throw StateError('Node search index is inconsistent');
    }
  }

  bool _hasUserTables() {
    return db.select('''
      SELECT 1
      FROM sqlite_master
      WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
      LIMIT 1
    ''').isNotEmpty;
  }
}

class AppDatabaseResetRequired implements Exception {
  const AppDatabaseResetRequired(this.foundVersion);

  final int foundVersion;

  @override
  String toString() => 'AppDatabaseResetRequired(foundVersion: $foundVersion)';
}

// Time columns named created_at / updated_at / last_opened_at store
// millisecond timestamps. This is the current clean schema baseline.
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

CREATE TABLE IF NOT EXISTS index_node_stats (
  node_id TEXT PRIMARY KEY,
  direct_entity_count INTEGER NOT NULL DEFAULT 0,
  descendant_entity_count INTEGER NOT NULL DEFAULT 0,
  child_node_count INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY(node_id) REFERENCES index_nodes(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS node_preview_overrides (
  node_id TEXT PRIMARY KEY,
  items_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY(node_id) REFERENCES index_nodes(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS thumbnail_assets (
  asset_key TEXT PRIMARY KEY,
  format TEXT NOT NULL,
  byte_size INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);

-- A directory build has exactly one durable parent state machine. The first
-- three stages are atomic checkpoints; derived asset stages resume per work
-- item without retaining a full source tree in memory.
CREATE TABLE IF NOT EXISTS library_build_jobs (
  id TEXT PRIMARY KEY,
  source_path TEXT NOT NULL,
  operation_type TEXT NOT NULL,
  target_node_id TEXT,
  index_root_id TEXT,
  staging_root_id TEXT,
  stage TEXT NOT NULL,
  status TEXT NOT NULL,
  manifest_total INTEGER NOT NULL DEFAULT 0,
  indexed_total INTEGER NOT NULL DEFAULT 0,
  document_preview_total INTEGER NOT NULL DEFAULT 0,
  document_preview_done INTEGER NOT NULL DEFAULT 0,
  document_preview_failed INTEGER NOT NULL DEFAULT 0,
  entity_preview_total INTEGER NOT NULL DEFAULT 0,
  entity_preview_done INTEGER NOT NULL DEFAULT 0,
  entity_preview_failed INTEGER NOT NULL DEFAULT 0,
  node_preview_total INTEGER NOT NULL DEFAULT 0,
  node_preview_done INTEGER NOT NULL DEFAULT 0,
  node_preview_failed INTEGER NOT NULL DEFAULT 0,
  error TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY(index_root_id) REFERENCES index_nodes(id) ON DELETE SET NULL,
  FOREIGN KEY(target_node_id) REFERENCES index_nodes(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS library_build_manifest (
  job_id TEXT NOT NULL,
  source_path TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  name TEXT NOT NULL,
  format TEXT NOT NULL,
  media_type TEXT NOT NULL,
  fingerprint TEXT,
  size INTEGER NOT NULL,
  metadata_preview TEXT,
  duration_ms INTEGER,
  source_created_at_ms INTEGER NOT NULL,
  source_modified_at_ms INTEGER NOT NULL,
  PRIMARY KEY(job_id, source_path),
  FOREIGN KEY(job_id) REFERENCES library_build_jobs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS library_entity_preview_work (
  job_id TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending',
  attempts INTEGER NOT NULL DEFAULT 0,
  error TEXT,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY(job_id, entity_id),
  FOREIGN KEY(job_id) REFERENCES library_build_jobs(id) ON DELETE CASCADE,
  FOREIGN KEY(entity_id) REFERENCES entities(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS library_document_preview_work (
  job_id TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending',
  attempts INTEGER NOT NULL DEFAULT 0,
  error TEXT,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY(job_id, entity_id),
  FOREIGN KEY(job_id) REFERENCES library_build_jobs(id) ON DELETE CASCADE,
  FOREIGN KEY(entity_id) REFERENCES entities(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS library_node_preview_work (
  job_id TEXT NOT NULL,
  node_id TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending',
  signature TEXT,
  attempts INTEGER NOT NULL DEFAULT 0,
  error TEXT,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY(job_id, node_id),
  FOREIGN KEY(job_id) REFERENCES library_build_jobs(id) ON DELETE CASCADE,
  FOREIGN KEY(node_id) REFERENCES index_nodes(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS node_preview_assets (
  node_id TEXT PRIMARY KEY,
  signature TEXT NOT NULL,
  asset_key TEXT NOT NULL,
  format TEXT NOT NULL,
  width INTEGER NOT NULL,
  height INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY(node_id) REFERENCES index_nodes(id) ON DELETE CASCADE
);

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

CREATE UNIQUE INDEX IF NOT EXISTS idx_index_nodes_root_source
ON index_nodes(source_path) WHERE source_path IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_index_nodes_single_root
ON index_nodes(node_type) WHERE node_type = 'root';
CREATE UNIQUE INDEX IF NOT EXISTS idx_index_nodes_sibling_name_type
ON index_nodes(parent_id, name, node_type) WHERE parent_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_index_nodes_parent_id ON index_nodes(parent_id);
CREATE INDEX IF NOT EXISTS idx_index_nodes_parent_sort_name
ON index_nodes(parent_id, sort_order, name COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_index_nodes_parent_name
ON index_nodes(parent_id, name COLLATE NOCASE, id);
CREATE INDEX IF NOT EXISTS idx_index_nodes_parent_updated
ON index_nodes(parent_id, updated_at DESC, name COLLATE NOCASE, id);
CREATE INDEX IF NOT EXISTS idx_index_nodes_node_type ON index_nodes(node_type);
CREATE INDEX IF NOT EXISTS idx_entities_path ON entities(path);
CREATE INDEX IF NOT EXISTS idx_entities_directory_root_id ON entities(directory_root_id);
CREATE INDEX IF NOT EXISTS idx_entities_media_type ON entities(media_type);
CREATE INDEX IF NOT EXISTS idx_entities_visible_name
ON entities(archived, name COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_entities_visible_modified
ON entities(archived, source_modified_at_ms);
CREATE INDEX IF NOT EXISTS idx_entities_visible_size ON entities(archived, size);
CREATE INDEX IF NOT EXISTS idx_entities_visible_format_name
ON entities(archived, format COLLATE NOCASE, name COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_index_node_entities_node
ON index_node_entities(index_node_id);
CREATE INDEX IF NOT EXISTS idx_index_node_entities_entity
ON index_node_entities(entity_id);
CREATE INDEX IF NOT EXISTS idx_index_node_entities_node_sort_name
ON index_node_entities(index_node_id, sort_name COLLATE NOCASE, entity_id);
CREATE INDEX IF NOT EXISTS idx_library_build_jobs_recovery
ON library_build_jobs(status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_library_build_manifest_sequence
ON library_build_manifest(job_id, sequence);
CREATE INDEX IF NOT EXISTS idx_library_entity_preview_work_pending
ON library_entity_preview_work(job_id, state, entity_id);

CREATE INDEX IF NOT EXISTS idx_library_document_preview_work_pending
ON library_document_preview_work(job_id, state, entity_id);
CREATE INDEX IF NOT EXISTS idx_library_node_preview_work_pending
ON library_node_preview_work(job_id, state, node_id);
CREATE INDEX IF NOT EXISTS idx_audio_playback_sessions_active
ON audio_playback_sessions(active, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_audio_playback_session_entries_session
ON audio_playback_session_entries(session_id, sort_order);
''';
