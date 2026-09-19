import 'package:sqlite3/sqlite3.dart';

/// Install safety boundaries before accepting any application commands.
void migrateSchemaV10(Database db) {
  final ruleColumns = db.select('PRAGMA table_info(index_rules)');
  if (!ruleColumns.any((r) => r['name'] == 'scope_state')) {
    db.execute('''
      ALTER TABLE index_rules ADD COLUMN scope_state TEXT NOT NULL DEFAULT 'all'
        CHECK(scope_state IN ('all', 'node', 'missing'));
      UPDATE index_rules SET scope_state = 'node' WHERE scope_node_id IS NOT NULL;
    ''');
  }
  db.execute('''
    CREATE TABLE IF NOT EXISTS query_revisions (
      domain TEXT NOT NULL, scope_id TEXT NOT NULL DEFAULT '',
      revision INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0),
      PRIMARY KEY(domain, scope_id)
    );
    CREATE TABLE IF NOT EXISTS query_revision_dirty (
      domain TEXT NOT NULL, scope_id TEXT NOT NULL DEFAULT '',
      PRIMARY KEY(domain, scope_id)
    );
    CREATE TABLE IF NOT EXISTS index_stats_dirty (
      node_id TEXT PRIMARY KEY REFERENCES index_nodes(id) ON DELETE CASCADE,
      revision INTEGER NOT NULL DEFAULT 1 CHECK(revision > 0)
    );
    CREATE TRIGGER IF NOT EXISTS rule_scope_deleted BEFORE DELETE ON index_nodes
    BEGIN
      UPDATE index_rules SET scope_state = 'missing', scope_node_id = NULL,
        updated_at = MAX(updated_at + 1, CAST(strftime('%s','now') AS INTEGER) * 1000)
      WHERE scope_node_id = OLD.id;
    END;
    CREATE TRIGGER IF NOT EXISTS protect_system_node_delete
    BEFORE DELETE ON index_nodes WHEN OLD.is_protected = 1
    BEGIN SELECT RAISE(ABORT, 'Protected node cannot be deleted'); END;
    CREATE TRIGGER IF NOT EXISTS protect_system_node_update
    BEFORE UPDATE ON index_nodes WHEN OLD.is_protected = 1 AND (
      NEW.name IS NOT OLD.name OR NEW.parent_id IS NOT OLD.parent_id
      OR NEW.is_protected IS NOT OLD.is_protected
      OR NEW.system_key IS NOT OLD.system_key OR NEW.node_type IS NOT OLD.node_type)
    BEGIN SELECT RAISE(ABORT, 'Protected node cannot be changed'); END;
    CREATE TRIGGER IF NOT EXISTS prevent_node_cycle BEFORE UPDATE OF parent_id ON index_nodes
    WHEN NEW.parent_id IS NOT OLD.parent_id AND NEW.parent_id IS NOT NULL
    BEGIN
      SELECT RAISE(ABORT, 'Node cycle') WHERE NEW.parent_id IN (
        WITH RECURSIVE descendants(id) AS (
          SELECT OLD.id UNION SELECT n.id FROM index_nodes n
          JOIN descendants d ON n.parent_id = d.id
        ) SELECT id FROM descendants
      );
    END;
  ''');
  for (final event in ['INSERT', 'UPDATE']) {
    db.execute(
        '''CREATE TRIGGER IF NOT EXISTS validate_rule_${event.toLowerCase()}
      BEFORE $event ON index_rules WHEN
        (NEW.min_size IS NOT NULL AND NEW.min_size < 0) OR
        (NEW.max_size IS NOT NULL AND NEW.max_size < 0) OR
        (NEW.min_size IS NOT NULL AND NEW.max_size IS NOT NULL AND NEW.min_size > NEW.max_size) OR
        (NEW.modified_within_days IS NOT NULL AND NEW.modified_within_days < 1) OR
        (NEW.opened_within_days IS NOT NULL AND NEW.opened_within_days < 1) OR
        NEW.max_results NOT BETWEEN 1 AND 100000 OR
        (NEW.scope_state = 'node' AND NEW.scope_node_id IS NULL) OR
        (NEW.scope_state <> 'node' AND NEW.scope_node_id IS NOT NULL) OR
        (NEW.scope_node_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM index_nodes WHERE id = NEW.scope_node_id AND node_type IN
          ('folder','directory_index_root','category','category_index_root')))
      BEGIN SELECT RAISE(ABORT, 'Invalid rule definition'); END;''');
  }
  final tables = db
      .select("SELECT name FROM sqlite_master WHERE type='table'")
      .map((r) => r['name'])
      .toSet();
  if (tables.contains('audio_playback_sessions')) {
    db.execute('''
      UPDATE audio_playback_sessions SET active = 0 WHERE active = 1 AND id <> (
        SELECT id FROM audio_playback_sessions WHERE active = 1
        ORDER BY updated_at DESC, id ASC LIMIT 1);
      CREATE UNIQUE INDEX IF NOT EXISTS idx_one_active_audio_session
      ON audio_playback_sessions(active) WHERE active = 1;
    ''');
  }
  final entityColumns =
      db.select('PRAGMA table_info(entities)').map((r) => r['name']).toSet();
  if (entityColumns.contains('archived')) {
    db.execute('''
      DROP INDEX IF EXISTS idx_entities_visible_last_opened;
      DROP INDEX IF EXISTS idx_entities_visible_open_count;
      DROP INDEX IF EXISTS idx_entities_type_last_opened;
      CREATE INDEX idx_entities_visible_last_opened ON entities
        (archived, COALESCE(last_opened_at,0) DESC, id ASC);
      CREATE INDEX idx_entities_visible_open_count ON entities
        (archived, open_count DESC, COALESCE(last_opened_at,0) DESC, id ASC);
      CREATE INDEX idx_entities_type_last_opened ON entities
        (archived, media_type, COALESCE(last_opened_at,0) DESC, id ASC);
      DROP INDEX IF EXISTS idx_entities_visible_name;
      DROP INDEX IF EXISTS idx_entities_visible_size;
      DROP INDEX IF EXISTS idx_entities_visible_modified;
      CREATE INDEX idx_entities_visible_name ON entities(archived, name COLLATE NOCASE, id);
      CREATE INDEX idx_entities_visible_size ON entities(archived, size DESC, id);
      CREATE INDEX idx_entities_visible_modified ON entities(archived, source_modified_at_ms DESC, id);
      CREATE INDEX IF NOT EXISTS idx_entities_format ON entities(archived, lower(format), id);
      DROP INDEX IF EXISTS idx_entities_path;
    ''');
    for (final event in ['INSERT', 'UPDATE']) {
      db.execute(
          '''CREATE TRIGGER IF NOT EXISTS validate_entity_${event.toLowerCase()}
        BEFORE $event ON entities WHEN NEW.size < 0 OR NEW.open_count < 0
        OR NEW.archived NOT IN (0,1) OR NEW.source_revision < 1
        OR NEW.source_created_at_ms < 0 OR NEW.source_modified_at_ms < 0
        BEGIN SELECT RAISE(ABORT, 'Invalid entity metadata'); END;''');
    }
  }
  for (final table in [
    'index_nodes',
    'index_node_entities',
    'entities',
    'index_rules'
  ]) {
    if (!tables.contains(table)) continue;
    final domain = switch (table) {
      'entities' => 'metadata',
      'index_rules' => 'rules',
      _ => 'structure',
    };
    for (final event in ['INSERT', 'UPDATE', 'DELETE']) {
      final updateColumns = table == 'entities' &&
              entityColumns.contains('archived')
          ? ' OF name, format, media_type, size, source_modified_at_ms, archived, source_revision'
          : '';
      db.execute(
          '''CREATE TRIGGER IF NOT EXISTS query_dirty_${table}_${event.toLowerCase()}
        AFTER $event${event == 'UPDATE' ? updateColumns : ''} ON $table
        BEGIN INSERT INTO query_revision_dirty(domain) VALUES ('$domain') ON CONFLICT DO NOTHING; END;''');
    }
  }
  if (entityColumns.contains('last_opened_at')) {
    db.execute('''CREATE TRIGGER IF NOT EXISTS query_dirty_access
      AFTER UPDATE OF open_count, last_opened_at ON entities
      BEGIN INSERT INTO query_revision_dirty(domain) VALUES ('access') ON CONFLICT DO NOTHING; END;''');
  }
  if (tables.contains('index_node_entities')) {
    for (final event in ['INSERT', 'DELETE']) {
      final value = event == 'DELETE' ? 'OLD' : 'NEW';
      db.execute(
          '''CREATE TRIGGER IF NOT EXISTS stats_dirty_link_${event.toLowerCase()}
        AFTER $event ON index_node_entities BEGIN
          INSERT INTO index_stats_dirty(node_id)
          WITH RECURSIVE ancestors(id, parent_id) AS (
            SELECT id, parent_id FROM index_nodes WHERE id = $value.index_node_id
            UNION SELECT n.id, n.parent_id FROM index_nodes n
            JOIN ancestors a ON n.id = a.parent_id
          ) SELECT id FROM ancestors WHERE true
          ON CONFLICT(node_id) DO UPDATE SET revision = revision + 1;
          INSERT INTO query_revision_dirty(domain, scope_id)
          WITH RECURSIVE ancestors(id, parent_id, node_type) AS (
            SELECT id, parent_id, node_type FROM index_nodes WHERE id = $value.index_node_id
            UNION SELECT n.id, n.parent_id, n.node_type FROM index_nodes n
            JOIN ancestors a ON n.id = a.parent_id
          ) SELECT 'structure', id FROM ancestors
          WHERE node_type IN ('directory_index_root', 'category_index_root')
          ON CONFLICT DO NOTHING;
        END;''');
    }
  }
}

/// Called once inside a successful command, before its commit/receipt.
void flushQueryRevisions(Database db) {
  db.execute('''INSERT INTO query_revisions(domain, scope_id, revision)
    SELECT domain, scope_id, 1 FROM query_revision_dirty WHERE true
    ON CONFLICT(domain, scope_id) DO UPDATE SET revision = revision + 1''');
  db.execute('DELETE FROM query_revision_dirty');
}
