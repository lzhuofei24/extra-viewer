import '../domain/models.dart';
import '../utils/ids.dart';
import 'library_repository.dart';
import '../../modules/build/build_access.dart';

enum _WorkCounter { document, entity, node }

/// Persistence boundary for the single parent build task. It deliberately
/// contains no rollback API: cancelling a build only stops future work and
/// never mutates already committed entities, nodes, or derived assets.
class LibraryBuildRepository implements BuildAccess {
  static const _jobSelect = '''SELECT library_build_jobs.*,
    (SELECT COUNT(*) FROM library_build_manifest m
     WHERE m.job_id = library_build_jobs.id AND m.write_state = 'failed') AS index_failed
    FROM library_build_jobs''';
  @override
  void finalizeIndex(LibraryBuildJob job) {
    validateScope(job);
    if (!job.manifestComplete) {
      throw StateError('目录尚未完整枚举，不能对账移除资料');
    }
    if ((get(job.id)?.indexFailed ?? 0) > 0) {
      block(job.id, '部分文件读取失败，已提交资料保留；修复后仅重试失败项。未执行删除对账。');
      return;
    }
    final rootId = job.indexRootId;
    if (rootId == null) throw StateError('索引根节点缺失');
    final scopeId = job.targetNodeId ?? rootId;
    final seen = <String>[];
    var cursor = -1;
    while (true) {
      final page = listManifestPage(job.id, afterSequence: cursor);
      if (page.isEmpty) break;
      seen.addAll(page.map((item) => item.sourcePath));
      cursor = page.last.sequence;
    }
    if (job.targetNodeId == null) {
      library.reconcileDirectoryIndexRoot(rootId: rootId, seenPaths: seen);
      if (job.stagingRootId != null) {
        library.replaceOverlappingDirectoryIndexRoots(
          keepRootId: rootId,
          sourcePath: job.sourcePath,
        );
      }
    } else {
      library.reconcileDirectoryIndexSubtree(
        nodeId: scopeId,
        rootId: rootId,
        seenPaths: seen,
      );
      library.pruneEmptyDirectoryNodes(rootId);
    }
    library.rebuildIndexNodeStats();
    prepareDocumentPreviewWork(job.id, scopeId);
    final refreshed = get(job.id)!;
    checkpointStage(
      jobId: job.id,
      stage: LibraryBuildStage.documentPreviews,
      documentPreviewTotal: refreshed.documentPreviewTotal,
    );
  }

  LibraryBuildRepository(this.library);

  final LibraryRepository library;

