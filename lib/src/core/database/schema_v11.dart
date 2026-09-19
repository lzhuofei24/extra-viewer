import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';

const progressColumns = [
  'last_position_ms',
  'reader_scroll_offset',
  'zoom_scale',
  'extra_state_json'
];
const previewColumns = [
  'metadata_preview',
  'thumbnail_status',
  'thumbnail_key',
  'thumbnail_format',
  'thumbnail_width',
  'thumbnail_height',
  'thumbnail_error',
  'preview_revision'
];

void migrateSchemaV11(Database db) {
  final columns =
      db.select('PRAGMA table_info(entities)').map((r) => r['name']).toSet();
  if (!columns.contains('path')) {
    return; // Minimal historical migration fixtures.
  }
  db.execute('''
    CREATE TABLE IF NOT EXISTS entity_progress (
      entity_id TEXT PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
      last_position_ms INTEGER CHECK(last_position_ms IS NULL OR last_position_ms >= 0),
      reader_scroll_offset REAL CHECK(reader_scroll_offset IS NULL OR reader_scroll_offset >= 0),
      zoom_scale REAL CHECK(zoom_scale IS NULL OR zoom_scale > 0),
      extra_state_json TEXT, updated_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS entity_previews (
      entity_id TEXT PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
      metadata_preview TEXT, thumbnail_status TEXT NOT NULL DEFAULT 'none',
      thumbnail_key TEXT, thumbnail_format TEXT, thumbnail_width INTEGER,
      thumbnail_height INTEGER, thumbnail_error TEXT,
      preview_revision INTEGER NOT NULL DEFAULT 1 CHECK(preview_revision > 0),
      updated_at INTEGER NOT NULL
    );
  ''');
  if (columns.contains('last_position_ms')) {
    db.execute('''INSERT INTO entity_progress
      SELECT id, ${progressColumns.join(',')}, updated_at FROM entities
      WHERE last_position_ms IS NOT NULL OR reader_scroll_offset IS NOT NULL
         OR zoom_scale IS NOT NULL OR extra_state_json IS NOT NULL''');
  }
  if (columns.contains('thumbnail_key')) {
    db.execute('''INSERT INTO entity_previews
      SELECT id, ${previewColumns.join(',')}, updated_at FROM entities''');
  }
  db.execute('DROP TRIGGER IF EXISTS retire_deleted_entity_preview');
  for (final column in [...progressColumns, ...previewColumns]) {
    if (columns.contains(column)) {
      db.execute('ALTER TABLE entities DROP COLUMN $column');
    }
  }
  db.execute('''
    CREATE INDEX IF NOT EXISTS idx_entity_preview_key ON entity_previews(thumbnail_key);
    CREATE TRIGGER IF NOT EXISTS create_entity_preview AFTER INSERT ON entities
    BEGIN INSERT INTO entity_previews(entity_id, updated_at) VALUES(NEW.id, NEW.updated_at); END;
    CREATE TRIGGER IF NOT EXISTS retire_deleted_entity_preview
    AFTER DELETE ON entity_previews WHEN OLD.thumbnail_key IS NOT NULL
    BEGIN
      INSERT INTO retired_preview_assets(kind, asset_key, format, not_before)
      VALUES('entity', OLD.thumbnail_key, COALESCE(OLD.thumbnail_format,'webp'),
        (CAST(strftime('%s','now') AS INTEGER)+86400)*1000)
      ON CONFLICT(kind, asset_key) DO UPDATE SET not_before=excluded.not_before;
    END;
    CREATE TRIGGER IF NOT EXISTS query_dirty_preview AFTER UPDATE ON entity_previews
    BEGIN INSERT INTO query_revision_dirty(domain) VALUES('preview') ON CONFLICT DO NOTHING; END;
    CREATE VIEW IF NOT EXISTS entity_details AS SELECT e.*,
      ${previewColumns.map((c) => 'v.$c').join(',')},
      ${progressColumns.map((c) => 'p.$c').join(',')}
    FROM entities e LEFT JOIN entity_previews v ON v.entity_id=e.id
    LEFT JOIN entity_progress p ON p.entity_id=e.id;
  ''');
  db.execute('''CREATE TABLE IF NOT EXISTS node_preview_override_items (
    node_id TEXT NOT NULL REFERENCES index_nodes(id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL CHECK(ordinal>=0),
    entity_id TEXT REFERENCES entities(id) ON DELETE CASCADE,
    target_node_id TEXT REFERENCES index_nodes(id) ON DELETE CASCADE,
    descriptor_json TEXT NOT NULL CHECK(json_valid(descriptor_json)),
    PRIMARY KEY(node_id,ordinal),
    CHECK((entity_id IS NOT NULL)+(target_node_id IS NOT NULL)=1)
  );
  CREATE INDEX IF NOT EXISTS idx_cover_entity ON node_preview_override_items(entity_id,node_id);
  CREATE INDEX IF NOT EXISTS idx_cover_node ON node_preview_override_items(target_node_id,node_id);
  ''');
  final old = db.select(
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name='node_preview_overrides'");
  if (old.isNotEmpty) {
    for (final row in db.select('SELECT * FROM node_preview_overrides')) {
      final items = jsonDecode(row['items_json'] as String) as List;
      for (var i = 0; i < items.length; i++) {
        final item = items[i] as Map;
        db.execute(
            'INSERT INTO node_preview_override_items VALUES(?,?,?,?,?)', [
          row['node_id'],
          i,
          item['entityId'],
          item['nodeId'],
          jsonEncode(item)
        ]);
      }
    }
    db.execute('DROP TABLE node_preview_overrides');
  }
  db.execute('''CREATE VIEW IF NOT EXISTS node_preview_overrides AS
    SELECT node_id, json_group_array(json(descriptor_json)) AS items_json
    FROM (SELECT * FROM node_preview_override_items ORDER BY node_id,ordinal) GROUP BY node_id;
    CREATE TRIGGER IF NOT EXISTS cover_target_removed AFTER DELETE ON node_preview_override_items
    WHEN EXISTS(SELECT 1 FROM index_nodes WHERE id=OLD.node_id)
    BEGIN
      INSERT INTO node_preview_versions(node_id,revision) VALUES(OLD.node_id,1)
        ON CONFLICT(node_id) DO UPDATE SET revision=revision+1;
      INSERT INTO node_preview_dirty(node_id,revision,reason,updated_at)
      SELECT node_id,revision,'cover_target_removed',CAST(strftime('%s','now') AS INTEGER)*1000
      FROM node_preview_versions WHERE node_id=OLD.node_id
      ON CONFLICT(node_id) DO UPDATE SET revision=excluded.revision,reason=excluded.reason;
    END;''');
}
