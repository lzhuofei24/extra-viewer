import '../domain/models.dart';
import '../utils/ids.dart';
import 'library_repository.dart';

enum _WorkCounter { document, entity, node }

/// Persistence boundary for the single parent build task. It deliberately
/// contains no rollback API: cancelling a build only stops future work and
/// never mutates already committed entities, nodes, or derived assets.
class LibraryBuildRepository {
  LibraryBuildRepository(this.library);

  final LibraryRepository library;

  LibraryBuildJob create({
    required String sourcePath,
    required LibraryBuildOperation operation,
    String? targetNodeId,
  }) {
    final now = nowMillis();
    final job = LibraryBuildJob(
      id: newId(),
      sourcePath: sourcePath,
      operation: operation,
      targetNodeId: targetNodeId,
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
        created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      job.id,
      job.sourcePath,
      job.operation.name,
      job.targetNodeId,
      job.stage.name,
      job.status.name,
      now,
      now,
    ]);
    return job;
  }

  LibraryBuildJob? get(String jobId) {
    final rows = library.database.db.select(
      'SELECT * FROM library_build_jobs WHERE id = ? LIMIT 1',
      [jobId],
    );
    return rows.isEmpty ? null : _jobFromRow(rows.single);
  }

  List<LibraryBuildJob> listRecoverable() => library.database.db.select('''
        SELECT * FROM library_build_jobs
        WHERE status IN ('pending', 'running', 'paused', 'failed')
          AND stage != 'completed'
        ORDER BY updated_at DESC
      ''').map(_jobFromRow).toList(growable: false);

  List<LibraryBuildJob> listHistory({int limit = 6}) => library.database.db
      .select('''
        SELECT * FROM library_build_jobs
        WHERE status IN ('completed', 'abandoned')
        ORDER BY updated_at DESC LIMIT ?
      ''', [limit.clamp(1, 100).toInt()])
      .map(_jobFromRow)
      .toList(growable: false);

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

  LibraryBuildJob setRunning(String jobId) => _update(
        jobId,
        status: LibraryBuildStatus.running,
        clearError: true,
      );

  LibraryBuildJob pause(String jobId) => _update(
        jobId,
        status: LibraryBuildStatus.paused,
      );

  LibraryBuildJob fail(String jobId, Object error) => _update(
        jobId,
        status: LibraryBuildStatus.failed,
        error: '$error',
      );

  void abandon(String jobId) {
    _update(jobId, status: LibraryBuildStatus.abandoned);
    library.database.checkpointWriteAheadLog();
  }

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
          item.metadataPreview,
          item.durationMs,
          item.sourceCreatedAtMs,
          item.sourceModifiedAtMs,
        ]);
      }
    } finally {
      statement.dispose();
    }
  }

  int manifestItemCount(String jobId) =>
      _count('library_build_manifest', jobId);

  void updateIndexedProgress(String jobId, int indexedTotal) {
    _update(jobId, indexedTotal: indexedTotal);
  }

  List<LibraryBuildManifestItem> listManifestPage(
    String jobId, {
    required int afterSequence,
    int limit = 200,
  }) =>
      library.database.db
          .select('''
        SELECT * FROM library_build_manifest
        WHERE job_id = ? AND sequence > ?
        ORDER BY sequence ASC LIMIT ?
      ''', [jobId, afterSequence, limit.clamp(1, 1000).toInt()])
          .map(_manifestFromRow)
          .toList(growable: false);

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
        AND entity.media_type IN ('image', 'video')
        AND (entity.thumbnail_status != 'success' OR entity.thumbnail_key IS NULL)
    ''', [scopeNodeId, jobId, now]);
    final count = _count('library_entity_preview_work', jobId);
    _update(jobId, entityPreviewTotal: count);
  }

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
        AND (entity.metadata_preview IS NULL OR entity.metadata_preview = '')
    ''', [scopeNodeId, jobId, now]);
    final count = _count('library_document_preview_work', jobId);
    _update(jobId, documentPreviewTotal: count);
  }

  void prepareNodePreviewWork(
    String jobId, {
    required String scopeNodeId,
    required String rootNodeId,
  }) {
    final now = nowMillis();
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
      FROM (
        SELECT id FROM subtree
        UNION
        SELECT id FROM ancestors
      )
    ''', [scopeNodeId, scopeNodeId, jobId, now]);
    final count = _count('library_node_preview_work', jobId);
    _update(jobId, nodePreviewTotal: count);
  }

  List<String> claimEntityPreviewWork(String jobId, {int limit = 100}) =>
      _claimWork(
        table: 'library_entity_preview_work',
        idColumn: 'entity_id',
        jobId: jobId,
        limit: limit,
      );

  List<String> claimDocumentPreviewWork(String jobId, {int limit = 100}) =>
      _claimWork(
        table: 'library_document_preview_work',
        idColumn: 'entity_id',
        jobId: jobId,
        limit: limit,
      );

  List<String> claimNodePreviewWork(String jobId, {int limit = 8}) =>
      _claimWork(
        table: 'library_node_preview_work',
        idColumn: 'node_id',
        jobId: jobId,
        limit: limit,
      );

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

  bool hasPendingEntityPreviewWork(String jobId) =>
      _hasPending('library_entity_preview_work', jobId);

  bool hasPendingNodePreviewWork(String jobId) =>
    _hasPending('library_node_preview_work', jobId);

  bool hasPendingDocumentPreviewWork(String jobId) =>
      _hasPending('library_document_preview_work', jobId);

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

  void retryFailedAssets(String jobId) {
    final job = get(jobId);
    if (job == null) return;
    final now = nowMillis();
    library.writeTransaction(() {
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
        SET stage = ?, status = 'pending', error = NULL, updated_at = ?
        WHERE id = ?
      ''', [retryStage.name, now, jobId]);
    });
  }

  void restartFromManifest(String jobId) {
    library.writeTransaction(() {
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
      final statement = library.database.db.prepare('''
        UPDATE $table SET state = ?, error = ?, updated_at = ?
        WHERE job_id = ? AND $idColumn = ?
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
        }
      } finally {
        statement.dispose();
      }
      final done = library.database.db.select('''
        SELECT COUNT(*) AS value FROM $table
        WHERE job_id = ? AND state IN ('completed', 'skipped')
      ''', [jobId]).single['value'] as int;
      final failed = library.database.db.select('''
        SELECT COUNT(*) AS value FROM $table
        WHERE job_id = ? AND state = 'failed'
      ''', [jobId]).single['value'] as int;
      final columns = switch (counter) {
        _WorkCounter.document => ('document_preview_done', 'document_preview_failed'),
        _WorkCounter.entity => ('entity_preview_done', 'entity_preview_failed'),
        _WorkCounter.node => ('node_preview_done', 'node_preview_failed'),
      };
      library.database.db.execute(
        'UPDATE library_build_jobs SET ${columns.$1} = ?, ${columns.$2} = ?, '
        'updated_at = ? WHERE id = ?',
        [done, failed, nowMillis(), jobId],
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
        metadataPreview: row['metadata_preview'] as String?,
        durationMs: row['duration_ms'] as int?,
        sourceCreatedAtMs: row['source_created_at_ms'] as int,
        sourceModifiedAtMs: row['source_modified_at_ms'] as int,
      );
}