  @override
  LibraryBuildJob create({
    required String sourcePath,
    required LibraryBuildOperation operation,
    String? targetNodeId,
    LibraryBuildKind kind = LibraryBuildKind.scanScope,
  }) {
    final now = nowMillis();
    final job = LibraryBuildJob(
      id: newId(),
      sourcePath: sourcePath,
      operation: operation,
      targetNodeId: targetNodeId,
      scopeNodeId: targetNodeId,
      kind: kind,
      stage: LibraryBuildStage.manifest,
      status: LibraryBuildStatus.pending,
      manifestTotal: 0,
      indexedTotal: 0,
      documentPreviewTotal: 0,
      documentPreviewDone: 0,
      documentPreviewFailed: 0,
      entityPreviewTotal: 0,
      entityPreviewDone: 0,
      entityPreviewFailed: 0,
      nodePreviewTotal: 0,
      nodePreviewDone: 0,
      nodePreviewFailed: 0,
      createdAtMs: now,
      updatedAtMs: now,
    );
    library.database.db.execute('''
      INSERT INTO library_build_jobs(
        id, source_path, operation_type, target_node_id, stage, status,
        created_at, updated_at, kind, scope_node_id
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      job.id,
      job.sourcePath,
      job.operation.name,
      job.targetNodeId,
      job.stage.name,
      job.status.name,
      now,
      now,
      kind.name,
      targetNodeId,
    ]);
    return job;
  }

  @override
  LibraryBuildJob? get(String jobId) {
    final rows = library.database.db.select(
      '$_jobSelect WHERE id = ? LIMIT 1',
      [jobId],
    );
    return rows.isEmpty ? null : _jobFromRow(rows.single);
  }

  @override
  List<LibraryBuildJob> listRecoverable() => library.database.db.select('''
        $_jobSelect
        WHERE status IN ('pending', 'running', 'pauseRequested', 'paused', 'blocked', 'failed', 'completedWithErrors')
          AND stage != 'completed'
        ORDER BY updated_at DESC
      ''').map(_jobFromRow).toList(growable: false);

  @override
  List<LibraryBuildJob> listHistory({int limit = 100}) => library.database.db
      .select('''
        $_jobSelect
        WHERE status IN ('completed', 'abandoned')
        ORDER BY updated_at DESC LIMIT ?
      ''', [limit.clamp(1, 100).toInt()])
      .map(_jobFromRow)
      .toList(growable: false);

  @override
  void markInterruptedRecoverable() {
    library.writeTransaction(() {
      final now = nowMillis();
      library.database.db.execute('''
        UPDATE library_build_jobs
        SET status = 'paused', updated_at = ?
        WHERE status = 'running'
      ''', [now]);
      library.database.db.execute('''
        UPDATE library_entity_preview_work
        SET state = 'pending', updated_at = ?
        WHERE state = 'processing'
      ''', [now]);
      library.database.db.execute('''
        UPDATE library_document_preview_work
        SET state = 'pending', updated_at = ?
        WHERE state = 'processing'
      ''', [now]);
      library.database.db.execute('''
        UPDATE library_node_preview_work
        SET state = 'pending', updated_at = ?
        WHERE state = 'processing'
      ''', [now]);
    });
  }

  @override
  LibraryBuildJob setRunning(String jobId) => _update(
        jobId,
        status: LibraryBuildStatus.running,
        clearError: true,
      );

  @override
  LibraryBuildJob pause(String jobId) => _update(
        jobId,
        status: LibraryBuildStatus.paused,
      );

  @override
  LibraryBuildJob fail(String jobId, Object error) => _update(
        jobId,
        status: LibraryBuildStatus.failed,
        error: '$error',
      );

  @override
  LibraryBuildJob block(String jobId, Object error) => _update(
        jobId,
        status: LibraryBuildStatus.blocked,
        error: '$error',
      );

  @override
  void validateScope(LibraryBuildJob job) {
    if (job.scopeNodeId != null &&
        (job.targetNodeId != job.scopeNodeId ||
            library.getIndexNode(job.scopeNodeId!) == null)) {
      throw StateError('任务目标已改变，禁止扩大到根目录');
    }
    if (job.stage != LibraryBuildStage.manifest &&
        job.stage != LibraryBuildStage.indexWrite &&
        (job.indexRootId == null ||
            library.getIndexNode(job.indexRootId!) == null)) {
      throw StateError('任务根节点已不存在');
    }
  }

  @override
  void completeManifest(String jobId, int total) {
    library.writeTransaction(() {
      library.database.db.execute(
          'UPDATE library_build_jobs SET manifest_complete = 1 WHERE id = ?',
          [jobId]);
      checkpointStage(
          jobId: jobId,
          stage: LibraryBuildStage.indexWrite,
          manifestTotal: total);
    });
  }

  @override
  void abandon(String jobId) {
    _update(jobId, status: LibraryBuildStatus.abandoned);
    library.database.checkpointWriteAheadLog();
  }

  @override
  LibraryBuildJob setRoots({
    required String jobId,
    required String indexRootId,
    String? stagingRootId,
  }) =>
      _update(
        jobId,
        indexRootId: indexRootId,
        stagingRootId: stagingRootId,
      );

  @override
  LibraryBuildJob checkpointStage({
    required String jobId,
    required LibraryBuildStage stage,
    int? manifestTotal,
    int? indexedTotal,
    int? documentPreviewTotal,
    int? entityPreviewTotal,
    int? nodePreviewTotal,
  }) =>
      _update(
        jobId,
        stage: stage,
        status: stage == LibraryBuildStage.completed
            ? LibraryBuildStatus.completed
            : LibraryBuildStatus.running,
        manifestTotal: manifestTotal,
        indexedTotal: indexedTotal,
        documentPreviewTotal: documentPreviewTotal,
        entityPreviewTotal: entityPreviewTotal,
        nodePreviewTotal: nodePreviewTotal,
      );

  @override
  void resetManifest(String jobId) {
    library.writeTransaction(() {
      library.database.db.execute(
        'DELETE FROM library_build_manifest WHERE job_id = ?',
        [jobId],
      );
      _update(
        jobId,
        stage: LibraryBuildStage.manifest,
        manifestTotal: 0,
        indexedTotal: 0,
      );
    });
  }

  @override
  void upsertManifest(Iterable<LibraryBuildManifestItem> values) {
    final items = values.toList(growable: false);
    if (items.isEmpty) return;
    final statement = library.database.db.prepare('''
      INSERT INTO library_build_manifest(
        job_id, source_path, relative_path, sequence, name, format,
        media_type, fingerprint, size, metadata_preview, duration_ms,
        source_created_at_ms, source_modified_at_ms
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(job_id, source_path) DO UPDATE SET
        relative_path = excluded.relative_path,
        sequence = excluded.sequence,
        name = excluded.name,
        format = excluded.format,
        media_type = excluded.media_type,
        fingerprint = excluded.fingerprint,
        size = excluded.size,
        metadata_preview = excluded.metadata_preview,
        duration_ms = excluded.duration_ms,
        source_created_at_ms = excluded.source_created_at_ms,
        source_modified_at_ms = excluded.source_modified_at_ms
    ''');
    try {
      for (final item in items) {
        statement.execute([
          item.jobId,
          item.sourcePath,
          item.relativePath,
          item.sequence,
          item.name,
          item.format,
          item.entityType.value,
          item.fingerprint,
          item.size,
          item.contentExcerpt,
          item.durationMs,
          item.sourceCreatedAtMs,
          item.sourceModifiedAtMs,
        ]);
      }
    } finally {
      statement.dispose();
    }
  }

  @override
  int manifestItemCount(String jobId) =>
      _count('library_build_manifest', jobId);

  @override
  bool hasDirectoryFrontier(String jobId) => library.database.db.select(
      'SELECT 1 FROM scan_directories WHERE job_id = ? LIMIT 1',
      [jobId]).isNotEmpty;

  @override
  void checkpoint() => library.database.checkpointWriteAheadLog();

  @override
  void seedDirectory(String jobId, String locator) {
    library.database.db.execute('''
      INSERT OR IGNORE INTO scan_directories(job_id, locator, relative_path)
      VALUES (?, ?, '')
    ''', [jobId, locator]);
  }

  @override
  ({String locator, String relativePath})? nextDirectory(String jobId) {
    final rows = library.database.db.select('''
      SELECT locator, relative_path FROM scan_directories
      WHERE job_id = ? AND state != 'completed' ORDER BY relative_path LIMIT 1
    ''', [jobId]);
    if (rows.isEmpty) return null;
    return (
      locator: rows.first['locator'] as String,
      relativePath: rows.first['relative_path'] as String
    );
  }

  @override
  int beginDirectory(String jobId, String locator, String relativePath) {
    library.writeTransaction(() {
      library.database.db.execute(
          'DELETE FROM library_build_manifest WHERE job_id = ? AND directory_locator = ?',
          [jobId, locator]);
      // An unfinished directory has not dispatched its children yet. Discard
      // that partial frontier before re-enumerating it in an arbitrary order.
      library.database.db.execute('''
        DELETE FROM scan_directories WHERE job_id = ? AND locator != ?
          AND (? = '' OR substr(relative_path, 1, length(?) + 1) = ? || '/')
      ''', [jobId, locator, relativePath, relativePath, relativePath]);
    });
    return library.database.db.select(
        'SELECT COALESCE(MAX(sequence), -1) + 1 AS next FROM library_build_manifest WHERE job_id = ?',
        [jobId]).single['next'] as int;
  }

  @override
  void commitDirectoryPage(
      String jobId,
      String locator,
      List<LibraryBuildManifestItem> items,
      List<({String locator, String relativePath})> directories) {
    library.writeTransaction(() {
      upsertManifest(items);
      final statement = library.database.db.prepare(
          'UPDATE library_build_manifest SET directory_locator = ? WHERE job_id = ? AND source_path = ?');
      try {
        for (final item in items) {
          statement.execute([locator, jobId, item.sourcePath]);
        }
      } finally {
        statement.dispose();
      }
      final enqueue = library.database.db.prepare(
          'INSERT OR IGNORE INTO scan_directories(job_id, locator, relative_path) VALUES (?, ?, ?)');
      try {
        for (final dir in directories) {
          enqueue.execute([jobId, dir.locator, dir.relativePath]);
        }
      } finally {
        enqueue.dispose();
      }
    });
  }

  @override
  void completeDirectory(String jobId, String locator) {
    library.database.db.execute(
        "UPDATE scan_directories SET state = 'completed', error = NULL WHERE job_id = ? AND locator = ?",
        [jobId, locator]);
  }

  @override
  void updateIndexedProgress(String jobId, int indexedTotal) {
    _update(jobId, indexedTotal: indexedTotal);
  }

  @override
  List<LibraryBuildManifestItem> listManifestPage(
    String jobId, {
    required int afterSequence,
    int limit = 200,
    bool pendingOnly = false,
  }) =>
      library.database.db
          .select('''
        SELECT * FROM library_build_manifest
        WHERE job_id = ? AND sequence > ?
          ${pendingOnly ? "AND write_state = 'pending'" : ''}
        ORDER BY sequence ASC LIMIT ?
      ''', [jobId, afterSequence, limit.clamp(1, 1000).toInt()])
          .map(_manifestFromRow)
          .toList(growable: false);

  @override
  void prepareEntityPreviewWork(String jobId, String scopeNodeId) {
    final now = nowMillis();
    library.database.db.execute('''
      WITH RECURSIVE subtree(id) AS (
        SELECT ?
        UNION ALL
        SELECT child.id FROM index_nodes child JOIN subtree ON child.parent_id = subtree.id
      )
      INSERT OR IGNORE INTO library_entity_preview_work(
        job_id, entity_id, state, attempts, updated_at
      )
      SELECT ?, entity.id, 'pending', 0, ?
      FROM index_node_entities link
      JOIN entities entity ON entity.id = link.entity_id
      WHERE link.index_node_id IN (SELECT id FROM subtree)
        AND (
          entity.media_type IN ('image', 'video') OR
          entity.format IN ('epub', 'docx')
        )
        AND (
          entity.thumbnail_status != 'success' OR
          entity.thumbnail_key IS NULL OR
          entity.thumbnail_key NOT LIKE 'v6_%'
        )
    ''', [scopeNodeId, jobId, now]);
    final count = _count('library_entity_preview_work', jobId);
    _update(jobId, entityPreviewTotal: count);
  }

  @override
  void prepareDocumentPreviewWork(String jobId, String scopeNodeId) {
    final now = nowMillis();
    library.database.db.execute('''
      WITH RECURSIVE subtree(id) AS (
        SELECT ?
        UNION ALL
        SELECT child.id FROM index_nodes child JOIN subtree ON child.parent_id = subtree.id
      )
      INSERT OR IGNORE INTO library_document_preview_work(
        job_id, entity_id, state, attempts, updated_at
      )
      SELECT ?, entity.id, 'pending', 0, ?
      FROM index_node_entities link
      JOIN entities entity ON entity.id = link.entity_id
      WHERE link.index_node_id IN (SELECT id FROM subtree)
        AND entity.media_type IN ('text', 'external')
        AND (
          entity.format = 'epub' OR
          entity.metadata_preview IS NULL OR entity.metadata_preview = ''
        )
    ''', [scopeNodeId, jobId, now]);
    final count = _count('library_document_preview_work', jobId);
    _update(jobId, documentPreviewTotal: count);
  }

  @override
  void prepareNodePreviewWork(
    String jobId, {
    required String scopeNodeId,
    required String rootNodeId,
    IndexPreviewRebuildScope scope = IndexPreviewRebuildScope.subtree,
  }) {
    final now = nowMillis();
    final selectedNodes = scope == IndexPreviewRebuildScope.subtree
        ? 'SELECT id FROM subtree UNION SELECT id FROM ancestors'
        : 'SELECT id FROM ancestors';
    library.database.db.execute('''
      WITH RECURSIVE subtree(id) AS (
        SELECT ?
        UNION ALL
        SELECT child.id FROM index_nodes child JOIN subtree ON child.parent_id = subtree.id
      ), ancestors(id) AS (
        SELECT ?
        UNION ALL
        SELECT parent.parent_id
        FROM index_nodes parent JOIN ancestors ON parent.id = ancestors.id
        WHERE parent.parent_id IS NOT NULL
      )
      INSERT OR IGNORE INTO library_node_preview_work(
        job_id, node_id, state, attempts, updated_at
      )
      SELECT ?, id, 'pending', 0, ?
      FROM ($selectedNodes)
    ''', [scopeNodeId, scopeNodeId, jobId, now]);
    final count = _count('library_node_preview_work', jobId);
    _update(jobId, nodePreviewTotal: count);
  }

  @override
  bool nodePreviewWorkIncludesDescendants(
    String jobId,
    String scopeNodeId,
  ) {
    return library.database.db.select('''
      WITH RECURSIVE descendants(id) AS (
        SELECT id FROM index_nodes WHERE parent_id = ?
        UNION ALL
        SELECT child.id
        FROM index_nodes child JOIN descendants ON child.parent_id = descendants.id
      )
      SELECT 1
      FROM library_node_preview_work work
      JOIN descendants ON descendants.id = work.node_id
      WHERE work.job_id = ?
      LIMIT 1
    ''', [scopeNodeId, jobId]).isNotEmpty;
  }

  @override
  List<String> claimEntityPreviewWork(String jobId, {int limit = 100}) =>
      _claimWork(
        table: 'library_entity_preview_work',
        idColumn: 'entity_id',
        jobId: jobId,
        limit: limit,
      );

  @override
  List<String> claimDocumentPreviewWork(String jobId, {int limit = 100}) =>
      _claimWork(
        table: 'library_document_preview_work',
        idColumn: 'entity_id',
        jobId: jobId,
        limit: limit,
      );

  @override
  List<String> claimNodePreviewWork(String jobId, {int limit = 8}) =>
      _claimWork(
        table: 'library_node_preview_work',
        idColumn: 'node_id',
        jobId: jobId,
        limit: limit,
      );

  @override
  void completeEntityPreviewWork(
    String jobId,
    Map<String, ({LibraryBuildWorkState state, String? error})> results,
  ) =>
      _completeWork(
        table: 'library_entity_preview_work',
        idColumn: 'entity_id',
        jobId: jobId,
        results: results,
        counter: _WorkCounter.entity,
      );

  @override
  void completeDocumentPreviewWork(
    String jobId,
    Map<String, ({LibraryBuildWorkState state, String? error})> results,
  ) =>
      _completeWork(
        table: 'library_document_preview_work',
        idColumn: 'entity_id',
        jobId: jobId,
        results: results,
        counter: _WorkCounter.document,
      );

  @override
  void completeNodePreviewWork(
    String jobId,
    Map<String, ({LibraryBuildWorkState state, String? error})> results,
  ) =>
      _completeWork(
        table: 'library_node_preview_work',
        idColumn: 'node_id',
        jobId: jobId,
        results: results,
        counter: _WorkCounter.node,
      );

  @override
  bool hasPendingEntityPreviewWork(String jobId) =>
      _hasPending('library_entity_preview_work', jobId);

  @override
  bool hasPendingNodePreviewWork(String jobId) =>
      _hasPending('library_node_preview_work', jobId);

  @override
  bool hasPendingDocumentPreviewWork(String jobId) =>
      _hasPending('library_document_preview_work', jobId);

  @override
  void releaseProcessingWork(String jobId, {required LibraryBuildStage stage}) {
    final table = switch (stage) {
      LibraryBuildStage.documentPreviews => 'library_document_preview_work',
      LibraryBuildStage.entityPreviews => 'library_entity_preview_work',
      LibraryBuildStage.nodePreviews => 'library_node_preview_work',
      _ => null,
    };
    if (table == null) return;
    library.database.db.execute('''
      UPDATE $table SET state = 'pending', updated_at = ?
      WHERE job_id = ? AND state = 'processing'
    ''', [nowMillis(), jobId]);
  }

  @override
  void retryFailedAssets(String jobId) {
    final job = get(jobId);
    if (job == null) return;
    final now = nowMillis();
    library.writeTransaction(() {
      if (job.indexFailed > 0) {
        library.database.db.execute(
            "UPDATE library_build_manifest SET write_state = 'pending', error = NULL WHERE job_id = ? AND write_state = 'failed'",
            [jobId]);
        library.database.db.execute(
            "UPDATE library_build_jobs SET index_cursor = -1, stage = 'indexWrite', status = 'pending', error = NULL, updated_at = ? WHERE id = ?",
            [now, jobId]);
        return;
      }
      for (final table in const [
        'library_document_preview_work',
        'library_entity_preview_work',
        'library_node_preview_work',
      ]) {
        library.database.db.execute('''
          UPDATE $table
          SET state = 'pending', error = NULL, updated_at = ?
          WHERE job_id = ? AND state = 'failed'
        ''', [now, jobId]);
      }
      final retryStage = job.documentPreviewFailed > 0
          ? LibraryBuildStage.documentPreviews
          : job.entityPreviewFailed > 0
              ? LibraryBuildStage.entityPreviews
              : LibraryBuildStage.nodePreviews;
      library.database.db.execute('''
        UPDATE library_build_jobs
        SET stage = ?, status = 'pending', error = NULL, updated_at = ?,
          document_preview_failed = 0, entity_preview_failed = 0, node_preview_failed = 0
        WHERE id = ?
      ''', [retryStage.name, now, jobId]);
    });
  }

  @override
  void restartFromManifest(String jobId) {
    final job = get(jobId);
    if (job == null) return;
    validateScope(job);
    if (job.kind != LibraryBuildKind.scanScope) {
      throw StateError('预览任务不支持重新枚举目录');
    }
    library.writeTransaction(() {
      library.database.db
          .execute('DELETE FROM scan_directories WHERE job_id = ?', [jobId]);
      library.database.db.execute(
        'DELETE FROM library_build_manifest WHERE job_id = ?',
        [jobId],
      );
      library.database.db.execute(
        'DELETE FROM library_entity_preview_work WHERE job_id = ?',
        [jobId],
      );
      library.database.db.execute(
        'DELETE FROM library_document_preview_work WHERE job_id = ?',
        [jobId],
      );
      library.database.db.execute(
        'DELETE FROM library_node_preview_work WHERE job_id = ?',
        [jobId],
      );
      library.database.db.execute('''
        UPDATE library_build_jobs SET
          stage = 'manifest', status = 'pending', manifest_total = 0,
          manifest_complete = 0, index_cursor = -1, scan_generation = scan_generation + 1,
          indexed_total = 0, document_preview_total = 0, document_preview_done = 0,
          document_preview_failed = 0, entity_preview_total = 0, entity_preview_done = 0,
          entity_preview_failed = 0, node_preview_total = 0,
          node_preview_done = 0, node_preview_failed = 0, error = NULL,
          updated_at = ?
        WHERE id = ?
      ''', [nowMillis(), jobId]);
    });
  }

  LibraryBuildJob _update(
    String jobId, {
    LibraryBuildStage? stage,
    LibraryBuildStatus? status,
    String? indexRootId,
    String? stagingRootId,
    int? manifestTotal,
    int? indexedTotal,
    int? documentPreviewTotal,
    int? entityPreviewTotal,
    int? nodePreviewTotal,
    String? error,
    bool clearError = false,
  }) {
    library.database.db.execute('''
      UPDATE library_build_jobs SET
        stage = COALESCE(?, stage),
        status = COALESCE(?, status),
        index_root_id = COALESCE(?, index_root_id),
        staging_root_id = COALESCE(?, staging_root_id),
        manifest_total = COALESCE(?, manifest_total),
        indexed_total = COALESCE(?, indexed_total),
        document_preview_total = COALESCE(?, document_preview_total),
        entity_preview_total = COALESCE(?, entity_preview_total),
        node_preview_total = COALESCE(?, node_preview_total),
        error = CASE WHEN ? THEN NULL ELSE COALESCE(?, error) END,
        updated_at = ?
      WHERE id = ?
    ''', [
      stage?.name,
      status?.name,
      indexRootId,
      stagingRootId,
      manifestTotal,
      indexedTotal,
      documentPreviewTotal,
      entityPreviewTotal,
      nodePreviewTotal,
      clearError ? 1 : 0,
      error,
      nowMillis(),
      jobId,
    ]);
    return get(jobId)!;
  }

  List<String> _claimWork({
    required String table,
    required String idColumn,
    required String jobId,
    required int limit,
  }) {
    final rows = library.database.db.select('''
      SELECT $idColumn FROM $table
      WHERE job_id = ? AND state = 'pending'
      ORDER BY $idColumn ASC LIMIT ?
    ''', [jobId, limit.clamp(1, 100).toInt()]);
    final ids = rows.map((row) => row[idColumn] as String).toList();
    if (ids.isEmpty) return ids;
    final placeholders = List.filled(ids.length, '?').join(',');
    library.database.db.execute('''
      UPDATE $table SET state = 'processing', attempts = attempts + 1, updated_at = ?
      WHERE job_id = ? AND $idColumn IN ($placeholders)
    ''', [nowMillis(), jobId, ...ids]);
    return ids;
  }

  void _completeWork({
    required String table,
    required String idColumn,
    required String jobId,
    required Map<String, ({LibraryBuildWorkState state, String? error})>
        results,
    required _WorkCounter counter,
  }) {
    if (results.isEmpty) return;
    library.writeTransaction(() {
      var doneDelta = 0;
      var failedDelta = 0;
      final statement = library.database.db.prepare('''
        UPDATE $table SET state = ?, error = ?, updated_at = ?
        WHERE job_id = ? AND $idColumn = ? AND state = 'processing'
      ''');
      try {
        for (final entry in results.entries) {
          statement.execute([
            entry.value.state.name,
            entry.value.error,
            nowMillis(),
            jobId,
            entry.key,
          ]);
          if (library.database.db.updatedRows == 0) continue;
          if (entry.value.state == LibraryBuildWorkState.completed ||
              entry.value.state == LibraryBuildWorkState.skipped) {
            doneDelta++;
          }
          if (entry.value.state == LibraryBuildWorkState.failed) failedDelta++;
        }
      } finally {
        statement.dispose();
      }
      final columns = switch (counter) {
        _WorkCounter.document => (
            'document_preview_done',
            'document_preview_failed'
          ),
        _WorkCounter.entity => ('entity_preview_done', 'entity_preview_failed'),
        _WorkCounter.node => ('node_preview_done', 'node_preview_failed'),
      };
      library.database.db.execute(
        'UPDATE library_build_jobs SET ${columns.$1} = ${columns.$1} + ?, ${columns.$2} = ${columns.$2} + ?, '
        'updated_at = ? WHERE id = ?',
        [doneDelta, failedDelta, nowMillis(), jobId],
      );
    });
  }

  int _count(String table, String jobId) => library.database.db.select(
      'SELECT COUNT(*) AS value FROM $table WHERE job_id = ?',
      [jobId]).single['value'] as int;

  bool _hasPending(String table, String jobId) => library.database.db.select('''
    SELECT 1 FROM $table WHERE job_id = ? AND state = 'pending' LIMIT 1
  ''', [jobId]).isNotEmpty;

  LibraryBuildJob _jobFromRow(dynamic row) => LibraryBuildJob(
        id: row['id'] as String,
        kind: LibraryBuildKind.values.byName(row['kind'] as String),
        scopeNodeId: row['scope_node_id'] as String?,
        manifestComplete: row['manifest_complete'] == 1,
        indexCursor: row['index_cursor'] as int,
        indexFailed: row['index_failed'] as int? ?? 0,
        sourcePath: row['source_path'] as String,
        operation: LibraryBuildOperation.values.byName(
          row['operation_type'] as String,
        ),
        targetNodeId: row['target_node_id'] as String?,
        indexRootId: row['index_root_id'] as String?,
        stagingRootId: row['staging_root_id'] as String?,
        stage: LibraryBuildStage.fromStorageValue(row['stage'] as String),
        status: LibraryBuildStatus.fromStorageValue(row['status'] as String),
        manifestTotal: row['manifest_total'] as int,
        indexedTotal: row['indexed_total'] as int,
        documentPreviewTotal: row['document_preview_total'] as int,
        documentPreviewDone: row['document_preview_done'] as int,
        documentPreviewFailed: row['document_preview_failed'] as int,
        entityPreviewTotal: row['entity_preview_total'] as int,
        entityPreviewDone: row['entity_preview_done'] as int,
        entityPreviewFailed: row['entity_preview_failed'] as int,
        nodePreviewTotal: row['node_preview_total'] as int,
        nodePreviewDone: row['node_preview_done'] as int,
        nodePreviewFailed: row['node_preview_failed'] as int,
        error: row['error'] as String?,
        createdAtMs: row['created_at'] as int,
        updatedAtMs: row['updated_at'] as int,
      );

  LibraryBuildManifestItem _manifestFromRow(dynamic row) =>
      LibraryBuildManifestItem(
        jobId: row['job_id'] as String,
        sourcePath: row['source_path'] as String,
        relativePath: row['relative_path'] as String,
        sequence: row['sequence'] as int,
        name: row['name'] as String,
        format: row['format'] as String,
        entityType: EntityType.fromValue(row['media_type'] as String),
        fingerprint: row['fingerprint'] as String?,
        size: row['size'] as int,
        contentExcerpt: row['metadata_preview'] as String?,
        durationMs: row['duration_ms'] as int?,
        sourceCreatedAtMs: row['source_created_at_ms'] as int,
        sourceModifiedAtMs: row['source_modified_at_ms'] as int,
      );
}
