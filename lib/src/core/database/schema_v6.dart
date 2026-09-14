const schemaV6Upgrade = '''
ALTER TABLE entities ADD COLUMN source_revision INTEGER NOT NULL DEFAULT 1;
ALTER TABLE entities ADD COLUMN preview_revision INTEGER NOT NULL DEFAULT 1;
ALTER TABLE library_build_jobs ADD COLUMN kind TEXT NOT NULL DEFAULT 'scanScope';
ALTER TABLE library_build_jobs ADD COLUMN scope_node_id TEXT;
ALTER TABLE library_build_jobs ADD COLUMN manifest_complete INTEGER NOT NULL DEFAULT 0;
ALTER TABLE library_build_jobs ADD COLUMN index_cursor INTEGER NOT NULL DEFAULT -1;
ALTER TABLE library_build_jobs ADD COLUMN scan_generation INTEGER NOT NULL DEFAULT 1;
ALTER TABLE library_build_manifest ADD COLUMN write_state TEXT NOT NULL DEFAULT 'pending';
ALTER TABLE library_build_manifest ADD COLUMN error TEXT;
ALTER TABLE library_build_manifest ADD COLUMN directory_locator TEXT;
UPDATE library_build_jobs SET scope_node_id = target_node_id,
  manifest_complete = CASE WHEN stage = 'manifest' THEN 0 ELSE 1 END,
  index_cursor = indexed_total - 1,
  kind = CASE WHEN source_path LIKE 'index://%' THEN 'rebuildPreviews' ELSE 'scanScope' END;
UPDATE library_build_jobs SET status = 'blocked', error = '旧清单需要重新枚举；已提交资料保持不变'
  WHERE stage = 'manifest' AND status NOT IN ('completed', 'abandoned');
UPDATE library_build_manifest SET write_state = 'completed'
  WHERE sequence <= (SELECT index_cursor FROM library_build_jobs WHERE id = job_id);
CREATE TABLE sources (
  id TEXT PRIMARY KEY, locator TEXT NOT NULL UNIQUE,
  availability TEXT NOT NULL DEFAULT 'unknown', revision INTEGER NOT NULL DEFAULT 1
);
INSERT OR IGNORE INTO sources(id, locator)
  SELECT 'source:' || id, source_path FROM index_nodes WHERE source_path IS NOT NULL;
CREATE TABLE scan_directories (
  job_id TEXT NOT NULL REFERENCES library_build_jobs(id) ON DELETE CASCADE,
  locator TEXT NOT NULL, relative_path TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending', error TEXT,
  PRIMARY KEY(job_id, locator)
);
CREATE TABLE node_preview_dirty (
  node_id TEXT PRIMARY KEY REFERENCES index_nodes(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL DEFAULT 1, reason TEXT, updated_at INTEGER NOT NULL
);
CREATE TABLE database_command_receipts (
  request_id TEXT PRIMARY KEY, changes INTEGER NOT NULL, committed_at INTEGER NOT NULL
);
CREATE INDEX idx_scan_directories_pending ON scan_directories(job_id, state);
CREATE INDEX idx_manifest_work ON library_build_manifest(job_id, write_state, sequence);
''';
