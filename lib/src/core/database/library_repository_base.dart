part of 'library_repository.dart';

/// Shared infrastructure for all repository mixins. Holds the database
/// connection, write worker, thumbnail store, transaction machinery, and
/// cross-cutting helpers used by every domain mixin.
class LibraryRepositoryBase {
  LibraryRepositoryBase(this.database, {this.writeWorker})
      : thumbnailStore = ThumbnailStore(database.storageDirectoryPath);

  final AppDatabase database;
  final LibraryWriteWorker? writeWorker;
  final ThumbnailStore thumbnailStore;
  String get storageDirectoryPath => database.storageDirectoryPath;

  int _transactionSequence = 0;
  var _indexStatsBatchDepth = 0;
  var _indexStatsDirty = false;

  /// Sends non-read-after-write bookkeeping to the dedicated writer. The
  /// synchronous fallback keeps in-memory tests and recovery mode functional.
  void _enqueueBackgroundWrite(
    String operation,
    String sql, [
    List<Object?> parameters = const <Object?>[],
  ]) {
    final worker = writeWorker;
    if (worker == null) {
      database.db.execute(sql, parameters);
      return;
    }
    unawaited(
      worker.execute(sql, parameters).then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          AppDiagnosticLog.instance.error(
            'database_background_write_failed',
            error,
            stackTrace,
            fields: {'operation': operation},
          );
        },
      ),
    );
  }

  Future<void> flushQueuedWrites() async {
    await writeWorker?.flush();
  }

  T batchIndexMutations<T>(T Function() action) {
    _indexStatsBatchDepth++;
    try {
      return action();
    } finally {
      _indexStatsBatchDepth--;
      if (_indexStatsBatchDepth == 0 && _indexStatsDirty) {
        _indexStatsDirty = false;
        _rebuildIndexNodeStatsNow();
      }
    }
  }

  T writeTransaction<T>(T Function() action) {
    final name = 'best_viewer_tx_${_transactionSequence++}';
    database.db.execute('SAVEPOINT $name');
    try {
      final result = action();
      database.db.execute('RELEASE SAVEPOINT $name');
      return result;
    } catch (_) {
      database.db.execute('ROLLBACK TO SAVEPOINT $name');
      database.db.execute('RELEASE SAVEPOINT $name');
      rethrow;
    }
  }

  Future<T> writeAsyncTransaction<T>(Future<T> Function() action) async {
    final name = 'best_viewer_async_tx_${_transactionSequence++}';
    database.db.execute('SAVEPOINT $name');
    try {
      final result = await action();
      database.db.execute('RELEASE SAVEPOINT $name');
      return result;
    } catch (_) {
      database.db.execute('ROLLBACK TO SAVEPOINT $name');
      database.db.execute('RELEASE SAVEPOINT $name');
      rethrow;
    }
  }

  IndexNode _ensureGlobalRoot() {
    final rows = database.db.select(
      'SELECT * FROM index_nodes WHERE node_type = ? LIMIT 1',
      [NodeType.root.value],
    );
    if (rows.isNotEmpty) return _nodeFromRow(rows.first);
    final now = nowMillis();
    final node = IndexNode(
      id: newId(),
      name: 'Root',
      nodeType: NodeType.root,
      viewType: ViewType.tree,
      sortOrder: 0,
      createdAtMs: now,
      updatedAtMs: now,
    );
    database.db.execute(
      '''
      INSERT INTO index_nodes
      (id, name, node_type, view_type, sort_order, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        node.id,
        node.name,
        node.nodeType.value,
        node.viewType.value,
        node.sortOrder,
        now,
        now,
      ],
    );
    return node;
  }

  IndexNode? _nodeById(String id) {
    final rows = database.db.select(
      'SELECT * FROM index_nodes WHERE id = ? LIMIT 1',
      [id],
    );
    if (rows.isEmpty) return null;
    return _nodeFromRow(rows.first);
  }

  void _touchIndexNode(String nodeId) {
    database.db.execute(
      'UPDATE index_nodes SET updated_at = ? WHERE id = ?',
      [nowMillis(), nodeId],
    );
  }

  void _requireEntityExists(String entityId) {
    if (getEntity(entityId) == null) {
      throw ArgumentError.value(
        entityId,
        'entityId',
        'Entity does not exist',
      );
    }
  }

  Set<String> _existingEntityIds(List<String> ids) {
    final result = <String>{};
    const batchSize = 400;
    for (var offset = 0; offset < ids.length; offset += batchSize) {
      final end = (offset + batchSize).clamp(0, ids.length).toInt();
      final batch = ids.sublist(offset, end);
      final placeholders = List<String>.filled(batch.length, '?').join(',');
      final rows = database.db.select(
        'SELECT id FROM entities WHERE id IN ($placeholders)',
        batch,
      );
      result.addAll(rows.map((row) => row['id'] as String));
    }
    return result;
  }

  IndexNode _requireLinkableIndexNode(String nodeId, String argumentName) {
    final node = _nodeById(nodeId);
    if (node == null) {
      throw ArgumentError.value(
        nodeId,
        argumentName,
        'Index node does not exist',
      );
    }
    if (node.nodeType == NodeType.root) {
      throw ArgumentError.value(
        nodeId,
        argumentName,
        'System root node cannot be used in relationships',
      );
    }
    return node;
  }

  IndexNode? _owningIndexRoot(IndexNode node) {
    var current = node;
    while (current.parentId != null) {
      final parent = _nodeById(current.parentId!);
      if (parent == null || parent.nodeType == NodeType.root) return current;
      current = parent;
    }
    return current.nodeType == NodeType.root ? null : current;
  }

  void _requireGraphEdgeNodes({
    required IndexNode fromNode,
    required IndexNode toNode,
  }) {
    if (fromNode.nodeType != NodeType.graphNode) {
      throw ArgumentError.value(
        fromNode.id,
        'fromNodeId',
        'Graph edges must start from graph_node nodes',
      );
    }
    if (toNode.nodeType != NodeType.graphNode) {
      throw ArgumentError.value(
        toNode.id,
        'toNodeId',
        'Graph edges must target graph_node nodes',
      );
    }
    final fromRoot = _owningIndexRoot(fromNode);
    final toRoot = _owningIndexRoot(toNode);
    if (fromRoot?.nodeType != NodeType.graphIndexRoot ||
        toRoot?.nodeType != NodeType.graphIndexRoot ||
        fromRoot?.id != toRoot?.id) {
      throw ArgumentError.value(
        toNode.id,
        'toNodeId',
        'Graph edges must stay inside the same graph index',
      );
    }
  }

  void _requireValidParentForNodeType({
    required NodeType nodeType,
    required String? parentId,
  }) {
    final requiredRootType = switch (nodeType) {
      NodeType.folder => NodeType.directoryIndexRoot,
      NodeType.customNode => NodeType.customIndexRoot,
      NodeType.graphNode => NodeType.graphIndexRoot,
      _ => null,
    };
    if (requiredRootType == null) return;
    if (parentId == null) {
      throw ArgumentError.value(
        parentId,
        'parentId',
        '${nodeType.value} nodes must be created inside a ${requiredRootType.value} index',
      );
    }
    final parent = _nodeById(parentId);
    if (parent == null) {
      throw ArgumentError.value(
        parentId,
        'parentId',
        'Parent index node does not exist',
      );
    }
    final owner = _owningIndexRoot(parent);
    if (owner?.nodeType != requiredRootType) {
      throw ArgumentError.value(
        parentId,
        'parentId',
        '${nodeType.value} nodes must be created inside a ${requiredRootType.value} index',
      );
    }
  }

  void _requireValidViewTypeForNodeType({
    required NodeType nodeType,
    required ViewType viewType,
  }) {
    final requiredViewType = switch (nodeType) {
      NodeType.customIndexRoot ||
      NodeType.folder ||
      NodeType.customNode =>
        ViewType.tree,
      NodeType.graphIndexRoot || NodeType.graphNode => ViewType.graph,
      _ => null,
    };
    if (requiredViewType == null || viewType == requiredViewType) return;
    throw ArgumentError.value(
      viewType.value,
      'viewType',
      '${nodeType.value} nodes must use ${requiredViewType.value} view type',
    );
  }

  List<String> _entityIdsUnderNode(String nodeId) {
    final rows = database.db.select(
      '''
      WITH RECURSIVE subtree(id) AS (
        SELECT ?
        UNION ALL
        SELECT n.id FROM index_nodes n JOIN subtree s ON n.parent_id = s.id
      )
      SELECT DISTINCT entity_id
      FROM index_node_entities
      WHERE index_node_id IN (SELECT id FROM subtree)
      ''',
      [nodeId],
    );
    return rows.map((row) => row['entity_id'] as String).toList();
  }

  void _markEntityPreviewDirty(String entityId, {required String reason}) {
    for (final nodeId in listIndexNodeIdsForEntity(entityId)) {
      markIndexNodePreviewDirty(nodeId, reason: reason);
    }
  }

  // ===========================================================================
  // Cross-cutting methods — called from multiple mixins or from the base class
  // itself. They must live here so every mixin with `on LibraryRepositoryBase`
  // can resolve them at compile time.
  // ===========================================================================

  // --- Entity lookup (called from base + IndexNodeRepositoryMixin) ---------

  Entity? getEntity(String id) {
    final rows =
        database.db.select('SELECT * FROM entities WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    return _entityFromRow(rows.first, thumbnailStore);
  }

  // --- Index stats rebuild (called from base + Entity, IndexBuild, IndexNode)

  void rebuildIndexNodeStats() {
    if (_indexStatsBatchDepth > 0) {
      _indexStatsDirty = true;
      return;
    }
    _rebuildIndexNodeStatsNow();
  }

  /// Rebuilds statistics only for the owning index tree. This is the common
  /// path for manual links, node creation and tree copies; scans retain the
  /// full rebuild because they can replace overlapping directory roots.
  void rebuildIndexNodeStatsForNode(String nodeId) {
    if (_indexStatsBatchDepth > 0) {
      _indexStatsDirty = true;
      return;
    }
    final node = _nodeById(nodeId);
    final root = node == null ? null : _owningIndexRoot(node);
    if (root == null || root.nodeType == NodeType.root) {
      _rebuildIndexNodeStatsNow();
      return;
    }
    _rebuildIndexNodeStatsForRootNow(root.id);
  }

  void _rebuildIndexNodeStatsNow() {
    final now = nowMillis();
    writeTransaction(() {
      database.db.execute('DELETE FROM index_node_stats');
      database.db.execute('''
WITH RECURSIVE closure(ancestor_id, id) AS (
  SELECT id, id FROM index_nodes
  UNION ALL
  SELECT closure.ancestor_id, child.id
  FROM closure
  JOIN index_nodes child ON child.parent_id = closure.id
),
direct_counts AS (
  SELECT link.index_node_id AS id, COUNT(DISTINCT entity.id) AS count
  FROM index_node_entities link
  JOIN entities entity ON entity.id = link.entity_id AND entity.archived = 0
  GROUP BY link.index_node_id
),
descendant_counts AS (
  SELECT closure.ancestor_id AS id, COUNT(DISTINCT entity.id) AS count
  FROM closure
  LEFT JOIN index_node_entities link ON link.index_node_id = closure.id
  LEFT JOIN entities entity
    ON entity.id = link.entity_id AND entity.archived = 0
  GROUP BY closure.ancestor_id
),
child_counts AS (
  SELECT parent_id AS id, COUNT(*) AS count
  FROM index_nodes
  WHERE parent_id IS NOT NULL
  GROUP BY parent_id
)
INSERT INTO index_node_stats (
  node_id, direct_entity_count, descendant_entity_count,
  child_node_count, updated_at
)
SELECT node.id,
       COALESCE(direct_counts.count, 0),
       COALESCE(descendant_counts.count, 0),
       COALESCE(child_counts.count, 0),
       ?
FROM index_nodes node
LEFT JOIN direct_counts ON direct_counts.id = node.id
LEFT JOIN descendant_counts ON descendant_counts.id = node.id
LEFT JOIN child_counts ON child_counts.id = node.id
''', [now]);
    });
  }

  void _rebuildIndexNodeStatsForRootNow(String rootId) {
    final now = nowMillis();
    writeTransaction(() {
      database.db.execute('''
WITH RECURSIVE subtree(id) AS (
  SELECT id FROM index_nodes WHERE id = ?
  UNION ALL
  SELECT child.id
  FROM index_nodes child
  JOIN subtree parent ON child.parent_id = parent.id
), closure(ancestor_id, id) AS (
  SELECT id, id FROM subtree
  UNION ALL
  SELECT closure.ancestor_id, child.id
  FROM closure
  JOIN index_nodes child ON child.parent_id = closure.id
), direct_counts AS (
  SELECT link.index_node_id AS id, COUNT(DISTINCT entity.id) AS count
  FROM index_node_entities link
  JOIN entities entity ON entity.id = link.entity_id AND entity.archived = 0
  WHERE link.index_node_id IN (SELECT id FROM subtree)
  GROUP BY link.index_node_id
), descendant_counts AS (
  SELECT closure.ancestor_id AS id, COUNT(DISTINCT entity.id) AS count
  FROM closure
  LEFT JOIN index_node_entities link ON link.index_node_id = closure.id
  LEFT JOIN entities entity
    ON entity.id = link.entity_id AND entity.archived = 0
  GROUP BY closure.ancestor_id
), child_counts AS (
  SELECT parent_id AS id, COUNT(*) AS count
  FROM index_nodes
  WHERE parent_id IN (SELECT id FROM subtree)
  GROUP BY parent_id
)
DELETE FROM index_node_stats WHERE node_id IN (SELECT id FROM subtree);
''', [rootId]);
      database.db.execute('''
WITH RECURSIVE subtree(id) AS (
  SELECT id FROM index_nodes WHERE id = ?
  UNION ALL
  SELECT child.id
  FROM index_nodes child
  JOIN subtree parent ON child.parent_id = parent.id
), closure(ancestor_id, id) AS (
  SELECT id, id FROM subtree
  UNION ALL
  SELECT closure.ancestor_id, child.id
  FROM closure
  JOIN index_nodes child ON child.parent_id = closure.id
), direct_counts AS (
  SELECT link.index_node_id AS id, COUNT(DISTINCT entity.id) AS count
  FROM index_node_entities link
  JOIN entities entity ON entity.id = link.entity_id AND entity.archived = 0
  WHERE link.index_node_id IN (SELECT id FROM subtree)
  GROUP BY link.index_node_id
), descendant_counts AS (
  SELECT closure.ancestor_id AS id, COUNT(DISTINCT entity.id) AS count
  FROM closure
  LEFT JOIN index_node_entities link ON link.index_node_id = closure.id
  LEFT JOIN entities entity
    ON entity.id = link.entity_id AND entity.archived = 0
  GROUP BY closure.ancestor_id
), child_counts AS (
  SELECT parent_id AS id, COUNT(*) AS count
  FROM index_nodes
  WHERE parent_id IN (SELECT id FROM subtree)
  GROUP BY parent_id
)
INSERT INTO index_node_stats (
  node_id, direct_entity_count, descendant_entity_count,
  child_node_count, updated_at
)
SELECT node.id,
       COALESCE(direct_counts.count, 0),
       COALESCE(descendant_counts.count, 0),
       COALESCE(child_counts.count, 0),
       ?
FROM index_nodes node
JOIN subtree ON subtree.id = node.id
LEFT JOIN direct_counts ON direct_counts.id = node.id
LEFT JOIN descendant_counts ON descendant_counts.id = node.id
LEFT JOIN child_counts ON child_counts.id = node.id
''', [rootId, now]);
    });
  }

  // --- Node preview dirty marking (called from base + IndexBuild, IndexNode)

  List<String> listIndexNodeIdsForEntity(String entityId) {
    final rows = database.db.select(
      'SELECT index_node_id FROM index_node_entities WHERE entity_id = ?',
      [entityId],
    );
    return rows
        .map((row) => row['index_node_id'] as String)
        .toSet()
        .toList(growable: false);
  }

  /// Preview assets are now scheduled explicitly by [LibraryBuildTaskController].
  /// This compatibility hook intentionally has no database side effects while
  /// older mutation helpers are being consolidated around that task boundary.
  void markIndexNodePreviewDirty(
    String nodeId, {
    IndexPreviewRebuildScope scope = IndexPreviewRebuildScope.node,
    String? reason,
  }) {}

  // --- Thumbnail file cleanup (called from IndexBuildMixin) ----------------

  void removeThumbnailAssets(Iterable<String> keys) {
    final unique = keys.where((key) => key.isNotEmpty).toSet().toList();
    if (unique.isEmpty) return;
    final placeholders = List.filled(unique.length, '?').join(', ');
    database.db.execute(
      'DELETE FROM thumbnail_assets WHERE asset_key IN ($placeholders)',
      unique,
    );
  }

  void _deleteUnreferencedThumbnailFiles(Iterable<String> keys) {
    final removed = <String>[];
    for (final key in keys.toSet()) {
      final referenced = database.db.select(
        'SELECT thumbnail_format FROM entities WHERE thumbnail_key = ? LIMIT 1',
        [key],
      );
      if (referenced.isNotEmpty) continue;
      for (final format in const ['webp', 'png', 'jpg', 'jpeg']) {
        final file = thumbnailStore.fileFor(key, format);
        if (file.existsSync()) file.deleteSync();
      }
      removed.add(key);
    }
    removeThumbnailAssets(removed);
  }

  Set<String> _thumbnailKeysUnderNodes(Set<String> nodeIds) {
    if (nodeIds.isEmpty) return const <String>{};
    final placeholders = List.filled(nodeIds.length, '?').join(', ');
    final rows = database.db.select('''
      WITH RECURSIVE subtree(id) AS (
        SELECT id FROM index_nodes WHERE id IN ($placeholders)
        UNION ALL
        SELECT child.id
        FROM index_nodes child JOIN subtree ON child.parent_id = subtree.id
      )
      SELECT DISTINCT entity.thumbnail_key
      FROM index_node_entities link
      JOIN entities entity ON entity.id = link.entity_id
      WHERE link.index_node_id IN (SELECT id FROM subtree)
        AND entity.thumbnail_key IS NOT NULL
    ''', nodeIds.toList(growable: false));
    return rows
        .map((row) => row['thumbnail_key'] as String?)
        .whereType<String>()
        .where((key) => key.isNotEmpty)
        .toSet();
  }
}
