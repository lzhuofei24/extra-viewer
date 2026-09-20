import 'package:sqlite3/sqlite3.dart';

void installStatisticsTracking(Database db) {
  if (!db
      .select('PRAGMA table_info(index_node_stats)')
      .any((r) => r['name'] == 'node_id')) {
    return;
  }
  if (!db
      .select('PRAGMA table_info(index_node_stats)')
      .any((r) => r['name'] == 'revision')) {
    db.execute(
        'ALTER TABLE index_node_stats ADD COLUMN revision INTEGER NOT NULL DEFAULT 0');
  }
  for (final event in ['INSERT', 'DELETE', 'UPDATE OF parent_id']) {
    final old = event.startsWith('INSERT') ? 'NULL' : 'OLD.parent_id';
    final next = event.startsWith('DELETE') ? 'NULL' : 'NEW.id';
    final suffix = event.split(' ').first.toLowerCase();
    db.execute('''CREATE TRIGGER IF NOT EXISTS statistics_node_$suffix
      AFTER $event ON index_nodes BEGIN
      INSERT INTO index_stats_dirty(node_id)
      WITH RECURSIVE ancestors(id,parent_id) AS (
        SELECT id,parent_id FROM index_nodes WHERE id IN ($old,$next)
        UNION SELECT n.id,n.parent_id FROM index_nodes n JOIN ancestors a ON a.parent_id=n.id
      ) SELECT id FROM ancestors WHERE true
      ON CONFLICT(node_id) DO UPDATE SET revision=revision+1;
      END;''');
  }
  installStatisticsGeneration(db);
  db.execute('''CREATE TRIGGER IF NOT EXISTS statistics_entity_archive
    AFTER UPDATE OF archived ON entities WHEN NEW.archived IS NOT OLD.archived BEGIN
      INSERT INTO index_stats_dirty(node_id)
      WITH RECURSIVE ancestors(id,parent_id) AS (
        SELECT n.id,n.parent_id FROM index_nodes n JOIN index_node_entities l ON l.index_node_id=n.id WHERE l.entity_id=NEW.id
        UNION SELECT n.id,n.parent_id FROM index_nodes n JOIN ancestors a ON a.parent_id=n.id
      ) SELECT id FROM ancestors WHERE true
      ON CONFLICT(node_id) DO UPDATE SET revision=revision+1;
    END;''');
  db.execute('''INSERT INTO index_stats_dirty(node_id)
    SELECT id FROM index_nodes WHERE id NOT IN(SELECT node_id FROM index_node_stats)
    ON CONFLICT(node_id) DO NOTHING''');
}

void installStatisticsGeneration(Database db) {
  db.execute('''CREATE TRIGGER IF NOT EXISTS statistics_dirty_generation
    AFTER INSERT ON index_stats_dirty BEGIN
      UPDATE index_stats_dirty SET revision=MAX(revision,
        COALESCE((SELECT revision FROM index_node_stats WHERE node_id=NEW.node_id),0)+1)
      WHERE node_id=NEW.node_id;
    END;''');
}

/// Recompute only affected ancestors; shared category references stay distinct.
void refreshDirtyStatistics(Database db) {
  publishStatistics(db, computeDirtyStatistics(db, limit: 1000000000));
}

/// Read all values under one snapshot, then release the read transaction.
List<Map<String, Object?>> computeDirtyStatistics(Database db,
    {int limit = 32}) {
  final pending = db.select(
      'SELECT node_id,revision FROM index_stats_dirty LIMIT ?', [limit]);
  final result = <Map<String, Object?>>[];
  for (final row in pending) {
    final id = row['node_id'];
    final counts = db.select('''WITH RECURSIVE subtree(id) AS (
        SELECT id FROM index_nodes WHERE id=?
        UNION SELECT n.id FROM index_nodes n JOIN subtree p ON n.parent_id=p.id
      ) SELECT
        (SELECT COUNT(*) FROM index_node_entities l JOIN entities e ON e.id=l.entity_id WHERE l.index_node_id=? AND e.archived=0) AS direct_count,
        (SELECT COUNT(DISTINCT e.id) FROM index_node_entities l JOIN entities e ON e.id=l.entity_id
          WHERE l.index_node_id IN(SELECT id FROM subtree) AND e.archived=0) AS descendant_count,
        (SELECT COUNT(*) FROM index_nodes WHERE parent_id=?) AS child_count
      WHERE EXISTS(SELECT 1 FROM index_nodes WHERE id=?)''', [id, id, id, id]);
    if (counts.isEmpty) continue;
    result.add({'nodeId': id, 'revision': row['revision'], ...counts.single});
  }
  return result;
}

/// Called only by the single writer, in a transaction. A stale result is ignored.
void publishStatistics(Database db, List<Map<String, Object?>> rows) {
  final now = DateTime.now().millisecondsSinceEpoch;
  for (final row in rows) {
    final id = row['nodeId'];
    db.execute('''INSERT INTO index_node_stats(node_id,direct_entity_count,
        descendant_entity_count,child_node_count,updated_at,revision)
      SELECT ?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM index_stats_dirty
        WHERE node_id=? AND revision=?)
      ON CONFLICT(node_id) DO UPDATE SET direct_entity_count=excluded.direct_entity_count,
        descendant_entity_count=excluded.descendant_entity_count,child_node_count=excluded.child_node_count,
        updated_at=excluded.updated_at,revision=excluded.revision''', [
      id,
      row['direct_count'],
      row['descendant_count'],
      row['child_count'],
      now,
      row['revision'],
      id,
      row['revision']
    ]);
    db.execute('DELETE FROM index_stats_dirty WHERE node_id=? AND revision=?',
        [id, row['revision']]);
  }
}
