import 'package:sqlite3/sqlite3.dart';
import '../domain/models.dart';

NodeSearchPage queryNodes(Database database, NodeSearchQuery query) {
  final text = query.text.trim();
  if (text.isEmpty) return NodeSearchPage(items: [], hasMore: false);
  final limit = query.limit.clamp(1, 60);
  final offset = query.offset.clamp(0, 1000000000);
  final pattern = text
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');
  final types = switch (query.scope) {
    NodeSearchScope.all => const [
        'directory_index_root',
        'folder',
        'category_index_root',
        'category',
        'rule'
      ],
    NodeSearchScope.directory => const ['directory_index_root', 'folder'],
    NodeSearchScope.collection => const ['category_index_root', 'category'],
    NodeSearchScope.rule => const ['rule'],
  };
  final fts = text.runes.length >= 3;
  final after = query.after;
  // Rank and page before loading breadcrumbs; only one page crosses the isolate.
  final rows = database.select('''
    WITH RECURSIVE hidden(id) AS (
      SELECT id FROM index_nodes WHERE is_staging = 1
      UNION SELECT n.id FROM index_nodes n JOIN hidden h ON n.parent_id = h.id
    ), ranked AS (
    SELECT n.*, CASE WHEN n.name = ? COLLATE NOCASE THEN 0
      WHEN n.name LIKE ? ESCAPE '\\' THEN 1 ELSE 2 END AS match_rank
    FROM index_nodes n
    ${fts ? 'JOIN index_node_search s ON s.rowid = n.rowid' : ''}
    WHERE ${fts ? 'index_node_search MATCH ?' : "n.name LIKE ? ESCAPE '\\'"}
      AND n.node_type IN (${List.filled(types.length, '?').join(',')})
      AND n.id NOT IN (SELECT id FROM hidden)
    ) SELECT * FROM ranked
    ${after == null ? '' : 'WHERE match_rank > ? OR (match_rank = ? AND (name COLLATE NOCASE > ? OR (name = ? COLLATE NOCASE AND id > ?)))'}
    ORDER BY match_rank, name COLLATE NOCASE, id
    LIMIT ? OFFSET ?
  ''', [
    text,
    '$pattern%',
    fts ? '"${text.replaceAll('"', '""')}"' : '%$pattern%',
    ...types,
    if (after != null) ...[
      after.rank,
      after.rank,
      after.name,
      after.name,
      after.id
    ],
    limit + 1,
    after == null ? offset : 0
  ]);
  final items = <NodeSearchResult>[];
  final pageRows = rows.take(limit).toList();
  final paths = <String, List<IndexNode>>{};
  if (pageRows.isNotEmpty) {
    final ancestors = database.select('''
      WITH RECURSIVE chain(result_id, id, parent_id, depth) AS (
        SELECT id, id, parent_id, 0 FROM index_nodes
        WHERE id IN (${List.filled(pageRows.length, '?').join(',')})
        UNION ALL SELECT c.result_id, n.id, n.parent_id, c.depth + 1
        FROM index_nodes n JOIN chain c ON c.parent_id = n.id WHERE c.depth < 1024
      ) SELECT n.*, c.result_id FROM chain c JOIN index_nodes n ON n.id = c.id
      WHERE n.node_type <> 'root' ORDER BY c.result_id, c.depth DESC
    ''', pageRows.map((row) => row['id']).toList());
    for (final ancestor in ancestors) {
      paths
          .putIfAbsent(ancestor['result_id'] as String, () => [])
          .add(_node(ancestor));
    }
  }
  for (final row in pageRows) {
    final path = paths[row['id']] ?? [];
    if (path.isEmpty) continue;
    items.add(NodeSearchResult(
        node: _node(row),
        root: path.first,
        breadcrumb: path,
        matchRank: row['match_rank'] as int));
  }
  return NodeSearchPage(items: items, hasMore: rows.length > limit);
}

IndexNode _node(Row row) => IndexNode(
      id: row['id'] as String,
      parentId: row['parent_id'] as String?,
      name: row['name'] as String,
      nodeType: NodeType.fromValue(row['node_type'] as String),
      viewType: ViewType.fromValue(row['view_type'] as String),
      sortOrder: row['sort_order'] as int,
      createdAtMs: row['created_at'] as int,
      updatedAtMs: row['updated_at'] as int,
      sourcePath: row['source_path'] as String?,
      isStaging: row['is_staging'] == 1,
      systemKey: row['system_key'] as String?,
      isProtected: (row['is_protected'] as int? ?? 0) != 0,
    );
