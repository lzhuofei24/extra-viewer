import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../domain/models.dart';
import '../formats/thumbnail_spec.dart';
import '../thumbnails/thumbnail_store.dart';
import '../utils/ids.dart';
import 'app_database.dart';

class LibraryRepository {
  LibraryRepository(this.database)
      : thumbnailStore = ThumbnailStore(database.storageDirectoryPath);

  final AppDatabase database;
  final ThumbnailStore thumbnailStore;
  int _transactionSequence = 0;

  IndexBuildJob beginIndexJob(
    String sourcePath, {
    bool restart = false,
    String? targetNodeId,
  }) {
    final normalizedPath = _normalizeSourcePath(sourcePath);
    if (!restart) {
      final existing = database.db.select(
        '''
        SELECT * FROM index_jobs
        WHERE source_path = ? AND status IN ('pending', 'running', 'paused', 'failed')
        ORDER BY updated_at DESC
        LIMIT 1
        ''',
        [normalizedPath],
      );
      if (existing.isNotEmpty) {
        final job = _indexBuildJobFromRow(existing.first);
        updateIndexJob(
          job.id,
          status: IndexJobStatus.running,
          error: null,
          clearError: true,
        );
        return getIndexJob(job.id)!;
      }
    }
    final now = nowMillis();
    final job = IndexBuildJob(
      id: newId(),
      sourcePath: normalizedPath,
      status: IndexJobStatus.running,
      phase: IndexJobPhase.discovering,
      discovered: 0,
      total: 0,
      processed: 0,
      previewTotal: 0,
      previewProcessed: 0,
      scanCompleted: false,
      targetNodeId: targetNodeId,
      createdAtMs: now,
      updatedAtMs: now,
    );
    database.db.execute(
      '''
      INSERT INTO index_jobs (
        id, source_path, status, phase, discovered, total, processed,
        preview_total, preview_processed, scan_completed, target_node_id,
        staging_root_id, created_at, updated_at
      ) VALUES (?, ?, ?, ?, 0, 0, 0, 0, 0, 0, ?, NULL, ?, ?)
      ''',
      [
        job.id,
        job.sourcePath,
        job.status.name,
        job.phase.name,
        targetNodeId,
        now,
        now,
      ],
    );
    return job;
  }

  IndexBuildJob? getIndexJob(String id) {
    final rows = database.db.select(
      'SELECT * FROM index_jobs WHERE id = ? LIMIT 1',
      [id],
    );
    return rows.isEmpty ? null : _indexBuildJobFromRow(rows.first);
  }

  List<IndexBuildJob> listRecoverableIndexJobs() {
    final rows = database.db.select('''
      SELECT * FROM index_jobs
      WHERE status IN ('pending', 'paused', 'failed')
      ORDER BY updated_at DESC
    ''');
    return rows.map(_indexBuildJobFromRow).toList(growable: false);
  }

  /// Removes a paused/failed scan manifest without touching indexed entities
  /// or any source files.
  void discardIndexJob(String jobId) {
    database.db.execute('DELETE FROM index_jobs WHERE id = ?', [jobId]);
  }

  void setIndexJobRoots({
    required String jobId,
    required String indexRootId,
    String? stagingRootId,
  }) {
    database.db.execute(
      'UPDATE index_jobs SET index_root_id = ?, staging_root_id = ?, updated_at = ? WHERE id = ?',
      [indexRootId, stagingRootId, nowMillis(), jobId],
    );
  }

  void snapshotEntityForIndexJob(String jobId, Entity entity) {
    database.db.execute(
      'INSERT OR IGNORE INTO index_job_entity_snapshots(job_id, entity_id, entity_json) VALUES (?, ?, ?)',
      [jobId, entity.id, jsonEncode(_entitySnapshotJson(entity))],
    );
  }

  void recordCreatedEntityForIndexJob(String jobId, String entityId) {
    database.db.execute(
      'INSERT OR IGNORE INTO index_job_created_entities(job_id, entity_id) VALUES (?, ?)',
      [jobId, entityId],
    );
  }

  void snapshotIndexJobLink({
    required String jobId,
    required String indexNodeId,
    required String entityId,
  }) {
    final existed = database.db.select(
      'SELECT 1 FROM index_node_entities WHERE index_node_id = ? AND entity_id = ? LIMIT 1',
      [indexNodeId, entityId],
    ).isNotEmpty;
    database.db.execute(
      '''
      INSERT OR IGNORE INTO index_job_link_changes
      (job_id, index_node_id, entity_id, existed_before)
      VALUES (?, ?, ?, ?)
      ''',
      [jobId, indexNodeId, entityId, boolToInt(existed)],
    );
  }

  void rollbackIndexJobStagingRoot(String jobId) {
    final job = getIndexJob(jobId);
    if (job == null) return;
    final snapshots = database.db.select(
      'SELECT entity_id, entity_json FROM index_job_entity_snapshots WHERE job_id = ?',
      [jobId],
    );
    final transientThumbnailKeys = snapshots.isEmpty
        ? const <String>{}
        : _thumbnailKeysForEntities(
            snapshots.map((row) => row['entity_id'] as String),
          );
    final addedLinks = database.db.select('''
      SELECT index_node_id, entity_id FROM index_job_link_changes
      WHERE job_id = ? AND existed_before = 0
    ''', [jobId]);
    final createdEntities = database.db.select(
      'SELECT entity_id FROM index_job_created_entities WHERE job_id = ?',
      [jobId],
    );
    writeTransaction(() {
      for (final link in addedLinks) {
        database.db.execute(
          'DELETE FROM index_node_entities WHERE index_node_id = ? AND entity_id = ?',
          [link['index_node_id'], link['entity_id']],
        );
      }
      for (final row in snapshots) {
        _restoreEntitySnapshot(
          row['entity_id'] as String,
          row['entity_json'] as String,
        );
      }
      for (final row in createdEntities) {
        final entityId = row['entity_id'] as String;
        final stillReferenced = database.db.select(
          'SELECT 1 FROM index_node_entities WHERE entity_id = ? LIMIT 1',
          [entityId],
        ).isNotEmpty;
        if (!stillReferenced) {
          database.db.execute('DELETE FROM entities WHERE id = ?', [entityId]);
        }
      }
    });
    final rootId = job.stagingRootId;
    if (rootId != null) {
      final thumbnails = _thumbnailKeysUnderNodes({rootId});
      deleteIndexNode(rootId);
      _deleteUnreferencedThumbnailFiles(thumbnails);
    }
    _deleteUnreferencedThumbnailFiles(transientThumbnailKeys);
    final indexedRootId = job.indexRootId;
    if (rootId == null && indexedRootId != null) {
      pruneEmptyDirectoryNodes(indexedRootId);
      rebuildIndexNodeStats();
    }
    database.db.execute(
      'UPDATE index_jobs SET index_root_id = NULL, staging_root_id = NULL, updated_at = ? WHERE id = ?',
      [nowMillis(), jobId],
    );
  }

  void updateIndexJob(
    String jobId, {
    IndexJobStatus? status,
    IndexJobPhase? phase,
    String? indexRootId,
    int? discovered,
    int? total,
    int? processed,
    int? previewTotal,
    int? previewProcessed,
    bool? scanCompleted,
    String? targetNodeId,
    String? stagingRootId,
    String? error,
    bool clearError = false,
  }) {
    database.db.execute(
      '''
      UPDATE index_jobs
      SET status = COALESCE(?, status),
          phase = COALESCE(?, phase),
          index_root_id = COALESCE(?, index_root_id),
          discovered = COALESCE(?, discovered),
          total = COALESCE(?, total),
          processed = COALESCE(?, processed),
          preview_total = COALESCE(?, preview_total),
          preview_processed = COALESCE(?, preview_processed),
          scan_completed = COALESCE(?, scan_completed),
          target_node_id = COALESCE(?, target_node_id),
          staging_root_id = COALESCE(?, staging_root_id),
          error = CASE WHEN ? THEN NULL ELSE COALESCE(?, error) END,
          updated_at = ?
      WHERE id = ?
      ''',
      [
        status?.name,
        phase?.name,
        indexRootId,
        discovered,
        total,
        processed,
        previewTotal,
        previewProcessed,
        scanCompleted == null ? null : boolToInt(scanCompleted),
        targetNodeId,
        stagingRootId,
        clearError ? 1 : 0,
        error,
        nowMillis(),
        jobId,
      ],
    );
  }

  void resetIndexJobManifest(String jobId) {
    writeTransaction(() {
      database.db.execute(
        'DELETE FROM index_job_candidates WHERE job_id = ?',
        [jobId],
      );
      updateIndexJob(
        jobId,
        phase: IndexJobPhase.discovering,
        discovered: 0,
        total: 0,
        processed: 0,
        previewTotal: 0,
        previewProcessed: 0,
        scanCompleted: false,
        clearError: true,
      );
    });
  }

  void upsertIndexJobCandidates(Iterable<IndexJobCandidate> candidates) {
    final values = candidates.toList(growable: false);
    if (values.isEmpty) return;
    final statement = database.db.prepare('''
      INSERT INTO index_job_candidates (
        job_id, source_path, relative_path, sequence, state, format,
        media_type, fingerprint, size, metadata_preview, duration_ms, error,
        source_created_at_ms, source_modified_at_ms, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(job_id, source_path) DO UPDATE SET
        relative_path = excluded.relative_path,
        sequence = excluded.sequence,
        state = excluded.state,
        format = excluded.format,
        media_type = excluded.media_type,
        fingerprint = excluded.fingerprint,
        size = excluded.size,
        metadata_preview = excluded.metadata_preview,
        duration_ms = excluded.duration_ms,
        source_created_at_ms = excluded.source_created_at_ms,
        source_modified_at_ms = excluded.source_modified_at_ms,
        error = excluded.error,
        updated_at = excluded.updated_at
    ''');
    try {
      for (final candidate in values) {
        statement.execute([
          candidate.jobId,
          candidate.sourcePath,
          candidate.relativePath,
          candidate.sequence,
          candidate.state.name,
          candidate.format,
          candidate.entityType?.value,
          candidate.fingerprint,
          candidate.size,
          candidate.metadataPreview,
          candidate.durationMs,
          candidate.error,
          candidate.sourceCreatedAtMs,
          candidate.sourceModifiedAtMs,
          candidate.updatedAtMs,
        ]);
      }
    } finally {
      statement.dispose();
    }
  }

