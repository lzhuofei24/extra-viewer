part of 'library_repository.dart';

/// Shared infrastructure for all repository mixins. Holds the database
/// connection, thumbnail store, transaction machinery, and
/// cross-cutting helpers used by every domain mixin.
class LibraryRepositoryBase {
  LibraryRepositoryBase(this.database)
      : thumbnailStore = ThumbnailStore(database.storageDirectoryPath);

  final AppDatabase database;
  final ThumbnailStore thumbnailStore;
  bool deferStatistics = false;
  String get storageDirectoryPath => database.storageDirectoryPath;

  int _transactionSequence = 0;
  void _retirePreviewAsset(String kind, String key, String format) {
    database.db.execute('''
      INSERT INTO retired_preview_assets(kind, asset_key, format, not_before)
      VALUES (?, ?, ?, ?) ON CONFLICT(kind, asset_key) DO UPDATE SET not_before = excluded.not_before
    ''', [
      kind,
      key,
      format,
      nowMillis() + const Duration(days: 1).inMilliseconds
    ]);
  }

  int collectRetiredPreviewAssets({int limit = 100}) {
    final rows = database.db.select(
        'SELECT * FROM retired_preview_assets WHERE not_before <= ? ORDER BY not_before LIMIT ?',
        [nowMillis(), limit.clamp(1, 1000)]);
    var removed = 0;
    for (final row in rows) {
      final key = row['asset_key'] as String;
      final format = row['format'] as String;
      final kind = row['kind'] as String;
      if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(key) ||
          !RegExp(r'^[a-zA-Z0-9]+$').hasMatch(format)) {
        continue;
      }
      final referenced = kind == 'entity'
          ? database.db.select(
              'SELECT 1 FROM entity_details WHERE thumbnail_key = ? LIMIT 1',
              [key]).isNotEmpty
          : database.db.select(
              'SELECT 1 FROM node_preview_assets WHERE asset_key = ? LIMIT 1',
              [key]).isNotEmpty;
      if (referenced) continue;
      final file = kind == 'entity'
          ? thumbnailStore.fileFor(key, format)
          : File(nodePreviewAssetPathFor(storageDirectoryPath, key, format));
      try {
        if (file.existsSync()) file.deleteSync();
        final partial = File('${file.path}.tmp');
        if (partial.existsSync()) partial.deleteSync();
        if (kind == 'node') {
          final portrait = File(portraitNodePreviewAssetPathFor(
            storageDirectoryPath,
            key,
            format,
          ));
          if (portrait.existsSync()) portrait.deleteSync();
          final portraitPartial = File('${portrait.path}.tmp');
          if (portraitPartial.existsSync()) portraitPartial.deleteSync();
        }
      } on FileSystemException {
        continue;
      }
      writeTransaction(() {
        database.db
            .execute('DELETE FROM preview_assets WHERE asset_key=?', [key]);
        if (kind == 'entity') {
          database.db.execute(
              'DELETE FROM thumbnail_assets WHERE asset_key = ?', [key]);
        }
        database.db.execute(
            'DELETE FROM retired_preview_assets WHERE kind = ? AND asset_key = ?',
            [kind, key]);
      });
      removed++;
    }
    return removed;
  }

  var _indexStatsBatchDepth = 0;
  var _indexStatsDirty = false;

  /// Executes inside DatabaseHost's single writer, including bookkeeping.
  void _enqueueBackgroundWrite(
    String operation,
    String sql, [
    List<Object?> parameters = const <Object?>[],
  ]) {
    database.db.execute(sql, parameters);
  }

  void _evaluateAccessRules(String entityId, int openedAt) {
    final entities = database.db.select(
      'SELECT * FROM entities WHERE id = ? AND archived = 0 LIMIT 1',
      [entityId],
    );
    if (entities.isEmpty) return;
    final entity = entities.single;
    final rules = database.db.select('SELECT * FROM index_rules');
    for (final rule in rules) {
      final types = (jsonDecode(rule['entity_types_json'] as String) as List)
          .cast<String>();
      final extensions = (jsonDecode(rule['extensions_json'] as String) as List)
          .cast<String>();
      final mediaType = entity['media_type'] as String;
      final format = (entity['format'] as String).toLowerCase();
      final size = entity['size'] as int;
      final minSize = rule['min_size'] as int?;
      final maxSize = rule['max_size'] as int?;
      final matches = (types.isEmpty || types.contains(mediaType)) &&
          (extensions.isEmpty || extensions.contains(format)) &&
          (minSize == null || size >= minSize) &&
          (maxSize == null || size <= maxSize);
      final ruleId = rule['node_id'] as String;
      if (!matches) {
        database.db.execute(
          'DELETE FROM rule_access_items WHERE rule_id = ? AND entity_id = ?',
          [ruleId, entityId],
        );
        continue;
      }
      database.db.execute('''
        INSERT INTO rule_access_items(rule_id, entity_id, matched_at)
        VALUES (?, ?, ?)
        ON CONFLICT(rule_id, entity_id)
        DO UPDATE SET matched_at = excluded.matched_at
      ''', [ruleId, entityId, openedAt]);
      final sort = RuleSortMode.values.byName(rule['default_sort'] as String);
      final limit = (rule['max_results'] as int).clamp(1, 1000);
      final count = database.db.select(
        'SELECT COUNT(*) AS count FROM rule_access_items WHERE rule_id = ?',
        [ruleId],
      ).single['count'] as int;
      if (count <= limit) continue;
      database.db.execute('''
        DELETE FROM rule_access_items
        WHERE rule_id = ? AND entity_id NOT IN (
          SELECT item.entity_id
          FROM rule_access_items item
          JOIN entities e ON e.id = item.entity_id
          WHERE item.rule_id = ? AND e.archived = 0
          ORDER BY ${_accessRuleOrderBy(sort)}
          LIMIT ?
        )
      ''', [ruleId, ruleId, limit]);
    }
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
      (id, name, node_type, sort_order, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ''',
      [
        node.id,
        node.name,
        node.nodeType.value,
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
        'SELECT id FROM entity_details WHERE id IN ($placeholders)',
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
    if (node.nodeType == NodeType.ruleIndexRoot ||
        node.nodeType == NodeType.ruleNode) {
      throw ArgumentError.value(
        nodeId,
        argumentName,
        'Rule nodes cannot contain static entity references',
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

  void _requireValidParentForNodeType({
    required NodeType nodeType,
    required String? parentId,
  }) {
    final requiredRootType = switch (nodeType) {
      NodeType.folder => NodeType.directoryIndexRoot,
      NodeType.customNode => NodeType.customIndexRoot,
      NodeType.ruleNode => NodeType.ruleIndexRoot,
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
      NodeType.ruleIndexRoot ||
      NodeType.folder ||
      NodeType.customNode ||
      NodeType.ruleNode =>
        ViewType.tree,
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
        database.db.select('SELECT * FROM entity_details WHERE id = ?', [id]);
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
    _rebuildIndexNodeStatsNow();
  }

  void _rebuildIndexNodeStatsNow() {
    if (deferStatistics) return;
    writeTransaction(() => refreshDirtyStatistics(database.db));
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
  }) {
    writeTransaction(() {
      final rows = database.db.select('''
        WITH RECURSIVE dependencies(source_id, dependent_id) AS (
          SELECT id, parent_id FROM index_nodes WHERE parent_id IS NOT NULL
          UNION
          SELECT target_node_id, node_id FROM node_preview_override_items WHERE target_node_id IS NOT NULL
        ), descendants(id) AS (
          SELECT id FROM index_nodes WHERE id = ?
          UNION SELECT node.id FROM index_nodes node JOIN descendants ON node.parent_id = descendants.id
          WHERE ?
        ), affected(id) AS (
          SELECT id FROM descendants
          UNION SELECT dependency.dependent_id FROM dependencies dependency
            JOIN affected ON dependency.source_id = affected.id
        ) SELECT id FROM affected WHERE id IN (SELECT id FROM index_nodes)
      ''', [nodeId, scope == IndexPreviewRebuildScope.subtree ? 1 : 0]);
      final version = database.db.prepare('''
        INSERT INTO node_preview_versions(node_id, revision) VALUES (?, 1)
        ON CONFLICT(node_id) DO UPDATE SET revision = revision + 1
      ''');
      final dirty = database.db.prepare('''
        INSERT INTO node_preview_dirty(node_id, revision, reason, updated_at)
        SELECT node_id, revision, ?, ? FROM node_preview_versions WHERE node_id = ?
        ON CONFLICT(node_id) DO UPDATE SET revision = excluded.revision,
          reason = excluded.reason, updated_at = excluded.updated_at
      ''');
      try {
        for (final row in rows) {
          version.execute([row['id']]);
          dirty.execute([reason, nowMillis(), row['id']]);
        }
      } finally {
        version.dispose();
        dirty.dispose();
      }
    });
  }

  void clearIndexNodePreviewDirty(
    String nodeId, {
    IndexPreviewRebuildScope scope = IndexPreviewRebuildScope.node,
  }) {
    writeTransaction(() {
      database.db.execute('''
        WITH RECURSIVE descendants(id) AS (
          SELECT id FROM index_nodes WHERE id = ?
          UNION ALL
          SELECT node.id FROM index_nodes node JOIN descendants
            ON node.parent_id = descendants.id
          WHERE ?
        ), ancestors(id) AS (
          SELECT id FROM index_nodes WHERE id = ?
          UNION ALL
          SELECT parent.parent_id FROM index_nodes parent JOIN ancestors
            ON parent.id = ancestors.id
          WHERE parent.parent_id IS NOT NULL
        ), affected(id) AS (
          SELECT id FROM descendants
          UNION SELECT id FROM ancestors
        )
        DELETE FROM node_preview_dirty
        WHERE node_id IN (SELECT id FROM affected)
      ''', [nodeId, scope == IndexPreviewRebuildScope.subtree ? 1 : 0, nodeId]);
    });
  }

  // --- Thumbnail file cleanup (called from IndexBuildMixin) ----------------
  void _recordTaskAffected(String jobId, String nodeId) {
    database.db.execute('''WITH RECURSIVE ancestors(id) AS (
      SELECT ? UNION SELECT n.parent_id FROM index_nodes n JOIN ancestors a ON n.id=a.id WHERE n.parent_id IS NOT NULL)
      INSERT OR REPLACE INTO library_task_dirty(job_id,node_id,revision)
      SELECT ?,node_id,revision FROM node_preview_dirty WHERE node_id IN (SELECT id FROM ancestors)''',
        [nodeId, jobId]);
  }

  void _deleteUnreferencedThumbnailFiles(Iterable<String> keys) {
    for (final key in keys.toSet()) {
      final referenced = database.db.select(
        'SELECT thumbnail_format FROM entity_details WHERE thumbnail_key = ? LIMIT 1',
        [key],
      );
      if (referenced.isNotEmpty) continue;
      final assets = database.db.select(
        'SELECT format FROM thumbnail_assets WHERE asset_key = ? LIMIT 1',
        [key],
      );
      final format = assets.isNotEmpty
          ? assets.first['format'] as String
          : const ['webp', 'png', 'jpg', 'jpeg'].firstWhere(
              (format) => thumbnailStore.fileFor(key, format).existsSync(),
              orElse: () => 'webp',
            );
      _retirePreviewAsset('entity', key, format);
    }
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
      JOIN entity_details entity ON entity.id = link.entity_id
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
