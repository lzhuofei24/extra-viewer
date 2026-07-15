import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../database/library_build_repository.dart';
import '../database/library_repository.dart';
import '../database/library_write_worker.dart';
import '../diagnostics/app_diagnostic_log.dart';
import '../domain/models.dart';
import '../formats/file_format_handlers.dart';
import '../formats/text_decoder.dart';
import '../readers/docx_decoder.dart';
import '../readers/epub_decoder.dart';
import '../scanner/candidate_source.dart';
import '../sources/platform_directory_picker.dart';
import '../sources/source_handle.dart';
import '../thumbnails/android_image_thumbnail_backend.dart';
import '../thumbnails/android_video_thumbnail_backend.dart';
import '../thumbnails/native_image_thumbnail_backend.dart';
import '../thumbnails/node_preview_composite_service.dart';
import '../thumbnails/thumbnail_service.dart';
import '../thumbnails/windows_wic_webp_thumbnail_backend.dart';
import '../utils/file_fingerprint.dart';
import '../utils/ids.dart';

class LibraryBuildProgress {
  const LibraryBuildProgress({
    required this.stage,
    required this.completed,
    required this.total,
    required this.message,
    this.failed = 0,
  });

  final LibraryBuildStage stage;
  final int completed;
  final int total;
  final int failed;
  final String message;

  double? get value => total == 0 ? null : completed.clamp(0, total) / total;
}

class LibraryBuildPausedException implements Exception {
  const LibraryBuildPausedException();
}

class LibraryBuildAbandonedException implements Exception {
  const LibraryBuildAbandonedException();
}

class LibraryBuildControl {
  bool _paused = false;
  bool _abandoned = false;

  bool get paused => _paused;
  bool get abandoned => _abandoned;

  void pause() => _paused = true;
  void abandon() => _abandoned = true;

  void check() {
    if (_abandoned) throw const LibraryBuildAbandonedException();
    if (_paused) throw const LibraryBuildPausedException();
  }
}

/// Executes the only directory build lifecycle. A process interruption can
/// restart manifest/index/finalize safely and resumes derived assets at the
/// most recently committed group of at most 100 work rows.
class LibraryBuildTaskController extends ChangeNotifier {
  LibraryBuildTaskController(this.library)
      : builds = LibraryBuildRepository(library),
        _thumbnails = ThumbnailService(
          library,
          androidImageBackend: AndroidImageThumbnailBackend(),
          androidVideoBackend: AndroidVideoThumbnailBackend(),
          nativeImageBackend: NativeImageThumbnailBackend(),
          windowsWicBackend: WindowsWicWebpThumbnailBackend(),
        ) {
    builds.markInterruptedRecoverable();
    refresh();
  }

  final LibraryRepository library;
  final LibraryBuildRepository builds;
  final ThumbnailService _thumbnails;

  LibraryBuildControl? _control;
  LibraryBuildProgress? _progress;
  LibraryBuildJob? _activeJob;
  List<LibraryBuildJob> _recoverable = const [];
  List<LibraryBuildJob> _history = const [];
  String? _error;
  Timer? _progressNotifyTimer;
  DateTime _lastProgressNotification = DateTime.fromMillisecondsSinceEpoch(0);

  static const _progressNotificationInterval = Duration(milliseconds: 150);

  bool get isRunning => _control != null;
  LibraryBuildProgress? get progress => _progress;
  LibraryBuildJob? get activeJob => _activeJob;
  List<LibraryBuildJob> get recoverableJobs => _recoverable;
  List<LibraryBuildJob> get history => _history;
  String? get errorMessage => _error;

  void refresh() {
    _recoverable = builds.listRecoverable();
    _history = builds.listHistory();
    notifyListeners();
  }

  @override
  void dispose() {
    _progressNotifyTimer?.cancel();
    super.dispose();
  }

  void pause() => _control?.pause();
  void abandonActive() => _control?.abandon();

  Future<LibraryBuildJob?> startRoot(
    String sourcePath, {
    String? displayName,
  }) async {
    if (isRunning || sourcePath.trim().isEmpty) return null;
    final job = builds.create(
      sourcePath: _normalizeSource(sourcePath),
      operation: LibraryBuildOperation.rootScan,
    );
    return _run(job, displayName: displayName);
  }

  Future<LibraryBuildJob?> updateNode(IndexNode node) async {
    if (isRunning) return null;
    final root = library.directoryIndexRootForNode(node.id);
    if (root == null || root.sourcePath == null) return null;
    final source = SourceHandle.parse(root.sourcePath!).isAndroidContentUri
        ? root.sourcePath!
        : p.join(
            root.sourcePath!,
            library.directoryNodeRelativePath(node.id) ?? '',
          );
    final job = builds.create(
      sourcePath: _normalizeSource(source),
      operation: LibraryBuildOperation.subtreeRefresh,
      targetNodeId: node.id,
    );
    return _run(job);
  }

  Future<LibraryBuildJob?> resume(LibraryBuildJob job) {
    if (isRunning) return Future<LibraryBuildJob?>.value(null);
    return _run(job);
  }

