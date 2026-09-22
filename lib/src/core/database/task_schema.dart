/// Additive, idempotent extension of the current library schema.
const taskSchemaSql = '''
CREATE TABLE IF NOT EXISTS library_task_details (
  job_id TEXT PRIMARY KEY REFERENCES library_build_jobs(id),
  task_kind TEXT NOT NULL, priority INTEGER NOT NULL DEFAULT 70,
  source_id TEXT NOT NULL, scope_descriptor TEXT NOT NULL,
  display_name TEXT, started_at INTEGER, finished_at INTEGER,
  current_item TEXT, retry_of_task_id TEXT, change_set_revision INTEGER,
  user_action_required INTEGER NOT NULL DEFAULT 0,
  added_count INTEGER NOT NULL DEFAULT 0, changed_count INTEGER NOT NULL DEFAULT 0,
  removed_count INTEGER NOT NULL DEFAULT 0, skipped_count INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS library_task_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id TEXT NOT NULL REFERENCES library_build_jobs(id),
  event TEXT NOT NULL, phase TEXT, message TEXT, created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_task_events ON library_task_events(job_id,id);
CREATE TABLE IF NOT EXISTS library_task_failures (
  job_id TEXT NOT NULL REFERENCES library_build_jobs(id),
  phase TEXT NOT NULL, item_id TEXT NOT NULL, source_path TEXT,
  error TEXT NOT NULL, source_revision INTEGER,
  PRIMARY KEY(job_id,phase,item_id)
);
CREATE TABLE IF NOT EXISTS library_task_changes (
  job_id TEXT NOT NULL REFERENCES library_build_jobs(id),
  source_path TEXT NOT NULL, entity_id TEXT, source_revision INTEGER,
  change_kind TEXT NOT NULL,
  PRIMARY KEY(job_id,source_path)
);
CREATE INDEX IF NOT EXISTS idx_task_changes_job_kind_entity
  ON library_task_changes(job_id,change_kind,entity_id);
CREATE INDEX IF NOT EXISTS idx_task_changes_job_kind_path
  ON library_task_changes(job_id,change_kind,source_path);
CREATE TABLE IF NOT EXISTS library_task_dirty (
  job_id TEXT NOT NULL REFERENCES library_build_jobs(id),
  node_id TEXT NOT NULL, revision INTEGER NOT NULL,
  PRIMARY KEY(job_id,node_id)
);
CREATE TABLE IF NOT EXISTS library_task_directory_changes (
  job_id TEXT NOT NULL REFERENCES library_build_jobs(id),
  relative_path TEXT NOT NULL, node_id TEXT, change_kind TEXT NOT NULL,
  PRIMARY KEY(job_id,relative_path)
);
CREATE TABLE IF NOT EXISTS library_task_source_versions (
  root_id TEXT PRIMARY KEY, revision INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS library_task_source_snapshot (
  job_id TEXT PRIMARY KEY REFERENCES library_build_jobs(id),
  root_id TEXT NOT NULL, revision INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS library_preview_queue_preparation (
  job_id TEXT PRIMARY KEY REFERENCES library_build_jobs(id) ON DELETE CASCADE,
  entity_cursor TEXT,
  complete INTEGER NOT NULL DEFAULT 0 CHECK(complete IN (0,1)),
  updated_at INTEGER NOT NULL
);
CREATE TRIGGER IF NOT EXISTS task_created AFTER INSERT ON library_build_jobs BEGIN
  INSERT INTO library_task_events(job_id,event,phase,message,created_at)
  VALUES(NEW.id,'created',NEW.stage,NEW.status,NEW.created_at);
END;
CREATE TRIGGER IF NOT EXISTS task_transition AFTER UPDATE OF status,stage ON library_build_jobs
WHEN OLD.status != NEW.status OR OLD.stage != NEW.stage BEGIN
  INSERT INTO library_task_events(job_id,event,phase,message,created_at)
  VALUES(NEW.id,'transition',NEW.stage,NEW.status,NEW.updated_at);
  UPDATE library_task_details SET
    started_at=CASE WHEN NEW.status='running' THEN COALESCE(started_at,NEW.updated_at) ELSE started_at END,
    finished_at=CASE WHEN NEW.status IN ('completed','completedWithErrors','abandoned','failed') THEN NEW.updated_at ELSE finished_at END,
    user_action_required=CASE WHEN NEW.status IN ('paused','interrupted','failed','blocked','completedWithErrors') THEN 1 ELSE user_action_required END
  WHERE job_id=NEW.id;
END;
''';