  List<IndexJobCandidate> listIndexJobCandidates(
    String jobId, {
    Set<IndexJobCandidateState>? states,
  }) {
    final requested = states?.toList(growable: false) ?? const [];
    final condition = requested.isEmpty
        ? ''
        : 'AND state IN (${List.filled(requested.length, '?').join(', ')})';
    final rows = database.db.select(
      '''
      SELECT * FROM index_job_candidates
      WHERE job_id = ? $condition
      ORDER BY sequence ASC, source_path ASC
      ''',
      [jobId, ...requested.map((state) => state.name)],
    );
    return rows.map(_indexJobCandidateFromRow).toList(growable: false);
  }

  IndexJobCandidateSummary summarizeIndexJobCandidates(String jobId) {
    final rows = database.db.select('''
      SELECT state, COUNT(*) AS count
      FROM index_job_candidates
      WHERE job_id = ?
      GROUP BY state
    ''', [jobId]);
    final counts = <String, int>{
      for (final row in rows) row['state'] as String: row['count'] as int,
    };
    return IndexJobCandidateSummary(
      pending: counts[IndexJobCandidateState.pending.name] ?? 0,
      prepared: counts[IndexJobCandidateState.prepared.name] ?? 0,
      written: counts[IndexJobCandidateState.written.name] ?? 0,
      previewed: counts[IndexJobCandidateState.previewed.name] ?? 0,
      failed: counts[IndexJobCandidateState.failed.name] ?? 0,
    );
  }

  List<IndexJobCandidate> listFailedIndexJobCandidates(String jobId) =>
      listIndexJobCandidates(
        jobId,
        states: {IndexJobCandidateState.failed},
      );

  bool prepareFailedIndexJobCandidatesForRetry(String jobId) {
    final failed = summarizeIndexJobCandidates(jobId).failed;
    if (failed == 0) return false;
    database.db.execute('''
      UPDATE index_job_candidates
      SET state = ?, error = NULL, updated_at = ?
      WHERE job_id = ? AND state = ?
    ''', [
      IndexJobCandidateState.written.name,
      nowMillis(),
      jobId,
      IndexJobCandidateState.failed.name,
    ]);
    updateIndexJob(
      jobId,
      status: IndexJobStatus.running,
      phase: IndexJobPhase.previews,
      previewProcessed: 0,
      clearError: true,
    );
    return true;
  }

  void updateIndexJobCandidateState(
    String jobId,
    String sourcePath,
    IndexJobCandidateState state, {
    String? error,
  }) {
    database.db.execute(
      '''
      UPDATE index_job_candidates
      SET state = ?, error = ?, updated_at = ?
      WHERE job_id = ? AND source_path = ?
      ''',
      [state.name, error, nowMillis(), jobId, sourcePath],
    );
  }

