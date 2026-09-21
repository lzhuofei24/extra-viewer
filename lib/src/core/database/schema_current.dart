// Final database baseline. No historical migrations run on creation.
const currentSchemaSql = r'''
CREATE TABLE schema_identity (id INTEGER PRIMARY KEY CHECK(id=1), application TEXT NOT NULL);
INSERT INTO schema_identity VALUES(1,'extra-viewer');
CREATE TABLE audio_playback_session_entries (
  session_id TEXT NOT NULL,
  sort_order INTEGER NOT NULL,
  entity_id TEXT NOT NULL,
  title TEXT NOT NULL,
  path TEXT NOT NULL,
  format TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  size INTEGER NOT NULL CHECK(size>=0),
  modified_at_ms INTEGER NOT NULL,
  duration_ms INTEGER,
  PRIMARY KEY(session_id, sort_order),
  FOREIGN KEY(session_id) REFERENCES audio_playback_sessions(id) ON DELETE CASCADE
);

CREATE TABLE audio_playback_sessions (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  source_node_id TEXT,
  source_node_name TEXT,
  mode TEXT NOT NULL CHECK(mode IN ('sequential','singleRepeat','nodeRepeat','nodeShuffle')),
  current_index INTEGER NOT NULL DEFAULT 0 CHECK(current_index>=0),
  position_ms INTEGER NOT NULL DEFAULT 0 CHECK(position_ms>=0),
  shuffle_remaining_json TEXT NOT NULL DEFAULT '[]',
  history_json TEXT NOT NULL DEFAULT '[]',
  active INTEGER NOT NULL DEFAULT 0 CHECK(active IN (0,1)),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE database_command_receipts (
  request_id TEXT PRIMARY KEY, changes INTEGER NOT NULL, committed_at INTEGER NOT NULL
);

CREATE TABLE document_preview_versions (
  entity_id TEXT PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
  source_revision INTEGER NOT NULL, cover_revision INTEGER
);

CREATE TABLE entities (
  id TEXT PRIMARY KEY,
  path TEXT NOT NULL UNIQUE,
  local_path TEXT,
  name TEXT NOT NULL,
  format TEXT NOT NULL,
  media_type TEXT NOT NULL CHECK(media_type IN ('text','image','audio','video','external_link')),
  hash TEXT NOT NULL,
  size INTEGER NOT NULL CHECK(size>=0),
  source_created_at_ms INTEGER NOT NULL,
  source_modified_at_ms INTEGER NOT NULL,
  archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1)),
  last_opened_at INTEGER,
  duration_ms INTEGER CHECK(duration_ms IS NULL OR duration_ms>=0),
  directory_root_id TEXT REFERENCES index_nodes(id) ON DELETE SET NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
, source_revision INTEGER NOT NULL DEFAULT 1 CHECK(source_revision>0), open_count INTEGER NOT NULL DEFAULT 0 CHECK(open_count>=0));

CREATE TABLE entity_locations (
      entity_id TEXT PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
      source_id TEXT REFERENCES sources(id) ON DELETE RESTRICT,
      document_identity TEXT, locator TEXT NOT NULL,
      state TEXT NOT NULL CHECK(state IN ('resolved','legacy','conflict')),
      updated_at INTEGER NOT NULL);

CREATE TABLE entity_previews (
      entity_id TEXT PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
      metadata_preview TEXT, thumbnail_status TEXT NOT NULL DEFAULT 'none' CHECK(thumbnail_status IN ('none','pending','success','failed')),
      thumbnail_key TEXT, thumbnail_format TEXT, thumbnail_width INTEGER,
      thumbnail_height INTEGER, thumbnail_error TEXT,
      preview_revision INTEGER NOT NULL DEFAULT 1 CHECK(preview_revision > 0),
      updated_at INTEGER NOT NULL
    );

CREATE TABLE entity_progress (
      entity_id TEXT PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
      last_position_ms INTEGER CHECK(last_position_ms IS NULL OR last_position_ms >= 0),
      reader_scroll_offset REAL CHECK(reader_scroll_offset IS NULL OR reader_scroll_offset >= 0),
      zoom_scale REAL CHECK(zoom_scale IS NULL OR zoom_scale > 0),
      settings_json TEXT CHECK(settings_json IS NULL OR json_valid(settings_json)),
      reading_kind TEXT CHECK(reading_kind IS NULL OR reading_kind IN ('pdf','reflow')),
      reading_version INTEGER CHECK(reading_version IS NULL OR reading_version=1),
      document_revision INTEGER CHECK(document_revision IS NULL OR document_revision>0),
      chapter_index INTEGER CHECK(chapter_index IS NULL OR chapter_index>=0),
      chapter_title TEXT,
      page_index INTEGER CHECK(page_index IS NULL OR page_index>=0),
      block_index INTEGER CHECK(block_index IS NULL OR block_index>=0),
      block_key TEXT,
      block_fraction REAL CHECK(block_fraction IS NULL OR block_fraction BETWEEN 0 AND 1),
      reading_mode TEXT CHECK(reading_mode IS NULL OR reading_mode IN ('scroll','book')),
      reading_offset REAL CHECK(reading_offset IS NULL OR reading_offset>=0),
      updated_at INTEGER NOT NULL
    );

CREATE TABLE index_node_entities (
  index_node_id TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  sort_name TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  PRIMARY KEY(index_node_id, entity_id),
  FOREIGN KEY(index_node_id) REFERENCES index_nodes(id) ON DELETE CASCADE,
  FOREIGN KEY(entity_id) REFERENCES entities(id) ON DELETE CASCADE
);

CREATE VIRTUAL TABLE index_node_search USING fts5(
  name, content='index_nodes', content_rowid='rowid', tokenize='trigram'
);

CREATE TABLE index_node_stats (
  node_id TEXT PRIMARY KEY,
  direct_entity_count INTEGER NOT NULL DEFAULT 0,
  descendant_entity_count INTEGER NOT NULL DEFAULT 0,
  child_node_count INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL, revision INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY(node_id) REFERENCES index_nodes(id) ON DELETE CASCADE
);

CREATE TABLE index_nodes (
  id TEXT PRIMARY KEY,
  parent_id TEXT,
  name TEXT NOT NULL,
  node_type TEXT NOT NULL CHECK(node_type IN ('root','directory_index_root','category_index_root','folder','category','rule_index_root','rule')),
  source_path TEXT,
  preview_json TEXT,
  relative_source_path TEXT,
  is_staging INTEGER NOT NULL DEFAULT 0 CHECK(is_staging IN (0,1)),
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_built_at_ms INTEGER, system_key TEXT, is_protected INTEGER NOT NULL DEFAULT 0 CHECK(is_protected IN (0,1)),
  FOREIGN KEY(parent_id) REFERENCES index_nodes(id) ON DELETE CASCADE
);

CREATE TABLE index_rules (
  node_id TEXT PRIMARY KEY,
  entity_types_json TEXT NOT NULL DEFAULT '[]',
  extensions_json TEXT NOT NULL DEFAULT '[]',
  scope_node_id TEXT,
  min_size INTEGER CHECK(min_size IS NULL OR min_size>=0),
  max_size INTEGER CHECK(max_size IS NULL OR (max_size>=0 AND (min_size IS NULL OR max_size>=min_size))),
  modified_within_days INTEGER CHECK(modified_within_days IS NULL OR modified_within_days>0),
  opened_within_days INTEGER CHECK(opened_within_days IS NULL OR opened_within_days>0),
  default_sort TEXT NOT NULL DEFAULT 'lastOpened' CHECK(default_sort IN ('lastOpened','openCount','modified','name','size')),
  max_results INTEGER NOT NULL DEFAULT 1000 CHECK(max_results BETWEEN 1 AND 100000),
  built_in_kind TEXT,
  updated_at INTEGER NOT NULL, scope_state TEXT NOT NULL DEFAULT 'all'
        CHECK(scope_state IN ('all', 'node', 'missing')),
  FOREIGN KEY(node_id) REFERENCES index_nodes(id) ON DELETE CASCADE,
  FOREIGN KEY(scope_node_id) REFERENCES index_nodes(id) ON DELETE SET NULL
);

CREATE TABLE index_stats_dirty (
      node_id TEXT PRIMARY KEY REFERENCES index_nodes(id) ON DELETE CASCADE,
      revision INTEGER NOT NULL DEFAULT 1 CHECK(revision > 0)
    );

CREATE TABLE library_build_jobs (
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
  updated_at INTEGER NOT NULL, kind TEXT NOT NULL DEFAULT 'scanScope', scope_node_id TEXT, manifest_complete INTEGER NOT NULL DEFAULT 0, index_cursor INTEGER NOT NULL DEFAULT -1, scan_generation INTEGER NOT NULL DEFAULT 1,
  FOREIGN KEY(index_root_id) REFERENCES index_nodes(id) ON DELETE SET NULL,
  FOREIGN KEY(target_node_id) REFERENCES index_nodes(id) ON DELETE SET NULL
);

CREATE TABLE library_build_manifest (
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
  source_modified_at_ms INTEGER NOT NULL, write_state TEXT NOT NULL DEFAULT 'pending', error TEXT, directory_locator TEXT,
  PRIMARY KEY(job_id, source_path),
  FOREIGN KEY(job_id) REFERENCES library_build_jobs(id) ON DELETE CASCADE
);

CREATE TABLE library_document_preview_work (
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

CREATE TABLE library_entity_preview_work (
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

CREATE TABLE library_node_preview_work (
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

CREATE TABLE node_preview_assets (
  node_id TEXT PRIMARY KEY,
  signature TEXT NOT NULL,
  asset_key TEXT NOT NULL,
  format TEXT NOT NULL,
  width INTEGER NOT NULL,
  height INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY(node_id) REFERENCES index_nodes(id) ON DELETE CASCADE
);

CREATE TABLE node_preview_dirty (
  node_id TEXT PRIMARY KEY REFERENCES index_nodes(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL DEFAULT 1, reason TEXT, updated_at INTEGER NOT NULL
);

CREATE TABLE node_preview_override_items (
    node_id TEXT NOT NULL REFERENCES index_nodes(id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL CHECK(ordinal>=0),
    entity_id TEXT REFERENCES entities(id) ON DELETE CASCADE,
    target_node_id TEXT REFERENCES index_nodes(id) ON DELETE CASCADE,
    descriptor_json TEXT NOT NULL CHECK(json_valid(descriptor_json)),
    PRIMARY KEY(node_id,ordinal),
    CHECK((entity_id IS NOT NULL)+(target_node_id IS NOT NULL)=1)
  );

CREATE TABLE node_preview_versions (
  node_id TEXT PRIMARY KEY REFERENCES index_nodes(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL DEFAULT 0,
  publication INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE preview_asset_files (
      asset_key TEXT NOT NULL REFERENCES preview_assets(asset_key) ON DELETE CASCADE,
      variant TEXT NOT NULL, path TEXT NOT NULL, format TEXT NOT NULL,
      width INTEGER, height INTEGER, byte_size INTEGER NOT NULL CHECK(byte_size>=0),
      PRIMARY KEY(asset_key,variant));

CREATE TABLE preview_assets (
    asset_key TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK(kind IN ('entity','node')),
    recipe TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('candidate','published','incomplete')),
    created_at INTEGER NOT NULL);

CREATE TABLE query_revision_dirty (
      domain TEXT NOT NULL, scope_id TEXT NOT NULL DEFAULT '',
      PRIMARY KEY(domain, scope_id)
    );

CREATE TABLE query_revisions (
      domain TEXT NOT NULL, scope_id TEXT NOT NULL DEFAULT '',
      revision INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0),
      PRIMARY KEY(domain, scope_id)
    );

CREATE TABLE retired_preview_assets (
  kind TEXT NOT NULL, asset_key TEXT NOT NULL, format TEXT NOT NULL,
  not_before INTEGER NOT NULL,
  PRIMARY KEY(kind, asset_key)
);

CREATE TABLE scan_directories (
  job_id TEXT NOT NULL REFERENCES library_build_jobs(id) ON DELETE CASCADE,
  locator TEXT NOT NULL, relative_path TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending', error TEXT,
  PRIMARY KEY(job_id, locator)
);

CREATE TABLE sources (
  id TEXT PRIMARY KEY, locator TEXT NOT NULL UNIQUE,
  availability TEXT NOT NULL DEFAULT 'unknown', revision INTEGER NOT NULL DEFAULT 1
, kind TEXT NOT NULL DEFAULT 'legacy', authority TEXT NOT NULL DEFAULT '', root_identity TEXT);

CREATE TABLE thumbnail_assets (
  asset_key TEXT PRIMARY KEY,
  format TEXT NOT NULL,
  byte_size INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE INDEX idx_audio_playback_session_entries_session
ON audio_playback_session_entries(session_id, sort_order);

CREATE INDEX idx_audio_playback_sessions_active
ON audio_playback_sessions(active, updated_at DESC);

CREATE INDEX idx_command_receipts_committed
ON database_command_receipts(committed_at);

CREATE INDEX idx_cover_entity ON node_preview_override_items(entity_id,node_id);

CREATE INDEX idx_cover_node ON node_preview_override_items(target_node_id,node_id);

CREATE INDEX idx_entities_directory_root_id ON entities(directory_root_id);

CREATE INDEX idx_entities_format ON entities(archived, lower(format), id);

CREATE INDEX idx_entities_media_type ON entities(media_type);

CREATE INDEX idx_entities_source_modified
ON entities(source_modified_at_ms DESC, id);

CREATE INDEX idx_entities_type_last_opened ON entities
        (archived, media_type, COALESCE(last_opened_at,0) DESC, id ASC);

CREATE INDEX idx_entities_visible_format_name
ON entities(archived, format COLLATE NOCASE, name COLLATE NOCASE);

CREATE INDEX idx_entities_visible_last_opened ON entities
        (archived, COALESCE(last_opened_at,0) DESC, id ASC);

CREATE INDEX idx_entities_visible_modified ON entities(archived, source_modified_at_ms DESC, id);

CREATE INDEX idx_entities_visible_name ON entities(archived, name COLLATE NOCASE, id);

CREATE INDEX idx_entities_visible_open_count ON entities
        (archived, open_count DESC, COALESCE(last_opened_at,0) DESC, id ASC);

CREATE INDEX idx_entities_visible_size ON entities(archived, size DESC, id);

CREATE INDEX idx_entity_preview_key ON entity_previews(thumbnail_key);

CREATE INDEX idx_index_node_entities_entity
ON index_node_entities(entity_id);

CREATE INDEX idx_index_node_entities_node
ON index_node_entities(index_node_id);

CREATE INDEX idx_index_node_entities_node_sort_name
ON index_node_entities(index_node_id, sort_name COLLATE NOCASE, entity_id);

CREATE INDEX idx_index_nodes_node_type ON index_nodes(node_type);

CREATE INDEX idx_index_nodes_parent_id ON index_nodes(parent_id);

CREATE INDEX idx_index_nodes_parent_name
ON index_nodes(parent_id, name COLLATE NOCASE, id);

CREATE INDEX idx_index_nodes_parent_sort_name
ON index_nodes(parent_id, sort_order, name COLLATE NOCASE);

CREATE INDEX idx_index_nodes_parent_updated
ON index_nodes(parent_id, updated_at DESC, name COLLATE NOCASE, id);

CREATE UNIQUE INDEX idx_index_nodes_root_source
ON index_nodes(source_path) WHERE source_path IS NOT NULL;

CREATE UNIQUE INDEX idx_index_nodes_sibling_name_type
ON index_nodes(parent_id, name, node_type) WHERE parent_id IS NOT NULL;

CREATE UNIQUE INDEX idx_index_nodes_single_root
ON index_nodes(node_type) WHERE node_type = 'root';

CREATE UNIQUE INDEX idx_index_nodes_system_key
ON index_nodes(system_key) WHERE system_key IS NOT NULL;

CREATE INDEX idx_library_build_jobs_recovery
ON library_build_jobs(status, updated_at DESC);

CREATE INDEX idx_library_build_manifest_sequence
ON library_build_manifest(job_id, sequence);

CREATE INDEX idx_library_build_manifest_source_path
ON library_build_manifest(job_id, source_path);

CREATE INDEX idx_library_document_preview_work_pending
ON library_document_preview_work(job_id, state, entity_id);

CREATE INDEX idx_library_entity_preview_work_pending
ON library_entity_preview_work(job_id, state, entity_id);

CREATE INDEX idx_library_node_preview_work_pending
ON library_node_preview_work(job_id, state, node_id);

CREATE UNIQUE INDEX idx_location_identity ON entity_locations(source_id,document_identity)
      WHERE document_identity IS NOT NULL;

CREATE INDEX idx_location_source ON entity_locations(source_id);

CREATE INDEX idx_manifest_work ON library_build_manifest(job_id, write_state, sequence);

CREATE UNIQUE INDEX idx_one_active_audio_session
      ON audio_playback_sessions(active) WHERE active = 1;

CREATE INDEX idx_retired_previews_due
ON retired_preview_assets(not_before);

CREATE INDEX idx_scan_directories_pending ON scan_directories(job_id, state);

CREATE UNIQUE INDEX idx_source_identity
    ON sources(kind,authority,root_identity) WHERE root_identity IS NOT NULL;

CREATE VIEW entity_details AS SELECT e.*,
      v.metadata_preview,v.thumbnail_status,v.thumbnail_key,v.thumbnail_format,v.thumbnail_width,v.thumbnail_height,v.thumbnail_error,v.preview_revision,
      p.last_position_ms,p.reader_scroll_offset,p.zoom_scale,
      CASE WHEN p.reading_kind IS NULL THEN p.settings_json ELSE
        json_patch(COALESCE(p.settings_json,'{}'),json_object('readingPosition',
          json_object('version',p.reading_version,'kind',p.reading_kind,
            'sourceRevision',p.document_revision,'chapter',p.chapter_index,
            'chapterTitle',p.chapter_title,'page',p.page_index,'block',p.block_index,
            'blockKey',p.block_key,'blockFraction',p.block_fraction,
            'mode',p.reading_mode,'scrollOffset',p.reading_offset))) END AS extra_state_json
    FROM entities e LEFT JOIN entity_previews v ON v.entity_id=e.id
    LEFT JOIN entity_progress p ON p.entity_id=e.id;

CREATE VIEW node_preview_overrides AS
    SELECT node_id, json_group_array(json(descriptor_json)) AS items_json
    FROM (SELECT * FROM node_preview_override_items ORDER BY node_id,ordinal) GROUP BY node_id;

CREATE UNIQUE INDEX idx_single_system_root ON index_nodes(node_type) WHERE node_type='root';
CREATE TRIGGER validate_node_parent_insert BEFORE INSERT ON index_nodes
WHEN NOT (
  (NEW.node_type='root' AND NEW.parent_id IS NULL) OR
  EXISTS(SELECT 1 FROM index_nodes p WHERE p.id=NEW.parent_id AND (
    (NEW.node_type IN ('directory_index_root','category_index_root','rule_index_root') AND p.node_type='root') OR
    (NEW.node_type='folder' AND p.node_type IN ('directory_index_root','folder')) OR
    (NEW.node_type='category' AND p.node_type IN ('category_index_root','category')) OR
    (NEW.node_type='rule' AND p.node_type='rule_index_root'))))
BEGIN SELECT RAISE(ABORT,'Invalid node parent type'); END;
CREATE TRIGGER validate_node_parent_update BEFORE UPDATE OF parent_id,node_type ON index_nodes
WHEN NOT (
  (NEW.node_type='root' AND NEW.parent_id IS NULL) OR
  EXISTS(SELECT 1 FROM index_nodes p WHERE p.id=NEW.parent_id AND (
    (NEW.node_type IN ('directory_index_root','category_index_root','rule_index_root') AND p.node_type='root') OR
    (NEW.node_type='folder' AND p.node_type IN ('directory_index_root','folder')) OR
    (NEW.node_type='category' AND p.node_type IN ('category_index_root','category')) OR
    (NEW.node_type='rule' AND p.node_type='rule_index_root'))))
BEGIN SELECT RAISE(ABORT,'Invalid node parent type'); END;

CREATE TRIGGER cover_target_removed AFTER DELETE ON node_preview_override_items
    WHEN EXISTS(SELECT 1 FROM index_nodes WHERE id=OLD.node_id)
    BEGIN
      INSERT INTO node_preview_versions(node_id,revision) VALUES(OLD.node_id,1)
        ON CONFLICT(node_id) DO UPDATE SET revision=revision+1;
      INSERT INTO node_preview_dirty(node_id,revision,reason,updated_at)
      SELECT node_id,revision,'cover_target_removed',CAST(strftime('%s','now') AS INTEGER)*1000
      FROM node_preview_versions WHERE node_id=OLD.node_id
      ON CONFLICT(node_id) DO UPDATE SET revision=excluded.revision,reason=excluded.reason;
    END;

CREATE TRIGGER create_entity_preview AFTER INSERT ON entities
    BEGIN INSERT INTO entity_previews(entity_id, updated_at) VALUES(NEW.id, NEW.updated_at); END;

CREATE TRIGGER index_node_search_delete AFTER DELETE ON index_nodes BEGIN
  INSERT INTO index_node_search(index_node_search, rowid, name)
  VALUES ('delete', old.rowid, old.name);
END;

CREATE TRIGGER index_node_search_insert AFTER INSERT ON index_nodes BEGIN
  INSERT INTO index_node_search(rowid, name) VALUES (new.rowid, new.name);
END;

CREATE TRIGGER index_node_search_update AFTER UPDATE OF name ON index_nodes BEGIN
  INSERT INTO index_node_search(index_node_search, rowid, name)
  VALUES ('delete', old.rowid, old.name);
  INSERT INTO index_node_search(rowid, name) VALUES (new.rowid, new.name);
END;

CREATE TRIGGER prevent_node_cycle BEFORE UPDATE OF parent_id ON index_nodes
    WHEN NEW.parent_id IS NOT OLD.parent_id AND NEW.parent_id IS NOT NULL
    BEGIN
      SELECT RAISE(ABORT, 'Node cycle') WHERE NEW.parent_id IN (
        WITH RECURSIVE descendants(id) AS (
          SELECT OLD.id UNION SELECT n.id FROM index_nodes n
          JOIN descendants d ON n.parent_id = d.id
        ) SELECT id FROM descendants
      );
    END;

CREATE TRIGGER protect_system_node_delete
    BEFORE DELETE ON index_nodes WHEN OLD.is_protected = 1
    BEGIN SELECT RAISE(ABORT, 'Protected node cannot be deleted'); END;

CREATE TRIGGER protect_system_node_update
    BEFORE UPDATE ON index_nodes WHEN OLD.is_protected = 1 AND (
      NEW.name IS NOT OLD.name OR NEW.parent_id IS NOT OLD.parent_id
      OR NEW.is_protected IS NOT OLD.is_protected
      OR NEW.system_key IS NOT OLD.system_key OR NEW.node_type IS NOT OLD.node_type)
    BEGIN SELECT RAISE(ABORT, 'Protected node cannot be changed'); END;

CREATE TRIGGER query_dirty_access
      AFTER UPDATE OF open_count, last_opened_at ON entities
      BEGIN INSERT INTO query_revision_dirty(domain) VALUES ('access') ON CONFLICT DO NOTHING; END;

CREATE TRIGGER query_dirty_entities_delete
        AFTER DELETE ON entities
        BEGIN INSERT INTO query_revision_dirty(domain) VALUES ('metadata') ON CONFLICT DO NOTHING; END;

CREATE TRIGGER query_dirty_entities_insert
        AFTER INSERT ON entities
        BEGIN INSERT INTO query_revision_dirty(domain) VALUES ('metadata') ON CONFLICT DO NOTHING; END;

CREATE TRIGGER query_dirty_entities_update
        AFTER UPDATE OF name, format, media_type, size, source_modified_at_ms, archived, source_revision ON entities
        BEGIN INSERT INTO query_revision_dirty(domain) VALUES ('metadata') ON CONFLICT DO NOTHING; END;

CREATE TRIGGER query_dirty_index_node_entities_delete
        AFTER DELETE ON index_node_entities
        BEGIN INSERT INTO query_revision_dirty(domain) VALUES ('structure') ON CONFLICT DO NOTHING; END;

CREATE TRIGGER query_dirty_index_node_entities_insert
        AFTER INSERT ON index_node_entities
        BEGIN INSERT INTO query_revision_dirty(domain) VALUES ('structure') ON CONFLICT DO NOTHING; END;

CREATE TRIGGER query_dirty_index_node_entities_update
        AFTER UPDATE ON index_node_entities
        BEGIN INSERT INTO query_revision_dirty(domain) VALUES ('structure') ON CONFLICT DO NOTHING; END;

CREATE TRIGGER query_dirty_index_nodes_delete
        AFTER DELETE ON index_nodes
        BEGIN INSERT INTO query_revision_dirty(domain) VALUES ('structure') ON CONFLICT DO NOTHING; END;

CREATE TRIGGER query_dirty_index_nodes_insert
        AFTER INSERT ON index_nodes
        BEGIN INSERT INTO query_revision_dirty(domain) VALUES ('structure') ON CONFLICT DO NOTHING; END;

CREATE TRIGGER query_dirty_index_nodes_update
        AFTER UPDATE ON index_nodes
        BEGIN INSERT INTO query_revision_dirty(domain) VALUES ('structure') ON CONFLICT DO NOTHING; END;

CREATE TRIGGER query_dirty_index_rules_delete
        AFTER DELETE ON index_rules
        BEGIN INSERT INTO query_revision_dirty(domain) VALUES ('rules') ON CONFLICT DO NOTHING; END;

CREATE TRIGGER query_dirty_index_rules_insert
        AFTER INSERT ON index_rules
        BEGIN INSERT INTO query_revision_dirty(domain) VALUES ('rules') ON CONFLICT DO NOTHING; END;

CREATE TRIGGER query_dirty_index_rules_update
        AFTER UPDATE ON index_rules
        BEGIN INSERT INTO query_revision_dirty(domain) VALUES ('rules') ON CONFLICT DO NOTHING; END;

CREATE TRIGGER query_dirty_preview AFTER UPDATE ON entity_previews
    BEGIN INSERT INTO query_revision_dirty(domain) VALUES('preview') ON CONFLICT DO NOTHING; END;

CREATE TRIGGER retire_deleted_entity_preview
    AFTER DELETE ON entity_previews WHEN OLD.thumbnail_key IS NOT NULL
    BEGIN
      INSERT INTO retired_preview_assets(kind, asset_key, format, not_before)
      VALUES('entity', OLD.thumbnail_key, COALESCE(OLD.thumbnail_format,'webp'),
        (CAST(strftime('%s','now') AS INTEGER)+86400)*1000)
      ON CONFLICT(kind, asset_key) DO UPDATE SET not_before=excluded.not_before;
    END;

CREATE TRIGGER retire_deleted_node_preview
AFTER DELETE ON node_preview_assets
BEGIN
  INSERT INTO retired_preview_assets(kind, asset_key, format, not_before)
  VALUES ('node', OLD.asset_key, OLD.format,
          (CAST(strftime('%s', 'now') AS INTEGER) + 86400) * 1000)
  ON CONFLICT(kind, asset_key) DO UPDATE SET not_before = excluded.not_before;
END;

CREATE TRIGGER rule_scope_deleted BEFORE DELETE ON index_nodes
    BEGIN
      UPDATE index_rules SET scope_state = 'missing', scope_node_id = NULL,
        updated_at = MAX(updated_at + 1, CAST(strftime('%s','now') AS INTEGER) * 1000)
      WHERE scope_node_id = OLD.id;
    END;

CREATE TRIGGER statistics_dirty_generation
    AFTER INSERT ON index_stats_dirty BEGIN
      UPDATE index_stats_dirty SET revision=MAX(revision,
        COALESCE((SELECT revision FROM index_node_stats WHERE node_id=NEW.node_id),0)+1)
      WHERE node_id=NEW.node_id;
    END;

CREATE TRIGGER statistics_entity_archive
    AFTER UPDATE OF archived ON entities WHEN NEW.archived IS NOT OLD.archived BEGIN
      INSERT INTO index_stats_dirty(node_id)
      WITH RECURSIVE ancestors(id,parent_id) AS (
        SELECT n.id,n.parent_id FROM index_nodes n JOIN index_node_entities l ON l.index_node_id=n.id WHERE l.entity_id=NEW.id
        UNION SELECT n.id,n.parent_id FROM index_nodes n JOIN ancestors a ON a.parent_id=n.id
      ) SELECT id FROM ancestors WHERE true
      ON CONFLICT(node_id) DO UPDATE SET revision=revision+1;
    END;

CREATE TRIGGER statistics_node_delete
      AFTER DELETE ON index_nodes BEGIN
      INSERT INTO index_stats_dirty(node_id)
      WITH RECURSIVE ancestors(id,parent_id) AS (
        SELECT id,parent_id FROM index_nodes WHERE id IN (OLD.parent_id,NULL)
        UNION SELECT n.id,n.parent_id FROM index_nodes n JOIN ancestors a ON a.parent_id=n.id
      ) SELECT id FROM ancestors WHERE true
      ON CONFLICT(node_id) DO UPDATE SET revision=revision+1;
      END;

CREATE TRIGGER statistics_node_insert
      AFTER INSERT ON index_nodes BEGIN
      INSERT INTO index_stats_dirty(node_id)
      WITH RECURSIVE ancestors(id,parent_id) AS (
        SELECT id,parent_id FROM index_nodes WHERE id IN (NULL,NEW.id)
        UNION SELECT n.id,n.parent_id FROM index_nodes n JOIN ancestors a ON a.parent_id=n.id
      ) SELECT id FROM ancestors WHERE true
      ON CONFLICT(node_id) DO UPDATE SET revision=revision+1;
      END;

CREATE TRIGGER statistics_node_update
      AFTER UPDATE OF parent_id ON index_nodes BEGIN
      INSERT INTO index_stats_dirty(node_id)
      WITH RECURSIVE ancestors(id,parent_id) AS (
        SELECT id,parent_id FROM index_nodes WHERE id IN (OLD.parent_id,NEW.id)
        UNION SELECT n.id,n.parent_id FROM index_nodes n JOIN ancestors a ON a.parent_id=n.id
      ) SELECT id FROM ancestors WHERE true
      ON CONFLICT(node_id) DO UPDATE SET revision=revision+1;
      END;

CREATE TRIGGER stats_dirty_link_delete
        AFTER DELETE ON index_node_entities BEGIN
          INSERT INTO index_stats_dirty(node_id)
          WITH RECURSIVE ancestors(id, parent_id) AS (
            SELECT id, parent_id FROM index_nodes WHERE id = OLD.index_node_id
            UNION SELECT n.id, n.parent_id FROM index_nodes n
            JOIN ancestors a ON n.id = a.parent_id
          ) SELECT id FROM ancestors WHERE true
          ON CONFLICT(node_id) DO UPDATE SET revision = revision + 1;
          INSERT INTO query_revision_dirty(domain, scope_id)
          WITH RECURSIVE ancestors(id, parent_id, node_type) AS (
            SELECT id, parent_id, node_type FROM index_nodes WHERE id = OLD.index_node_id
            UNION SELECT n.id, n.parent_id, n.node_type FROM index_nodes n
            JOIN ancestors a ON n.id = a.parent_id
          ) SELECT 'structure', id FROM ancestors
          WHERE node_type IN ('directory_index_root', 'category_index_root')
          ON CONFLICT DO NOTHING;
        END;

CREATE TRIGGER stats_dirty_link_insert
        AFTER INSERT ON index_node_entities BEGIN
          INSERT INTO index_stats_dirty(node_id)
          WITH RECURSIVE ancestors(id, parent_id) AS (
            SELECT id, parent_id FROM index_nodes WHERE id = NEW.index_node_id
            UNION SELECT n.id, n.parent_id FROM index_nodes n
            JOIN ancestors a ON n.id = a.parent_id
          ) SELECT id FROM ancestors WHERE true
          ON CONFLICT(node_id) DO UPDATE SET revision = revision + 1;
          INSERT INTO query_revision_dirty(domain, scope_id)
          WITH RECURSIVE ancestors(id, parent_id, node_type) AS (
            SELECT id, parent_id, node_type FROM index_nodes WHERE id = NEW.index_node_id
            UNION SELECT n.id, n.parent_id, n.node_type FROM index_nodes n
            JOIN ancestors a ON n.id = a.parent_id
          ) SELECT 'structure', id FROM ancestors
          WHERE node_type IN ('directory_index_root', 'category_index_root')
          ON CONFLICT DO NOTHING;
        END;

CREATE TRIGGER validate_entity_insert
        BEFORE INSERT ON entities WHEN NEW.size < 0 OR NEW.open_count < 0
        OR NEW.archived NOT IN (0,1) OR NEW.source_revision < 1
        OR NEW.source_created_at_ms < 0 OR NEW.source_modified_at_ms < 0
        BEGIN SELECT RAISE(ABORT, 'Invalid entity metadata'); END;

CREATE TRIGGER validate_entity_update
        BEFORE UPDATE ON entities WHEN NEW.size < 0 OR NEW.open_count < 0
        OR NEW.archived NOT IN (0,1) OR NEW.source_revision < 1
        OR NEW.source_created_at_ms < 0 OR NEW.source_modified_at_ms < 0
        BEGIN SELECT RAISE(ABORT, 'Invalid entity metadata'); END;

CREATE TRIGGER validate_rule_insert
      BEFORE INSERT ON index_rules WHEN
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
      BEGIN SELECT RAISE(ABORT, 'Invalid rule definition'); END;

CREATE TRIGGER validate_rule_update
      BEFORE UPDATE ON index_rules WHEN
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
      BEGIN SELECT RAISE(ABORT, 'Invalid rule definition'); END;
''';
