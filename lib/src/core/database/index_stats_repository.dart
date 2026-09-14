part of 'library_repository.dart';

/// Aggregated entity counts per index node. The stats table is a derived
/// cache rebuilt after mutations; reads always go through the cache.
///
/// Rebuild logic ([rebuildIndexNodeStats], [rebuildIndexNodeStatsForNode],
/// [_rebuildIndexNodeStatsNow], [_rebuildIndexNodeStatsForRootNow]) lives on
/// [LibraryRepositoryBase] because it is called from multiple mixins.
mixin IndexStatsRepositoryMixin on LibraryRepositoryBase {
  int countEntitiesUnderIndexNode(String indexNodeId) {
    final result = database.db.select(
      '''
      SELECT COALESCE(descendant_entity_count, 0) AS count
      FROM index_node_stats
      WHERE node_id = ?
      ''',
      [indexNodeId],
    );
    return result.isEmpty ? 0 : result.first['count'] as int;
  }

  Map<String, int> countEntitiesUnderIndexNodes(Iterable<String> nodeIds) {
    final ids = nodeIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const <String, int>{};
    final placeholders = List<String>.filled(ids.length, '?').join(', ');
    final rows = database.db.select(
      '''
      SELECT node.id,
             COALESCE(stats.descendant_entity_count, 0) AS entity_count
      FROM index_nodes node
      LEFT JOIN index_node_stats stats ON stats.node_id = node.id
      WHERE node.id IN ($placeholders)
      ''',
      ids,
    );
    return <String, int>{
      for (final row in rows) row['id'] as String: row['entity_count'] as int,
    };
  }
}