  Future<LibraryBuildJob?> retryFailed(LibraryBuildJob job) async {
    if (isRunning) return null;
    builds.retryFailedAssets(job.id);
    return _run(builds.get(job.id) ?? job);
  }

  Future<LibraryBuildJob?> recheck(LibraryBuildJob job) async {
    if (isRunning) return null;
    builds.restartFromManifest(job.id);
    return _run(builds.get(job.id) ?? job);
  }

  void abandon(LibraryBuildJob job) {
    if (isRunning) {
      _control?.abandon();
      return;
    }
    builds.abandon(job.id);
    refresh();
  }

  /// Queues an explicit node-preview refresh through the same durable node
  /// asset work table. It never requests entity thumbnails from the browser.
  Future<LibraryBuildJob?> rebuildNodePreview(String nodeId) async {
    if (isRunning) return null;
    final root = library.owningIndexRootForNode(nodeId);
    if (root == null) return null;
    final job = builds.create(
      sourcePath: root.sourcePath ?? 'index://${root.id}',
      operation: LibraryBuildOperation.subtreeRefresh,
      targetNodeId: nodeId,
    );
    builds.setRoots(jobId: job.id, indexRootId: root.id);
    builds.prepareNodePreviewWork(
      job.id,
      scopeNodeId: nodeId,
      rootNodeId: root.id,
    );
    final prepared = builds.get(job.id)!;
    builds.checkpointStage(
      jobId: job.id,
      stage: LibraryBuildStage.nodePreviews,
      nodePreviewTotal: prepared.nodePreviewTotal,
    );
    return _run(builds.get(job.id)!);
  }

  /// Repairs EPUB excerpts created by older builds that completed before the
  /// document-preview phase existed. It never rescans folders or regenerates
  /// media thumbnails, and is deliberately skipped while a durable build job
  /// owns the repository.
  Future<int> repairMissingEpubMetadataPreviews({int limit = 200}) async {
    if (isRunning) return 0;
    final entities = library.listEpubsMissingMetadataPreview(limit: limit);
    if (entities.isEmpty) return 0;
    var repaired = 0;
    await _forEachConcurrent(entities, 2, (entity) async {
      try {
        final metadata = await _metadataForEntity(
          entity,
          const EpubFileHandler(),
        );
        if (metadata.$1 == null || metadata.$1!.trim().isEmpty) {
          throw StateError('EPUB 中没有可用于预览的正文');
        }
        library.updateEntityMetadataPreview(entity.id, metadata.$1, null);
        repaired++;
      } catch (error, stackTrace) {
        AppDiagnosticLog.instance.error(
          'epub_preview_repair_failed',
          error,
          stackTrace,
          fields: {
            'entityId': entity.id,
            'name': entity.name,
            'path': entity.path,
          },
        );
      }
    });
    if (repaired > 0) {
      AppDiagnosticLog.instance.info(
        'epub_preview_repair_completed',
        fields: {'repaired': repaired, 'requested': entities.length},
      );
    }
    return repaired;
  }

