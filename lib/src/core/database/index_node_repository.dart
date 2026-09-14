part of 'library_repository.dart';

/// Index node CRUD, graph edges, entity linking, tree traversal, and
/// paginated entity listing under nodes.
mixin IndexNodeRepositoryMixin on LibraryRepositoryBase {
  IndexNode ensureCategoryIndexRoot(String name) {
    return ensureCollectionIndexRoot(name);
  }

  /// Creates a static, user-curated collection. Its contents are references to
  /// existing entities and never trigger source scanning or thumbnail work.
  IndexNode ensureCollectionIndexRoot(String name) {
    final root = _ensureGlobalRoot();
    final node = ensureIndexNode(
      parentId: root.id,
      name: name,
      nodeType: NodeType.customIndexRoot,
      viewType: ViewType.tree,
    );
    rebuildIndexNodeStats();
    return node;
  }

  IndexNode ensureGraphIndexRoot(String name) {
    final root = _ensureGlobalRoot();
    final node = ensureIndexNode(
      parentId: root.id,
      name: name,
      nodeType: NodeType.graphIndexRoot,
      viewType: ViewType.graph,
    );
    rebuildIndexNodeStats();
    return node;
  }

  IndexNode ensureGraphNode({
    required String parentId,
    required String name,
    int sortOrder = 0,
  }) {
    final node = writeTransaction(
      () {
        final created = ensureIndexNode(
          parentId: parentId,
          name: name,
          nodeType: NodeType.graphNode,
          viewType: ViewType.graph,
          sortOrder: sortOrder,
        );
        markIndexNodePreviewDirty(parentId, reason: 'graph_node_created');
        return created;
      },
    );
    rebuildIndexNodeStats();
    return node;
  }

  IndexNode ensureIndexNode({
    required String name,
    required NodeType nodeType,
    required ViewType viewType,
    String? parentId,
    String? sourcePath,
    int sortOrder = 0,
  }) {
    if (nodeType == NodeType.root) {
      throw ArgumentError.value(
        nodeType.value,
        'nodeType',
        'root index node is managed internally',
      );
    }
    if (nodeType == NodeType.directoryIndexRoot) {
      throw ArgumentError.value(
        nodeType.value,
        'nodeType',
        'directory index root must be created through ensureDirectoryIndexRoot',
      );
    }
    if (sourcePath != null && nodeType != NodeType.directoryIndexRoot) {
      throw ArgumentError.value(
        sourcePath,
        'sourcePath',
        'sourcePath is only valid for directory index roots',
      );
    }
    if (_isTopLevelIndexRootType(nodeType)) {
      final root = _ensureGlobalRoot();
      if (parentId != root.id) {
        throw ArgumentError.value(
          parentId,
          'parentId',
          'index root nodes must be direct children of the system root',
        );
      }
    }
    _requireValidParentForNodeType(
      nodeType: nodeType,
      parentId: parentId,
    );
    _requireValidViewTypeForNodeType(
      nodeType: nodeType,
      viewType: viewType,
    );
    final normalizedName = _normalizeIndexNodeName(name);
    final existing = database.db.select(
      '''
      SELECT * FROM index_nodes
      WHERE parent_id IS ? AND name = ? AND node_type = ?
      LIMIT 1
      ''',
      [parentId, normalizedName, nodeType.value],
    );
    if (existing.isNotEmpty) return _nodeFromRow(existing.first);
    final now = nowMillis();
    final node = IndexNode(
      id: newId(),
      parentId: parentId,
      name: normalizedName,
      nodeType: nodeType,
      viewType: viewType,
      sourcePath: sourcePath,
      sortOrder: sortOrder,
      createdAtMs: now,
      updatedAtMs: now,
    );
    database.db.execute(
      '''
      INSERT INTO index_nodes
      (id, parent_id, name, node_type, view_type, source_path, sort_order, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        node.id,
        node.parentId,
        normalizedName,
        node.nodeType.value,
        node.viewType.value,
        node.sourcePath,
        node.sortOrder,
        now,
        now,
      ],
    );
    return node;
  }

  void setDirectoryNodeRelativePath(String nodeId, String relativePath) {
    database.db.execute(
      'UPDATE index_nodes SET relative_source_path = ? WHERE id = ?',
      [relativePath.replaceAll('\\', '/'), nodeId],
    );
  }

  /// Creates a generated directory node without running the insert on the
  /// caller isolate. The caller still performs a small read afterwards so it
  /// receives the winner when concurrent SAF batches discover the same folder.
  Future<IndexNode> ensureDirectoryFolderAsync({
    required String parentId,
    required String name,
    required String relativePath,
  }) async {
    final normalizedName = _normalizeIndexNodeName(name);
    final existingRows = database.db.select(
      '''
      SELECT * FROM index_nodes
      WHERE parent_id = ? AND name = ? AND node_type = ?
      LIMIT 1
      ''',
      [parentId, normalizedName, NodeType.folder.value],
    );
    if (existingRows.isNotEmpty) {
      final existing = _nodeFromRow(existingRows.first);
      final normalizedRelativePath = relativePath.replaceAll('\\', '/');
      if (existingRows.first['relative_source_path'] !=
          normalizedRelativePath) {
        final worker = writeWorker;
        if (worker == null) {
          setDirectoryNodeRelativePath(existing.id, normalizedRelativePath);
        } else {
          await worker.execute(
            'UPDATE index_nodes SET relative_source_path = ? WHERE id = ?',
            [normalizedRelativePath, existing.id],
          );
        }
      }
      return existing;
    }
    _requireValidParentForNodeType(
      nodeType: NodeType.folder,
      parentId: parentId,
    );
    final now = nowMillis();
    final id = newId();
    final normalizedRelativePath = relativePath.replaceAll('\\', '/');
    final statements = <LibraryWriteStatement>[
      LibraryWriteStatement(
        '''
        INSERT OR IGNORE INTO index_nodes
        (id, parent_id, name, node_type, view_type, relative_source_path,
         sort_order, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
        ''',
        [
          id,
          parentId,
          normalizedName,
          NodeType.folder.value,
          ViewType.tree.value,
          normalizedRelativePath,
          now,
          now,
        ],
      ),
    ];
    final worker = writeWorker;
    if (worker == null) {
      final node = ensureIndexNode(
        parentId: parentId,
        name: normalizedName,
        nodeType: NodeType.folder,
        viewType: ViewType.tree,
      );
      setDirectoryNodeRelativePath(node.id, normalizedRelativePath);
      return _nodeById(node.id)!;
    }
    await worker.executeBatch(statements);
    final rows = database.db.select(
      '''
      SELECT * FROM index_nodes
      WHERE parent_id = ? AND name = ? AND node_type = ?
      LIMIT 1
      ''',
      [parentId, normalizedName, NodeType.folder.value],
    );
    if (rows.isEmpty) {
      throw StateError('目录节点写入后无法读取：$normalizedRelativePath');
    }
    return _nodeFromRow(rows.first);
  }

  String? directoryNodeRelativePath(String nodeId) {
    final rows = database.db.select(
      'SELECT relative_source_path FROM index_nodes WHERE id = ? LIMIT 1',
      [nodeId],
    );
    return rows.isEmpty ? null : rows.first['relative_source_path'] as String?;
  }

  void backfillDirectoryNodeRelativePaths(String rootId) {
    database.db.execute(
      '''
      WITH RECURSIVE tree(id, relative_path) AS (
        SELECT id, '' FROM index_nodes WHERE id = ?
        UNION ALL
        SELECT child.id,
               CASE WHEN tree.relative_path = '' THEN child.name
                    ELSE tree.relative_path || '/' || child.name END
        FROM index_nodes child JOIN tree ON child.parent_id = tree.id
      )
      UPDATE index_nodes
      SET relative_source_path = (
        SELECT relative_path FROM tree WHERE tree.id = index_nodes.id
      )
      WHERE id IN (SELECT id FROM tree)
        AND (relative_source_path IS NULL OR relative_source_path = '')
      ''',
      [rootId],
    );
  }

  void linkEntityToIndexNode({
    required String entityId,
    required String indexNodeId,
  }) {
    _requireLinkableIndexNode(indexNodeId, 'indexNodeId');
    if (getEntity(entityId) == null) {
      throw ArgumentError.value(
        entityId,
        'entityId',
        'Entity does not exist',
      );
    }
    writeTransaction(() {
      database.db.execute(
        '''
        INSERT OR IGNORE INTO index_node_entities
        (index_node_id, entity_id, sort_name, created_at)
        SELECT ?, id, lower(name), ? FROM entities WHERE id = ?
        ''',
        [indexNodeId, nowMillis(), entityId],
      );
      _touchIndexNode(indexNodeId);
      markIndexNodePreviewDirty(indexNodeId, reason: 'entity_linked');
    });
    rebuildIndexNodeStatsForNode(indexNodeId);
  }

  /// Scanner-oriented bulk link insertion. Entity and node existence is
  /// enforced by foreign keys, while each touched node is updated only once.
  void linkEntitiesToIndexNodes(
    Iterable<({String entityId, String indexNodeId})> links, {
    bool rebuildStats = true,
    bool markPreviewDirty = true,
  }) {
    final uniqueLinks = links.toSet().toList(growable: false);
    if (uniqueLinks.isEmpty) return;
    final statement = database.db.prepare('''
      INSERT OR IGNORE INTO index_node_entities
      (index_node_id, entity_id, sort_name, created_at)
      SELECT ?, id, lower(name), ? FROM entities WHERE id = ?
    ''');
    final touchedNodes = <String>{};
    final now = nowMillis();
    try {
      for (final link in uniqueLinks) {
        statement.execute([link.indexNodeId, now, link.entityId]);
        touchedNodes.add(link.indexNodeId);
      }
    } finally {
      statement.dispose();
    }
    if (touchedNodes.isEmpty) return;
    final touchStatement = database.db.prepare(
      'UPDATE index_nodes SET updated_at = ? WHERE id = ?',
    );
    try {
      for (final nodeId in touchedNodes) {
        touchStatement.execute([now, nodeId]);
      }
    } finally {
      touchStatement.dispose();
    }
    if (rebuildStats) {
      for (final nodeId in touchedNodes) {
        rebuildIndexNodeStatsForNode(nodeId);
      }
    }
    if (markPreviewDirty) {
      for (final nodeId in touchedNodes) {
        markIndexNodePreviewDirty(nodeId, reason: 'entities_linked');
      }
    }
  }

  /// Adds all valid entities in one transaction. Repeated selections are
  /// harmless because the relation has a composite primary key.
  void linkEntitiesToIndexNode({
    required Iterable<String> entityIds,
    required String indexNodeId,
  }) {
    _requireLinkableIndexNode(indexNodeId, 'indexNodeId');
    final ids = entityIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    final existingIds = _existingEntityIds(ids);
    if (existingIds.length != ids.length) {
      final missing = ids.firstWhere((id) => !existingIds.contains(id));
      throw ArgumentError.value(missing, 'entityIds', 'Entity does not exist');
    }
    writeTransaction(() {
      final statement = database.db.prepare('''
          INSERT OR IGNORE INTO index_node_entities
          (index_node_id, entity_id, sort_name, created_at)
          SELECT ?, id, lower(name), ? FROM entities WHERE id = ?
      ''');
      final now = nowMillis();
      try {
        for (final entityId in ids) {
          statement.execute([indexNodeId, now, entityId]);
        }
      } finally {
        statement.dispose();
      }
      _touchIndexNode(indexNodeId);
      markIndexNodePreviewDirty(indexNodeId, reason: 'entities_linked');
    });
    rebuildIndexNodeStatsForNode(indexNodeId);
  }

  IndexNode createCollectionWithEntities({
    required String name,
    required Iterable<String> entityIds,
  }) {
    return batchIndexMutations(() {
      return writeTransaction(() {
        final collection = ensureCollectionIndexRoot(name);
        linkEntitiesToIndexNode(
          entityIds: entityIds,
          indexNodeId: collection.id,
        );
        return collection;
      });
    });
  }

  IndexNode createCustomNode({
    required String parentId,
    required String name,
  }) {
    final node = writeTransaction(
      () {
        final created = ensureIndexNode(
          parentId: parentId,
          name: name,
          nodeType: NodeType.customNode,
          viewType: ViewType.tree,
        );
        _touchIndexNode(parentId);
        markIndexNodePreviewDirty(parentId, reason: 'child_node_created');
        return created;
      },
    );
    rebuildIndexNodeStatsForNode(parentId);
    return node;
  }

  /// Copies a tree's structure into a manual index while retaining references
  /// to the same entities. Graph edges are intentionally not copied because
  /// the destination is a tree. Source nodes and source files are unchanged.
  IndexNode cloneIndexNodeTree({
    required String sourceNodeId,
    required String targetParentId,
  }) {
    final source = _nodeById(sourceNodeId);
    final targetParent = _nodeById(targetParentId);
    if (source == null || source.nodeType == NodeType.root) {
      throw ArgumentError.value(
          sourceNodeId, 'sourceNodeId', 'Invalid source node');
    }
    if (targetParent == null) {
      throw ArgumentError.value(
          targetParentId, 'targetParentId', 'Target index node does not exist');
    }
    final targetRoot = _owningIndexRoot(targetParent);
    if (targetRoot?.nodeType != NodeType.customIndexRoot) {
      throw ArgumentError.value(
        targetParentId,
        'targetParentId',
        'Tree clones can only be placed in a custom index',
      );
    }
    final targetIsInsideSource = database.db.select(
      '''
      WITH RECURSIVE subtree(id) AS (
        SELECT ?
        UNION ALL
        SELECT node.id FROM index_nodes node JOIN subtree ON node.parent_id = subtree.id
      )
      SELECT 1 FROM subtree WHERE id = ? LIMIT 1
      ''',
      [sourceNodeId, targetParentId],
    ).isNotEmpty;
    if (targetIsInsideSource) {
      throw ArgumentError.value(
        targetParentId,
        'targetParentId',
        'Cannot clone a node tree into itself or one of its descendants',
      );
    }

    final now = nowMillis();
    late final IndexNode clonedRoot;
    writeTransaction(() {
      final usedNamesByParent = <String, Set<String>>{};
      final nodeInsert = database.db.prepare('''
        INSERT INTO index_nodes
        (id, parent_id, name, node_type, view_type, sort_order, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''');
      final entityLinkInsert = database.db.prepare('''
        INSERT OR IGNORE INTO index_node_entities(index_node_id, entity_id, sort_name, created_at)
        SELECT ?, id, lower(name), ? FROM entities WHERE id = ?
      ''');

      String uniqueName(String parentId, String proposedName) {
        final used = usedNamesByParent.putIfAbsent(parentId, () {
          final rows = database.db.select(
            'SELECT name FROM index_nodes WHERE parent_id = ? COLLATE NOCASE',
            [parentId],
          );
          return rows
              .map((row) => (row['name'] as String).toLowerCase())
              .toSet();
        });
        var candidate = proposedName;
        var copyNumber = 2;
        while (!used.add(candidate.toLowerCase())) {
          candidate = '$proposedName (copy $copyNumber)';
          copyNumber++;
        }
        return candidate;
      }

      IndexNode copyNode(IndexNode original, String parentId) {
        final copied = IndexNode(
          id: newId(),
          parentId: parentId,
          name: uniqueName(parentId, original.name),
          nodeType: NodeType.customNode,
          viewType: ViewType.tree,
          sortOrder: original.sortOrder,
          createdAtMs: now,
          updatedAtMs: now,
        );
        nodeInsert.execute([
          copied.id,
          copied.parentId,
          copied.name,
          copied.nodeType.value,
          copied.viewType.value,
          copied.sortOrder,
          now,
          now,
        ]);
        final entityRows = database.db.select(
          'SELECT entity_id, created_at FROM index_node_entities WHERE index_node_id = ?',
          [original.id],
        );
        for (final row in entityRows) {
          entityLinkInsert.execute([
            copied.id,
            row['created_at'],
            row['entity_id'],
          ]);
        }
        final childRows = database.db.select(
          '''
          SELECT * FROM index_nodes
          WHERE parent_id = ?
          ORDER BY sort_order, name COLLATE NOCASE, id
          ''',
          [original.id],
        );
        for (final childRow in childRows) {
          final child = _nodeFromRow(childRow);
          copyNode(child, copied.id);
        }
        return copied;
      }

      try {
        clonedRoot = copyNode(source, targetParent.id);
        _touchIndexNode(targetParent.id);
        markIndexNodePreviewDirty(
          clonedRoot.id,
          scope: IndexPreviewRebuildScope.subtree,
          reason: 'node_tree_cloned',
        );
      } finally {
        entityLinkInsert.dispose();
        nodeInsert.dispose();
      }
    });
    rebuildIndexNodeStatsForNode(targetParentId);
    return clonedRoot;
  }

  IndexNodeEdge linkIndexNodes({
    required String fromNodeId,
    required String toNodeId,
    String edgeType = 'related',
    String? label,
    int sortOrder = 0,
  }) {
    final fromNode = _requireLinkableIndexNode(fromNodeId, 'fromNodeId');
    final toNode = _requireLinkableIndexNode(toNodeId, 'toNodeId');
    _requireGraphEdgeNodes(fromNode: fromNode, toNode: toNode);
    final normalizedEdgeType = _normalizeEdgeType(edgeType);
    final normalizedLabel = _normalizeOptionalText(label);
    final existing = database.db.select(
      '''
      SELECT * FROM index_node_edges
      WHERE from_node_id = ? AND to_node_id = ? AND edge_type = ?
      LIMIT 1
      ''',
      [fromNodeId, toNodeId, normalizedEdgeType],
    );
    if (existing.isNotEmpty) return _edgeFromRow(existing.first);
    final edge = IndexNodeEdge(
      id: newId(),
      fromNodeId: fromNodeId,
      toNodeId: toNodeId,
      edgeType: normalizedEdgeType,
      label: normalizedLabel,
      sortOrder: sortOrder,
    );
    database.db.execute(
      '''
      INSERT INTO index_node_edges
      (id, from_node_id, to_node_id, edge_type, label, sort_order)
      VALUES (?, ?, ?, ?, ?, ?)
      ''',
      [
        edge.id,
        edge.fromNodeId,
        edge.toNodeId,
        edge.edgeType,
        edge.label,
        edge.sortOrder,
      ],
    );
    return edge;
  }

  List<IndexNodeEdge> listOutgoingEdges(String fromNodeId) {
    final rows = database.db.select(
      '''
      SELECT * FROM index_node_edges
      WHERE from_node_id = ?
      ORDER BY sort_order, edge_type, label
      ''',
      [fromNodeId],
    );
    return rows.map(_edgeFromRow).toList();
  }

  List<IndexNodeEdge> listIncomingEdges(String toNodeId) {
    final rows = database.db.select(
      '''
      SELECT * FROM index_node_edges
      WHERE to_node_id = ?
      ORDER BY sort_order, edge_type, label
      ''',
      [toNodeId],
    );
    return rows.map(_edgeFromRow).toList();
  }

  List<IndexNodeEdge> listGraphEdges(String graphRootId) {
    final rows = database.db.select(
      '''
      WITH RECURSIVE graph_nodes(id) AS (
        SELECT id FROM index_nodes
        WHERE id = ? AND node_type = ?
        UNION ALL
        SELECT child.id
        FROM index_nodes child
        JOIN graph_nodes parent ON child.parent_id = parent.id
        WHERE child.node_type = ?
      )
      SELECT edge.*
      FROM index_node_edges edge
      JOIN index_nodes source ON source.id = edge.from_node_id
      WHERE source.id IN (SELECT id FROM graph_nodes)
        AND source.node_type = ?
      ORDER BY edge.sort_order, edge.edge_type, edge.label
      ''',
      [
        graphRootId,
        NodeType.graphIndexRoot.value,
        NodeType.graphNode.value,
        NodeType.graphNode.value,
      ],
    );
    return rows.map(_edgeFromRow).toList();
  }

  List<IndexNode> listGraphNodes(String graphRootId) {
    final rows = database.db.select(
      '''
      WITH RECURSIVE graph_nodes(id, depth) AS (
        SELECT id, 0 FROM index_nodes
        WHERE id = ? AND node_type = ?
        UNION ALL
        SELECT child.id, graph_nodes.depth + 1
        FROM index_nodes child
        JOIN graph_nodes ON child.parent_id = graph_nodes.id
        WHERE child.node_type = ?
      )
      SELECT node.*
      FROM index_nodes node
      JOIN graph_nodes ON graph_nodes.id = node.id
      WHERE node.node_type = ?
      ORDER BY graph_nodes.depth, node.sort_order, node.name COLLATE NOCASE, node.id
      ''',
      [
        graphRootId,
        NodeType.graphIndexRoot.value,
        NodeType.graphNode.value,
        NodeType.graphNode.value,
      ],
    );
    return rows.map(_nodeFromRow).toList(growable: false);
  }

  Map<String, GraphNodePosition> listGraphNodePositions(String graphRootId) {
    final rows = database.db.select(
      '''
      WITH RECURSIVE graph_nodes(id) AS (
        SELECT id FROM index_nodes
        WHERE id = ? AND node_type = ?
        UNION ALL
        SELECT child.id
        FROM index_nodes child
        JOIN graph_nodes parent ON child.parent_id = parent.id
        WHERE child.node_type = ?
      )
      SELECT position.node_id, position.x, position.y
      FROM graph_node_positions position
      JOIN index_nodes node ON node.id = position.node_id
      WHERE node.id IN (SELECT id FROM graph_nodes)
        AND node.node_type = ?
      ''',
      [
        graphRootId,
        NodeType.graphIndexRoot.value,
        NodeType.graphNode.value,
        NodeType.graphNode.value,
      ],
    );
    return Map.unmodifiable({
      for (final row in rows)
        row['node_id'] as String: GraphNodePosition(
          nodeId: row['node_id'] as String,
          x: row['x'] as double,
          y: row['y'] as double,
        ),
    });
  }

  void setGraphNodePosition({
    required String nodeId,
    required double x,
    required double y,
  }) {
    database.db.execute(
      '''
      INSERT INTO graph_node_positions(node_id, x, y, updated_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(node_id) DO UPDATE SET x = excluded.x, y = excluded.y,
        updated_at = excluded.updated_at
      ''',
      [nodeId, x, y, nowMillis()],
    );
  }

  List<IndexNode> listIndexRoots({
    EntitySortMode sortMode = EntitySortMode.nameAsc,
  }) {
    final root = _ensureGlobalRoot();
    final rows = database.db.select(
      '''
      SELECT node.* FROM index_nodes node
      LEFT JOIN index_node_stats stats ON stats.node_id = node.id
      WHERE node.parent_id = ?
        AND node.is_staging = 0
      ORDER BY ${_indexNodeOrderBy(sortMode)}
      ''',
      [root.id],
    );
    return rows.map(_nodeFromRow).toList();
  }

  List<IndexNode> listChildNodes(
    String indexRootId, {
    String? parentId,
    EntitySortMode sortMode = EntitySortMode.nameAsc,
  }) {
    final rows = database.db.select(
      '''
      SELECT node.* FROM index_nodes node
      LEFT JOIN index_node_stats stats ON stats.node_id = node.id
      WHERE node.parent_id = ?
      ORDER BY ${_indexNodeOrderBy(sortMode)}
      ''',
      [parentId ?? indexRootId],
    );
    return rows.map(_nodeFromRow).toList();
  }

  IndexNode? getIndexNode(String id) => _nodeById(id);

  /// Returns the directory index root that owns [nodeId], if the node is part
  /// of a source-generated directory tree.
  IndexNode? directoryIndexRootForNode(String nodeId) {
    final rows = database.db.select(
      '''
      WITH RECURSIVE ancestors(id, parent_id, node_type) AS (
        SELECT id, parent_id, node_type FROM index_nodes WHERE id = ?
        UNION ALL
        SELECT parent.id, parent.parent_id, parent.node_type
        FROM index_nodes parent
        JOIN ancestors child ON child.parent_id = parent.id
      )
      SELECT node.*
      FROM ancestors
      JOIN index_nodes node ON node.id = ancestors.id
      WHERE node.node_type = ?
      LIMIT 1
      ''',
      [nodeId, NodeType.directoryIndexRoot.value],
    );
    return rows.isEmpty ? null : _nodeFromRow(rows.first);
  }

  /// Loads only the ancestor chain needed by the breadcrumb/path rail.
  List<IndexNode> listNodePath(String indexRootId, String currentNodeId) {
    final rows = database.db.select(
      '''
      WITH RECURSIVE ancestors(id, parent_id, depth) AS (
        SELECT id, parent_id, 0
        FROM index_nodes
        WHERE id = ?
        UNION ALL
        SELECT parent.id, parent.parent_id, ancestors.depth + 1
        FROM index_nodes parent
        JOIN ancestors ON ancestors.parent_id = parent.id
      )
      SELECT node.*
      FROM ancestors
      JOIN index_nodes node ON node.id = ancestors.id
      WHERE node.node_type <> ?
      ORDER BY ancestors.depth DESC
      ''',
      [currentNodeId, NodeType.root.value],
    );
    final path = rows.map(_nodeFromRow).toList(growable: false);
    if (path.isEmpty || path.first.id != indexRootId) return const [];
    return path;
  }

  /// Returns compact node metadata in two batched aggregate queries. These
  /// values are for browsing cards only and never change entity ownership.
  Map<String, IndexNodeSummary> listIndexNodeSummaries(
    Iterable<String> nodeIds,
  ) {
    final ids = nodeIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const <String, IndexNodeSummary>{};
    final placeholders = List<String>.filled(ids.length, '?').join(', ');
    final rows = database.db.select(
      '''
      SELECT node.id,
             COALESCE(stats.direct_entity_count, 0) AS direct_count,
             COALESCE(stats.descendant_entity_count, 0) AS descendant_count,
             COALESCE(stats.child_node_count, 0) AS child_count
      FROM index_nodes node
      LEFT JOIN index_node_stats stats ON stats.node_id = node.id
      WHERE node.id IN ($placeholders)
      ''',
      ids,
    );
    return Map<String, IndexNodeSummary>.unmodifiable({
      for (final row in rows)
        row['id'] as String: IndexNodeSummary(
          directEntityCount: row['direct_count'] as int,
          descendantEntityCount: row['descendant_count'] as int,
          childNodeCount: row['child_count'] as int,
        ),
    });
  }

  List<IndexTreeNode> listIndexTree(String indexRootId) {
    return loadIndexTree(indexRootId).tree;
  }

  /// Reads a complete index tree and all descendant entity counts in one query.
  /// The previous implementation issued one recursive count query per node.
  IndexTreeSnapshot loadIndexTree(String indexRootId) {
    final rows = database.db.select(
      '''
      WITH RECURSIVE descendants(id) AS (
        SELECT ?
        UNION ALL
        SELECT node.id
        FROM index_nodes node
        JOIN descendants parent ON node.parent_id = parent.id
      ),
      closure(ancestor_id, id) AS (
        SELECT id, id FROM descendants
        UNION ALL
        SELECT closure.ancestor_id, node.id
        FROM closure
        JOIN index_nodes node ON node.parent_id = closure.id
      ),
      counts AS (
        SELECT closure.ancestor_id AS id, COUNT(DISTINCT entity.id) AS entity_count
        FROM closure
        LEFT JOIN index_node_entities link ON link.index_node_id = closure.id
        LEFT JOIN entities entity
          ON entity.id = link.entity_id AND entity.archived = 0
        GROUP BY closure.ancestor_id
      )
      SELECT node.*, COALESCE(counts.entity_count, 0) AS entity_count
      FROM index_nodes node
      JOIN descendants ON descendants.id = node.id
      LEFT JOIN counts ON counts.id = node.id
      ORDER BY node.parent_id, node.sort_order, node.name COLLATE NOCASE
      ''',
      [indexRootId],
    );
    final nodesById = <String, IndexNode>{};
    final childrenByParent = <String, List<IndexNode>>{};
    final counts = <String, int>{};
    for (final row in rows) {
      final node = _nodeFromRow(row);
      nodesById[node.id] = node;
      counts[node.id] = row['entity_count'] as int;
      final parentId = node.parentId;
      if (parentId != null) {
        childrenByParent.putIfAbsent(parentId, () => <IndexNode>[]).add(node);
      }
    }

    List<IndexTreeNode> build(String parentId) {
      return (childrenByParent[parentId] ?? const <IndexNode>[])
          .map(
            (node) => IndexTreeNode(
              item: node,
              children: build(node.id),
              entityCount: counts[node.id] ?? 0,
            ),
          )
          .toList(growable: false);
    }

    return IndexTreeSnapshot(
      tree: build(indexRootId),
      entityCounts: Map<String, int>.unmodifiable(counts),
    );
  }

  List<EntityListItem> listEntitiesUnderNode(
    String? indexNodeId, {
    EntitySortMode sortMode = EntitySortMode.nameAsc,
  }) {
    if (indexNodeId == null) return const [];
    final orderBy = _entityOrderBy(sortMode);
    final rows = database.db.select(
      '''
            WITH RECURSIVE subtree(id) AS (
              SELECT ?
              UNION ALL
              SELECT n.id FROM index_nodes n JOIN subtree s ON n.parent_id = s.id
            )
            SELECT DISTINCT e.* FROM index_node_entities l
            JOIN entities e ON e.id = l.entity_id
            WHERE l.index_node_id IN (SELECT id FROM subtree)
            AND e.archived = 0
            ORDER BY $orderBy
            ''',
      [indexNodeId],
    );
    return rows.map((row) => _listItemFromRow(row, thumbnailStore)).toList();
  }

  List<EntityListItem> listEntitiesDirectlyUnderNode(
    String? indexNodeId, {
    EntitySortMode sortMode = EntitySortMode.nameAsc,
  }) {
    return listEntityPageDirectlyUnderNode(
      indexNodeId,
      sortMode: sortMode,
    ).items;
  }

  EntityPage listEntityPageByTypes(
    Iterable<EntityType> entityTypes, {
    EntitySortMode sortMode = EntitySortMode.nameAsc,
    EntityPageCursor? after,
    int? limit,
  }) {
    final types = entityTypes.map((type) => type.value).toSet().toList();
    if (types.isEmpty) return const EntityPage(items: [], hasMore: false);
    final cursor = after == null
        ? null
        : _entityCursorCondition(after, sortMode, alias: 'e');
    final typePlaceholders = List<String>.filled(types.length, '?').join(', ');
    final parameters = <Object>[
      ...types,
      if (cursor != null) ...cursor.parameters,
    ];
    final pagination = limit == null ? '' : 'LIMIT ?';
    if (limit != null) parameters.add(limit + 1);
    final rows = database.db.select(
      '''
      SELECT e.* FROM entities e
      WHERE e.archived = 0
        AND e.media_type IN ($typePlaceholders)
        ${cursor == null ? '' : 'AND (${cursor.sql})'}
      ORDER BY ${_entityOrderBy(sortMode)}
      $pagination
      ''',
      parameters,
    );
    final hasMore = limit != null && rows.length > limit;
    final visibleRows = hasMore ? rows.sublist(0, limit) : rows;
    return EntityPage(
      items: visibleRows
          .map((row) => _listItemFromRow(row, thumbnailStore))
          .toList(growable: false),
      hasMore: hasMore,
    );
  }

  /// Bounded database-side filtering used only while attaching existing
  /// entities to a user-managed node.
  List<EntityListItem> listEntitiesForNodeLinkPicker({
    String query = '',
    int limit = 160,
  }) {
    final normalizedQuery = query.trim().toLowerCase();
    final safeLimit = limit.clamp(1, 500).toInt();
    final rows = database.db.select(
      '''
      SELECT e.* FROM entities e
      WHERE e.archived = 0
        AND (? = '' OR instr(lower(e.name), ?) > 0)
      ORDER BY ${_entityOrderBy(EntitySortMode.nameAsc)}
      LIMIT ?
      ''',
      [normalizedQuery, normalizedQuery, safeLimit],
    );
    return rows
        .map((row) => _listItemFromRow(row, thumbnailStore))
        .toList(growable: false);
  }

  EntityPage listEntityPageDirectlyUnderNode(
    String? indexNodeId, {
    EntitySortMode sortMode = EntitySortMode.nameAsc,
    EntityPageCursor? after,
    int? limit,
  }) {
    if (indexNodeId == null) {
      return const EntityPage(items: <EntityListItem>[], hasMore: false);
    }
    final orderBy = sortMode == EntitySortMode.nameAsc
        ? 'l.sort_name COLLATE NOCASE ASC, e.id ASC'
        : _entityOrderBy(sortMode);
    final cursor = after == null
        ? null
        : _entityCursorCondition(after, sortMode, alias: 'e');
    final parameters = <Object>[
      indexNodeId,
      if (cursor != null) ...cursor.parameters,
    ];
    final pagination = limit == null ? '' : 'LIMIT ?';
    if (limit != null) parameters.add(limit + 1);
    final rows = database.db.select(
      '''
      SELECT e.* FROM index_node_entities l
      JOIN entities e ON e.id = l.entity_id
      WHERE l.index_node_id = ?
      AND e.archived = 0
      ${cursor == null ? '' : 'AND (${cursor.sql})'}
      ORDER BY $orderBy
      $pagination
      ''',
      parameters,
    );
    final hasMore = limit != null && rows.length > limit;
    final visibleRows = hasMore ? rows.sublist(0, limit) : rows;
    return EntityPage(
      items: visibleRows
          .map((row) => _listItemFromRow(row, thumbnailStore))
          .toList(growable: false),
      hasMore: hasMore,
    );
  }

  /// Returns de-duplicated entities linked to this node or any node below it.
  /// The node hierarchy is a tree, so the recursive CTE cannot cycle.
  EntityPage listEntityPageRecursivelyUnderNode(
    String? indexNodeId, {
    EntitySortMode sortMode = EntitySortMode.nameAsc,
    RecursiveEntityPageCursor? after,
    int? limit,
  }) {
    if (indexNodeId == null) {
      return const EntityPage(items: <EntityListItem>[], hasMore: false);
    }
    final orderBy = _entityOrderBy(sortMode);
    final entityCursor = after == null
        ? null
        : _entityCursorCondition(after.entityCursor, sortMode, alias: 'e');
    final parameters = <Object>[
      indexNodeId,
      if (after != null) ...[
        after.hierarchyPath,
        after.hierarchyPath,
        ...entityCursor!.parameters,
      ],
    ];
    final pagination = limit == null ? '' : 'LIMIT ?';
    if (limit != null) parameters.add(limit + 1);
    final rows = database.db.select(
      '''
      WITH RECURSIVE subtree(id, hierarchy_path) AS (
        SELECT id,
               printf('%010d', sort_order) || char(31) ||
               lower(name) || char(31) || id
        FROM index_nodes
        WHERE id = ?
        UNION ALL
        SELECT node.id,
               parent.hierarchy_path || char(30) ||
               printf('%010d', node.sort_order) || char(31) ||
               lower(node.name) || char(31) || node.id
        FROM index_nodes node
        JOIN subtree parent ON node.parent_id = parent.id
      ), entity_nodes AS (
        SELECT link.entity_id, MIN(subtree.hierarchy_path) AS hierarchy_path
        FROM index_node_entities link
        JOIN subtree ON subtree.id = link.index_node_id
        GROUP BY link.entity_id
      )
      SELECT e.*, entity_nodes.hierarchy_path AS recursive_hierarchy_path
      FROM entity_nodes
      JOIN entities e ON e.id = entity_nodes.entity_id
      WHERE e.archived = 0
      ${after == null ? '' : 'AND (entity_nodes.hierarchy_path > ? OR (entity_nodes.hierarchy_path = ? AND (${entityCursor!.sql})) )'}
      ORDER BY entity_nodes.hierarchy_path ASC, $orderBy
      $pagination
      ''',
      parameters,
    );
    final hasMore = limit != null && rows.length > limit;
    final visibleRows = hasMore ? rows.sublist(0, limit) : rows;
    final items = visibleRows
        .map((row) => _listItemFromRow(row, thumbnailStore))
        .toList(growable: false);
    final recursiveCursor = items.isEmpty
        ? null
        : RecursiveEntityPageCursor(
            hierarchyPath:
                visibleRows.last['recursive_hierarchy_path'] as String,
            entityCursor: EntityPageCursor.fromEntity(items.last, sortMode),
          );
    return EntityPage(
      items: items,
      hasMore: hasMore,
      recursiveCursor: recursiveCursor,
    );
  }

  void renameIndexNode(String nodeId, String name) {
    final normalizedName = _normalizeIndexNodeName(name);
    final node = _nodeById(nodeId);
    if (node == null) return;
    if (node.nodeType == NodeType.root) return;
    if (normalizedName == node.name) return;
    final duplicate = database.db.select(
      '''
      SELECT 1 FROM index_nodes
      WHERE parent_id IS ? AND name = ? AND node_type = ? AND id <> ?
      LIMIT 1
      ''',
      [node.parentId, normalizedName, node.nodeType.value, nodeId],
    );
    if (duplicate.isNotEmpty) {
      throw ArgumentError.value(
        name,
        'name',
        'Sibling index node with the same name and type already exists',
      );
    }
    writeTransaction(() {
      database.db.execute(
        'UPDATE index_nodes SET name = ?, updated_at = ? WHERE id = ?',
        [normalizedName, nowMillis(), nodeId],
      );
      markIndexNodePreviewDirty(nodeId, reason: 'node_renamed');
    });
  }

  void deleteIndexNode(String nodeId) {
    final node = _nodeById(nodeId);
    if (node == null) return;
    if (node.nodeType == NodeType.root) return;
    final owner = _owningIndexRoot(node);
    final deleteEntities = owner?.nodeType == NodeType.directoryIndexRoot;
    final entityIds = deleteEntities ? _entityIdsUnderNode(nodeId) : <String>[];
    final parentId = node.parentId;

    writeTransaction(() {
      // Mark before the cascade removes the deleted node's own dirty row.
      if (parentId != null) {
        markIndexNodePreviewDirty(parentId, reason: 'child_node_deleted');
      }
      database.db.execute('DELETE FROM index_nodes WHERE id = ?', [nodeId]);
      for (final entityId in entityIds) {
        final stillReferenced = database.db.select(
          'SELECT 1 FROM index_node_entities WHERE entity_id = ? LIMIT 1',
          [entityId],
        ).isNotEmpty;
        if (!stillReferenced) {
          database.db.execute('DELETE FROM entities WHERE id = ?', [entityId]);
        }
      }
    });
    if (owner == null || owner.id == nodeId) {
      rebuildIndexNodeStats();
    } else {
      rebuildIndexNodeStatsForNode(owner.id);
    }
  }

  bool willDeleteEntitiesWhenDeletingNode(String nodeId) {
    final node = _nodeById(nodeId);
    if (node == null) return false;
    if (_owningIndexRoot(node)?.nodeType != NodeType.directoryIndexRoot) {
      return false;
    }
    return database.db.select(
      '''
      WITH RECURSIVE subtree(id) AS (
        SELECT ?
        UNION ALL
        SELECT node.id FROM index_nodes node JOIN subtree ON node.parent_id = subtree.id
      )
      SELECT 1
      FROM index_node_entities link
      WHERE link.index_node_id IN (SELECT id FROM subtree)
        AND NOT EXISTS (
          SELECT 1 FROM index_node_entities external_link
          WHERE external_link.entity_id = link.entity_id
            AND external_link.index_node_id NOT IN (SELECT id FROM subtree)
        )
      LIMIT 1
      ''',
      [nodeId],
    ).isNotEmpty;
  }

  void unlinkEntityFromIndexNode({
    required String entityId,
    required String indexNodeId,
  }) {
    writeTransaction(() {
      database.db.execute(
        '''
        DELETE FROM index_node_entities
        WHERE entity_id = ? AND index_node_id = ?
        ''',
        [entityId, indexNodeId],
      );
      _touchIndexNode(indexNodeId);
      markIndexNodePreviewDirty(indexNodeId, reason: 'entity_unlinked');
    });
    rebuildIndexNodeStatsForNode(indexNodeId);
  }
}
