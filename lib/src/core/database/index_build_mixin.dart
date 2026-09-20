part of 'library_repository.dart';

/// Directory index lifecycle: create roots, reconcile scans, prune empties,
/// inspect and delete directory indexes.
mixin IndexBuildMixin on LibraryRepositoryBase {
  int commitInspectedPage({
    required LibraryBuildJob job,
    required List<LibraryBuildManifestItem> page,
    required String rootId,
    required Map<String, Entity> existing,
    required Map<int, (String, int, int, int, String?, int?)> detailsBySequence,
    required Map<int, IndexNode> nodesBySequence,
    required int indexedBefore,
    Map<int, String> inspectionErrors = const {},
  }) {
    final statements = <LibraryWriteStatement>[];
    final now = nowMillis();
    final touchedNodes = <String>{};
    final locations = <String, String>{};
    var completed = 0;
    for (final item in page) {
      final details = detailsBySequence[item.sequence];
      final node = nodesBySequence[item.sequence];
      if (details == null || node == null) {
        statements.add(LibraryWriteStatement(
          "UPDATE library_build_manifest SET write_state = 'failed', error = ? WHERE job_id = ? AND sequence = ?",
          [
            inspectionErrors[item.sequence] ?? '文件读取未返回结果',
            job.id,
            item.sequence
          ],
        ));
        continue;
      }
      final current = existing[item.sourcePath];
      final entityId = current?.id ?? newId();
      locations[entityId] = item.sourcePath;
      if (current == null) {
        statements.add(LibraryWriteStatement(
          '''
          INSERT INTO entities(
            id, path, local_path, name, format, media_type, hash,
            size, source_created_at_ms,
            source_modified_at_ms, duration_ms, directory_root_id,
            created_at, updated_at
          ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            entityId,
            _normalizeEntityPath(item.sourcePath),
            item.name,
            item.format,
            item.entityType.value,
            details.$1,
            details.$2,
            details.$3,
            details.$4,
            details.$6,
            rootId,
            now,
            now,
          ],
        ));
      } else if (!_isUnchangedIndexEntity(
        current,
        item: item,
        details: details,
        rootId: rootId,
      )) {
        final preserveThumbnail = (item.entityType == EntityType.image ||
                item.entityType == EntityType.video ||
                item.entityType == EntityType.document) &&
            current.entityType == item.entityType &&
            current.hash == details.$1;
        final status = preserveThumbnail
            ? current.thumbnailStatus.value
            : ThumbnailStatus.none.value;
        final preserveFields = current.thumbnailKey != null;
        statements.add(LibraryWriteStatement(
          '''
          UPDATE entities
          SET source_revision = source_revision + CASE WHEN hash != ? OR size != ? THEN 1 ELSE 0 END,
              path = ?, name = ?, format = ?, media_type = ?, hash = ?,
              size = ?, source_created_at_ms = ?, source_modified_at_ms = ?,
              duration_ms = ?, directory_root_id = ?, local_path = NULL,
              updated_at = ?
          WHERE id = ?
          ''',
          [
            details.$1,
            details.$2,
            _normalizeEntityPath(item.sourcePath),
            item.name,
            item.format,
            item.entityType.value,
            details.$1,
            details.$2,
            details.$3,
            details.$4,
            details.$6 ?? current.durationMs,
            rootId,
            now,
            entityId,
          ],
        ));
        statements.add(LibraryWriteStatement('''UPDATE entity_previews SET
          thumbnail_status=?, thumbnail_error=CASE WHEN ? THEN thumbnail_error ELSE NULL END,
          thumbnail_key=CASE WHEN ? THEN thumbnail_key ELSE NULL END,
          thumbnail_format=CASE WHEN ? THEN thumbnail_format ELSE NULL END,
          thumbnail_width=CASE WHEN ? THEN thumbnail_width ELSE NULL END,
          thumbnail_height=CASE WHEN ? THEN thumbnail_height ELSE NULL END,
          updated_at=? WHERE entity_id=?''', [
          status,
          status == ThumbnailStatus.failed.value,
          preserveFields,
          preserveFields,
          preserveFields,
          preserveFields,
          now,
          entityId
        ]));
      }
      statements.add(LibraryWriteStatement('''UPDATE entity_previews
        SET metadata_preview=COALESCE(?,metadata_preview) WHERE entity_id=?''',
          [details.$5, entityId]));
      statements.add(LibraryWriteStatement(
        '''
        INSERT OR IGNORE INTO index_node_entities(
          index_node_id, entity_id, sort_name, created_at
        ) SELECT ?, id, lower(name), ? FROM entity_details WHERE id = ?
        ''',
        [node.id, now, entityId],
      ));
      touchedNodes.add(node.id);
      statements.add(LibraryWriteStatement(
        "UPDATE library_build_manifest SET write_state = 'completed', error = NULL WHERE job_id = ? AND sequence = ?",
        [job.id, item.sequence],
      ));
      completed++;
    }
    for (final nodeId in touchedNodes) {
      statements.add(LibraryWriteStatement(
        'UPDATE index_nodes SET updated_at = ? WHERE id = ?',
        [now, nodeId],
      ));
    }
    statements.add(LibraryWriteStatement(
      'UPDATE library_build_jobs SET indexed_total = ?, index_cursor = ?, updated_at = ? WHERE id = ?',
      [indexedBefore + completed, page.last.sequence, now, job.id],
    ));
    if (completed > 0) {
      statements.add(LibraryWriteStatement(
        'UPDATE index_nodes SET is_staging = 0 WHERE id = ?',
        [rootId],
      ));
    }
    writeTransaction(() {
      final prepared = <String, PreparedStatement>{};
      try {
        for (final statement in statements) {
          prepared
              .putIfAbsent(
                  statement.sql, () => database.db.prepare(statement.sql))
              .execute(statement.parameters);
        }
        for (final nodeId in touchedNodes) {
          markIndexNodePreviewDirty(nodeId, reason: 'index_page_committed');
        }
        final rootLocator = _nodeById(rootId)?.sourcePath;
        for (final entry in locations.entries) {
          registerEntityLocation(database.db, entry.key, entry.value,
              rootLocator: rootLocator);
        }
      } finally {
        for (final statement in prepared.values) {
          statement.dispose();
        }
      }
    });
    return completed;
  }

  bool _isUnchangedIndexEntity(
    Entity entity, {
    required LibraryBuildManifestItem item,
    required (String, int, int, int, String?, int?) details,
    required String rootId,
  }) {
    return entity.path == _normalizeEntityPath(item.sourcePath) &&
        entity.hash == details.$1 &&
        entity.name == item.name &&
        (details.$5 == null || entity.contentExcerpt == details.$5) &&
        entity.entityType == item.entityType &&
        entity.format == item.format &&
        entity.size == details.$2 &&
        (details.$6 == null || entity.durationMs == details.$6) &&
        entity.directoryRootId == rootId &&
        entity.localPath == null;
  }

  IndexNode ensureDirectoryIndexRoot(
    String sourcePath, {
    bool staging = false,
    String? displayName,
  }) {
    final normalized = _normalizeSourcePath(sourcePath);
    final rootName = _indexNameForRoot(normalized, displayName: displayName);
    final root = _ensureGlobalRoot();
    final oldRoots = database.db.select(
      '''
      SELECT * FROM index_nodes
      WHERE node_type = ? AND source_path IS NOT NULL
      ''',
      [NodeType.directoryIndexRoot.value],
    );
    for (final row in oldRoots) {
      final oldPath = row['source_path'] as String;
      if (oldPath == normalized) {
        final existing = _nodeFromRow(row);
        if (displayName != null &&
            displayName.trim().isNotEmpty &&
            existing.name != rootName) {
          database.db.execute(
            'UPDATE index_nodes SET name = ?, updated_at = ? WHERE id = ?',
            [rootName, nowMillis(), existing.id],
          );
        }
        return _resetDirectoryIndexRootForRescan(
          existing,
          normalized,
          staging,
        );
      }
      // Overlapping roots are replaced only after the new scan completes.
      // Deleting here would destroy a working index when the new scan fails.
    }

    final now = nowMillis();
    final node = IndexNode(
      id: newId(),
      parentId: root.id,
      name: rootName,
      nodeType: NodeType.directoryIndexRoot,
      viewType: ViewType.tree,
      sourcePath: normalized,
      sortOrder: 0,
      createdAtMs: now,
      updatedAtMs: now,
      lastBuiltAtMs: now,
      isStaging: staging,
    );
    database.db.execute(
      '''
      INSERT INTO index_nodes
      (id, parent_id, name, node_type, view_type, source_path, sort_order, created_at, updated_at, last_built_at_ms, is_staging)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        node.id,
        node.parentId,
        node.name,
        node.nodeType.value,
        node.viewType.value,
        node.sourcePath,
        node.sortOrder,
        now,
        now,
        now,
        boolToInt(staging),
      ],
    );
    return node;
  }

  /// Commits a successfully rebuilt directory root by retiring older roots
  /// that overlap its source. This is intentionally separate from creation.
  void replaceOverlappingDirectoryIndexRoots({
    required String keepRootId,
    required String sourcePath,
  }) {
    final oldRootIds = directoryIndexRootIdsOverlapping(
      sourcePath,
      excludingRootId: keepRootId,
    );
    final thumbnailCandidates = _thumbnailKeysUnderNodes(oldRootIds);
    writeTransaction(() {
      database.db.execute('''
        WITH RECURSIVE subtree(id) AS (
          SELECT ?
          UNION ALL
          SELECT child.id FROM index_nodes child JOIN subtree ON child.parent_id = subtree.id
        )
        UPDATE entities SET directory_root_id = ?
        WHERE id IN (
          SELECT entity_id FROM index_node_entities
          WHERE index_node_id IN (SELECT id FROM subtree)
        )
      ''', [keepRootId, keepRootId]);
      if (oldRootIds.isNotEmpty) {
        final placeholders = List.filled(oldRootIds.length, '?').join(', ');
        database.db.execute(
          'UPDATE entities SET directory_root_id = NULL WHERE directory_root_id IN ($placeholders)',
          oldRootIds.toList(growable: false),
        );
        database.db.execute('''
          WITH RECURSIVE old_subtree(id) AS (
            SELECT id FROM index_nodes WHERE id IN ($placeholders)
            UNION ALL
            SELECT child.id
            FROM index_nodes child JOIN old_subtree ON child.parent_id = old_subtree.id
          )
          DELETE FROM entities
          WHERE id IN (
            SELECT entity_id FROM index_node_entities
            WHERE index_node_id IN (SELECT id FROM old_subtree)
          )
          AND NOT EXISTS (
            SELECT 1 FROM index_node_entities external_link
            WHERE external_link.entity_id = entities.id
              AND external_link.index_node_id NOT IN (SELECT id FROM old_subtree)
          )
        ''', oldRootIds.toList(growable: false));
      }
      database.db.execute(
        'UPDATE index_nodes SET is_staging = 0, updated_at = ? WHERE id = ?',
        [nowMillis(), keepRootId],
      );
      if (oldRootIds.isNotEmpty) {
        final placeholders = List.filled(oldRootIds.length, '?').join(', ');
        database.db.execute(
          'DELETE FROM index_nodes WHERE id IN ($placeholders)',
          oldRootIds.toList(growable: false),
        );
      }
    });
    _deleteUnreferencedThumbnailFiles(thumbnailCandidates);
    rebuildIndexNodeStats();
  }

  Set<String> directoryIndexRootIdsOverlapping(
    String sourcePath, {
    String? excludingRootId,
  }) {
    final normalized = _normalizeSourcePath(sourcePath);
    final rows = database.db.select('''
      SELECT id, source_path FROM index_nodes
      WHERE node_type = ? AND source_path IS NOT NULL
    ''', [NodeType.directoryIndexRoot.value]);
    return {
      for (final row in rows)
        if (row['id'] as String != excludingRootId &&
            _pathsOverlap(row['source_path'] as String, normalized))
          row['id'] as String,
    };
  }

  IndexNode? directoryIndexRootForSource(String sourcePath) {
    final rows = database.db.select(
      '''
      SELECT * FROM index_nodes
      WHERE node_type = ? AND source_path = ?
      LIMIT 1
      ''',
      [NodeType.directoryIndexRoot.value, _normalizeSourcePath(sourcePath)],
    );
    return rows.isEmpty ? null : _nodeFromRow(rows.first);
  }

  bool isDirectoryIndexRootEmpty(String rootId) {
    final rows = database.db.select('''
      WITH RECURSIVE subtree(id) AS (
        SELECT ?
        UNION ALL
        SELECT child.id FROM index_nodes child JOIN subtree ON child.parent_id = subtree.id
      )
      SELECT
        (SELECT COUNT(*) FROM index_nodes WHERE parent_id IN (SELECT id FROM subtree)) AS child_count,
        (SELECT COUNT(*) FROM index_node_entities WHERE index_node_id IN (SELECT id FROM subtree)) AS entity_count
    ''', [rootId]);
    if (rows.isEmpty) return true;
    return (rows.first['child_count'] as int) == 0 &&
        (rows.first['entity_count'] as int) == 0;
  }

  IndexNode _resetDirectoryIndexRootForRescan(
    IndexNode node,
    String normalizedPath,
    bool staging,
  ) {
    final now = nowMillis();
    // Rescans must be incremental. Clearing links and child nodes up front
    // makes the existing library disappear and defeats thumbnail reuse.
    database.db.execute(
      '''
      UPDATE index_nodes
      SET source_path = ?, is_staging = ?, updated_at = ?, last_built_at_ms = ?
      WHERE id = ?
      ''',
      [normalizedPath, boolToInt(staging), now, now, node.id],
    );
    return _nodeById(node.id)!;
  }

  /// Inspects a directory index deletion without changing source files.
  ///
  /// An entity's [Entity.directoryRootId] identifies the directory index that
  /// owns its database record. Links outside that directory tree are reported
  /// so callers can require an explicit force-delete confirmation.
  DirectoryIndexDeletionReport inspectDirectoryIndexDeletion(String rootId) {
    final root = _nodeById(rootId);
    if (root?.nodeType != NodeType.directoryIndexRoot) {
      throw ArgumentError.value(
        rootId,
        'rootId',
        'must identify a directory index root',
      );
    }
    final directoryRoot = root!;
    final entityCount = database.db.select(
      'SELECT COUNT(*) AS count FROM entity_details WHERE directory_root_id = ?',
      [rootId],
    ).single['count'] as int;
    final conflictCount = database.db.select(
      '''
      WITH RECURSIVE subtree(id) AS (
        SELECT ?
        UNION ALL
        SELECT child.id
        FROM index_nodes child
        JOIN subtree ON child.parent_id = subtree.id
      ), index_roots(node_id, root_id) AS (
        SELECT id, id
        FROM index_nodes
        WHERE node_type IN ('directory_index_root', 'category_index_root')
        UNION ALL
        SELECT child.id, index_roots.root_id
        FROM index_nodes child
        JOIN index_roots ON child.parent_id = index_roots.node_id
      )
      SELECT COUNT(DISTINCT e.id) AS count
      FROM entity_details e
      JOIN index_node_entities link ON link.entity_id = e.id
      WHERE e.directory_root_id = ?
        AND link.index_node_id NOT IN (SELECT id FROM subtree)
      ''',
      [rootId, rootId],
    ).single['count'] as int;
    final rows = database.db.select(
      '''
      WITH RECURSIVE subtree(id) AS (
        SELECT ?
        UNION ALL
        SELECT child.id FROM index_nodes child JOIN subtree ON child.parent_id = subtree.id
      ), index_roots(node_id, root_id) AS (
        SELECT id, id FROM index_nodes
        WHERE node_type IN ('directory_index_root', 'category_index_root')
        UNION ALL
        SELECT child.id, index_roots.root_id
        FROM index_nodes child JOIN index_roots ON child.parent_id = index_roots.node_id
      ), conflict_entities AS (
        SELECT DISTINCT e.id, e.name, e.path
        FROM entity_details e
        JOIN index_node_entities link ON link.entity_id = e.id
        WHERE e.directory_root_id = ?
          AND link.index_node_id NOT IN (SELECT id FROM subtree)
        ORDER BY e.name COLLATE NOCASE ASC
        LIMIT ?
      )
      SELECT e.id AS entity_id, e.name AS entity_name, e.path AS entity_path,
             root.name AS index_name
      FROM conflict_entities e
      JOIN index_node_entities link ON link.entity_id = e.id
      JOIN index_roots owner ON owner.node_id = link.index_node_id
      JOIN index_nodes root ON root.id = owner.root_id
      WHERE link.index_node_id NOT IN (SELECT id FROM subtree)
      ORDER BY e.name COLLATE NOCASE ASC, root.name COLLATE NOCASE ASC
      ''',
      [rootId, rootId, 20],
    );
    final conflicts = <String, DirectoryIndexDeletionConflict>{};
    for (final row in rows) {
      final entityId = row['entity_id'] as String;
      final existing = conflicts[entityId];
      final indexName = row['index_name'] as String;
      final indexNames = <String>[...?existing?.indexNames];
      if (!indexNames.contains(indexName)) indexNames.add(indexName);
      conflicts[entityId] = DirectoryIndexDeletionConflict(
        entityId: entityId,
        entityName: row['entity_name'] as String,
        entityPath: row['entity_path'] as String,
        indexNames: indexNames,
      );
    }
    return DirectoryIndexDeletionReport(
      root: directoryRoot,
      entityCount: entityCount,
      conflictCount: conflictCount,
      conflicts: conflicts.values.toList(growable: false),
    );
  }

  /// Deletes a directory index from Best Viewer only. Source files are never
  /// read, modified, or deleted by this operation.
  DirectoryIndexDeletionResult deleteDirectoryIndex(
    String rootId, {
    required bool force,
  }) {
    final report = inspectDirectoryIndexDeletion(rootId);
    if (report.hasConflicts && !force) {
      throw StateError('directory index has external entity references');
    }
    final thumbnailRows = database.db.select(
      '''
      SELECT thumbnail_key, thumbnail_format
      FROM entity_details
      WHERE directory_root_id = ?
        AND thumbnail_key IS NOT NULL
        AND thumbnail_format IS NOT NULL
      ''',
      [rootId],
    );
    final externallyAffectedNodes = database.db.select('''
      WITH RECURSIVE subtree(id) AS (
        SELECT ?
        UNION ALL
        SELECT child.id FROM index_nodes child JOIN subtree ON child.parent_id = subtree.id
      )
      SELECT DISTINCT link.index_node_id AS node_id
      FROM index_node_entities link
      JOIN entity_details entity ON entity.id = link.entity_id
      WHERE entity.directory_root_id = ?
        AND link.index_node_id NOT IN (SELECT id FROM subtree)
    ''', [rootId, rootId]);
    writeTransaction(() {
      for (final row in externallyAffectedNodes) {
        markIndexNodePreviewDirty(
          row['node_id'] as String,
          reason: 'directory_entities_deleted',
        );
      }
      database.db.execute(
        '''
        WITH RECURSIVE subtree(id) AS (
          SELECT ?
          UNION ALL
          SELECT child.id FROM index_nodes child JOIN subtree ON child.parent_id = subtree.id
        )
        DELETE FROM index_node_entities
        WHERE entity_id IN (
          SELECT id FROM entity_details WHERE directory_root_id = ?
        )
        AND index_node_id NOT IN (SELECT id FROM subtree)
        ''',
        [rootId, rootId],
      );
      database.db.execute(
        'DELETE FROM entities WHERE directory_root_id = ?',
        [rootId],
      );
      database.db.execute('DELETE FROM index_nodes WHERE id = ?', [rootId]);
    });
    _deleteUnreferencedThumbnailFiles(
      thumbnailRows.map((row) => row['thumbnail_key'] as String),
    );
    rebuildIndexNodeStats();
    return DirectoryIndexDeletionResult(deletedEntityCount: report.entityCount);
  }

  /// Reconciles a completed incremental directory scan. Existing results stay
  /// visible while scanning; only after the full source has been observed are
  /// missing paths unlinked from this directory tree. Entities referenced by a
  /// custom classifications remain intact.
  void reconcileDirectoryScan(
      {required String jobId, required String rootId, required String nodeId}) {
    writeTransaction(() {
      final valid = database.db.select('''SELECT 1 FROM library_build_jobs job
        WHERE job.id = ? AND job.manifest_complete = 1 AND job.index_root_id = ?
          AND COALESCE(job.scope_node_id, job.index_root_id) = ?
          AND EXISTS (SELECT 1 FROM index_nodes WHERE id = ?)
          AND NOT EXISTS (SELECT 1 FROM library_build_manifest manifest
            WHERE manifest.job_id = job.id AND manifest.write_state IN ('pending', 'processing', 'failed'))
      ''', [jobId, rootId, nodeId, nodeId]);
      if (valid.isEmpty) throw StateError('对账范围未完整提交或已失效');
      database.db.execute(
          'CREATE TEMP TABLE IF NOT EXISTS stale_scan_entities(id TEXT PRIMARY KEY)');
      database.db.execute('DELETE FROM stale_scan_entities');
      database.db.execute('''
        WITH RECURSIVE subtree(id) AS (
          SELECT ? UNION ALL SELECT child.id FROM index_nodes child
          JOIN subtree parent ON child.parent_id = parent.id
        )
        INSERT OR IGNORE INTO stale_scan_entities(id)
        SELECT entity.id FROM entity_details entity JOIN index_node_entities link
          ON link.entity_id = entity.id
        WHERE link.index_node_id IN (SELECT id FROM subtree)
          AND entity.directory_root_id = ?
          AND NOT EXISTS (SELECT 1 FROM library_build_manifest manifest
            WHERE manifest.job_id = ? AND manifest.source_path = entity.path)
      ''', [nodeId, rootId, jobId]);
      database.db.execute('''
        WITH RECURSIVE subtree(id) AS (
          SELECT ? UNION ALL SELECT child.id FROM index_nodes child
          JOIN subtree parent ON child.parent_id = parent.id
        )
        DELETE FROM index_node_entities WHERE index_node_id IN (SELECT id FROM subtree)
          AND entity_id IN (SELECT id FROM stale_scan_entities)
      ''', [nodeId]);
      database.db.execute('''DELETE FROM entities
        WHERE id IN (SELECT id FROM stale_scan_entities)
          AND NOT EXISTS (SELECT 1 FROM index_node_entities link WHERE link.entity_id = entities.id)
      ''');
      database.db.execute('DELETE FROM stale_scan_entities');
    });
    pruneEmptyDirectoryNodes(nodeId);
  }

  void pruneEmptyDirectoryNodes(String rootId) {
    // Repeat because deleting an empty leaf can make its parent empty.
    while (true) {
      database.db.execute(
        '''
        WITH RECURSIVE subtree(id) AS (
          SELECT ?
          UNION ALL
          SELECT child.id FROM index_nodes child JOIN subtree ON child.parent_id = subtree.id
        )
        DELETE FROM index_nodes
        WHERE id IN (SELECT id FROM subtree)
          AND id <> ?
          AND node_type = ?
          AND NOT EXISTS (SELECT 1 FROM index_node_entities link WHERE link.index_node_id = index_nodes.id)
          AND NOT EXISTS (SELECT 1 FROM index_nodes child WHERE child.parent_id = index_nodes.id)
        ''',
        [rootId, rootId, NodeType.folder.value],
      );
      final changed =
          database.db.select('SELECT changes() AS value').first['value'] as int;
      if (changed == 0) return;
    }
  }
}