  Future<LibraryBuildJob?> _run(
    LibraryBuildJob initial, {
    String? displayName,
  }) async {
    _control = LibraryBuildControl();
    _error = null;
    var job = builds.setRunning(initial.id);
    _activeJob = job;
    _report(
      job,
      _storedStageCompleted(job),
      _storedStageTotal(job),
      initial.status == LibraryBuildStatus.paused
          ? '正在继续任务：已恢复已保存进度'
          : '正在启动索引任务',
    );
    try {
      while (job.stage != LibraryBuildStage.completed) {
        _control!.check();
        switch (job.stage) {
          case LibraryBuildStage.manifest:
            await _buildManifest(job);
          case LibraryBuildStage.indexWrite:
            await _writeIndex(job, displayName: displayName);
          case LibraryBuildStage.finalize:
            await _finalizeIndex(job);
          case LibraryBuildStage.documentPreviews:
            await _buildDocumentPreviews(job);
          case LibraryBuildStage.entityPreviews:
            await _buildEntityPreviews(job);
          case LibraryBuildStage.nodePreviews:
            await _buildNodePreviews(job);
          case LibraryBuildStage.completed:
            break;
        }
        job = builds.get(job.id)!;
        _activeJob = job;
        _notifyProgress(force: true);
        if (job.status != LibraryBuildStatus.running &&
            job.stage != LibraryBuildStage.completed) {
          return job;
        }
        // Let the progress UI paint the checkpoint before a fast following
        // stage completes synchronously (especially for text-only indexes).
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      return job;
    } on LibraryBuildPausedException {
      builds.releaseProcessingWork(
        job.id,
        stage: job.stage,
      );
      builds.pause(job.id);
      return null;
    } on LibraryBuildAbandonedException {
      if (job.stage == LibraryBuildStage.documentPreviews ||
          job.stage == LibraryBuildStage.entityPreviews ||
          job.stage == LibraryBuildStage.nodePreviews) {
        builds.releaseProcessingWork(
          job.id,
          stage: job.stage,
        );
      }
      builds.abandon(job.id);
      return null;
    } catch (error) {
      _error = '索引构建失败：$error';
      builds.fail(job.id, _error!);
      return null;
    } finally {
      _control = null;
      _progress = null;
      _activeJob = null;
      refresh();
    }
  }

  Future<void> _buildManifest(LibraryBuildJob job) async {
    final resumeAfter = builds.manifestItemCount(job.id);
    if (resumeAfter == 0) {
      builds.resetManifest(job.id);
    }
    _report(
      job,
      resumeAfter,
      0,
      resumeAfter == 0 ? '正在建立清单' : '正在继续建立清单：已保留 $resumeAfter 项',
    );
    final source = SourceHandle.parse(job.sourcePath);
    final total = source.isAndroidContentUri
        ? await _buildAndroidManifest(job, resumeAfter: resumeAfter)
        : await _buildLocalManifest(job, resumeAfter: resumeAfter);
    _control!.check();
    builds.checkpointStage(
      jobId: job.id,
      stage: LibraryBuildStage.indexWrite,
      manifestTotal: total,
    );
  }

  Future<int> _buildLocalManifest(
    LibraryBuildJob job, {
    required int resumeAfter,
  }) async {
    final root = Directory(job.sourcePath);
    if (!await root.exists()) {
      throw FileSystemException('目录不存在', job.sourcePath);
    }
    var sequence = 0;
    var batch = <LibraryBuildManifestItem>[];
    await for (final entry in root.list(recursive: true, followLinks: false)) {
      _control!.check();
      if (entry is! File) continue;
      final handler = FileFormatRegistry.resolvePath(entry.path);
      if (handler == null) continue;
      final itemSequence = sequence++;
      if (itemSequence < resumeAfter) continue;
      batch.add(LibraryBuildManifestItem(
        jobId: job.id,
        sourcePath: p.normalize(entry.path),
        relativePath:
            p.relative(entry.path, from: job.sourcePath).replaceAll('\\', '/'),
        sequence: itemSequence,
        name: p.basename(entry.path),
        format: handler.formatFor(entry.path),
        entityType: handler.entityType,
        // The manifest is deliberately a cheap, resumable directory listing.
        // Hashing and document decoding belong to index writing, not here.
        size: 0,
        sourceCreatedAtMs: 0,
        sourceModifiedAtMs: 0,
      ));
      if (batch.length == 200) {
        await builds.upsertManifestAsync(batch);
        batch = <LibraryBuildManifestItem>[];
        _report(job, sequence, 0, '正在建立清单：$sequence 个实体');
      }
    }
    if (batch.isNotEmpty) await builds.upsertManifestAsync(batch);
    _report(job, sequence, sequence, '清单已建立：$sequence 个实体');
    return sequence;
  }

  Future<int> _buildAndroidManifest(
    LibraryBuildJob job, {
    required int resumeAfter,
  }) async {
    final provider = SafCandidateSourceProvider(job.sourcePath);
    final scope = job.targetNodeId == null
        ? null
        : library.directoryNodeRelativePath(job.targetNodeId!);
    await provider.clearTransientDocuments();
    try {
      final total = await provider.begin(relativeScope: scope);
      var sequence = 0;
      await for (final sources in provider.readBatches()) {
        _control!.check();
        final items = <LibraryBuildManifestItem>[];
        for (final source in sources) {
          final handler = FileFormatRegistry.resolvePath(source.name);
          if (handler == null) continue;
          final itemSequence = sequence++;
          if (itemSequence < resumeAfter) continue;
          items.add(LibraryBuildManifestItem(
            jobId: job.id,
            sourcePath: source.sourcePath,
            relativePath: source.relativePath,
            sequence: itemSequence,
            name: source.name,
            format: handler.formatFor(source.name),
            entityType: handler.entityType,
            size: source.document.size,
            sourceCreatedAtMs: source.document.modifiedAtMs,
            sourceModifiedAtMs: source.document.modifiedAtMs,
          ));
        }
        if (items.isNotEmpty) await builds.upsertManifestAsync(items);
        _report(job, sequence, total, '正在建立清单：$sequence/$total');
      }
      return sequence;
    } finally {
      await provider.cancel();
      await provider.clearTransientDocuments();
    }
  }

  Future<void> _writeIndex(
    LibraryBuildJob job, {
    String? displayName,
  }) async {
    _control!.check();
    final target = job.targetNodeId == null
        ? null
        : library.getIndexNode(job.targetNodeId!);
    if (job.targetNodeId != null && target == null) {
      throw StateError('目录节点已不存在');
    }
    final existingRoot = target == null
        ? library.directoryIndexRootForSource(job.sourcePath)
        : library.directoryIndexRootForNode(target.id);
    final root = existingRoot ??
        library.ensureDirectoryIndexRoot(
          job.sourcePath,
          staging: target == null,
          displayName: displayName,
        );
    builds.setRoots(
      jobId: job.id,
      indexRootId: root.id,
      stagingRootId: target == null && existingRoot == null ? root.id : null,
    );
    final attachNode = target ?? root;
    final directoryCache = <String, IndexNode>{'': attachNode};
    var cursor = job.indexedTotal - 1;
    var written = job.indexedTotal;
    while (true) {
      _control!.check();
      final page = builds.listManifestPage(job.id, afterSequence: cursor);
      if (page.isEmpty) break;
      final existing =
          library.getEntitiesByPaths(page.map((item) => item.sourcePath));
      final detailsBySequence = <int, (String, int, int, int, String?, int?)>{};
      // SAF reads are latency-bound. Keep up to eight in flight, then leave
      // all SQLite work to the single writer transaction below.
      await _forEachConcurrent(page, 8, (item) async {
        final handler = FileFormatRegistry.resolvePath(item.name);
        if (handler == null) return;
        detailsBySequence[item.sequence] =
            await _inspectForIndex(item, handler);
      });
      final nodesBySequence = <int, IndexNode>{};
      for (final item in page) {
        _control!.check();
        nodesBySequence[item.sequence] = await _ensureDirectoryNode(
          root: attachNode,
          relativePath: item.relativePath,
          cache: directoryCache,
        );
      }
      final indexedInPage = await _commitIndexPage(
        job: job,
        page: page,
        rootId: root.id,
        existing: existing,
        detailsBySequence: detailsBySequence,
        nodesBySequence: nodesBySequence,
        indexedBefore: written,
      );
      written += indexedInPage;
      cursor = page.last.sequence;
      _report(job, written, job.manifestTotal,
          '正在写入索引：$written/${job.manifestTotal}');
    }
    _control!.check();
    builds.checkpointStage(
      jobId: job.id,
      stage: LibraryBuildStage.finalize,
      indexedTotal: written,
    );
  }

  /// Builds one serializable SQLite transaction for a manifest page. File
  /// inspection and directory-node discovery happen on this isolate, but all
  /// entity, relation, and checkpoint writes are committed by the dedicated
  /// writer isolate as one durable page.
  Future<int> _commitIndexPage({
    required LibraryBuildJob job,
    required List<LibraryBuildManifestItem> page,
    required String rootId,
    required Map<String, Entity> existing,
    required Map<int, (String, int, int, int, String?, int?)> detailsBySequence,
    required Map<int, IndexNode> nodesBySequence,
    required int indexedBefore,
  }) async {
    final statements = <LibraryWriteStatement>[];
    final now = nowMillis();
    final touchedNodes = <String>{};
    var completed = 0;
    for (final item in page) {
      final details = detailsBySequence[item.sequence];
      final node = nodesBySequence[item.sequence];
      if (details == null || node == null) continue;
      final current = existing[item.sourcePath];
      final entityId = current?.id ?? newId();
      if (current == null) {
        statements.add(LibraryWriteStatement(
          '''
          INSERT INTO entities(
            id, path, local_path, name, format, media_type, hash,
            metadata_preview, thumbnail_status, thumbnail_key,
            thumbnail_format, thumbnail_width, thumbnail_height,
            thumbnail_error, size, source_created_at_ms,
            source_modified_at_ms, duration_ms, directory_root_id,
            created_at, updated_at
          ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?, 'none', NULL, NULL, NULL,
                    NULL, NULL, ?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            entityId,
            item.sourcePath,
            item.name,
            item.format,
            item.entityType.value,
            details.$1,
            details.$5,
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
        final preserveFields = status == ThumbnailStatus.success.value;
        statements.add(LibraryWriteStatement(
          '''
          UPDATE entities
          SET name = ?, format = ?, media_type = ?, hash = ?,
              metadata_preview = ?, thumbnail_status = ?,
              thumbnail_key = CASE WHEN ? THEN thumbnail_key ELSE NULL END,
              thumbnail_format = CASE WHEN ? THEN thumbnail_format ELSE NULL END,
              thumbnail_width = CASE WHEN ? THEN thumbnail_width ELSE NULL END,
              thumbnail_height = CASE WHEN ? THEN thumbnail_height ELSE NULL END,
              thumbnail_error = CASE WHEN ? THEN thumbnail_error ELSE NULL END,
              size = ?, source_created_at_ms = ?, source_modified_at_ms = ?,
              duration_ms = ?, directory_root_id = ?, local_path = NULL,
              updated_at = ?
          WHERE id = ?
          ''',
          [
            item.name,
            item.format,
            item.entityType.value,
            details.$1,
            details.$5,
            status,
            preserveFields ? 1 : 0,
            preserveFields ? 1 : 0,
            preserveFields ? 1 : 0,
            preserveFields ? 1 : 0,
            status == ThumbnailStatus.failed.value ? 1 : 0,
            details.$2,
            details.$3,
            details.$4,
            details.$6,
            rootId,
            now,
            entityId,
          ],
        ));
      }
      statements.add(LibraryWriteStatement(
        '''
        INSERT OR IGNORE INTO index_node_entities(
          index_node_id, entity_id, sort_name, created_at
        ) SELECT ?, id, lower(name), ? FROM entities WHERE id = ?
        ''',
        [node.id, now, entityId],
      ));
      touchedNodes.add(node.id);
      completed++;
    }
    for (final nodeId in touchedNodes) {
      statements.add(LibraryWriteStatement(
        'UPDATE index_nodes SET updated_at = ? WHERE id = ?',
        [now, nodeId],
      ));
    }
    statements.add(LibraryWriteStatement(
      'UPDATE library_build_jobs SET indexed_total = ?, updated_at = ? WHERE id = ?',
      [indexedBefore + completed, now, job.id],
    ));
    final worker = library.writeWorker;
    if (worker == null) {
      library.writeTransaction(() {
        for (final statement in statements) {
          library.database.db.execute(statement.sql, statement.parameters);
        }
      });
    } else {
      await worker.executeBatch(statements);
    }
    return completed;
  }

  bool _isUnchangedIndexEntity(
    Entity entity, {
    required LibraryBuildManifestItem item,
    required (String, int, int, int, String?, int?) details,
    required String rootId,
  }) {
    final needsGeneratedThumbnail = item.entityType == EntityType.image ||
        item.entityType == EntityType.video ||
        item.entityType == EntityType.document;
    return entity.hash == details.$1 &&
        entity.contentExcerpt == details.$5 &&
        entity.entityType == item.entityType &&
        entity.format == item.format &&
        entity.size == details.$2 &&
        entity.durationMs == details.$6 &&
        entity.directoryRootId == rootId &&
        entity.localPath == null &&
        (!needsGeneratedThumbnail ||
            entity.thumbnailStatus == ThumbnailStatus.none);
  }

  Future<void> _finalizeIndex(LibraryBuildJob job) async {
    _report(job, 0, 1, '正在整理并提交索引');
    _control!.check();
    final rootId = job.indexRootId;
    if (rootId == null) throw StateError('索引根节点缺失');
    final scopeId = job.targetNodeId ?? rootId;
    final seen = <String>[];
    var cursor = -1;
    while (true) {
      final page = builds.listManifestPage(job.id, afterSequence: cursor);
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
    builds.prepareDocumentPreviewWork(job.id, scopeId);
    final refreshed = builds.get(job.id)!;
    builds.checkpointStage(
      jobId: job.id,
      stage: LibraryBuildStage.documentPreviews,
      documentPreviewTotal: refreshed.documentPreviewTotal,
    );
  }

  Future<void> _buildDocumentPreviews(LibraryBuildJob job) async {
    while (true) {
      _control!.check();
      final entityIds = builds.claimDocumentPreviewWork(job.id);
      if (entityIds.isEmpty) break;
      final entities = library.getEntitiesByIds(entityIds);
      final results =
          <String, ({LibraryBuildWorkState state, String? error})>{};
      await _forEachConcurrent(entityIds, 4, (id) async {
        final entity = entities[id];
        if (entity == null) {
          results[id] = (state: LibraryBuildWorkState.failed, error: '实体不存在');
          return;
        }
        try {
          final handler = FileFormatRegistry.resolvePath(entity.path);
          if (handler == null) {
            results[id] = (state: LibraryBuildWorkState.skipped, error: null);
            return;
          }
          final metadata = await _metadataForEntity(entity, handler);
          library.updateEntityMetadataPreview(id, metadata.$1, metadata.$2);
          results[id] = (state: LibraryBuildWorkState.completed, error: null);
        } on LibraryBuildPausedException {
          rethrow;
        } on LibraryBuildAbandonedException {
          rethrow;
        } catch (error) {
          results[id] = (state: LibraryBuildWorkState.failed, error: '$error');
        }
      });
      builds.completeDocumentPreviewWork(job.id, results);
      final current = builds.get(job.id)!;
      _report(
        current,
        current.documentPreviewDone + current.documentPreviewFailed,
        current.documentPreviewTotal,
        '正在解析文档预览：${current.documentPreviewDone}/${current.documentPreviewTotal}',
        failed: current.documentPreviewFailed,
      );
    }
    final rootId = job.indexRootId;
    if (rootId == null) throw StateError('索引根节点缺失');
    builds.prepareEntityPreviewWork(job.id, job.targetNodeId ?? rootId);
    final refreshed = builds.get(job.id)!;
    builds.checkpointStage(
      jobId: job.id,
      stage: LibraryBuildStage.entityPreviews,
      entityPreviewTotal: refreshed.entityPreviewTotal,
    );
  }

  Future<void> _buildEntityPreviews(LibraryBuildJob job) async {
    while (true) {
      _control!.check();
      final entityIds = builds.claimEntityPreviewWork(job.id);
      if (entityIds.isEmpty) break;
      final entities = library.getEntitiesByIds(entityIds);
      final results =
          <String, ({LibraryBuildWorkState state, String? error})>{};
      final imageConcurrency = _thumbnails.recommendedImageConcurrency;
      final videoConcurrency = _thumbnails.recommendedVideoConcurrency;
      await Future.wait([
        _forEachConcurrent(entityIds, imageConcurrency, (id) async {
          final entity = entities[id];
          if (entity?.entityType != EntityType.image) return;
          await _buildOneEntityPreview(job.id, id, entity!, results);
        }),
        _forEachConcurrent(entityIds, videoConcurrency, (id) async {
          final entity = entities[id];
          if (entity?.entityType != EntityType.video) return;
          await _buildOneEntityPreview(job.id, id, entity!, results);
        }),
        // EPUB and DOCX are archive containers. Keep their image extraction
        // bounded independently so large books do not compete with media
        // decoding or exhaust Android archive memory.
        _forEachConcurrent(entityIds, 2, (id) async {
          final entity = entities[id];
          if (entity == null ||
              (entity.format != 'epub' && entity.format != 'docx')) {
            return;
          }
          await _buildOneEntityPreview(job.id, id, entity, results);
        }),
      ]);
      for (final id in entityIds) {
        results.putIfAbsent(
          id,
          () => (state: LibraryBuildWorkState.failed, error: '实体不存在或类型不支持'),
        );
      }
      builds.completeEntityPreviewWork(job.id, results);
      final current = builds.get(job.id)!;
      _report(
        current,
        current.entityPreviewDone + current.entityPreviewFailed,
        current.entityPreviewTotal,
        '正在构建实体预览：${current.entityPreviewDone}/${current.entityPreviewTotal}',
        failed: current.entityPreviewFailed,
      );
    }
    final rootId = job.indexRootId;
    if (rootId == null) throw StateError('索引根节点缺失');
    builds.prepareNodePreviewWork(
      job.id,
      scopeNodeId: job.targetNodeId ?? rootId,
      rootNodeId: rootId,
    );
    final refreshed = builds.get(job.id)!;
    builds.checkpointStage(
      jobId: job.id,
      stage: LibraryBuildStage.nodePreviews,
      nodePreviewTotal: refreshed.nodePreviewTotal,
    );
  }

  Future<void> _buildOneEntityPreview(
    String jobId,
    String id,
    Entity entity,
    Map<String, ({LibraryBuildWorkState state, String? error})> results,
  ) async {
    File? transientDocument;
    try {
      _control!.check();
      if ((entity.format == 'epub' || entity.format == 'docx') &&
          SourceHandle.parse(entity.path).isAndroidContentUri) {
        final path = await PlatformDirectoryPicker.materializeDocument(
          entity.path,
          name: entity.name,
          cacheScope: 'scan',
        );
        transientDocument = File(path);
      }
      if (transientDocument == null) {
        await _thumbnails.ensureThumbnail(entity);
      } else {
        await _thumbnails.ensureThumbnailFromFile(entity, transientDocument);
      }
      _control!.check();
      final refreshed = library.getEntity(id);
      if (refreshed?.thumbnailStatus == ThumbnailStatus.success) {
        results[id] = (state: LibraryBuildWorkState.completed, error: null);
        return;
      }
      // A book without embedded images intentionally renders the persisted
      // text excerpt rather than a generated image thumbnail.
      if ((entity.format == 'epub' || entity.format == 'docx') &&
          refreshed?.thumbnailStatus == ThumbnailStatus.none) {
        results[id] = (state: LibraryBuildWorkState.completed, error: null);
        return;
      }
      final message = refreshed?.thumbnailError ?? '缩略图生成失败';
      results[id] = (state: LibraryBuildWorkState.failed, error: message);
      _logThumbnailFailure(jobId, entity, message, StackTrace.current);
    } on LibraryBuildPausedException {
      rethrow;
    } on LibraryBuildAbandonedException {
      rethrow;
    } catch (error, stackTrace) {
      results[id] = (state: LibraryBuildWorkState.failed, error: '$error');
      _logThumbnailFailure(jobId, entity, '$error', stackTrace);
    } finally {
      final transient = transientDocument;
      if (transient != null && await transient.exists()) {
        await transient.delete();
      }
    }
  }

  void _logThumbnailFailure(
    String jobId,
    Entity entity,
    String message,
    StackTrace stackTrace,
  ) {
    AppDiagnosticLog.instance.error(
      'thumbnail_build_failed',
      StateError(message),
      stackTrace,
      fields: {
        'jobId': jobId,
        'entityId': entity.id,
        'name': entity.name,
        'path': entity.path,
        'type': entity.entityType.value,
        'format': entity.format,
      },
    );
  }

  Future<void> _buildNodePreviews(LibraryBuildJob job) async {
    final rootId = job.indexRootId;
    if (rootId == null) throw StateError('索引根节点缺失');
    // Preview descriptions are computed bottom-up once before the composite
    // work. The asset writer then only reads existing entity WebPs.
    _report(job, 0, job.nodePreviewTotal, '正在整理节点预览描述');
    await Future<void>.delayed(const Duration(milliseconds: 16));
    library.rebuildIndexNodePreviewCache(job.targetNodeId ?? rootId);
    final compositor = NodePreviewCompositeService(library);
    while (true) {
      _control!.check();
      final nodeIds = builds.claimNodePreviewWork(job.id);
      if (nodeIds.isEmpty) break;
      final results =
          <String, ({LibraryBuildWorkState state, String? error})>{};
      _control!.check();
      final outcomes = await compositor.rebuildNodesAsync(nodeIds);
      _control!.check();
      for (final nodeId in nodeIds) {
        final outcome = outcomes[nodeId];
        if (outcome?.error != null) {
          results[nodeId] = (
            state: LibraryBuildWorkState.failed,
            error: outcome!.error,
          );
        } else {
          results[nodeId] =
              (state: LibraryBuildWorkState.completed, error: null);
        }
      }
      builds.completeNodePreviewWork(job.id, results);
      final current = builds.get(job.id)!;
      _report(
        current,
        current.nodePreviewDone + current.nodePreviewFailed,
        current.nodePreviewTotal,
        '正在构建节点预览：${current.nodePreviewDone}/${current.nodePreviewTotal}',
        failed: current.nodePreviewFailed,
      );
      // The bounded background batch has returned; yield before the next
      // database claim so taps and the progress card remain responsive.
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final nodeComplete = builds.get(job.id)!;
    final failed = nodeComplete.documentPreviewFailed +
        nodeComplete.entityPreviewFailed +
        nodeComplete.nodePreviewFailed;
    if (failed > 0) {
      builds.fail(
        job.id,
        '索引已写入；有 $failed 项预览失败，可使用“仅重试失败项”恢复。',
      );
      return;
    }
    builds.checkpointStage(
      jobId: job.id,
      stage: LibraryBuildStage.completed,
    );
    library.database.checkpointWriteAheadLog();
  }

  Future<IndexNode> _ensureDirectoryNode({
    required IndexNode root,
    required String relativePath,
    required Map<String, IndexNode> cache,
  }) async {
    final normalized = relativePath.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    if (slash < 0) return root;
    var parent = root;
    var current = '';
    for (final segment in normalized.substring(0, slash).split('/')) {
      if (segment.isEmpty) continue;
      current = current.isEmpty ? segment : '$current/$segment';
      parent = cache[current] ??= await library.ensureDirectoryFolderAsync(
        parentId: parent.id,
        name: segment,
        relativePath: current,
      );
    }
    return parent;
  }

  Future<(String?, int?)> _metadataForFile(
    File file,
    FileFormatHandler handler,
  ) async {
    final preview = switch (handler.entityType) {
      EntityType.text =>
        _limitPreview(await readTextFile(file, maxBytes: 8192)),
      EntityType.audio => 'AUDIO ${handler.formatFor(file.path).toUpperCase()}',
      EntityType.document when handler.formatFor(file.path) == 'docx' =>
        _limitPreview(await readDocxText(file)),
      EntityType.document when handler.formatFor(file.path) == 'epub' =>
        await _epubPreviewText(file),
      EntityType.document when handler.formatFor(file.path) == 'pdf' => 'PDF',
      EntityType.document =>
        'DOCUMENT ${handler.formatFor(file.path).toUpperCase()}',
      EntityType.image || EntityType.video => null,
    };
    final duration = handler.entityType == EntityType.audio
        ? await probeMediaDurationMs(file)
        : null;
    return (preview?.isEmpty == true ? null : preview, duration);
  }

  /// Use the same block parser as the reader instead of the older EPUB book
  /// compatibility parser. This follows the spine and extracts paragraphs,
  /// headings, lists, and fallback XHTML text consistently.
  Future<String> _epubPreviewText(File file) async {
    Object? primaryError;
    try {
      final text = (await readEpubDocument(file)).plainText.trim();
      if (text.isNotEmpty) return _limitPreview(text);
    } catch (error) {
      primaryError = error;
    }

    // Some older EPUBs use XHTML that the reflow parser intentionally skips
    // (for example a chapter made from legacy nested markup). The reader's
    // compatibility parser still extracts body text from those chapters.
    try {
      final book = await readEpubBook(file);
      final text =
          book.chapters.map((chapter) => chapter.text).join('\n\n').trim();
      if (text.isNotEmpty) return _limitPreview(text);
    } catch (fallbackError) {
      throw StateError(
        'EPUB 正文解析失败：${primaryError ?? fallbackError}；兼容解析：$fallbackError',
      );
    }
    throw StateError(
        'EPUB 中没有可用于预览的正文${primaryError == null ? '' : '：$primaryError'}');
  }

  Future<(String, int, int, int, String?, int?)> _inspectForIndex(
    LibraryBuildManifestItem item,
    FileFormatHandler handler,
  ) async {
    final source = SourceHandle.parse(item.sourcePath);
    if (!source.isAndroidContentUri) {
      final file = File(item.sourcePath);
      final stat = await file.stat();
      final metadata = handler.entityType == EntityType.audio
          ? await _metadataForFile(file, handler)
          : (null, null);
      return (
        await fingerprintFile(file, size: stat.size),
        stat.size,
        stat.changed.toUtc().millisecondsSinceEpoch,
        stat.modified.toUtc().millisecondsSinceEpoch,
        metadata.$1,
        metadata.$2,
      );
    }

    final prefix = await PlatformDirectoryPicker.readDocumentPrefix(
      item.sourcePath,
      maxBytes: fileFingerprintPrefixBytes,
    );
    String? contentExcerpt;
    int? durationMs;
    if (handler.entityType == EntityType.audio) {
      final localPath = await PlatformDirectoryPicker.materializeDocument(
        item.sourcePath,
        name: item.name,
        cacheScope: 'scan',
      );
      final file = File(localPath);
      try {
        (contentExcerpt, durationMs) = await _metadataForFile(file, handler);
      } finally {
        if (await file.exists()) await file.delete();
      }
    }
    return (
      fingerprintFromPrefix(size: item.size, prefix: prefix),
      item.size,
      item.sourceCreatedAtMs,
      item.sourceModifiedAtMs,
      contentExcerpt,
      durationMs,
    );
  }

  Future<(String?, int?)> _metadataForEntity(
    Entity entity,
    FileFormatHandler handler,
  ) async {
    final source = SourceHandle.parse(entity.path);
    if (!source.isAndroidContentUri) {
      return _metadataForFile(File(entity.path), handler);
    }
    final path = await PlatformDirectoryPicker.materializeDocument(
      entity.path,
      name: entity.name,
      cacheScope: 'scan',
    );
    final file = File(path);
    try {
      return await _metadataForFile(file, handler);
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> _forEachConcurrent<T>(
    List<T> values,
    int concurrency,
    Future<void> Function(T value) action,
  ) async {
    var next = 0;
    final control = _control;
    Future<void> worker() async {
      while (next < values.length) {
        // Startup repair work intentionally has no pause/cancel controller;
        // durable index jobs still retain the same captured controller.
        control?.check();
        final value = values[next++];
        await action(value);
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
  }

  int _storedStageCompleted(LibraryBuildJob job) => switch (job.stage) {
        LibraryBuildStage.manifest => builds.manifestItemCount(job.id),
        LibraryBuildStage.indexWrite => job.indexedTotal,
        LibraryBuildStage.finalize => 0,
        LibraryBuildStage.documentPreviews =>
          job.documentPreviewDone + job.documentPreviewFailed,
        LibraryBuildStage.entityPreviews =>
          job.entityPreviewDone + job.entityPreviewFailed,
        LibraryBuildStage.nodePreviews =>
          job.nodePreviewDone + job.nodePreviewFailed,
        LibraryBuildStage.completed => 1,
      };

  int _storedStageTotal(LibraryBuildJob job) => switch (job.stage) {
        LibraryBuildStage.manifest => job.manifestTotal,
        LibraryBuildStage.indexWrite => job.manifestTotal,
        LibraryBuildStage.finalize => 1,
        LibraryBuildStage.documentPreviews => job.documentPreviewTotal,
        LibraryBuildStage.entityPreviews => job.entityPreviewTotal,
        LibraryBuildStage.nodePreviews => job.nodePreviewTotal,
        LibraryBuildStage.completed => 1,
      };

  void _report(
    LibraryBuildJob job,
    int completed,
    int total,
    String message, {
    int failed = 0,
  }) {
    final current = builds.get(job.id) ?? job;
    _activeJob = current;
    final stageChanged = _progress?.stage != current.stage;
    _progress = LibraryBuildProgress(
      stage: current.stage,
      completed: completed,
      total: total,
      failed: failed,
      message: message,
    );
    _notifyProgress(force: stageChanged);
  }

  /// Build callbacks can arrive once per SAF page, thumbnail, and node.
  /// Coalescing repaint notifications prevents a long build from repeatedly
  /// rebuilding the full index-management page while retaining the latest
  /// in-memory progress value for the next frame.
  void _notifyProgress({bool force = false}) {
    if (force) {
      _progressNotifyTimer?.cancel();
      _progressNotifyTimer = null;
      _lastProgressNotification = DateTime.now();
      notifyListeners();
      return;
    }
    final now = DateTime.now();
    final elapsed = now.difference(_lastProgressNotification);
    if (elapsed >= _progressNotificationInterval) {
      _progressNotifyTimer?.cancel();
      _progressNotifyTimer = null;
      _lastProgressNotification = now;
      notifyListeners();
      return;
    }
    if (_progressNotifyTimer != null) return;
    _progressNotifyTimer = Timer(_progressNotificationInterval - elapsed, () {
      _progressNotifyTimer = null;
      _lastProgressNotification = DateTime.now();
      notifyListeners();
    });
  }
}

String _normalizeSource(String value) {
  final source = value.trim();
  return SourceHandle.parse(source).isAndroidContentUri
      ? source
      : p.normalize(source);
}

String _limitPreview(String value) {
  final trimmed = value.trim();
  if (trimmed.length <= 500) return trimmed;
  return '${trimmed.substring(0, 500)}…';
}
