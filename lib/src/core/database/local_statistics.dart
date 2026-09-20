import 'package:sqlite3/sqlite3.dart';

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