  /// Transitions a batch atomically. Candidate state is the durable resume
  /// boundary, so callers never need to infer progress from a UI counter.
  void updateIndexJobCandidateStates(
    String jobId,
    Iterable<String> sourcePaths,
    IndexJobCandidateState state, {
    String? error,
  }) {
    final paths = sourcePaths.toSet().toList(growable: false);
    if (paths.isEmpty) return;
    final statement = database.db.prepare('''
      UPDATE index_job_candidates
      SET state = ?, error = ?, updated_at = ?
      WHERE job_id = ? AND source_path = ?
    ''');
    try {
      final updatedAt = nowMillis();
      for (final path in paths) {
        statement.execute([state.name, error, updatedAt, jobId, path]);
      }
    } finally {
      statement.dispose();
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
      nodeType: NodeType.categoryIndexRoot,
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
    final node = ensureIndexNode(
      parentId: parentId,
      name: name,
      nodeType: NodeType.graphNode,
      viewType: ViewType.graph,
      sortOrder: sortOrder,
    );
    rebuildIndexNodeStats();
    return node;
  }

  IndexNode ensureDirectoryIndexRoot(
    String sourcePath, {
    bool staging = false,
  }) {
    final normalized = _normalizeSourcePath(sourcePath);
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
        return _resetDirectoryIndexRootForRescan(
          _nodeFromRow(row),
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
      name: _indexNameForRoot(normalized),
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
        boolToInt(staging),
        now,
        now,
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

  EntityUpsertResult upsertEntity({
    required String path,
    required String name,
    required String format,
    required EntityType entityType,
    required String hash,
    required int size,
    required int sourceCreatedAtMs,
    required int sourceModifiedAtMs,
    String? metadataPreview,
    int? durationMs,
    String? directoryRootId,
    String? localPath,
    Entity? knownExisting,
    bool existingLookupCompleted = false,
  }) {
    final normalizedPath = _normalizeEntityPath(path);
    final normalizedName = _normalizeEntityText(name, 'name');
    final normalizedFormat =
        _normalizeEntityText(format, 'format').toLowerCase();
    final normalizedHash = _normalizeEntityText(hash, 'hash');
    final normalizedPreview = _normalizeOptionalText(metadataPreview);
    final normalizedLocalPath = localPath == null || localPath.trim().isEmpty
        ? null
        : p.normalize(localPath.trim());
    if (directoryRootId != null) {
      final root = _nodeById(directoryRootId);
      if (root?.nodeType != NodeType.directoryIndexRoot) {
        throw ArgumentError.value(
          directoryRootId,
          'directoryRootId',
          'must identify a directory index root',
        );
      }
    }
    _validateNonNegativeInt(size, 'size');
    _validateNonNegativeInt(sourceCreatedAtMs, 'sourceCreatedAtMs');
    _validateNonNegativeInt(sourceModifiedAtMs, 'sourceModifiedAtMs');
    if (durationMs != null) _validateNonNegativeInt(durationMs, 'durationMs');
    final existingRows = existingLookupCompleted || knownExisting != null
        ? const <Row>[]
        : database.db.select(
            'SELECT * FROM entities WHERE path = ? LIMIT 1',
            [normalizedPath],
          );
    final nextThumbnailStatus = _defaultThumbnailStatusFor(entityType);
    final existing = knownExisting ??
        (existingRows.isEmpty
            ? null
            : _entityFromRow(existingRows.first, thumbnailStore));
    if (existing != null) {
      final requiresRuntimePreview = !_hasGeneratedThumbnail(entityType);
      if (existing.hash == normalizedHash &&
          existing.metadataPreview == normalizedPreview &&
          existing.entityType == entityType &&
          existing.format == normalizedFormat &&
          existing.size == size &&
          existing.durationMs == durationMs &&
          existing.directoryRootId == directoryRootId &&
          existing.localPath == normalizedLocalPath &&
          (!requiresRuntimePreview ||
              existing.thumbnailStatus == ThumbnailStatus.none)) {
        return EntityUpsertResult(
          entity: existing,
          status: EntityUpsertStatus.skipped,
        );
      }
      final now = nowMillis();
      final thumbnailReset = !requiresRuntimePreview &&
              existing.hash == normalizedHash &&
              existing.entityType == entityType
          ? existing.thumbnailStatus
          : nextThumbnailStatus;
      if (requiresRuntimePreview &&
          existing.thumbnailKey != null &&
          existing.thumbnailFormat != null) {
        final staleThumbnail = thumbnailStore.fileFor(
          existing.thumbnailKey!,
          existing.thumbnailFormat!,
        );
        if (staleThumbnail.existsSync()) staleThumbnail.deleteSync();
      }
      database.db.execute(
        '''
        UPDATE entities
        SET name = ?, format = ?, media_type = ?, hash = ?, metadata_preview = ?,
            thumbnail_status = ?, thumbnail_key = CASE WHEN ? = 'success' THEN thumbnail_key ELSE NULL END,
            thumbnail_format = CASE WHEN ? = 'success' THEN thumbnail_format ELSE NULL END,
            thumbnail_width = CASE WHEN ? = 'success' THEN thumbnail_width ELSE NULL END,
            thumbnail_height = CASE WHEN ? = 'success' THEN thumbnail_height ELSE NULL END,
            thumbnail_error = CASE WHEN ? = 'failed' THEN thumbnail_error ELSE NULL END,
            size = ?, source_created_at_ms = ?, source_modified_at_ms = ?, duration_ms = ?,
            directory_root_id = ?, local_path = ?, updated_at = ?
        WHERE id = ?
        ''',
        [
          normalizedName,
          normalizedFormat,
          entityType.value,
          normalizedHash,
          normalizedPreview,
          thumbnailReset.value,
          thumbnailReset.value,
          thumbnailReset.value,
          thumbnailReset.value,
          thumbnailReset.value,
          thumbnailReset.value,
          size,
          sourceCreatedAtMs,
          sourceModifiedAtMs,
          durationMs,
          directoryRootId,
          normalizedLocalPath,
          now,
          existing.id,
        ],
      );
      final thumbnailKey = thumbnailReset == ThumbnailStatus.success
          ? existing.thumbnailKey
          : null;
      final thumbnailFormat = thumbnailReset == ThumbnailStatus.success
          ? existing.thumbnailFormat
          : null;
      return EntityUpsertResult(
        entity: Entity(
          id: existing.id,
          path: normalizedPath,
          name: normalizedName,
          format: normalizedFormat,
          entityType: entityType,
          hash: normalizedHash,
          size: size,
          sourceCreatedAtMs: sourceCreatedAtMs,
          sourceModifiedAtMs: sourceModifiedAtMs,
          createdAtMs: existing.createdAtMs,
          updatedAtMs: now,
          metadataPreview: normalizedPreview,
          thumbnailStatus: thumbnailReset,
          thumbnailKey: thumbnailKey,
          thumbnailFormat: thumbnailFormat,
          thumbnailWidth: thumbnailReset == ThumbnailStatus.success
              ? existing.thumbnailWidth
              : null,
          thumbnailHeight: thumbnailReset == ThumbnailStatus.success
              ? existing.thumbnailHeight
              : null,
          thumbnailError: thumbnailReset == ThumbnailStatus.failed
              ? existing.thumbnailError
              : null,
          thumbnailPath: thumbnailKey != null && thumbnailFormat != null
              ? thumbnailStore.pathFor(thumbnailKey, thumbnailFormat)
              : null,
          archived: existing.archived,
          lastOpenedAtMs: existing.lastOpenedAtMs,
          lastPositionMs: existing.lastPositionMs,
          durationMs: durationMs,
          readerScrollOffset: existing.readerScrollOffset,
          zoomScale: existing.zoomScale,
          extraStateJson: existing.extraStateJson,
          directoryRootId: directoryRootId,
          localPath: normalizedLocalPath,
        ),
        status: EntityUpsertStatus.updated,
      );
    }

    final now = nowMillis();
    final id = newId();
    database.db.execute(
      '''
      INSERT INTO entities
      (id, path, local_path, name, format, media_type, hash, metadata_preview,
       thumbnail_status, thumbnail_key, thumbnail_format, thumbnail_width, thumbnail_height, thumbnail_error, size,
       source_created_at_ms, source_modified_at_ms, duration_ms, directory_root_id, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        id,
        normalizedPath,
        normalizedLocalPath,
        normalizedName,
        normalizedFormat,
        entityType.value,
        normalizedHash,
        normalizedPreview,
        nextThumbnailStatus.value,
        null,
        null,
        null,
        null,
        null,
        size,
        sourceCreatedAtMs,
        sourceModifiedAtMs,
        durationMs,
        directoryRootId,
        now,
        now,
      ],
    );
    return EntityUpsertResult(
      entity: Entity(
        id: id,
        path: normalizedPath,
        name: normalizedName,
        format: normalizedFormat,
        entityType: entityType,
        hash: normalizedHash,
        size: size,
        sourceCreatedAtMs: sourceCreatedAtMs,
        sourceModifiedAtMs: sourceModifiedAtMs,
        createdAtMs: now,
        updatedAtMs: now,
        metadataPreview: normalizedPreview,
        thumbnailStatus: nextThumbnailStatus,
        durationMs: durationMs,
        directoryRootId: directoryRootId,
        localPath: normalizedLocalPath,
      ),
      status: EntityUpsertStatus.inserted,
    );
  }

  Entity? getEntity(String id) {
    final rows =
        database.db.select('SELECT * FROM entities WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    return _entityFromRow(rows.first, thumbnailStore);
  }

  /// SAF scans use a temporary local file only while extracting metadata and
  /// rendering previews. It must never become persistent entity state.
  void clearEntityLocalPath(String id) {
    database.db.execute(
      'UPDATE entities SET local_path = NULL WHERE id = ?',
      [id],
    );
  }

  Entity? getEntityByPath(String path) {
    final rows = database.db.select(
      'SELECT * FROM entities WHERE path = ? LIMIT 1',
      [_normalizeEntityPath(path)],
    );
    if (rows.isEmpty) return null;
    return _entityFromRow(rows.first, thumbnailStore);
  }

  /// Loads source entities in bounded batches so large scans avoid one lookup
  /// per file without exceeding SQLite's host-parameter limit.
  Map<String, Entity> getEntitiesByPaths(Iterable<String> paths) {
    final normalizedPaths =
        paths.map(_normalizeEntityPath).toSet().toList(growable: false);
    if (normalizedPaths.isEmpty) return const <String, Entity>{};
    final result = <String, Entity>{};
    const batchSize = 400;
    for (var offset = 0; offset < normalizedPaths.length; offset += batchSize) {
      final end = (offset + batchSize).clamp(0, normalizedPaths.length);
      final batch = normalizedPaths.sublist(offset, end);
      final placeholders = List<String>.filled(batch.length, '?').join(',');
      final rows = database.db.select(
        'SELECT * FROM entities WHERE path IN ($placeholders)',
        batch,
      );
      for (final row in rows) {
        final entity = _entityFromRow(row, thumbnailStore);
        result[entity.path] = entity;
      }
    }
    return Map<String, Entity>.unmodifiable(result);
  }

  Map<String, Entity> getEntitiesByIds(Iterable<String> entityIds) {
    final ids = entityIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const <String, Entity>{};
    final result = <String, Entity>{};
    const batchSize = 400;
    for (var offset = 0; offset < ids.length; offset += batchSize) {
      final end = (offset + batchSize).clamp(0, ids.length);
      final batch = ids.sublist(offset, end);
      final placeholders = List<String>.filled(batch.length, '?').join(',');
      final rows = database.db.select(
        'SELECT * FROM entities WHERE id IN ($placeholders)',
        batch,
      );
      for (final row in rows) {
        final entity = _entityFromRow(row, thumbnailStore);
        result[entity.id] = entity;
      }
    }
    return Map<String, Entity>.unmodifiable(result);
  }

  void updateEntityThumbnailPending(String entityId) {
    database.db.execute(
      '''
      UPDATE entities
      SET thumbnail_status = ?, thumbnail_error = NULL, updated_at = ?
      WHERE id = ?
      ''',
      [ThumbnailStatus.pending.value, nowMillis(), entityId],
    );
  }

  /// Applies a bounded group of thumbnail state changes in one SQLite savepoint.
  /// Scanner workers use this path so thumbnail throughput is not limited by
  /// per-file transactions.
  void applyThumbnailUpdates(Iterable<ThumbnailDatabaseUpdate> updates) {
    final batch = updates.toList(growable: false);
    if (batch.isEmpty) return;
    final now = nowMillis();
    writeTransaction(() {
      for (final update in batch) {
        switch (update.type) {
          case ThumbnailUpdateType.pending:
            database.db.execute(
              'UPDATE entities SET thumbnail_status = ?, thumbnail_error = NULL, updated_at = ? WHERE id = ?',
              [ThumbnailStatus.pending.value, now, update.entityId],
            );
          case ThumbnailUpdateType.success:
            database.db.execute(
              '''
              UPDATE entities SET thumbnail_status = ?, thumbnail_key = ?, thumbnail_format = ?,
                thumbnail_width = ?, thumbnail_height = ?, thumbnail_error = NULL,
                duration_ms = COALESCE(?, duration_ms), updated_at = ? WHERE id = ?
              ''',
              [
                ThumbnailStatus.success.value,
                update.key,
                update.format,
                update.width,
                update.height,
                update.durationMs,
                now,
                update.entityId,
              ],
            );
          case ThumbnailUpdateType.failed:
            database.db.execute(
              '''
              UPDATE entities SET thumbnail_status = ?, thumbnail_error = ?, thumbnail_key = NULL,
                thumbnail_format = NULL, thumbnail_width = NULL, thumbnail_height = NULL,
                updated_at = ? WHERE id = ?
              ''',
              [
                ThumbnailStatus.failed.value,
                update.error?.trim(),
                now,
                update.entityId,
              ],
            );
          case ThumbnailUpdateType.none:
            database.db.execute(
              '''
              UPDATE entities SET thumbnail_status = ?, thumbnail_key = NULL, thumbnail_format = NULL,
                thumbnail_width = NULL, thumbnail_height = NULL, thumbnail_error = NULL,
                updated_at = ? WHERE id = ?
              ''',
              [ThumbnailStatus.none.value, now, update.entityId],
            );
        }
      }
    });
  }

  void updateEntityThumbnailSuccess({
    required String entityId,
    required String key,
    required String format,
    required int width,
    required int height,
  }) {
    database.db.execute(
      '''
      UPDATE entities
      SET thumbnail_status = ?, thumbnail_key = ?, thumbnail_format = ?,
          thumbnail_width = ?, thumbnail_height = ?, thumbnail_error = NULL,
          updated_at = ?
      WHERE id = ?
      ''',
      [
        ThumbnailStatus.success.value,
        key,
        format,
        width,
        height,
        nowMillis(),
        entityId,
      ],
    );
  }

  void updateEntityThumbnailFailed(String entityId, String error) {
    database.db.execute(
      '''
      UPDATE entities
      SET thumbnail_status = ?, thumbnail_error = ?, thumbnail_key = NULL,
          thumbnail_format = NULL, thumbnail_width = NULL, thumbnail_height = NULL,
          updated_at = ?
      WHERE id = ?
      ''',
      [ThumbnailStatus.failed.value, error.trim(), nowMillis(), entityId],
    );
  }

  void updateEntityThumbnailNone(String entityId) {
    database.db.execute(
      '''
      UPDATE entities
      SET thumbnail_status = ?, thumbnail_key = NULL, thumbnail_format = NULL,
          thumbnail_width = NULL, thumbnail_height = NULL, thumbnail_error = NULL,
          updated_at = ?
      WHERE id = ?
      ''',
      [ThumbnailStatus.none.value, nowMillis(), entityId],
    );
  }

  void updateEntityDuration(String entityId, int durationMs) {
    _validateNonNegativeInt(durationMs, 'durationMs');
    database.db.execute(
      '''
      UPDATE entities
      SET duration_ms = ?, updated_at = ?
      WHERE id = ?
      ''',
      [durationMs, nowMillis(), entityId],
    );
  }

  bool hasEntityForPath(String path) {
    final rows = database.db.select(
      'SELECT 1 FROM entities WHERE path = ? LIMIT 1',
      [_normalizeEntityPath(path)],
    );
    return rows.isNotEmpty;
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
    database.db.execute(
      '''
      INSERT OR IGNORE INTO index_node_entities
      (index_node_id, entity_id, sort_name, created_at)
      SELECT ?, id, lower(name), ? FROM entities WHERE id = ?
      ''',
      [indexNodeId, nowMillis(), entityId],
    );
    _touchIndexNode(indexNodeId);
    rebuildIndexNodeStats();
  }

  /// Scanner-oriented bulk link insertion. Entity and node existence is
  /// enforced by foreign keys, while each touched node is updated only once.
  void linkEntitiesToIndexNodes(
    Iterable<({String entityId, String indexNodeId})> links, {
    bool rebuildStats = true,
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
    if (rebuildStats) rebuildIndexNodeStats();
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
    });
    rebuildIndexNodeStats();
  }

  IndexNode createCollectionWithEntities({
    required String name,
    required Iterable<String> entityIds,
  }) {
    return writeTransaction(() {
      final collection = ensureCollectionIndexRoot(name);
      linkEntitiesToIndexNode(
        entityIds: entityIds,
        indexNodeId: collection.id,
      );
      return collection;
    });
  }

  IndexNode createCustomNode({
    required String parentId,
    required String name,
  }) {
    final node = ensureIndexNode(
      parentId: parentId,
      name: name,
      nodeType: NodeType.category,
      viewType: ViewType.tree,
    );
    _touchIndexNode(parentId);
    rebuildIndexNodeStats();
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
    if (targetRoot?.nodeType != NodeType.categoryIndexRoot) {
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
          nodeType: NodeType.category,
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
      } finally {
        entityLinkInsert.dispose();
        nodeInsert.dispose();
      }
    });
    rebuildIndexNodeStats();
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
             thumbnail_png, preview_json, sort_order, created_at, updated_at, last_built_at_ms
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
        previews[nodeId] = _buildIndexNodePreview(
          nodeId: nodeId,
          childTiles: override
              .map(
                (tile) => _resolvePreviewOverrideTile(
                  tile,
                  overrideEntities,
                  overrideNodes,
                ),
              )
              .toList(growable: false),
          entities: const [],
        );
        continue;
      }
      final children = childrenByParent[nodeId] ?? const <IndexNode>[];
      final childTiles = children
          .map(
            (child) =>
                _representativePreviewTileFromCache(child) ??
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
    return Map<String, IndexNodePreview>.unmodifiable(previews);
  }

  /// Rebuilds one lightweight representative per node, bottom-up. The cache
  /// contains only metadata and thumbnail cache keys, never image bytes.
  void rebuildIndexNodePreviewCache(String rootId) {
    final nodeRows = database.db.select(
      '''
      WITH RECURSIVE subtree(id, depth) AS (
        SELECT ?, 0
        UNION ALL
        SELECT child.id, subtree.depth + 1
        FROM index_nodes child JOIN subtree ON child.parent_id = subtree.id
      )
      SELECT node.*, subtree.depth
      FROM index_nodes node JOIN subtree ON subtree.id = node.id
      ORDER BY subtree.depth DESC, node.name COLLATE NOCASE ASC
      ''',
      [rootId],
    );
    if (nodeRows.isEmpty) return;
    final nodes = nodeRows.map(_nodeFromRow).toList(growable: false);
    final nodeIds = nodes.map((node) => node.id).toList(growable: false);
    final placeholders = List.filled(nodeIds.length, '?').join(', ');
    final entityRows = database.db.select(
      '''
      SELECT link.index_node_id AS preview_node_id, entity.*
      FROM index_node_entities link
      JOIN entities entity ON entity.id = link.entity_id
      WHERE link.index_node_id IN ($placeholders) AND entity.archived = 0
      ORDER BY link.index_node_id, entity.name COLLATE NOCASE, entity.id
      ''',
      nodeIds,
    );
    final entitiesByNode = <String, List<EntityListItem>>{};
    for (final row in entityRows) {
      final nodeId = row['preview_node_id'] as String;
      entitiesByNode.putIfAbsent(nodeId, () => []).add(
            _listItemFromRow(row, thumbnailStore),
          );
    }
    final childrenByParent = <String, List<IndexNode>>{};
    for (final node in nodes) {
      final parentId = node.parentId;
      if (parentId != null) {
        childrenByParent.putIfAbsent(parentId, () => []).add(node);
      }
    }
    final representatives = <String, IndexNodePreviewTile?>{};
    final updates = <({String id, String? json})>[];
    for (final node in nodes) {
      final overrideRepresentative = _overrideRepresentativeTile(node);
      if (overrideRepresentative != null) {
        representatives[node.id] = overrideRepresentative;
        updates.add(
            (id: node.id, json: _previewTileToJson(overrideRepresentative)));
        continue;
      }
      final childRepresentatives = (childrenByParent[node.id] ?? const [])
          .map((child) => representatives[child.id])
          .whereType<IndexNodePreviewTile>()
          .toList(growable: false);
      final representative = _selectRepresentativePreviewTile(
        node,
        entitiesByNode[node.id] ?? const <EntityListItem>[],
        childRepresentatives,
      );
      representatives[node.id] = representative;
      updates.add((id: node.id, json: _previewTileToJson(representative)));
    }
    final statement = database.db.prepare(
      'UPDATE index_nodes SET preview_json = ?, updated_at = ? WHERE id = ?',
    );
    final now = nowMillis();
    writeTransaction(() {
      try {
        for (final update in updates) {
          statement.execute([update.json, now, update.id]);
        }
      } finally {
        statement.dispose();
      }
    });
  }

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

  Map<String, List<String>> listDirectThumbnailPathsUnderRoot(String rootId) {
    final rows = database.db.select(
      '''
      WITH RECURSIVE subtree(id) AS (
        SELECT ?
        UNION ALL
        SELECT child.id
        FROM index_nodes child
        JOIN subtree ON child.parent_id = subtree.id
      )
      SELECT link.index_node_id, entity.thumbnail_key, entity.thumbnail_format
      FROM index_node_entities link
      JOIN entities entity ON entity.id = link.entity_id
      WHERE link.index_node_id IN (SELECT id FROM subtree)
        AND entity.archived = 0
        AND entity.thumbnail_status = 'success'
        AND entity.thumbnail_key IS NOT NULL
        AND entity.thumbnail_format IS NOT NULL
      ORDER BY entity.source_modified_at_ms DESC, entity.id
      ''',
      [rootId],
    );
    final result = <String, List<String>>{};
    for (final row in rows) {
      final nodeId = row['index_node_id'] as String;
      final paths = result.putIfAbsent(nodeId, () => <String>[]);
      if (paths.length >= 4) continue;
      final path = thumbnailStore.pathFor(
        row['thumbnail_key'] as String,
        row['thumbnail_format'] as String,
      );
      if (File(path).existsSync()) paths.add(path);
    }
    return result;
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

  void rebuildIndexNodeStats() {
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

  List<EntityListItem> listRecentOpenedEntities({
    int limit = 12,
    Iterable<EntityType>? entityTypes,
  }) {
    final types = entityTypes?.map((type) => type.value).toSet().toList() ??
        const <String>[];
    final typePlaceholders = types.isEmpty
        ? ''
        : 'AND media_type IN (${List<String>.filled(types.length, '?').join(', ')})';
    final rows = database.db.select(
      '''
      SELECT * FROM entities
      WHERE archived = 0 AND last_opened_at IS NOT NULL
      $typePlaceholders
      ORDER BY last_opened_at DESC
      LIMIT ?
      ''',
      [...types, limit],
    );
    return rows.map((row) => _listItemFromRow(row, thumbnailStore)).toList();
  }

  List<EntityListItem> listRecentlyModifiedEntities({int limit = 12}) {
    final rows = database.db.select(
      '''
      SELECT * FROM entities
      WHERE archived = 0
      ORDER BY source_modified_at_ms DESC
      LIMIT ?
      ''',
      [limit],
    );
    return rows.map((row) => _listItemFromRow(row, thumbnailStore)).toList();
  }

  Set<String> entityIdsUnderDirectorySource(String sourcePath) {
    final rows = database.db.select(
      '''
      SELECT id FROM index_nodes
      WHERE node_type = ? AND source_path = ?
      LIMIT 1
      ''',
      [NodeType.directoryIndexRoot.value, _normalizeSourcePath(sourcePath)],
    );
    if (rows.isEmpty) return <String>{};
    return _entityIdsUnderNode(rows.first['id'] as String).toSet();
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
    database.db.execute(
      'UPDATE index_nodes SET name = ?, updated_at = ? WHERE id = ?',
      [normalizedName, nowMillis(), nodeId],
    );
  }

  void setIndexNodeThumbnailPng(String nodeId, Uint8List thumbnailPng) {
    _validateThumbnailPng(thumbnailPng);
    database.db.execute(
      'UPDATE index_nodes SET thumbnail_png = ?, updated_at = ? WHERE id = ?',
      [thumbnailPng, nowMillis(), nodeId],
    );
  }

  void setIndexNodeThumbnailsPng(Map<String, Uint8List> thumbnails) {
    if (thumbnails.isEmpty) return;
    for (final thumbnail in thumbnails.values) {
      _validateThumbnailPng(thumbnail);
    }
    final statement = database.db.prepare('''
      UPDATE index_nodes
      SET thumbnail_png = ?, updated_at = ?
      WHERE id = ?
    ''');
    final now = nowMillis();
    writeTransaction(() {
      try {
        for (final entry in thumbnails.entries) {
          statement.execute([entry.value, now, entry.key]);
        }
      } finally {
        statement.dispose();
      }
    });
  }

  void setIndexNodeThumbnailPngIfEmpty(
    String nodeId,
    Uint8List thumbnailPng,
  ) {
    _validateThumbnailPng(thumbnailPng);
    database.db.execute(
      '''
      UPDATE index_nodes
      SET thumbnail_png = ?, updated_at = ?
      WHERE id = ? AND thumbnail_png IS NULL
      ''',
      [thumbnailPng, nowMillis(), nodeId],
    );
  }

  /// Removes artwork produced by the retired recursive PNG compositor. Node
  /// previews are now rendered from direct content metadata and cache files.
  void clearLegacyIndexNodeThumbnails(String rootId) {
    database.db.execute(
      '''
      WITH RECURSIVE subtree(id) AS (
        SELECT ?
        UNION ALL
        SELECT node.id
        FROM index_nodes node
        JOIN subtree ON node.parent_id = subtree.id
      )
      UPDATE index_nodes
      SET thumbnail_png = NULL
      WHERE id IN (SELECT id FROM subtree)
      ''',
      [rootId],
    );
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
      'SELECT COUNT(*) AS count FROM entities WHERE directory_root_id = ?',
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
        WHERE node_type IN ('directory_index_root', 'category_index_root', 'graph_index_root')
        UNION ALL
        SELECT child.id, index_roots.root_id
        FROM index_nodes child
        JOIN index_roots ON child.parent_id = index_roots.node_id
      )
      SELECT COUNT(DISTINCT e.id) AS count
      FROM entities e
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
        WHERE node_type IN ('directory_index_root', 'category_index_root', 'graph_index_root')
        UNION ALL
        SELECT child.id, index_roots.root_id
        FROM index_nodes child JOIN index_roots ON child.parent_id = index_roots.node_id
      ), conflict_entities AS (
        SELECT DISTINCT e.id, e.name, e.path
        FROM entities e
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
      FROM entities
      WHERE directory_root_id = ?
        AND thumbnail_key IS NOT NULL
        AND thumbnail_format IS NOT NULL
      ''',
      [rootId],
    );
    writeTransaction(() {
      database.db.execute(
        '''
        WITH RECURSIVE subtree(id) AS (
          SELECT ?
          UNION ALL
          SELECT child.id FROM index_nodes child JOIN subtree ON child.parent_id = subtree.id
        )
        DELETE FROM index_node_entities
        WHERE entity_id IN (
          SELECT id FROM entities WHERE directory_root_id = ?
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
    for (final row in thumbnailRows) {
      final key = row['thumbnail_key'] as String;
      final format = row['thumbnail_format'] as String;
      final file = thumbnailStore.fileFor(key, format);
      if (file.existsSync()) file.deleteSync();
    }
    rebuildIndexNodeStats();
    return DirectoryIndexDeletionResult(deletedEntityCount: report.entityCount);
  }

  void deleteIndexNode(String nodeId) {
    final node = _nodeById(nodeId);
    if (node == null) return;
    if (node.nodeType == NodeType.root) return;
    final owner = _owningIndexRoot(node);
    final deleteEntities = owner?.nodeType == NodeType.directoryIndexRoot;
    final entityIds = deleteEntities ? _entityIdsUnderNode(nodeId) : <String>[];

    writeTransaction(() {
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
    rebuildIndexNodeStats();
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

  Set<String> _thumbnailKeysForEntities(Iterable<String> entityIds) {
    final ids = entityIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const <String>{};
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = database.db.select(
      'SELECT thumbnail_key FROM entities WHERE id IN ($placeholders) AND thumbnail_key IS NOT NULL',
      ids,
    );
    return rows
        .map((row) => row['thumbnail_key'] as String?)
        .whereType<String>()
        .where((key) => key.isNotEmpty)
        .toSet();
  }

  void _deleteUnreferencedThumbnailFiles(Iterable<String> keys) {
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
    }
  }

  Map<String, Object?> _entitySnapshotJson(Entity entity) => {
        'path': entity.path,
        'localPath': entity.localPath,
        'name': entity.name,
        'format': entity.format,
        'mediaType': entity.entityType.value,
        'hash': entity.hash,
        'metadataPreview': entity.metadataPreview,
        'thumbnailStatus': entity.thumbnailStatus.value,
        'thumbnailKey': entity.thumbnailKey,
        'thumbnailFormat': entity.thumbnailFormat,
        'thumbnailWidth': entity.thumbnailWidth,
        'thumbnailHeight': entity.thumbnailHeight,
        'thumbnailError': entity.thumbnailError,
        'size': entity.size,
        'sourceCreatedAtMs': entity.sourceCreatedAtMs,
        'sourceModifiedAtMs': entity.sourceModifiedAtMs,
        'archived': boolToInt(entity.archived),
        'lastOpenedAtMs': entity.lastOpenedAtMs,
        'lastPositionMs': entity.lastPositionMs,
        'durationMs': entity.durationMs,
        'readerScrollOffset': entity.readerScrollOffset,
        'zoomScale': entity.zoomScale,
        'extraStateJson': entity.extraStateJson,
        'directoryRootId': entity.directoryRootId,
        'createdAtMs': entity.createdAtMs,
        'updatedAtMs': entity.updatedAtMs,
      };

  void _restoreEntitySnapshot(String entityId, String encoded) {
    final value = jsonDecode(encoded);
    if (value is! Map) return;
    final snapshot = Map<String, dynamic>.from(value);
    database.db.execute('''
      UPDATE entities
      SET path = ?, local_path = ?, name = ?, format = ?, media_type = ?,
          hash = ?, metadata_preview = ?, thumbnail_status = ?,
          thumbnail_key = ?, thumbnail_format = ?, thumbnail_width = ?,
          thumbnail_height = ?, thumbnail_error = ?, size = ?,
          source_created_at_ms = ?, source_modified_at_ms = ?, archived = ?,
          last_opened_at = ?, last_position_ms = ?, duration_ms = ?,
          reader_scroll_offset = ?, zoom_scale = ?, extra_state_json = ?,
          directory_root_id = ?, created_at = ?, updated_at = ?
      WHERE id = ?
    ''', [
      snapshot['path'],
      snapshot['localPath'],
      snapshot['name'],
      snapshot['format'],
      snapshot['mediaType'],
      snapshot['hash'],
      snapshot['metadataPreview'],
      snapshot['thumbnailStatus'],
      snapshot['thumbnailKey'],
      snapshot['thumbnailFormat'],
      snapshot['thumbnailWidth'],
      snapshot['thumbnailHeight'],
      snapshot['thumbnailError'],
      snapshot['size'],
      snapshot['sourceCreatedAtMs'],
      snapshot['sourceModifiedAtMs'],
      snapshot['archived'],
      snapshot['lastOpenedAtMs'],
      snapshot['lastPositionMs'],
      snapshot['durationMs'],
      snapshot['readerScrollOffset'],
      snapshot['zoomScale'],
      snapshot['extraStateJson'],
      snapshot['directoryRootId'],
      snapshot['createdAtMs'],
      snapshot['updatedAtMs'],
      entityId,
    ]);
  }

  /// Clears metadata for files evicted by [ThumbnailStore]'s LRU policy.
  /// The source entity remains untouched and will receive a new preview during
  /// its next index build or an explicit regeneration.
  void invalidateThumbnailCacheKeys(Iterable<String> keys) {
    final uniqueKeys = keys.toSet();
    if (uniqueKeys.isEmpty) return;
    final placeholders = List.filled(uniqueKeys.length, '?').join(', ');
    database.db.execute(
      '''
      UPDATE entities
      SET thumbnail_status = 'none',
          thumbnail_key = NULL,
          thumbnail_format = NULL,
          thumbnail_width = NULL,
          thumbnail_height = NULL,
          thumbnail_error = NULL
      WHERE thumbnail_key IN ($placeholders)
      ''',
      uniqueKeys.toList(growable: false),
    );
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

  void markOpened(String entityId) {
    _requireEntityExists(entityId);
    database.db.execute(
      'UPDATE entities SET last_opened_at = ?, updated_at = ? WHERE id = ?',
      [nowMillis(), nowMillis(), entityId],
    );
  }

  void savePlaybackState({
    required String entityId,
    required int positionMs,
    required int durationMs,
  }) {
    _requireEntityExists(entityId);
    final safeDurationMs = durationMs < 0 ? 0 : durationMs;
    final safePositionMs = (positionMs < 0 ? 0 : positionMs)
        .clamp(
          0,
          safeDurationMs > 0 ? safeDurationMs : 0x7fffffffffffffff,
        )
        .toInt();
    database.db.execute(
      '''
      UPDATE entities
      SET last_position_ms = ?, duration_ms = ?, updated_at = ?
      WHERE id = ?
      ''',
      [safePositionMs, safeDurationMs, nowMillis(), entityId],
    );
  }

  AudioPlaybackSession createAudioPlaybackSession({
    required List<EntityListItem> entries,
    required int currentIndex,
    String? sourceNodeId,
    String? sourceNodeName,
    AudioPlaybackMode mode = AudioPlaybackMode.sequential,
  }) {
    final audioEntries = entries
        .where((entry) => entry.entityType == EntityType.audio)
        .toList(growable: false);
    if (audioEntries.isEmpty) {
      throw ArgumentError.value(
          entries, 'entries', 'Audio session needs audio entries');
    }
    final now = nowMillis();
    final id = newId();
    final safeIndex = currentIndex.clamp(0, audioEntries.length - 1);
    final name = sourceNodeName?.trim().isNotEmpty == true
        ? sourceNodeName!.trim()
        : '临时播放列表';
    writeTransaction(() {
      database.db.execute(
          'UPDATE audio_playback_sessions SET active = 0 WHERE active = 1');
      database.db.execute(
        '''INSERT INTO audio_playback_sessions
          (id, name, source_node_id, source_node_name, mode, current_index, position_ms, shuffle_remaining_json, history_json, active, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, 0, '[]', '[]', 1, ?, ?)''',
        [
          id,
          name,
          sourceNodeId,
          sourceNodeName,
          mode.name,
          safeIndex,
          now,
          now
        ],
      );
      for (var index = 0; index < audioEntries.length; index++) {
        final entry = audioEntries[index];
        database.db.execute(
          '''INSERT INTO audio_playback_session_entries
            (session_id, sort_order, entity_id, title, path, format, fingerprint, size, modified_at_ms, duration_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          [
            id,
            index,
            entry.id,
            entry.title,
            entry.path,
            entry.format,
            entry.hash,
            entry.size,
            entry.modifiedAtMs,
            entry.durationMs
          ],
        );
      }
    });
    return getAudioPlaybackSession(id)!;
  }

  List<AudioPlaybackSession> listAudioPlaybackSessions() {
    final rows = database.db.select(
      'SELECT * FROM audio_playback_sessions ORDER BY active DESC, updated_at DESC',
    );
    return rows.map(_audioSessionFromRow).toList(growable: false);
  }

  AudioPlaybackSession? getAudioPlaybackSession(String id) {
    final rows = database.db.select(
        'SELECT * FROM audio_playback_sessions WHERE id = ? LIMIT 1', [id]);
    return rows.isEmpty ? null : _audioSessionFromRow(rows.first);
  }

  void updateAudioPlaybackSession({
    required String id,
    int? currentIndex,
    int? positionMs,
    AudioPlaybackMode? mode,
    List<int>? shuffleRemaining,
    List<int>? history,
    bool? active,
  }) {
    if (active == true) {
      database.db.execute(
          'UPDATE audio_playback_sessions SET active = 0 WHERE active = 1 AND id <> ?',
          [id]);
    }
    database.db.execute(
      '''UPDATE audio_playback_sessions SET
        current_index = COALESCE(?, current_index),
        position_ms = COALESCE(?, position_ms),
        mode = COALESCE(?, mode),
        shuffle_remaining_json = COALESCE(?, shuffle_remaining_json),
        history_json = COALESCE(?, history_json),
        active = COALESCE(?, active), updated_at = ? WHERE id = ?''',
      [
        currentIndex,
        positionMs,
        mode?.name,
        shuffleRemaining == null ? null : jsonEncode(shuffleRemaining),
        history == null ? null : jsonEncode(history),
        active == null ? null : boolToInt(active),
        nowMillis(),
        id
      ],
    );
  }

  void deleteAudioPlaybackSession(String id) {
    database.db
        .execute('DELETE FROM audio_playback_sessions WHERE id = ?', [id]);
  }

  void saveReaderState({
    required String entityId,
    double? scrollOffset,
    double? zoomScale,
    String? extraStateJson,
  }) {
    _requireEntityExists(entityId);
    final safeScrollOffset =
        scrollOffset == null ? null : (scrollOffset < 0 ? 0.0 : scrollOffset);
    final safeZoomScale =
        zoomScale == null || zoomScale <= 0 ? null : zoomScale;
    database.db.execute(
      '''
      UPDATE entities
      SET reader_scroll_offset = COALESCE(?, reader_scroll_offset),
          zoom_scale = COALESCE(?, zoom_scale),
          extra_state_json = COALESCE(?, extra_state_json),
          updated_at = ?
      WHERE id = ?
      ''',
      [safeScrollOffset, safeZoomScale, extraStateJson, nowMillis(), entityId],
    );
  }

  void restoreEntityUserState({
    required String entityId,
    required bool archived,
    int? lastOpenedAtMs,
    int? lastPositionMs,
    double? readerScrollOffset,
    double? zoomScale,
    String? extraStateJson,
  }) {
    database.db.execute(
      '''
      UPDATE entities
      SET archived = ?, last_opened_at = ?,
          last_position_ms = ?, reader_scroll_offset = ?, zoom_scale = ?,
          extra_state_json = ?, updated_at = ?
      WHERE id = ?
      ''',
      [
        boolToInt(archived),
        lastOpenedAtMs,
        lastPositionMs,
        readerScrollOffset,
        zoomScale,
        extraStateJson,
        nowMillis(),
        entityId,
      ],
    );
  }

  void setArchived(String entityId, bool archived) {
    _requireEntityExists(entityId);
    database.db.execute(
      'UPDATE entities SET archived = ?, updated_at = ? WHERE id = ?',
      [boolToInt(archived), nowMillis(), entityId],
    );
    rebuildIndexNodeStats();
  }

  void unlinkEntityFromIndexNode({
    required String entityId,
    required String indexNodeId,
  }) {
    database.db.execute(
      '''
      DELETE FROM index_node_entities
      WHERE entity_id = ? AND index_node_id = ?
      ''',
      [entityId, indexNodeId],
    );
    _touchIndexNode(indexNodeId);
    rebuildIndexNodeStats();
  }

  void removeEntityFromLibrary(String entityId) {
    database.db.execute('DELETE FROM entities WHERE id = ?', [entityId]);
    rebuildIndexNodeStats();
  }

  void removeEntitiesFromLibrary(Iterable<String> entityIds) {
    final ids = entityIds.toList(growable: false);
    if (ids.isEmpty) return;
    writeTransaction(() {
      for (final entityId in ids) {
        database.db.execute('DELETE FROM entities WHERE id = ?', [entityId]);
      }
    });
    rebuildIndexNodeStats();
  }

  /// Reconciles a completed incremental directory scan. Existing results stay
  /// visible while scanning; only after the full source has been observed are
  /// missing paths unlinked from this directory tree. Entities referenced by a
  /// custom or graph index remain intact.
  void reconcileDirectoryIndexRoot({
    required String rootId,
    required Iterable<String> seenPaths,
  }) {
    final paths =
        seenPaths.map(_normalizeEntityPath).toSet().toList(growable: false);
    writeTransaction(() {
      database.db.execute('''
        CREATE TEMP TABLE IF NOT EXISTS current_directory_scan_paths (
          path TEXT PRIMARY KEY
        )
      ''');
      database.db.execute('DELETE FROM current_directory_scan_paths');
      final insert = database.db.prepare(
        'INSERT OR IGNORE INTO current_directory_scan_paths(path) VALUES (?)',
      );
      try {
        for (final path in paths) {
          insert.execute([path]);
        }
      } finally {
        insert.dispose();
      }
      database.db.execute(
        '''
        WITH RECURSIVE subtree(id) AS (
          SELECT ?
          UNION ALL
          SELECT child.id
          FROM index_nodes child
          JOIN subtree parent ON child.parent_id = parent.id
        )
        DELETE FROM index_node_entities
        WHERE index_node_id IN (SELECT id FROM subtree)
          AND entity_id IN (
            SELECT entity.id
            FROM entities entity
            WHERE entity.directory_root_id = ?
              AND NOT EXISTS (
                SELECT 1 FROM current_directory_scan_paths seen
                WHERE seen.path = entity.path
              )
          )
        ''',
        [rootId, rootId],
      );
      database.db.execute(
        '''
        DELETE FROM entities
        WHERE directory_root_id = ?
          AND NOT EXISTS (
            SELECT 1 FROM current_directory_scan_paths seen
            WHERE seen.path = entities.path
          )
          AND NOT EXISTS (
            SELECT 1 FROM index_node_entities link
            WHERE link.entity_id = entities.id
          )
        ''',
        [rootId],
      );
      database.db.execute('DELETE FROM current_directory_scan_paths');
    });
    pruneEmptyDirectoryNodes(rootId);
  }

  /// Reconciles only [nodeId] and its descendants after a targeted directory
  /// refresh. Sibling branches of the same directory index are untouched.
  void reconcileDirectoryIndexSubtree({
    required String nodeId,
    required String rootId,
    required Iterable<String> seenPaths,
  }) {
    final paths =
        seenPaths.map(_normalizeEntityPath).toSet().toList(growable: false);
    writeTransaction(() {
      database.db.execute('''
        CREATE TEMP TABLE IF NOT EXISTS current_directory_scan_paths (
          path TEXT PRIMARY KEY
        )
      ''');
      database.db.execute('DELETE FROM current_directory_scan_paths');
      final insert = database.db.prepare(
        'INSERT OR IGNORE INTO current_directory_scan_paths(path) VALUES (?)',
      );
      try {
        for (final path in paths) {
          insert.execute([path]);
        }
      } finally {
        insert.dispose();
      }
      database.db.execute(
        '''
        WITH RECURSIVE subtree(id) AS (
          SELECT ?
          UNION ALL
          SELECT child.id
          FROM index_nodes child
          JOIN subtree parent ON child.parent_id = parent.id
        )
        DELETE FROM index_node_entities
        WHERE index_node_id IN (SELECT id FROM subtree)
          AND entity_id IN (
            SELECT entity.id
            FROM entities entity
            WHERE entity.directory_root_id = ?
              AND NOT EXISTS (
                SELECT 1 FROM current_directory_scan_paths seen
                WHERE seen.path = entity.path
              )
          )
        ''',
        [nodeId, rootId],
      );
      database.db.execute('''
        DELETE FROM entities
        WHERE directory_root_id = ?
          AND NOT EXISTS (
            SELECT 1 FROM index_node_entities link
            WHERE link.entity_id = entities.id
          )
      ''', [rootId]);
      database.db.execute('DELETE FROM current_directory_scan_paths');
    });
    pruneEmptyDirectoryNodes(rootId);
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

  String? getNodePreviewOverride(String nodeId) {
    final rows = database.db.select(
      'SELECT items_json FROM node_preview_overrides WHERE node_id = ? LIMIT 1',
      [nodeId],
    );
    return rows.isEmpty ? null : rows.first['items_json'] as String;
  }

  void setNodePreviewOverride(String nodeId, String itemsJson) {
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
    _rebuildPreviewCacheThroughAncestors(nodeId);
  }

  void clearNodePreviewOverride(String nodeId) {
    database.db.execute(
        'DELETE FROM node_preview_overrides WHERE node_id = ?', [nodeId]);
    _rebuildPreviewCacheThroughAncestors(nodeId);
  }

  void _rebuildPreviewCacheThroughAncestors(String nodeId) {
    for (final node in listIndexNodeAncestors(nodeId)) {
      rebuildIndexNodePreviewCacheForNode(node.id);
    }
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
        final representative =
            child == null ? null : _representativePreviewTileFromCache(child);
        if (representative != null) return representative;
      }
    }
    return tiles.first;
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

  AudioPlaybackSession _audioSessionFromRow(Row row) {
    final id = row['id'] as String;
    final entryRows =
        database.db.select('''SELECT * FROM audio_playback_session_entries
         WHERE session_id = ? ORDER BY sort_order''', [id]);
    final entries = entryRows
        .map((entry) => EntityListItem(
              id: entry['entity_id'] as String,
              title: entry['title'] as String,
              entityType: EntityType.audio,
              path: entry['path'] as String,
              format: entry['format'] as String,
              hash: entry['fingerprint'] as String,
              size: entry['size'] as int,
              modifiedAtMs: entry['modified_at_ms'] as int,
              durationMs: entry['duration_ms'] as int?,
            ))
        .toList(growable: false);
    return AudioPlaybackSession(
      id: id,
      name: row['name'] as String,
      sourceNodeId: row['source_node_id'] as String?,
      sourceNodeName: row['source_node_name'] as String?,
      mode: AudioPlaybackMode.values.firstWhere(
        (mode) => mode.name == row['mode'],
        orElse: () => AudioPlaybackMode.sequential,
      ),
      entries: entries,
      currentIndex: row['current_index'] as int,
      positionMs: row['position_ms'] as int,
      active: intToBool(row['active']),
      createdAtMs: row['created_at'] as int,
      updatedAtMs: row['updated_at'] as int,
      shuffleRemaining:
          _intListFromJson(row['shuffle_remaining_json'] as String?),
      history: _intListFromJson(row['history_json'] as String?),
    );
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
      NodeType.category => NodeType.categoryIndexRoot,
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
      NodeType.categoryIndexRoot ||
      NodeType.folder ||
      NodeType.category =>
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
}

String _indexNodeOrderBy(EntitySortMode sortMode) => switch (sortMode) {
      EntitySortMode.modifiedDesc =>
        'node.updated_at DESC, node.name COLLATE NOCASE ASC, node.id ASC',
      EntitySortMode.nameAsc => 'node.name COLLATE NOCASE ASC, node.id ASC',
      EntitySortMode.nameDesc => 'node.name COLLATE NOCASE DESC, node.id ASC',
      EntitySortMode.sizeDesc =>
        'COALESCE(stats.descendant_entity_count, 0) DESC, '
            'node.name COLLATE NOCASE ASC, node.id ASC',
      EntitySortMode.sizeAsc =>
        'COALESCE(stats.descendant_entity_count, 0) ASC, '
            'node.name COLLATE NOCASE ASC, node.id ASC',
      EntitySortMode.modifiedAsc =>
        'node.updated_at ASC, node.name COLLATE NOCASE ASC, node.id ASC',
      EntitySortMode.typeAsc =>
        'node.node_type ASC, node.name COLLATE NOCASE ASC, node.id ASC',
    };

List<int> _intListFromJson(String? value) {
  try {
    final decoded = jsonDecode(value ?? '[]');
    return decoded is List
        ? decoded.whereType<num>().map((item) => item.toInt()).toList()
        : const [];
  } catch (_) {
    return const [];
  }
}

Entity _entityFromRow(Row row, [ThumbnailStore? thumbnailStore]) {
  final thumbnailStatus =
      ThumbnailStatus.fromValue(row['thumbnail_status'] as String? ?? 'none');
  final thumbnailKey = row['thumbnail_key'] as String?;
  final thumbnailFormat = row['thumbnail_format'] as String?;
  return Entity(
    id: row['id'] as String,
    path: row['path'] as String,
    localPath: row['local_path'] as String?,
    name: row['name'] as String,
    format: row['format'] as String,
    entityType: EntityType.fromValue(row['media_type'] as String),
    hash: row['hash'] as String,
    size: row['size'] as int,
    sourceCreatedAtMs: row['source_created_at_ms'] as int,
    sourceModifiedAtMs: row['source_modified_at_ms'] as int,
    createdAtMs: row['created_at'] as int,
    updatedAtMs: row['updated_at'] as int,
    metadataPreview: row['metadata_preview'] as String?,
    thumbnailStatus: thumbnailStatus,
    thumbnailKey: thumbnailKey,
    thumbnailFormat: thumbnailFormat,
    thumbnailWidth: row['thumbnail_width'] as int?,
    thumbnailHeight: row['thumbnail_height'] as int?,
    thumbnailError: row['thumbnail_error'] as String?,
    thumbnailPath: thumbnailStatus == ThumbnailStatus.success &&
            thumbnailKey != null &&
            thumbnailFormat != null &&
            thumbnailKey.isNotEmpty &&
            thumbnailFormat.isNotEmpty
        ? thumbnailStore?.pathFor(thumbnailKey, thumbnailFormat)
        : null,
    archived: intToBool(row['archived']),
    lastOpenedAtMs: row['last_opened_at'] as int?,
    lastPositionMs: row['last_position_ms'] as int?,
    durationMs: row['duration_ms'] as int?,
    readerScrollOffset: row['reader_scroll_offset'] as double?,
    zoomScale: row['zoom_scale'] as double?,
    extraStateJson: row['extra_state_json'] as String?,
    directoryRootId: row['directory_root_id'] as String?,
  );
}

IndexBuildJob _indexBuildJobFromRow(Row row) => IndexBuildJob(
      id: row['id'] as String,
      sourcePath: row['source_path'] as String,
      indexRootId: row['index_root_id'] as String?,
      status: IndexJobStatus.values.byName(row['status'] as String),
      phase: IndexJobPhase.values.byName(row['phase'] as String),
      discovered: row['discovered'] as int,
      total: row['total'] as int,
      processed: row['processed'] as int,
      previewTotal: row['preview_total'] as int,
      previewProcessed: row['preview_processed'] as int,
      scanCompleted: (row['scan_completed'] as int? ?? 0) != 0,
      error: row['error'] as String?,
      targetNodeId: row['target_node_id'] as String?,
      stagingRootId: row['staging_root_id'] as String?,
      createdAtMs: row['created_at'] as int,
      updatedAtMs: row['updated_at'] as int,
    );

IndexJobCandidate _indexJobCandidateFromRow(Row row) => IndexJobCandidate(
      jobId: row['job_id'] as String,
      sourcePath: row['source_path'] as String,
      relativePath: row['relative_path'] as String,
      sequence: row['sequence'] as int,
      state: IndexJobCandidateState.values.byName(row['state'] as String),
      format: row['format'] as String?,
      entityType: (row['media_type'] as String?) == null
          ? null
          : EntityType.fromValue(row['media_type'] as String),
      fingerprint: row['fingerprint'] as String?,
      size: row['size'] as int?,
      metadataPreview: row['metadata_preview'] as String?,
      durationMs: row['duration_ms'] as int?,
      sourceCreatedAtMs: row['source_created_at_ms'] as int?,
      sourceModifiedAtMs: row['source_modified_at_ms'] as int?,
      error: row['error'] as String?,
      updatedAtMs: row['updated_at'] as int,
    );

IndexNode _nodeFromRow(Row row) {
  return IndexNode(
    id: row['id'] as String,
    parentId: row['parent_id'] as String?,
    name: row['name'] as String,
    nodeType: NodeType.fromValue(row['node_type'] as String),
    viewType: ViewType.fromValue(row['view_type'] as String),
    sourcePath: row['source_path'] as String?,
    thumbnailPng: row['thumbnail_png'] as Uint8List?,
    previewJson: row['preview_json'] as String?,
    sortOrder: row['sort_order'] as int,
    createdAtMs: row['created_at'] as int,
    updatedAtMs: row['updated_at'] as int,
    lastBuiltAtMs: row['last_built_at_ms'] as int?,
    isStaging: (row['is_staging'] as int? ?? 0) != 0,
  );
}

IndexNodePreviewTile _representativePreviewTile(
  IndexNode node,
  List<EntityListItem> entities,
) {
  final visuals = entities
      .where((entity) =>
          entity.entityType == EntityType.image ||
          entity.entityType == EntityType.video)
      .toList(growable: false);
  if (visuals.isNotEmpty) return _visualPreviewTile(visuals.first);
  final audioNames = entities
      .where((entity) => entity.entityType == EntityType.audio)
      .map(_nodePreviewAudioTitle)
      .toList(growable: false);
  final documentNames = entities
      .where(_isTextDataPreviewEntity)
      .map((entity) => entity.title)
      .toList(growable: false);
  if (audioNames.isNotEmpty && documentNames.isNotEmpty) {
    return IndexNodePreviewTile(
      kind: IndexNodePreviewTileKind.mixedData,
      title: node.name,
      audioNames: audioNames,
      documentNames: documentNames,
    );
  }
  if (audioNames.isNotEmpty) {
    return IndexNodePreviewTile(
      kind: IndexNodePreviewTileKind.audio,
      title: node.name,
      audioNames: audioNames,
    );
  }
  if (documentNames.isNotEmpty) {
    return IndexNodePreviewTile(
      kind: IndexNodePreviewTileKind.document,
      title: node.name,
      documentNames: documentNames,
    );
  }
  return IndexNodePreviewTile(
      kind: IndexNodePreviewTileKind.node, title: node.name);
}

IndexNodePreviewTile? _representativePreviewTileFromCache(IndexNode node) {
  final json = node.previewJson;
  if (json == null || json.isEmpty) return null;
  try {
    final value = jsonDecode(json);
    if (value is! Map<String, dynamic>) return null;
    final kind =
        IndexNodePreviewTileKind.values.byName(value['kind'] as String);
    final path = value['thumbnailPath'] as String?;
    return IndexNodePreviewTile(
      kind: kind,
      title: value['title'] as String? ?? node.name,
      thumbnailPath: path,
      aspectRatio: (value['aspectRatio'] as num?)?.toDouble() ?? 1,
      audioNames:
          (value['audioNames'] as List?)?.whereType<String>().toList() ??
              const [],
      documentNames:
          (value['documentNames'] as List?)?.whereType<String>().toList() ??
              const [],
    );
  } catch (_) {
    return null;
  }
}

List<IndexNodePreviewTile> _previewOverrideTiles(String value) {
  try {
    final decoded = jsonDecode(value);
    if (decoded is! List) return const [];
    return decoded.take(4).whereType<Map>().map((raw) {
      final item = Map<String, dynamic>.from(raw);
      return IndexNodePreviewTile(
        kind: IndexNodePreviewTileKind.values.byName(item['kind'] as String),
        title: item['title'] as String? ?? '',
        thumbnailPath: item['thumbnailPath'] as String?,
        entityId: item['entityId'] as String?,
        nodeId: item['nodeId'] as String?,
        aspectRatio: (item['aspectRatio'] as num?)?.toDouble() ?? 1,
        audioNames:
            (item['audioNames'] as List?)?.whereType<String>().toList() ??
                const [],
        documentNames:
            (item['documentNames'] as List?)?.whereType<String>().toList() ??
                const [],
      );
    }).toList(growable: false);
  } catch (_) {
    return const [];
  }
}

String? _previewTileToJson(IndexNodePreviewTile? tile) {
  if (tile == null) return null;
  return jsonEncode({
    'kind': tile.kind.name,
    'title': tile.title,
    'thumbnailPath': tile.thumbnailPath,
    'entityId': tile.entityId,
    'nodeId': tile.nodeId,
    'aspectRatio': tile.aspectRatio,
    'audioNames': tile.audioNames.take(3).toList(),
    'documentNames': tile.documentNames.take(3).toList(),
  });
}

IndexNodePreviewTile? _selectRepresentativePreviewTile(
  IndexNode node,
  List<EntityListItem> entities,
  List<IndexNodePreviewTile> childRepresentatives,
) {
  final visuals = entities
      .where((entity) =>
          entity.entityType == EntityType.image ||
          entity.entityType == EntityType.video)
      .toList(growable: false);
  if (visuals.isNotEmpty) return _visualPreviewTile(visuals.first);
  for (final child in childRepresentatives) {
    if (child.kind == IndexNodePreviewTileKind.visual) return child;
  }
  final direct = _representativePreviewTile(node, entities);
  if (direct.kind != IndexNodePreviewTileKind.node) return direct;
  return childRepresentatives.isEmpty ? direct : childRepresentatives.first;
}

IndexNodePreview _buildIndexNodePreview({
  required String nodeId,
  required List<IndexNodePreviewTile> childTiles,
  required List<EntityListItem> entities,
}) {
  final visuals = entities
      .where((entity) =>
          entity.entityType == EntityType.image ||
          entity.entityType == EntityType.video)
      .map(_visualPreviewTile)
      .toList(growable: false);
  final audioNames = entities
      .where((entity) => entity.entityType == EntityType.audio)
      .map(_nodePreviewAudioTitle)
      .toList(growable: false);
  final documentNames = entities
      .where(_isTextDataPreviewEntity)
      .map((entity) => entity.title)
      .toList(growable: false);
  final hasSemanticData = audioNames.isNotEmpty || documentNames.isNotEmpty;
  final visualCandidates = <IndexNodePreviewTile>[...childTiles, ...visuals]
    ..sort((left, right) => left.title.compareTo(right.title));

  if (visualCandidates.isEmpty) {
    if (audioNames.isEmpty && documentNames.isEmpty) {
      return IndexNodePreview(nodeId: nodeId, kind: IndexNodePreviewKind.empty);
    }
    if (audioNames.isNotEmpty && documentNames.isNotEmpty) {
      return IndexNodePreview(
        nodeId: nodeId,
        kind: IndexNodePreviewKind.splitLists,
        audioNames: audioNames,
        documentNames: documentNames,
      );
    }
    return IndexNodePreview(
      nodeId: nodeId,
      kind: audioNames.isNotEmpty
          ? IndexNodePreviewKind.audioList
          : IndexNodePreviewKind.documentList,
      audioNames: audioNames,
      documentNames: documentNames,
    );
  }

  // A pure media node deliberately keeps a single representative image.
  if (childTiles.isEmpty && !hasSemanticData) {
    return IndexNodePreview(
      nodeId: nodeId,
      kind: IndexNodePreviewKind.singleVisual,
      tiles: [visualCandidates.first],
    );
  }
  final tiles = <IndexNodePreviewTile>[
    ...visualCandidates.take(hasSemanticData ? 3 : 4)
  ];
  if (hasSemanticData) {
    tiles.add(IndexNodePreviewTile(
      kind: audioNames.isNotEmpty && documentNames.isNotEmpty
          ? IndexNodePreviewTileKind.mixedData
          : audioNames.isNotEmpty
              ? IndexNodePreviewTileKind.audio
              : IndexNodePreviewTileKind.document,
      title: '资料',
      audioNames: audioNames,
      documentNames: documentNames,
    ));
  }
  return IndexNodePreview(
    nodeId: nodeId,
    kind: IndexNodePreviewKind.visualGrid,
    tiles: tiles,
  );
}

IndexNodePreviewTile _visualPreviewTile(EntityListItem entity) =>
    IndexNodePreviewTile(
      kind: IndexNodePreviewTileKind.visual,
      title: entity.title,
      thumbnailPath: entity.thumbnailPath,
      entityId: entity.id,
      aspectRatio: _nodePreviewAspectRatio(entity),
    );

IndexNodePreviewTile _resolvePreviewOverrideTile(
  IndexNodePreviewTile tile,
  Map<String, EntityListItem> entities,
  Map<String, IndexNode> nodes,
) {
  final entityId = tile.entityId;
  if (entityId != null) {
    final entity = entities[entityId];
    if (entity != null) return _visualPreviewTile(entity);
  }
  final nodeId = tile.nodeId;
  if (nodeId != null) {
    final node = nodes[nodeId];
    if (node != null) {
      final representative = _representativePreviewTileFromCache(node);
      if (representative != null) {
        return IndexNodePreviewTile(
          kind: representative.kind,
          title: representative.title,
          thumbnailPath: representative.thumbnailPath,
          entityId: representative.entityId,
          nodeId: nodeId,
          aspectRatio: representative.aspectRatio,
          audioNames: representative.audioNames,
          documentNames: representative.documentNames,
        );
      }
      return IndexNodePreviewTile(
        kind: IndexNodePreviewTileKind.node,
        title: node.name,
        nodeId: nodeId,
      );
    }
  }
  return tile;
}

double _nodePreviewAspectRatio(EntityListItem entity) {
  final width = entity.thumbnailWidth;
  final height = entity.thumbnailHeight;
  if (width == null || height == null || width <= 0 || height <= 0) return 1;
  return width / height;
}

bool _isTextDataPreviewEntity(EntityListItem entity) {
  if (entity.entityType == EntityType.text) return true;
  return switch (entity.format.trim().toLowerCase()) {
    'epub' || 'pdf' || 'docx' || 'txt' || 'md' => true,
    _ => false,
  };
}

String _nodePreviewAudioTitle(EntityListItem entity) {
  final title = entity.title.trim();
  final extension = p.extension(title);
  return extension.isEmpty ? title : p.basenameWithoutExtension(title);
}

IndexNodeEdge _edgeFromRow(Row row) {
  return IndexNodeEdge(
    id: row['id'] as String,
    fromNodeId: row['from_node_id'] as String,
    toNodeId: row['to_node_id'] as String,
    edgeType: row['edge_type'] as String,
    label: row['label'] as String?,
    sortOrder: row['sort_order'] as int,
  );
}

EntityListItem _listItemFromRow(Row row, ThumbnailStore thumbnailStore) {
  final entity = _entityFromRow(row, thumbnailStore);
  return EntityListItem(
    id: entity.id,
    title: entity.name,
    entityType: entity.entityType,
    path: entity.path,
    format: entity.format,
    hash: entity.hash,
    size: entity.size,
    mimeType: entity.mimeType,
    metadataPreview: entity.metadataPreview,
    thumbnailStatus: entity.thumbnailStatus,
    thumbnailPath: entity.thumbnailPath,
    thumbnailWidth: entity.thumbnailWidth,
    thumbnailHeight: entity.thumbnailHeight,
    modifiedAtMs: entity.sourceModifiedAtMs,
    archived: entity.archived,
    lastOpenedAtMs: entity.lastOpenedAtMs,
    lastPositionMs: entity.lastPositionMs,
    durationMs: entity.durationMs,
    readerScrollOffset: entity.readerScrollOffset,
    zoomScale: entity.zoomScale,
    extraStateJson: entity.extraStateJson,
    localPath: entity.localPath,
  );
}

String _entityOrderBy(EntitySortMode sortMode) {
  return switch (sortMode) {
    EntitySortMode.nameAsc => 'e.name COLLATE NOCASE ASC, e.id ASC',
    EntitySortMode.nameDesc => 'e.name COLLATE NOCASE DESC, e.id ASC',
    EntitySortMode.modifiedDesc => 'e.source_modified_at_ms DESC, e.id ASC',
    EntitySortMode.modifiedAsc => 'e.source_modified_at_ms ASC, e.id ASC',
    EntitySortMode.sizeDesc => 'e.size DESC, e.id ASC',
    EntitySortMode.sizeAsc => 'e.size ASC, e.id ASC',
    EntitySortMode.typeAsc =>
      'e.format COLLATE NOCASE ASC, e.name COLLATE NOCASE ASC, e.id ASC',
  };
}

({String sql, List<Object> parameters}) _entityCursorCondition(
  EntityPageCursor cursor,
  EntitySortMode sortMode, {
  required String alias,
}) {
  if (cursor.sortMode != sortMode) {
    throw ArgumentError('Pagination cursor sort mode does not match query');
  }
  return switch (sortMode) {
    EntitySortMode.nameAsc => (
        sql:
            '$alias.name COLLATE NOCASE > ? OR ($alias.name COLLATE NOCASE = ? AND $alias.id > ?)',
        parameters: [cursor.primary, cursor.primary, cursor.entityId],
      ),
    EntitySortMode.nameDesc => (
        sql:
            '$alias.name COLLATE NOCASE < ? OR ($alias.name COLLATE NOCASE = ? AND $alias.id > ?)',
        parameters: [cursor.primary, cursor.primary, cursor.entityId],
      ),
    EntitySortMode.modifiedDesc => (
        sql:
            '$alias.source_modified_at_ms < ? OR ($alias.source_modified_at_ms = ? AND $alias.id > ?)',
        parameters: [cursor.primary, cursor.primary, cursor.entityId],
      ),
    EntitySortMode.modifiedAsc => (
        sql:
            '$alias.source_modified_at_ms > ? OR ($alias.source_modified_at_ms = ? AND $alias.id > ?)',
        parameters: [cursor.primary, cursor.primary, cursor.entityId],
      ),
    EntitySortMode.sizeDesc => (
        sql: '$alias.size < ? OR ($alias.size = ? AND $alias.id > ?)',
        parameters: [cursor.primary, cursor.primary, cursor.entityId],
      ),
    EntitySortMode.sizeAsc => (
        sql: '$alias.size > ? OR ($alias.size = ? AND $alias.id > ?)',
        parameters: [cursor.primary, cursor.primary, cursor.entityId],
      ),
    EntitySortMode.typeAsc => (
        sql: '''
$alias.format COLLATE NOCASE > ? OR
($alias.format COLLATE NOCASE = ? AND (
  $alias.name COLLATE NOCASE > ? OR
  ($alias.name COLLATE NOCASE = ? AND $alias.id > ?)
))
''',
        parameters: [
          cursor.primary,
          cursor.primary,
          cursor.secondary!,
          cursor.secondary!,
          cursor.entityId,
        ],
      ),
  };
}

bool _isSameOrChild(String path, String possibleParent) {
  final normalizedPath = p.normalize(path).toLowerCase();
  final normalizedParent = p.normalize(possibleParent).toLowerCase();
  return normalizedPath == normalizedParent ||
      p.isWithin(normalizedParent, normalizedPath);
}

bool _pathsOverlap(String left, String right) {
  return _isSameOrChild(left, right) || _isSameOrChild(right, left);
}

bool _isTopLevelIndexRootType(NodeType nodeType) {
  return nodeType == NodeType.categoryIndexRoot ||
      nodeType == NodeType.graphIndexRoot;
}

String _indexNameForRoot(String rootPath) {
  final normalized = p.normalize(rootPath);
  final name = p.basename(normalized).trim();
  return name.isEmpty ? '未命名索引' : name;
}

String _normalizeIndexNodeName(String name) {
  final normalized = name.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(name, 'name', 'Index node name cannot be empty');
  }
  return normalized;
}

String _normalizeEntityPath(String path) {
  final trimmed = path.trim();
  if (trimmed.startsWith('content://')) return trimmed;
  final normalized = p.normalize(trimmed);
  if (normalized.isEmpty || normalized == '.') {
    throw ArgumentError.value(path, 'path', 'Entity path cannot be empty');
  }
  return normalized;
}

String _normalizeSourcePath(String sourcePath) {
  final trimmed = sourcePath.trim();
  if (trimmed.startsWith('content://')) return trimmed;
  final normalized = p.normalize(trimmed);
  if (normalized.isEmpty || normalized == '.') {
    throw ArgumentError.value(
      sourcePath,
      'sourcePath',
      'Source path cannot be empty',
    );
  }
  return normalized;
}

String _normalizeEntityText(String value, String argumentName) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(
      value,
      argumentName,
      'Entity $argumentName cannot be empty',
    );
  }
  return normalized;
}

void _validateNonNegativeInt(int value, String argumentName) {
  if (value < 0) {
    throw ArgumentError.value(
      value,
      argumentName,
      'Entity $argumentName cannot be negative',
    );
  }
}

String _normalizeEdgeType(String edgeType) {
  final normalized = edgeType.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(
      edgeType,
      'edgeType',
      'Index node edge type cannot be empty',
    );
  }
  return normalized;
}

String? _normalizeOptionalText(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

ThumbnailStatus _defaultThumbnailStatusFor(EntityType type) {
  return ThumbnailStatus.none;
}

bool _hasGeneratedThumbnail(EntityType type) {
  return type == EntityType.image || type == EntityType.video;
}

void _validateThumbnailPng(Uint8List thumbnailPng) {
  final image = img.decodePng(thumbnailPng);
  if (image == null ||
      image.width != indexThumbnailWidth ||
      image.height != indexThumbnailHeight) {
    throw ArgumentError(
      'thumbnail_png must be a $indexThumbnailWidth x $indexThumbnailHeight PNG',
    );
  }
}
