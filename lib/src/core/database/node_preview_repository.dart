part of 'library_repository.dart';

/// Node preview cache: representative tiles, composite assets, overrides,
/// and the bottom-up rebuild chain that propagates thumbnail changes.
mixin NodePreviewRepositoryMixin on LibraryRepositoryBase {
  /// Builds render descriptions for a page of index nodes in two batched
  /// queries. A parent only receives each child's representative tile, never
  /// the child's full mosaic, so thumbnail composition cannot recurse.
  Map<String, IndexNodePreview> listIndexNodePreviews(
    Iterable<String> nodeIds,
  ) {
    final ids = nodeIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const <String, IndexNodePreview>{};
    final placeholders = List<String>.filled(ids.length, '?').join(', ');
    final childRows = database.db.select(
      '''
      SELECT id, parent_id, name, node_type, view_type, source_path,
             preview_json, sort_order, created_at, updated_at, last_built_at_ms
      FROM index_nodes
      WHERE parent_id IN ($placeholders)
      ORDER BY parent_id, name COLLATE NOCASE, id
      ''',
      ids,
    );
    final childrenByParent = <String, List<IndexNode>>{};
    final childIds = <String>{};
    for (final row in childRows) {
      final child = _nodeFromRow(row);
      childrenByParent
          .putIfAbsent(child.parentId!, () => <IndexNode>[])
          .add(child);
      childIds.add(child.id);
    }

    final entityNodeIds = {...ids, ...childIds}.toList(growable: false);
    final entityPlaceholders =
        List<String>.filled(entityNodeIds.length, '?').join(', ');
    final entityRows = database.db.select(
      '''
      SELECT link.index_node_id AS preview_node_id, entity.*
      FROM index_node_entities link
      JOIN entities entity ON entity.id = link.entity_id
      WHERE link.index_node_id IN ($entityPlaceholders)
        AND entity.archived = 0
      ORDER BY link.index_node_id, entity.name COLLATE NOCASE, entity.id
      ''',
      entityNodeIds,
    );
    final entitiesByNode = <String, List<EntityListItem>>{};
    for (final row in entityRows) {
      final nodeId = row['preview_node_id'] as String;
      entitiesByNode.putIfAbsent(nodeId, () => <EntityListItem>[]).add(
            _listItemFromRow(row, thumbnailStore),
          );
    }

    final previews = <String, IndexNodePreview>{};
    final overrideRows = database.db.select(
      'SELECT node_id, items_json FROM node_preview_overrides WHERE node_id IN ($placeholders)',
      ids,
    );
    final overrides = <String, List<IndexNodePreviewTile>>{
      for (final row in overrideRows)
        row['node_id'] as String:
            _previewOverrideTiles(row['items_json'] as String),
    };
    final overrideEntityIds = overrides.values
        .expand((tiles) => tiles)
        .map((tile) => tile.entityId)
        .whereType<String>()
        .toSet()
        .toList(growable: false);
    final overrideEntities = <String, EntityListItem>{};
    if (overrideEntityIds.isNotEmpty) {
      final entityIdPlaceholders =
          List.filled(overrideEntityIds.length, '?').join(', ');
      final rows = database.db.select(
        'SELECT * FROM entities WHERE id IN ($entityIdPlaceholders)',
        overrideEntityIds,
      );
      for (final row in rows) {
        final entity = _listItemFromRow(row, thumbnailStore);
        overrideEntities[entity.id] = entity;
      }
    }
    final overrideNodeIds = overrides.values
        .expand((tiles) => tiles)
        .map((tile) => tile.nodeId)
        .whereType<String>()
        .toSet()
        .toList(growable: false);
    final overrideNodes = <String, IndexNode>{};
    if (overrideNodeIds.isNotEmpty) {
      final nodeIdPlaceholders =
          List.filled(overrideNodeIds.length, '?').join(', ');
      final rows = database.db.select(
        'SELECT * FROM index_nodes WHERE id IN ($nodeIdPlaceholders)',
        overrideNodeIds,
      );
      for (final row in rows) {
        final node = _nodeFromRow(row);
        overrideNodes[node.id] = node;
      }
    }
    for (final nodeId in ids) {
      final override = overrides[nodeId];
      if (override != null && override.isNotEmpty) {
        previews[nodeId] = _buildOverrideIndexNodePreview(
          nodeId: nodeId,
          tiles: override
              .map((tile) => _resolvePreviewOverrideTile(
                    tile,
                    overrideEntities,
                    overrideNodes,
                    thumbnailStore,
                  ))
              .toList(growable: false),
        );
        continue;
      }
      final children = childrenByParent[nodeId] ?? const <IndexNode>[];
      final childTiles = children
          .map(
            (child) =>
                _representativePreviewTileFromCache(child, thumbnailStore) ??
                _representativePreviewTile(
                  child,
                  entitiesByNode[child.id] ?? const <EntityListItem>[],
                ),
          )
          .toList(growable: false);
      previews[nodeId] = _buildIndexNodePreview(
        nodeId: nodeId,
        childTiles: childTiles,
        entities: entitiesByNode[nodeId] ?? const <EntityListItem>[],
      );
    }
    final assetRows = database.db.select(
      'SELECT node_id, asset_key, format, width, height FROM node_preview_assets WHERE node_id IN ($placeholders)',
      ids,
    );
    final assets = <String, ({String path, double aspectRatio})>{};
    for (final row in assetRows) {
      final nodeId = row['node_id'] as String;
      final assetKey = row['asset_key'] as String;
      final format = row['format'] as String;
      final path = _nodePreviewAssetPath(assetKey, format);
      final width = row['width'] as int;
      final height = row['height'] as int;
      // The database read path must not synchronously touch the filesystem.
      // Image.file reports a missing or stale asset asynchronously in the UI.
      if (width > 0 && height > 0) {
        assets[nodeId] = (path: path, aspectRatio: width / height);
      }
    }
    return Map<String, IndexNodePreview>.unmodifiable({
      for (final entry in previews.entries)
        entry.key: _withNodePreviewAsset(entry.value, assets[entry.key]),
    });
  }

  String nodePreviewAssetPath(String assetKey, String format) =>
      _nodePreviewAssetPath(assetKey, format);

  List<NodePreviewBuildInput> prepareNodePreviewBuilds(
          Iterable<String> nodeIds) =>
      writeTransaction(() {
        final ids = nodeIds.toList(growable: false);
        for (final id in ids) {
          rebuildIndexNodePreviewCacheForNode(id);
        }
        final previews = listIndexNodePreviews(ids);
        final inputs = <NodePreviewBuildInput>[];
        for (final preview in previews.values) {
          if (_nodeById(preview.nodeId) == null) continue;
          database.db.execute('''
        INSERT INTO node_preview_versions(node_id, publication) VALUES (?, 1)
        ON CONFLICT(node_id) DO UPDATE SET publication = publication + 1
      ''', [preview.nodeId]);
          final row = database.db.select(
              'SELECT revision, publication FROM node_preview_versions WHERE node_id = ?',
              [preview.nodeId]).single;
          final revision = row['revision'] as int;
          final publication = row['publication'] as int;
          final key =
              'node_v7_${sha256.convert(utf8.encode('${preview.nodeId}|$revision|$publication|webp80'))}';
          _retirePreviewAsset('node', key, 'webp');
          inputs.add(NodePreviewBuildInput(
              NodePreviewTicket(
                  nodeId: preview.nodeId,
                  revision: revision,
                  publication: publication,
                  assetKey: key),
              preview));
        }
        return List.unmodifiable(inputs);
      });

  bool publishNodePreview(
    NodePreviewTicket ticket, {
    String? signature,
    int? width,
    int? height,
  }) =>
      writeTransaction(() {
        final current = database.db.select('''
      SELECT 1 FROM node_preview_versions WHERE node_id = ? AND revision = ? AND publication = ?
    ''', [ticket.nodeId, ticket.revision, ticket.publication]);
        if (current.isEmpty) return false;
        final previous = database.db.select(
            'SELECT asset_key, format FROM node_preview_assets WHERE node_id = ?',
            [ticket.nodeId]);
        if (signature == null) {
          database.db.execute(
              'DELETE FROM node_preview_assets WHERE node_id = ?',
              [ticket.nodeId]);
        } else {
          if ((width ?? 0) <= 0 ||
              (height ?? 0) <= 0 ||
              File(_nodePreviewAssetPath(ticket.assetKey, 'webp'))
                      .lengthSync() <=
                  0) {
            throw StateError('Node preview file is not ready to publish');
          }
          database.db.execute('''
        INSERT INTO node_preview_assets(node_id, signature, asset_key, format, width, height, updated_at)
        VALUES (?, ?, ?, 'webp', ?, ?, ?)
        ON CONFLICT(node_id) DO UPDATE SET signature = excluded.signature,
          asset_key = excluded.asset_key, format = excluded.format, width = excluded.width,
          height = excluded.height, updated_at = excluded.updated_at
      ''', [
            ticket.nodeId,
            signature,
            ticket.assetKey,
            width,
            height,
            nowMillis()
          ]);
          database.db.execute(
              "DELETE FROM retired_preview_assets WHERE kind = 'node' AND asset_key = ?",
              [ticket.assetKey]);
        }
        database.db.execute(
            'DELETE FROM node_preview_dirty WHERE node_id = ? AND revision = ?',
            [ticket.nodeId, ticket.revision]);
        for (final row in previous) {
          if (row['asset_key'] != ticket.assetKey) {
            _retirePreviewAsset(
                'node', row['asset_key'] as String, row['format'] as String);
          }
        }
        return true;
      });

  String _nodePreviewAssetPath(String assetKey, String format) =>
      nodePreviewAssetPathFor(storageDirectoryPath, assetKey, format);

  /// Rebuilds only one representative tile from its direct content and the
  /// already-cached representatives of its children. Used to propagate a
  /// local subtree rebuild through its ancestor chain without rescanning the
  /// entire directory index.
  void rebuildIndexNodePreviewCacheForNode(String nodeId) {
    final node = _nodeById(nodeId);
    if (node == null) return;
    final overrideRepresentative = _overrideRepresentativeTile(node);
    if (overrideRepresentative != null) {
      database.db.execute(
        'UPDATE index_nodes SET preview_json = ?, updated_at = ? WHERE id = ?',
        [_previewTileToJson(overrideRepresentative), nowMillis(), nodeId],
      );
      return;
    }
    final childRows = database.db.select(
      'SELECT * FROM index_nodes WHERE parent_id = ? ORDER BY name COLLATE NOCASE, id',
      [nodeId],
    );
    final childTiles = childRows
        .map(_nodeFromRow)
        .map(_representativePreviewTileFromCache)
        .whereType<IndexNodePreviewTile>()
        .toList(growable: false);
    final entityRows = database.db.select('''
      SELECT entity.*
      FROM index_node_entities link
      JOIN entities entity ON entity.id = link.entity_id
      WHERE link.index_node_id = ? AND entity.archived = 0
      ORDER BY entity.name COLLATE NOCASE, entity.id
    ''', [nodeId]);
    final entities = entityRows
        .map((row) => _listItemFromRow(row, thumbnailStore))
        .toList(growable: false);
    final representative =
        _selectRepresentativePreviewTile(node, entities, childTiles);
    database.db.execute(
      'UPDATE index_nodes SET preview_json = ?, updated_at = ? WHERE id = ?',
      [_previewTileToJson(representative), nowMillis(), nodeId],
    );
  }

  /// Rebuilds only a node and its ancestors. This is the cheap path for a
  /// custom preview override or a single entity thumbnail change; descendants
  /// already have valid representative caches and do not need to be scanned.

  IndexNode? owningIndexRootForNode(String nodeId) {
    final node = _nodeById(nodeId);
    return node == null ? null : _owningIndexRoot(node);
  }

  List<IndexNode> listIndexNodeAncestors(String nodeId) {
    final rows = database.db.select('''
      WITH RECURSIVE ancestors(id, parent_id, depth) AS (
        SELECT id, parent_id, 0 FROM index_nodes WHERE id = ?
        UNION ALL
        SELECT parent.id, parent.parent_id, ancestors.depth + 1
        FROM index_nodes parent JOIN ancestors ON ancestors.parent_id = parent.id
      )
      SELECT node.* FROM ancestors
      JOIN index_nodes node ON node.id = ancestors.id
      WHERE node.node_type <> ?
      ORDER BY ancestors.depth ASC
    ''', [nodeId, NodeType.root.value]);
    return rows.map(_nodeFromRow).toList(growable: false);
  }

  Set<String> listIndexNodeDescendantIds(String nodeId) {
    final rows = database.db.select('''
      WITH RECURSIVE subtree(id) AS (
        SELECT id FROM index_nodes WHERE id = ?
        UNION ALL
        SELECT child.id
        FROM index_nodes child
        JOIN subtree ON child.parent_id = subtree.id
      )
      SELECT id FROM subtree
    ''', [nodeId]);
    return rows.map((row) => row['id'] as String).toSet();
  }

  /// Paged recursive candidates for the node-preview picker. The query keeps
  /// the current node out of the node results while retaining entities linked
  /// anywhere in its subtree.
  NodePreviewCandidatePage listNodePreviewCandidates(
    String nodeId, {
    String query = '',
    int offset = 0,
    int limit = 80,
  }) {
    final normalizedQuery = query.trim().toLowerCase();
    final safeOffset = offset < 0 ? 0 : offset;
    final safeLimit = limit.clamp(1, 160).toInt();
    final rows = database.db.select(
      '''
      WITH RECURSIVE subtree(id, path) AS (
        SELECT id, '' FROM index_nodes WHERE id = ?
        UNION ALL
        SELECT child.id,
               CASE WHEN subtree.path = '' THEN child.name
                    ELSE subtree.path || ' / ' || child.name END
        FROM index_nodes child
        JOIN subtree ON child.parent_id = subtree.id
      ), candidates AS (
        SELECT DISTINCT
          'entity' AS candidate_type,
          e.id AS candidate_id,
          e.name AS title,
          e.media_type AS media_type,
          e.thumbnail_key AS thumbnail_key,
          e.thumbnail_format AS thumbnail_format,
          e.thumbnail_width AS thumbnail_width,
          e.thumbnail_height AS thumbnail_height
        FROM index_node_entities link
        JOIN subtree ON subtree.id = link.index_node_id
        JOIN entities e ON e.id = link.entity_id
        WHERE e.archived = 0
        UNION ALL
        SELECT
          'node' AS candidate_type,
          subtree.id AS candidate_id,
          subtree.path AS title,
          NULL AS media_type,
          NULL AS thumbnail_key,
          NULL AS thumbnail_format,
          NULL AS thumbnail_width,
          NULL AS thumbnail_height
        FROM subtree
        WHERE subtree.id != ?
      )
      SELECT * FROM candidates
      WHERE lower(title) LIKE ?
      ORDER BY CASE WHEN thumbnail_key IS NOT NULL THEN 0 ELSE 1 END,
               candidate_type ASC,
               title COLLATE NOCASE ASC,
               candidate_id ASC
      LIMIT ? OFFSET ?
      ''',
      [nodeId, nodeId, '%$normalizedQuery%', safeLimit + 1, safeOffset],
    );
    final hasMore = rows.length > safeLimit;
    final visible = hasMore ? rows.sublist(0, safeLimit) : rows;
    return NodePreviewCandidatePage(
      items: visible.map((row) {
        final candidateType = row['candidate_type'] as String;
        final key = row['thumbnail_key'] as String?;
        final format = row['thumbnail_format'] as String?;
        final width = row['thumbnail_width'] as int?;
        final height = row['thumbnail_height'] as int?;
        final entityType = candidateType == 'entity'
            ? EntityType.fromValue(row['media_type'] as String)
            : null;
        final kind = switch (entityType) {
          EntityType.image ||
          EntityType.video when key != null && format != null =>
            IndexNodePreviewTileKind.visual,
          EntityType.audio => IndexNodePreviewTileKind.audio,
          EntityType.text ||
          EntityType.document =>
            IndexNodePreviewTileKind.document,
          _ => IndexNodePreviewTileKind.node,
        };
        return NodePreviewCandidate(
          kind: kind,
          title: row['title'] as String,
          entityId:
              candidateType == 'entity' ? row['candidate_id'] as String : null,
          nodeId:
              candidateType == 'node' ? row['candidate_id'] as String : null,
          thumbnailKey: key,
          thumbnailFormat: format,
          thumbnailPath: key != null && format != null
              ? thumbnailStore.pathFor(key, format)
              : null,
          aspectRatio: width != null && height != null && height > 0
              ? width / height
              : 1,
        );
      }).toList(growable: false),
      hasMore: hasMore,
    );
  }

  String? getNodePreviewOverride(String nodeId) {
    final rows = database.db.select(
      'SELECT items_json FROM node_preview_overrides WHERE node_id = ? LIMIT 1',
      [nodeId],
    );
    return rows.isEmpty ? null : rows.first['items_json'] as String;
  }

  void setNodePreviewOverride(String nodeId, String itemsJson) {
    writeTransaction(() {
      database.db.execute(
        '''
        INSERT INTO node_preview_overrides(node_id, items_json, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(node_id) DO UPDATE SET
          items_json = excluded.items_json,
          updated_at = excluded.updated_at
        ''',
        [nodeId, itemsJson, nowMillis()],
      );
      markIndexNodePreviewDirty(nodeId, reason: 'preview_override_set');
    });
  }

  void clearNodePreviewOverride(String nodeId) {
    writeTransaction(() {
      database.db.execute(
        'DELETE FROM node_preview_overrides WHERE node_id = ?',
        [nodeId],
      );
      markIndexNodePreviewDirty(nodeId, reason: 'preview_override_cleared');
    });
  }

  IndexNodePreviewTile? _overrideRepresentativeTile(IndexNode node) {
    final override = getNodePreviewOverride(node.id);
    if (override == null || override.isEmpty) return null;
    final tiles = _previewOverrideTiles(override);
    if (tiles.isEmpty) return null;
    for (final tile in tiles) {
      if (tile.kind == IndexNodePreviewTileKind.visual) return tile;
      if (tile.nodeId != null) {
        final child = _nodeById(tile.nodeId!);
        final representative = child == null
            ? null
            : _representativePreviewTileFromCache(child, thumbnailStore);
        if (representative != null) return representative;
      }
    }
    return tiles.first;
  }
}
