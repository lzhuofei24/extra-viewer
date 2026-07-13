import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../database/library_repository.dart';
import '../domain/models.dart';
import 'candidate_processor.dart';
import 'candidate_source.dart';
import '../formats/file_format_handlers.dart';
import '../formats/text_decoder.dart';
import '../readers/docx_decoder.dart';
import '../readers/epub_decoder.dart';
import '../media/audio_waveform_service.dart';
import '../thumbnails/android_image_thumbnail_backend.dart';
import '../thumbnails/android_video_thumbnail_backend.dart';
import '../thumbnails/thumbnail_service.dart';
import '../thumbnails/image_thumbnail_worker_pool.dart';
import '../thumbnails/index_node_thumbnail_service.dart';
import '../thumbnails/native_image_thumbnail_backend.dart';
import '../thumbnails/windows_wic_webp_thumbnail_backend.dart';
import '../sources/source_handle.dart';

typedef ScanProgressCallback = void Function(ScanProgress progress);

class IndexScanControl {
  bool _pauseRequested = false;
  bool _cancelRequested = false;

  void pause() => _pauseRequested = true;
  void cancel() => _cancelRequested = true;
}

class IndexScanPausedException implements Exception {
  const IndexScanPausedException();
}

class IndexScanCanceledException implements Exception {
  const IndexScanCanceledException();
}

enum ScanPhase { discovering, processing, completed }

class ScanProgress {
  const ScanProgress({
    required this.phase,
    required this.discovered,
    required this.total,
    required this.processed,
    required this.thumbnailTotal,
    required this.thumbnailProcessed,
    required this.message,
  });

  final ScanPhase phase;
  final int discovered;
  final int total;
  final int processed;
  final int thumbnailTotal;
  final int thumbnailProcessed;
  final String message;

  double? get entityProgress {
    if (total <= 0) return null;
    return processed.clamp(0, total) / total;
  }

  double? get thumbnailProgress {
    if (thumbnailTotal <= 0) return null;
    return thumbnailProcessed.clamp(0, thumbnailTotal) / thumbnailTotal;
  }
}

class ScanSummary {
  const ScanSummary({
    required this.indexRootId,
    required this.scanned,
    required this.imported,
    required this.updated,
    required this.skipped,
    required this.thumbnailsBuilt,
    this.timings = const ScanTimingSummary(),
  });

  final String indexRootId;
  final int scanned;
  final int imported;
  final int updated;
  final int skipped;
  final int thumbnailsBuilt;
  final ScanTimingSummary timings;
}

class ScanTimingSummary {
  const ScanTimingSummary({
    this.discoveryMs = 0,
    this.preparationMs = 0,
    this.indexWriteMs = 0,
    this.thumbnailWallMs = 0,
    this.totalMs = 0,
    this.imageThumbnailMs = 0,
    this.videoThumbnailMs = 0,
    this.documentThumbnailMs = 0,
    this.imageReadMs = 0,
    this.imageDecodeMs = 0,
    this.imageResizeMs = 0,
    this.imageEncodeMs = 0,
    this.imageP95Ms = 0,
    this.imageAverageMegapixels = 0,
  });

  final int discoveryMs;
  final int preparationMs;
  final int indexWriteMs;
  final int thumbnailWallMs;
  final int totalMs;
  final int imageThumbnailMs;
  final int videoThumbnailMs;
  final int documentThumbnailMs;
  final int imageReadMs;
  final int imageDecodeMs;
  final int imageResizeMs;
  final int imageEncodeMs;
  final int imageP95Ms;
  final double imageAverageMegapixels;

  String get compactReport =>
      '总计 ${_formatDuration(totalMs)} · 扫描 ${_formatDuration(discoveryMs)} · '
      '预处理 ${_formatDuration(preparationMs)} · 缩略图 '
      '${_formatDuration(thumbnailWallMs)}（图 ${_formatDuration(imageThumbnailMs)}、'
      '视频 ${_formatDuration(videoThumbnailMs)}、文档 '
      '${_formatDuration(documentThumbnailMs)}）· 图片阶段 读 '
      '${_formatDuration(imageReadMs)} / 解码 ${_formatDuration(imageDecodeMs)} / '
      '缩放 ${_formatDuration(imageResizeMs)} / WebP ${_formatDuration(imageEncodeMs)} · '
      'P95 ${imageP95Ms}ms · 平均 ${imageAverageMegapixels.toStringAsFixed(1)}MP';
}

class LibraryScanner {
  LibraryScanner(this.repository);

  final LibraryRepository repository;

  static const _nodeRefreshJobPrefix = '__node_refresh__';

  static String? directoryNodeIdFromJobSource(String sourcePath) {
    if (!sourcePath.startsWith(_nodeRefreshJobPrefix)) return null;
    final nodeId = sourcePath.substring(_nodeRefreshJobPrefix.length).trim();
    return nodeId.isEmpty ? null : nodeId;
  }

  Future<ScanSummary> scanPath(
    String path, {
    ScanProgressCallback? onProgress,
    IndexScanControl? control,
  }) async {
    final rootPath = _normalizeScanRootPath(path);
    final scope = ScanScope.root(sourcePath: rootPath);
    final job = repository.beginIndexJob(scope.jobSource);
    try {
      final summary = SourceHandle.parse(rootPath).isAndroidContentUri
          ? await _runAndroidSafScan(
              rootPath,
              job: job,
              onProgress: onProgress,
              control: control,
            )
          : await _runScanPath(
              rootPath,
              job: job,
              onProgress: onProgress,
              control: control,
            );
      _completeScopeJob(job: job, scope: scope, summary: summary);
      return summary;
    } on IndexScanPausedException {
      repository.updateIndexJob(job.id, status: IndexJobStatus.paused);
      rethrow;
    } on IndexScanCanceledException {
      // A cancelled task is deliberately not recoverable. Its partial
      // manifest has no user-visible continuation route and must not keep
      // accumulating in the database.
      repository.abandonIndexJob(job.id);
      rethrow;
    } catch (error) {
      repository.rollbackIndexJobStagingRoot(job.id);
      repository.updateIndexJob(
        job.id,
        status: IndexJobStatus.failed,
        error: '$error',
      );
      rethrow;
    }
  }

  /// Refreshes just one source-generated directory node and its descendants.
  /// The selected node remains the attachment point, so sibling branches are
  /// never rebuilt or reconciled.
  Future<ScanSummary> scanDirectoryNode(
    String nodeId, {
    ScanProgressCallback? onProgress,
    IndexScanControl? control,
  }) async {
    final indexRoot = repository.directoryIndexRootForNode(nodeId);
    final targetNode = repository.getIndexNode(nodeId);
    if (indexRoot == null ||
        targetNode == null ||
        indexRoot.sourcePath == null) {
      throw ArgumentError.value(
          nodeId, 'nodeId', 'must be inside a directory index');
    }
    repository.backfillDirectoryNodeRelativePaths(indexRoot.id);
    final path = repository.listNodePath(indexRoot.id, targetNode.id);
    if (path.isEmpty) {
      throw StateError(
          'directory node is no longer attached to its index root');
    }
    final storedRelativePath = repository.directoryNodeRelativePath(nodeId);
    final segments = storedRelativePath == null || storedRelativePath.isEmpty
        ? path.skip(1).map((node) => node.name).toList(growable: false)
        : storedRelativePath
            .split('/')
            .where((part) => part.isNotEmpty)
            .toList();
    final isAndroidSource =
        SourceHandle.parse(indexRoot.sourcePath!).isAndroidContentUri;
    final relativeScope = isAndroidSource ? segments.join('/') : null;
    final scope = isAndroidSource
        ? indexRoot.sourcePath!
        : p.joinAll([indexRoot.sourcePath!, ...segments]);
    // A node refresh must never share a resumable manifest with a full-root
    // scan. The stable node id makes the resume route unambiguous on both
    // local paths and Android SAF URIs.
    final scopeDescriptor = ScanScope.subtree(
      sourcePath: indexRoot.sourcePath!,
      indexRootId: indexRoot.id,
      targetNodeId: nodeId,
      relativePath: isAndroidSource
          ? relativeScope
          : p.relative(scope, from: indexRoot.sourcePath!),
    );
    final job = repository.beginIndexJob(
      scopeDescriptor.jobSource,
      targetNodeId: scopeDescriptor.targetNodeId,
    );
    try {
      final summary = isAndroidSource
          ? await _runAndroidSafScan(
              indexRoot.sourcePath!,
              job: job,
              onProgress: onProgress,
              control: control,
              indexRootOverride: indexRoot,
              targetNode: targetNode,
              relativeScope: relativeScope,
            )
          : await _runScanPath(
              scope,
              job: job,
              onProgress: onProgress,
              control: control,
              indexRootOverride: indexRoot,
              targetNode: targetNode,
            );
      _completeScopeJob(job: job, scope: scopeDescriptor, summary: summary);
      return summary;
    } on IndexScanPausedException {
      repository.updateIndexJob(job.id, status: IndexJobStatus.paused);
      rethrow;
    } on IndexScanCanceledException {
      repository.abandonIndexJob(job.id);
      rethrow;
    } catch (error) {
      repository.rollbackIndexJobStagingRoot(job.id);
      repository.updateIndexJob(job.id,
          status: IndexJobStatus.failed, error: '$error');
      rethrow;
    }
  }

  void _completeScopeJob({
    required IndexBuildJob job,
    required ScanScope scope,
    required ScanSummary summary,
  }) {
    if (scope.isRoot) {
      repository.replaceOverlappingDirectoryIndexRoots(
        keepRootId: summary.indexRootId,
        sourcePath: scope.sourcePath,
      );
    }
    final candidateSummary = repository.summarizeIndexJobCandidates(job.id);
    if (candidateSummary.failed > 0) {
      repository.updateIndexJob(
        job.id,
        status: IndexJobStatus.attentionRequired,
        phase: IndexJobPhase.previews,
        error: '${candidateSummary.failed} 个预览任务失败，可单独重试。',
      );
      repository.checkpointWriteAheadLog();
      return;
    }
    repository.updateIndexJob(
      job.id,
      status: IndexJobStatus.completed,
      phase: IndexJobPhase.completed,
      processed: summary.scanned,
      clearError: true,
    );
    repository.recordIndexJobHistory(
      job: repository.getIndexJob(job.id) ?? job,
      status: IndexJobStatus.completed,
      summary:
          '完成 · ${summary.imported} 新增，${summary.updated} 更新，${summary.skipped} 未变化',
    );
    repository.discardIndexJob(job.id);
    repository.checkpointWriteAheadLog();
  }

  Future<ScanSummary> _runAndroidSafScan(
    String source, {
    required IndexBuildJob job,
    ScanProgressCallback? onProgress,
    IndexScanControl? control,
    IndexNode? indexRootOverride,
    IndexNode? targetNode,
    String? relativeScope,
  }) async {
    return _runAndroidSafScanStreaming(
      source,
      job: job,
      onProgress: onProgress,
      control: control,
      indexRootOverride: indexRootOverride,
      targetNode: targetNode,
      relativeScope: relativeScope,
    );
  }

  Future<ScanSummary> _runAndroidSafScanStreaming(
    String source, {
    required IndexBuildJob job,
    ScanProgressCallback? onProgress,
    IndexScanControl? control,
    IndexNode? indexRootOverride,
    IndexNode? targetNode,
    String? relativeScope,
  }) async {
    if (!SafCandidateSourceProvider.isSupported) {
      throw UnsupportedError('Android SAF directory indexing requires Android');
    }
    final sourceProvider = SafCandidateSourceProvider(source);
    await sourceProvider.clearTransientDocuments();
    final progressSubscription =
        sourceProvider.discoveryProgress.listen((discovered) {
      onProgress?.call(ScanProgress(
        phase: ScanPhase.discovering,
        discovered: discovered,
        total: 0,
        processed: 0,
        thumbnailTotal: 0,
        thumbnailProcessed: 0,
        message: '正在读取 Android 目录：已发现 $discovered 个实体',
      ));
    });
    onProgress?.call(const ScanProgress(
      phase: ScanPhase.discovering,
      discovered: 0,
      total: 0,
      processed: 0,
      thumbnailTotal: 0,
      thumbnailProcessed: 0,
      message: '正在统计 Android 目录中的实体数量',
    ));
    var totalCandidates = 0;
    try {
      totalCandidates =
          await sourceProvider.begin(relativeScope: relativeScope);
    } catch (_) {
      await progressSubscription.cancel();
      rethrow;
    }
    final existingRoot = indexRootOverride == null
        ? repository.directoryIndexRootForSource(source)
        : null;
    final indexRoot = indexRootOverride ??
        repository.ensureDirectoryIndexRoot(
          source,
          staging: existingRoot == null && targetNode == null,
        );
    final createdRoot = indexRootOverride == null && existingRoot == null;
    final stagingRoot =
        targetNode == null && (createdRoot || indexRoot.isStaging);
    repository.setIndexJobRoots(
      jobId: job.id,
      indexRootId: indexRoot.id,
      stagingRootId: stagingRoot ? indexRoot.id : null,
    );
    Future<void> abortManifestStage() async {
      await progressSubscription.cancel();
      await sourceProvider.cancel();
      await sourceProvider.clearTransientDocuments();
    }

    // Android starts the SAF session at the requested subdirectory, so paths
    // returned by the native scanner are already relative to [attachNode].
    const scopePrefix = '';
    final attachNode = targetNode ?? indexRoot;
    final preservedOwnerRootIds = stagingRoot
        ? repository.directoryIndexRootIdsOverlapping(
            source,
            excludingRootId: indexRoot.id,
          )
        : const <String>{};
    final nodeCache = <String, IndexNode>{'': attachNode};
    final candidateProcessor = CandidateProcessor(repository);
    final existingCandidates = repository.listIndexJobCandidates(job.id);
    final hasCompleteManifest =
        job.scanCompleted && existingCandidates.length == job.total;
    var manifestComplete = hasCompleteManifest;
    if (hasCompleteManifest) {
      // Task totals count supported entities, whereas SAF's native count also
      // includes files the format registry deliberately ignores.
      totalCandidates = job.total;
    }
    try {
      if (!hasCompleteManifest) {
        // The first SAF pass is intentionally metadata-only. It makes a full
        // durable manifest before expensive reads begin, so process death can
        // resume by skipping completed rows rather than rebuilding the index.
        repository.resetIndexJobManifest(job.id);
        var sequence = 0;
        await for (final sourceBatch in sourceProvider.readBatches()) {
          final candidates = <IndexJobCandidate>[];
          for (final candidate in sourceBatch) {
            final handler = FileFormatRegistry.resolvePath(candidate.name);
            if (handler == null) continue;
            candidates.add(IndexJobCandidate(
              jobId: job.id,
              sourcePath: candidate.sourcePath,
              relativePath: candidate.relativePath,
              sequence: sequence++,
              state: IndexJobCandidateState.pending,
              format: handler.formatFor(candidate.name),
              entityType: handler.entityType,
              size: candidate.document.size,
              sourceCreatedAtMs: candidate.document.modifiedAtMs,
              sourceModifiedAtMs: candidate.document.modifiedAtMs,
              updatedAtMs: DateTime.now().millisecondsSinceEpoch,
            ));
          }
          repository.upsertIndexJobCandidates(candidates);
          repository.updateIndexJob(job.id, processed: 0, total: sequence);
          _checkControl(job.id, control);
        }
        totalCandidates = sequence;
        repository.updateIndexJob(
          job.id,
          phase: IndexJobPhase.preparing,
          discovered: totalCandidates,
          total: totalCandidates,
          processed: 0,
          scanCompleted: true,
        );
        manifestComplete = true;
        // The manifest pass consumed the native pull session. Processing uses
        // a fresh session and remains safe after an app restart.
        await sourceProvider.begin(relativeScope: relativeScope);
      }
    } catch (_) {
      await abortManifestStage();
      rethrow;
    }
    final performance = ThumbnailPerformanceProfile.forCurrentPlatform();
    final imageWorkerPool = ImageThumbnailWorkerPool(
      workerCount: performance.imageWorkerCount,
    );
    final thumbnailUpdates = ThumbnailUpdateBuffer(repository, batchSize: 50);
    final thumbnailService = ThumbnailService(
      repository,
      imageWorkerPool: imageWorkerPool,
      androidImageBackend: AndroidImageThumbnailBackend(),
      androidVideoBackend: AndroidVideoThumbnailBackend(),
      updateBuffer: thumbnailUpdates,
    );
    final waveformService = AudioWaveformService(
      AudioWaveformStore(repository.database.storageDirectoryPath),
    );
    var imported = 0;
    var updated = 0;
    var skipped = 0;
    var thumbnailsBuilt = 0;
    var processed = 0;
    final discovered = totalCandidates;
    final seenDocumentPaths = <String>{};
    final persistedByPath = {
      for (final candidate in repository.listIndexJobCandidates(job.id))
        candidate.sourcePath: candidate,
    };
    final checkpointCandidates = <IndexJobCandidate>[];

    void flushCheckpoint() {
      if (checkpointCandidates.isEmpty) return;
      candidateProcessor.checkpoint(
        jobId: job.id,
        candidates: checkpointCandidates,
        processed: processed,
      );
      checkpointCandidates.clear();
    }

    repository.updateIndexJob(
      job.id,
      phase: IndexJobPhase.preparing,
      discovered: discovered,
      total: totalCandidates,
      processed: job.processed,
    );

    void reportProcessed() {
      processed++;
      onProgress?.call(ScanProgress(
        phase: ScanPhase.processing,
        discovered: discovered,
        total: totalCandidates,
        processed: processed,
        thumbnailTotal: 0,
        thumbnailProcessed: 0,
        message: '正在处理 Android 文件：$processed / $totalCandidates',
      ));
    }

    Future<void> processDocument(
      SafCandidateSource source, {
      Entity? knownExisting,
      required List<({String entityId, String indexNodeId})> pendingLinks,
    }) async {
      final document = source.document;
      _checkControl(job.id, control);
      final handler = FileFormatRegistry.resolvePath(document.name);
      if (handler == null) return;
      seenDocumentPaths.add(document.source);
      final persisted = persistedByPath[document.source];
      final format = handler.formatFor(document.name);
      final canReuse = persisted != null &&
          persisted.state == IndexJobCandidateState.previewed &&
          persisted.format == format &&
          persisted.size == document.size &&
          persisted.fingerprint != null &&
          knownExisting?.hash == persisted.fingerprint &&
          knownExisting?.directoryRootId == indexRoot.id &&
          (!handler.supportsGeneratedThumbnail ||
              knownExisting?.thumbnailStatus == ThumbnailStatus.success);
      final relativePath = scopePrefix.isEmpty
          ? document.relativePath
          : document.relativePath.substring(scopePrefix.length);
      final node = _ensureDirectoryNodeForRelativePath(
        indexRoot: attachNode,
        relativePath: relativePath,
        cache: nodeCache,
      );
      if (canReuse) {
        pendingLinks.add((entityId: knownExisting!.id, indexNodeId: node.id));
        skipped++;
        reportProcessed();
        return;
      }
      final fingerprint = persisted != null &&
              persisted.fingerprint != null &&
              persisted.format == format &&
              persisted.size == document.size
          ? persisted.fingerprint!
          : (await source.inspect()).fingerprint;
      // Media metadata is already fully represented by the SAF fingerprint.
      // Avoid a write, local materialization and thumbnail service call on a
      // repeat scan when the persistent WebP is still present.
      if (persisted?.state == IndexJobCandidateState.previewed &&
          _isUnchangedAndroidMedia(
            entity: knownExisting,
            handler: handler,
            source: source,
            fingerprint: fingerprint,
            indexRootId: indexRoot.id,
          )) {
        pendingLinks.add((entityId: knownExisting!.id, indexNodeId: node.id));
        skipped++;
        reportProcessed();
        return;
      }
      // Android's native image and video backends read SAF URIs directly.
      // Materializing large media here only creates avoidable cache spikes.
      final requiresTemporaryFile = handler.entityType != EntityType.image &&
          handler.entityType != EntityType.video;
      File? temporaryFile;
      if (requiresTemporaryFile) {
        temporaryFile = await source.materialize(cacheScope: 'scan');
      }
      String? entityId;
      try {
        final metadataPreview = temporaryFile == null
            ? null
            : await _tryBuildMetadataPreview(
                file: temporaryFile,
                handler: handler,
              );
        final durationMs = temporaryFile == null
            ? null
            : await _tryBuildDurationMs(
                file: temporaryFile,
                handler: handler,
              );
        final result = candidateProcessor.write(CandidateWriteRequest(
          jobId: job.id,
          path: document.source,
          localPath: temporaryFile?.path,
          name: document.name,
          format: format,
          entityType: handler.entityType,
          hash: fingerprint,
          size: document.size,
          sourceCreatedAtMs: document.modifiedAtMs,
          sourceModifiedAtMs: document.modifiedAtMs,
          metadataPreview: metadataPreview,
          durationMs: durationMs,
          directoryRootId:
              preservedOwnerRootIds.contains(knownExisting?.directoryRootId)
                  ? knownExisting!.directoryRootId!
                  : indexRoot.id,
          existing: knownExisting,
        ));
        entityId = result.entity.id;
        switch (result.status) {
          case EntityUpsertStatus.inserted:
            imported++;
          case EntityUpsertStatus.updated:
            updated++;
          case EntityUpsertStatus.skipped:
            skipped++;
        }
        pendingLinks.add((entityId: result.entity.id, indexNodeId: node.id));
        var candidateState = IndexJobCandidateState.written;
        String? candidateError;
        if (handler.supportsGeneratedThumbnail) {
          try {
            if (await thumbnailService.ensureThumbnail(result.entity)) {
              thumbnailsBuilt++;
            }
          } catch (error) {
            candidateError = '$error';
            candidateState = IndexJobCandidateState.failed;
          }
        }
        if (handler.entityType == EntityType.audio) {
          try {
            await waveformService.ensure(
              path: temporaryFile!.path,
              fingerprint: result.entity.hash,
              durationMs: result.entity.durationMs,
            );
            candidateState = IndexJobCandidateState.previewed;
          } catch (error) {
            candidateError = '$error';
            candidateState = IndexJobCandidateState.failed;
          }
        }
        if (!handler.supportsGeneratedThumbnail &&
            handler.entityType != EntityType.audio) {
          candidateState = IndexJobCandidateState.previewed;
        }
        final manifestCandidate = IndexJobCandidate(
          jobId: job.id,
          sourcePath: document.source,
          relativePath: document.relativePath,
          sequence: processed,
          state: candidateState,
          format: format,
          entityType: handler.entityType,
          fingerprint: fingerprint,
          size: document.size,
          metadataPreview: result.entity.metadataPreview,
          durationMs: result.entity.durationMs,
          sourceCreatedAtMs: document.modifiedAtMs,
          sourceModifiedAtMs: document.modifiedAtMs,
          error: candidateError,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
        checkpointCandidates.add(manifestCandidate);
        persistedByPath[document.source] = manifestCandidate;
      } finally {
        if (entityId != null) repository.clearEntityLocalPath(entityId);
        if (temporaryFile?.existsSync() ?? false) temporaryFile!.deleteSync();
      }
      reportProcessed();
    }

    Future<void> processBatch(List<SafCandidateSource> batch) async {
      final existingByPath = repository.getEntitiesByPaths(
        batch.map((source) => source.sourcePath),
      );
      final pendingLinks = <({String entityId, String indexNodeId})>[];
      final imageDocuments = <SafCandidateSource>[];
      final videoDocuments = <SafCandidateSource>[];
      final documentDocuments = <SafCandidateSource>[];
      final audioDocuments = <SafCandidateSource>[];
      for (final source in batch) {
        final handler = FileFormatRegistry.resolvePath(source.name);
        switch (handler?.entityType) {
          case EntityType.image:
            imageDocuments.add(source);
          case EntityType.video:
            videoDocuments.add(source);
          case EntityType.audio:
            audioDocuments.add(source);
          case EntityType.text:
          case EntityType.externalLink:
            documentDocuments.add(source);
          case null:
            break;
        }
      }
      await _mapConcurrently(
        imageDocuments,
        maxConcurrent: performance.smallImageConcurrency,
        mapper: (source) => processDocument(
          source,
          knownExisting: existingByPath[source.sourcePath],
          pendingLinks: pendingLinks,
        ),
      );
      await _mapConcurrently(
        videoDocuments,
        maxConcurrent: performance.videoConcurrency,
        mapper: (source) => processDocument(
          source,
          knownExisting: existingByPath[source.sourcePath],
          pendingLinks: pendingLinks,
        ),
      );
      flushCheckpoint();
      await _mapConcurrently(
        documentDocuments,
        maxConcurrent: performance.documentConcurrency,
        mapper: (source) => processDocument(
          source,
          knownExisting: existingByPath[source.sourcePath],
          pendingLinks: pendingLinks,
        ),
      );
      await _mapConcurrently(
        audioDocuments,
        maxConcurrent: performance.audioConcurrency,
        mapper: (source) => processDocument(
          source,
          knownExisting: existingByPath[source.sourcePath],
          pendingLinks: pendingLinks,
        ),
      );
      candidateProcessor.writeLinks(job.id, pendingLinks);
    }

    try {
      await for (final sourceBatch in sourceProvider.readBatches()) {
        _checkControl(job.id, control);
        final scopedBatch = scopePrefix.isEmpty
            ? sourceBatch
            : sourceBatch
                .where((candidate) =>
                    candidate.relativePath.startsWith(scopePrefix))
                .toList(growable: false);
        if (scopedBatch.isNotEmpty) await processBatch(scopedBatch);
      }
      if (!manifestComplete) {
        throw StateError('Cannot reconcile an incomplete Android manifest');
      }
      if (targetNode == null) {
        repository.reconcileDirectoryIndexRoot(
          rootId: indexRoot.id,
          seenPaths: seenDocumentPaths,
        );
      } else {
        repository.reconcileDirectoryIndexSubtree(
          nodeId: targetNode.id,
          rootId: indexRoot.id,
          seenPaths: seenDocumentPaths,
        );
      }
    } finally {
      flushCheckpoint();
      await progressSubscription.cancel();
      thumbnailUpdates.flush();
      candidateProcessor.finalizeWrittenPreviewStates(job.id);
      await imageWorkerPool.close();
      if (control?._pauseRequested != true) {
        await sourceProvider.cancel();
      }
      // Covers cancelled jobs and failed materialization before a Dart File
      // object was returned. This cache must never survive a scan.
      await sourceProvider.clearTransientDocuments();
      if (control?._cancelRequested == true &&
          createdRoot &&
          repository.isDirectoryIndexRootEmpty(indexRoot.id)) {
        repository.deleteIndexNode(indexRoot.id);
      }
    }
    await thumbnailService.trimCacheToPlatformLimit();
    repository.rebuildIndexNodeStats();
    await IndexNodeThumbnailService(repository).rebuildForRoot(indexRoot);
    return ScanSummary(
      indexRootId: indexRoot.id,
      scanned: targetNode == null ? totalCandidates : processed,
      imported: imported,
      updated: updated,
      skipped: skipped,
      thumbnailsBuilt: thumbnailsBuilt,
    );
  }

  Future<ScanSummary> _runScanPath(
    String path, {
    required IndexBuildJob job,
    ScanProgressCallback? onProgress,
    IndexScanControl? control,
    IndexNode? indexRootOverride,
    IndexNode? targetNode,
  }) async {
    final totalWatch = Stopwatch()..start();
    final rootPath = path;
    final sourceProvider = FileCandidateSourceProvider(rootPath);
    if (!sourceProvider.existsSync) {
      throw FileSystemException('Library root not found', rootPath);
    }

    final discoveryWatch = Stopwatch();
    final preparationWatch = Stopwatch();
    final indexWriteWatch = Stopwatch();
    final preparedCandidates = <_PreparedScanCandidate>[];
    final candidateManifest = repository.listIndexJobCandidates(
      job.id,
      states: {
        IndexJobCandidateState.prepared,
        IndexJobCandidateState.written,
        IndexJobCandidateState.previewed,
        IndexJobCandidateState.failed,
      },
    );
    final persistedFiles = candidateManifest
        .where((candidate) =>
            candidate.format != null &&
            candidate.entityType != null &&
            candidate.fingerprint != null &&
            candidate.size != null &&
            candidate.sourceCreatedAtMs != null &&
            candidate.sourceModifiedAtMs != null)
        .map(_PersistedScanFile.fromCandidate)
        .toList(growable: false);
    // A complete manifest is a durable checkpoint. Recovery must not walk the
    // source directory again once all candidates have been persisted.
    var canResumeManifest = job.scanCompleted &&
        persistedFiles.isNotEmpty &&
        job.total > 0 &&
        persistedFiles.length == job.total &&
        job.phase != IndexJobPhase.discovering;
    var canReusePartialManifest =
        persistedFiles.isNotEmpty && job.phase != IndexJobPhase.discovering;
    var manifestComplete = job.scanCompleted;
    if (canResumeManifest) {
      // Continue always reflects the current source tree. This keeps Windows
      // recovery consistent with Android SAF, but avoids re-reading content
      // when the inexpensive path set has not changed.
      final currentPaths = <String>{};
      await for (final source in sourceProvider.enumerate()) {
        if (FileFormatRegistry.resolvePath(source.name) != null) {
          currentPaths.add(source.sourcePath);
        }
      }
      final manifestPaths = persistedFiles.map((file) => file.path).toSet();
      if (currentPaths.length != manifestPaths.length ||
          !currentPaths.containsAll(manifestPaths)) {
        repository.resetIndexJobManifest(job.id);
        canResumeManifest = false;
        canReusePartialManifest = false;
        manifestComplete = false;
      }
    }
    late final int totalCandidates;
    if (canResumeManifest) {
      for (final persisted in persistedFiles) {
        final handler = FileFormatRegistry.resolveFormat(persisted.format);
        if (handler == null) continue;
        preparedCandidates.add(_PreparedScanCandidate(
          file: File(persisted.path),
          handler: handler,
          hash: persisted.hash,
          size: persisted.size,
          sourceCreatedAtMs: persisted.sourceCreatedAtMs,
          sourceModifiedAtMs: persisted.sourceModifiedAtMs,
          metadataPreview: persisted.metadataPreview,
          durationMs: persisted.durationMs,
        ));
      }
      totalCandidates = preparedCandidates.length;
      onProgress?.call(ScanProgress(
        phase: ScanPhase.processing,
        discovered: totalCandidates,
        total: totalCandidates,
        processed: 0,
        thumbnailTotal: 0,
        thumbnailProcessed: 0,
        message: '正在从任务清单恢复：$totalCandidates 个实体',
      ));
    } else {
      // A pause during preparation has a partial manifest. Keep it and only
      // calculate fingerprints/metadata for paths that are not present yet.
      // We still enumerate the directory so files added or removed while the
      // task was paused cannot make the persisted manifest authoritative.
      if (!canReusePartialManifest) {
        repository.resetIndexJobManifest(job.id);
      }
      discoveryWatch.start();
      final candidates = <_ScanCandidate>[];
      await for (final source in sourceProvider.enumerate()) {
        final handler = FileFormatRegistry.resolvePath(source.name);
        if (handler == null) continue;
        candidates.add(_ScanCandidate(file: source.file, handler: handler));
        _checkControl(job.id, control);
        onProgress?.call(ScanProgress(
          phase: ScanPhase.discovering,
          discovered: candidates.length,
          total: 0,
          processed: 0,
          thumbnailTotal: 0,
          thumbnailProcessed: 0,
          message: '正在统计目录：已发现 ${candidates.length} 个实体',
        ));
      }
      discoveryWatch.stop();
      totalCandidates = candidates.length;
      repository.updateIndexJob(
        job.id,
        phase: IndexJobPhase.preparing,
        discovered: totalCandidates,
        total: totalCandidates,
      );
      onProgress?.call(ScanProgress(
        phase: ScanPhase.processing,
        discovered: totalCandidates,
        total: totalCandidates,
        processed: 0,
        thumbnailTotal: 0,
        thumbnailProcessed: 0,
        message: '目录统计完成：$totalCandidates 个实体',
      ));

      final persistedByPath = {
        for (final persisted in persistedFiles)
          p.normalize(persisted.path): persisted,
      };
      final pendingCandidates = <_ScanCandidate>[];
      for (final candidate in candidates) {
        final persisted = persistedByPath[p.normalize(candidate.file.path)];
        if (persisted == null ||
            persisted.format !=
                candidate.handler.formatFor(candidate.file.path)) {
          pendingCandidates.add(candidate);
          continue;
        }
        preparedCandidates.add(_PreparedScanCandidate(
          file: candidate.file,
          handler: candidate.handler,
          hash: persisted.hash,
          size: persisted.size,
          sourceCreatedAtMs: persisted.sourceCreatedAtMs,
          sourceModifiedAtMs: persisted.sourceModifiedAtMs,
          metadataPreview: persisted.metadataPreview,
          durationMs: persisted.durationMs,
        ));
      }
      preparationWatch.start();
      var preparedCount = preparedCandidates.length;
      if (preparedCount > 0) {
        onProgress?.call(ScanProgress(
          phase: ScanPhase.processing,
          discovered: totalCandidates,
          total: totalCandidates,
          processed: preparedCount,
          thumbnailTotal: 0,
          thumbnailProcessed: 0,
          message: '正在恢复元数据：$preparedCount/$totalCandidates',
        ));
      }
      final existingByPath = repository.getEntitiesByPaths(
        candidates.map((candidate) => candidate.file.path),
      );
      const preparationBatchSize = 200;
      for (var offset = 0;
          offset < pendingCandidates.length;
          offset += preparationBatchSize) {
        final end = (offset + preparationBatchSize)
            .clamp(0, pendingCandidates.length)
            .toInt();
        final batch = pendingCandidates.sublist(offset, end);
        final prepared = await _mapConcurrently(
          batch,
          maxConcurrent: 6,
          mapper: (candidate) async {
            final file = candidate.file;
            final source = FileCandidateSource(file: file, rootPath: rootPath);
            final sourceSnapshot = await source.inspect();
            final fingerprint = sourceSnapshot.fingerprint;
            final existing = existingByPath[p.normalize(file.path)];
            final format = candidate.handler.formatFor(file.path);
            final unchanged = existing != null &&
                existing.hash == fingerprint &&
                existing.format == format &&
                existing.entityType == candidate.handler.entityType;
            // Older index versions could persist malformed UTF-8 previews.
            // Re-read only those text previews even when the source is unchanged.
            final needsTextPreviewRepair =
                candidate.handler.entityType == EntityType.text &&
                    _hasCorruptedTextPreview(existing?.metadataPreview);
            String? metadataPreview = existing?.metadataPreview;
            int? durationMs = existing?.durationMs;
            if (!unchanged || needsTextPreviewRepair) {
              final details = await Future.wait([
                _tryBuildMetadataPreview(
                    file: file, handler: candidate.handler),
                _tryBuildDurationMs(file: file, handler: candidate.handler),
              ]);
              metadataPreview = details[0] as String?;
              durationMs = details[1] as int?;
            }
            preparedCount++;
            onProgress?.call(ScanProgress(
              phase: ScanPhase.processing,
              discovered: totalCandidates,
              total: totalCandidates,
              processed: preparedCount,
              thumbnailTotal: 0,
              thumbnailProcessed: 0,
              message: '正在检查文件变化：$preparedCount/$totalCandidates',
            ));
            return _PreparedScanCandidate(
              file: file,
              handler: candidate.handler,
              hash: fingerprint,
              size: sourceSnapshot.size,
              sourceCreatedAtMs: sourceSnapshot.sourceCreatedAtMs,
              sourceModifiedAtMs: sourceSnapshot.sourceModifiedAtMs,
              metadataPreview: metadataPreview,
              durationMs: durationMs,
            );
          },
        );
        final sequenceStart = preparedCandidates.length;
        preparedCandidates.addAll(prepared);
        repository.upsertIndexJobCandidates(
          prepared.indexed.map(
            (entry) => IndexJobCandidate(
              // The persisted sequence is independent of filesystem order.
              jobId: job.id,
              sourcePath: p.normalize(entry.$2.file.path),
              relativePath: p
                  .relative(entry.$2.file.path, from: rootPath)
                  .replaceAll('\\', '/'),
              sequence: sequenceStart + entry.$1,
              state: IndexJobCandidateState.prepared,
              format: entry.$2.handler.formatFor(entry.$2.file.path),
              entityType: entry.$2.handler.entityType,
              fingerprint: entry.$2.hash,
              size: entry.$2.size,
              metadataPreview: entry.$2.metadataPreview,
              durationMs: entry.$2.durationMs,
              sourceCreatedAtMs: entry.$2.sourceCreatedAtMs,
              sourceModifiedAtMs: entry.$2.sourceModifiedAtMs,
              updatedAtMs: DateTime.now().millisecondsSinceEpoch,
            ),
          ),
        );
        repository.updateIndexJob(job.id, processed: preparedCandidates.length);
        _checkControl(job.id, control);
      }
      preparationWatch.stop();
      // The candidate rows now describe the entire source snapshot. Only a
      // complete snapshot may ever drive reconciliation after a restart.
      repository.updateIndexJob(job.id, scanCompleted: true);
      manifestComplete = true;
    }
    final resumingPreviews =
        canResumeManifest && job.phase == IndexJobPhase.previews;
    // The persisted manifest is keyed by path rather than discovery order.
    // Replaying writes is cheap and prevents an interrupted write from
    // skipping files when the filesystem enumerates in a different order.
    final writeStartOffset = resumingPreviews ? totalCandidates : 0;
    if (!resumingPreviews) {
      repository.updateIndexJob(
        job.id,
        phase: IndexJobPhase.writing,
        processed: writeStartOffset,
        total: totalCandidates,
      );
    }

    final existingIndexRoot = indexRootOverride == null
        ? repository.directoryIndexRootForSource(rootPath)
        : null;
    late final IndexNode indexRoot;
    repository.writeTransaction(() {
      indexRoot = indexRootOverride ??
          repository.ensureDirectoryIndexRoot(
            rootPath,
            staging: existingIndexRoot == null && targetNode == null,
          );
      repository.setIndexJobRoots(
        jobId: job.id,
        indexRootId: indexRoot.id,
        stagingRootId: targetNode == null &&
                (existingIndexRoot == null || indexRoot.isStaging)
            ? indexRoot.id
            : null,
      );
      repository.updateIndexJob(
        job.id,
        indexRootId: indexRoot.id,
        phase:
            resumingPreviews ? IndexJobPhase.previews : IndexJobPhase.writing,
      );
    });
    final writableExistingByPath = Map<String, Entity>.of(
      repository.getEntitiesByPaths(
        preparedCandidates.map((candidate) => candidate.file.path),
      ),
    );
    final preservedOwnerRootIds =
        targetNode == null && existingIndexRoot == null
            ? repository.directoryIndexRootIdsOverlapping(
                rootPath,
                excludingRootId: indexRoot.id,
              )
            : const <String>{};
    final directoryNodeCache = <String, IndexNode>{
      p.normalize(rootPath): targetNode ?? indexRoot,
    };
    var scanned = writeStartOffset;
    var imported = 0;
    var updated = 0;
    var skipped = 0;
    final mediaEntities = <Entity>[];
    final audioEntities = <Entity>[];
    final candidateProcessor = CandidateProcessor(repository);
    const writeBatchSize = 500;
    indexWriteWatch.start();
    try {
      for (var offset = writeStartOffset;
          offset < preparedCandidates.length;
          offset += writeBatchSize) {
        final end = (offset + writeBatchSize)
            .clamp(0, preparedCandidates.length)
            .toInt();
        final batch = preparedCandidates.sublist(offset, end);
        repository.writeTransaction(() {
          final links = <({String entityId, String indexNodeId})>[];
          final writtenPaths = <String>[];
          for (final candidate in batch) {
            final file = candidate.file;
            final handler = candidate.handler;
            final normalizedPath = p.normalize(file.path);
            final existing = writableExistingByPath[normalizedPath];
            final result = candidateProcessor.write(CandidateWriteRequest(
              jobId: job.id,
              path: normalizedPath,
              name: p.basename(file.path),
              format: handler.formatFor(file.path),
              entityType: handler.entityType,
              hash: candidate.hash,
              size: candidate.size,
              sourceCreatedAtMs: candidate.sourceCreatedAtMs,
              sourceModifiedAtMs: candidate.sourceModifiedAtMs,
              metadataPreview: candidate.metadataPreview,
              durationMs: candidate.durationMs,
              directoryRootId:
                  preservedOwnerRootIds.contains(existing?.directoryRootId)
                      ? existing!.directoryRootId!
                      : indexRoot.id,
              existing: existing,
            ));
            writableExistingByPath[normalizedPath] = result.entity;
            switch (result.status) {
              case EntityUpsertStatus.inserted:
                imported++;
              case EntityUpsertStatus.updated:
                updated++;
              case EntityUpsertStatus.skipped:
                skipped++;
            }
            final directoryNode = _ensureDirectoryNode(
              indexRoot: targetNode ?? indexRoot,
              rootPath: rootPath,
              filePath: file.path,
              cache: directoryNodeCache,
            );
            links.add((
              entityId: result.entity.id,
              indexNodeId: directoryNode.id,
            ));
            writtenPaths.add(normalizedPath);
            if (handler.supportsGeneratedThumbnail) {
              mediaEntities.add(result.entity);
            }
            if (handler.entityType == EntityType.audio) {
              audioEntities.add(result.entity);
            }
          }
          candidateProcessor.writeLinks(job.id, links, transactional: false);
          candidateProcessor.markStates(
            job.id,
            writtenPaths,
            IndexJobCandidateState.written,
          );
        });
        scanned = end;
        repository.updateIndexJob(job.id, processed: scanned);
        _checkControl(job.id, control);
        onProgress?.call(ScanProgress(
          phase: ScanPhase.processing,
          discovered: totalCandidates,
          total: totalCandidates,
          processed: scanned,
          thumbnailTotal: 0,
          thumbnailProcessed: 0,
          message: '正在写入索引：$scanned/$totalCandidates',
        ));
      }
      if (!manifestComplete) {
        throw StateError('Cannot reconcile an incomplete directory manifest');
      }
      if (targetNode == null) {
        repository.reconcileDirectoryIndexRoot(
          rootId: indexRoot.id,
          seenPaths: preparedCandidates.map((candidate) => candidate.file.path),
        );
      } else {
        repository.reconcileDirectoryIndexSubtree(
          nodeId: targetNode.id,
          rootId: indexRoot.id,
          seenPaths: preparedCandidates.map((candidate) => candidate.file.path),
        );
      }
    } finally {
      indexWriteWatch.stop();
    }
    // A resumed write starts after a persisted offset, so rehydrate all media
    // candidates before entering previews instead of only using the tail batch.
    mediaEntities
      ..clear()
      ..addAll(preparedCandidates
          .where((candidate) => candidate.handler.supportsGeneratedThumbnail)
          .map((candidate) =>
              writableExistingByPath[p.normalize(candidate.file.path)])
          .whereType<Entity>());
    audioEntities
      ..clear()
      ..addAll(preparedCandidates
          .where(
              (candidate) => candidate.handler.entityType == EntityType.audio)
          .map((candidate) =>
              writableExistingByPath[p.normalize(candidate.file.path)])
          .whereType<Entity>());
    final writeResult = _ScanWriteResult(
      summary: ScanSummary(
        indexRootId: indexRoot.id,
        scanned: scanned,
        imported: imported,
        updated: updated,
        skipped: skipped,
        thumbnailsBuilt: 0,
      ),
      mediaEntities: mediaEntities,
      audioEntities: audioEntities,
    );
    repository.rebuildIndexNodeStats();
    // Thumbnail success is durable in the entity row and the cache store, so
    // it is a safer resume checkpoint than a concurrent progress counter.
    final pendingMediaEntities = mediaEntities
        .where((entity) =>
            entity.thumbnailStatus != ThumbnailStatus.success ||
            entity.thumbnailPath == null)
        .toList(growable: false);
    final previewRequiredPaths = <String>{
      ...mediaEntities.map((entity) => p.normalize(entity.path)),
      ...audioEntities.map((entity) => p.normalize(entity.path)),
    };
    candidateProcessor.markStates(
      job.id,
      preparedCandidates
          .map((candidate) => p.normalize(candidate.file.path))
          .where((path) => !previewRequiredPaths.contains(path)),
      IndexJobCandidateState.previewed,
    );
    // Existing thumbnail cache entries are already durable preview results.
    candidateProcessor.markStates(
      job.id,
      mediaEntities
          .where((entity) =>
              entity.thumbnailStatus == ThumbnailStatus.success &&
              entity.thumbnailPath != null)
          .map((entity) => p.normalize(entity.path)),
      IndexJobCandidateState.previewed,
    );
    final candidateStates = {
      for (final candidate in repository.listIndexJobCandidates(job.id))
        p.normalize(candidate.sourcePath): candidate.state,
    };
    final audioNeedingPreview = audioEntities
        .where((entity) =>
            candidateStates[p.normalize(entity.path)] !=
            IndexJobCandidateState.previewed)
        .toList(growable: false);
    final previewTotal =
        pendingMediaEntities.length + audioNeedingPreview.length;
    repository.updateIndexJob(
      job.id,
      phase: IndexJobPhase.previews,
      previewTotal: previewTotal,
      previewProcessed: 0,
    );
    if (previewTotal == 0) {
      await IndexNodeThumbnailService(repository).rebuildForRoot(indexRoot);
      totalWatch.stop();
      onProgress?.call(
        ScanProgress(
          phase: ScanPhase.completed,
          discovered: totalCandidates,
          total: totalCandidates,
          processed: totalCandidates,
          thumbnailTotal: 0,
          thumbnailProcessed: 0,
          message: '索引构建完成',
        ),
      );
      return _withTimings(
        writeResult.summary,
        ScanTimingSummary(
          discoveryMs: discoveryWatch.elapsedMilliseconds,
          preparationMs: preparationWatch.elapsedMilliseconds,
          indexWriteMs: indexWriteWatch.elapsedMilliseconds,
          totalMs: totalWatch.elapsedMilliseconds,
        ),
      );
    }

    final imageEntities = pendingMediaEntities
        .where((entity) => entity.entityType == EntityType.image)
        .toList(growable: false)
      ..sort((left, right) => left.size.compareTo(right.size));
    const largeImageThresholdBytes = 10 * 1024 * 1024;
    final smallImageEntities = imageEntities
        .where((entity) => entity.size < largeImageThresholdBytes)
        .toList(growable: false);
    final largeImageEntities = imageEntities
        .where((entity) => entity.size >= largeImageThresholdBytes)
        .toList(growable: false);
    final otherMediaEntities = pendingMediaEntities
        .where((entity) => entity.entityType != EntityType.image)
        .toList(growable: false);
    final orderedMediaEntities = <Entity>[
      ...smallImageEntities,
      ...largeImageEntities,
      ...otherMediaEntities,
    ];
    final hasImages = imageEntities.isNotEmpty;
    final performance = ThumbnailPerformanceProfile.forCurrentPlatform();
    final imageWorkerPool = hasImages
        ? ImageThumbnailWorkerPool(workerCount: performance.imageWorkerCount)
        : null;
    final updateBuffer = ThumbnailUpdateBuffer(repository);
    final service = ThumbnailService(
      repository,
      imageWorkerPool: imageWorkerPool,
      androidImageBackend: hasImages ? AndroidImageThumbnailBackend() : null,
      androidVideoBackend: AndroidVideoThumbnailBackend(),
      nativeImageBackend: hasImages ? NativeImageThumbnailBackend() : null,
      windowsWicBackend: hasImages ? WindowsWicWebpThumbnailBackend() : null,
      updateBuffer: updateBuffer,
    );
    final waveformService = AudioWaveformService(
      AudioWaveformStore(repository.database.storageDirectoryPath),
    );
    final videoQueue = ThumbnailQueue(
      service: service,
      maxConcurrent: performance.videoConcurrency,
    );
    final smallImageQueue = ThumbnailQueue(
      service: service,
      maxConcurrent: performance.smallImageConcurrency,
    );
    final largeImageQueue = ThumbnailQueue(
      service: service,
      maxConcurrent: performance.largeImageConcurrency,
    );
    final documentQueue = ThumbnailQueue(
      service: service,
      maxConcurrent: performance.documentConcurrency,
    );
    ThumbnailQueue queueFor(Entity entity) => switch (entity.entityType) {
          EntityType.video => videoQueue,
          EntityType.image when entity.size >= largeImageThresholdBytes =>
            largeImageQueue,
          EntityType.image => smallImageQueue,
          _ => documentQueue,
        };
    var processedThumbnails = 0;
    var thumbnailsBuilt = 0;
    final thumbnailWatch = Stopwatch()..start();
    final progressWatch = Stopwatch()..start();
    void reportPreviewProgress() {
      processedThumbnails++;
      if (processedThumbnails == previewTotal ||
          processedThumbnails % 20 == 0) {
        repository.updateIndexJob(
          job.id,
          previewProcessed: processedThumbnails,
        );
      }
      _checkControl(job.id, control);
      final shouldRenderProgress = processedThumbnails == 1 ||
          processedThumbnails == previewTotal ||
          processedThumbnails % 25 == 0 ||
          progressWatch.elapsedMilliseconds >= 100;
      if (!shouldRenderProgress) return;
      progressWatch
        ..reset()
        ..start();
      onProgress?.call(
        ScanProgress(
          phase: ScanPhase.processing,
          discovered: totalCandidates,
          total: totalCandidates,
          processed: totalCandidates,
          thumbnailTotal: previewTotal,
          thumbnailProcessed: processedThumbnails,
          message: '正在生成预览数据：$processedThumbnails/$previewTotal',
        ),
      );
    }

    try {
      await Future.wait([
        Future.wait(orderedMediaEntities.map((entity) async {
          try {
            final built = await queueFor(entity).enqueue(entity);
            if (built) thumbnailsBuilt++;
          } catch (error) {
            // Failed candidates are included in the next resume manifest.
            candidateProcessor.markState(
              job.id,
              p.normalize(entity.path),
              IndexJobCandidateState.failed,
              error: '$error',
            );
          } finally {
            reportPreviewProgress();
          }
        })),
        _mapConcurrently(
          audioNeedingPreview,
          maxConcurrent: performance.audioConcurrency,
          mapper: (entity) async {
            try {
              await waveformService.ensure(
                path: entity.path,
                fingerprint: entity.hash,
                durationMs: entity.durationMs,
              );
              candidateProcessor.markState(
                job.id,
                p.normalize(entity.path),
                IndexJobCandidateState.previewed,
              );
            } catch (error) {
              candidateProcessor.markState(
                job.id,
                p.normalize(entity.path),
                IndexJobCandidateState.failed,
                error: '$error',
              );
            } finally {
              reportPreviewProgress();
            }
          },
        ),
      ]);
    } finally {
      thumbnailWatch.stop();
      updateBuffer.flush();
      candidateProcessor.finalizeWrittenPreviewStates(job.id);
      await imageWorkerPool?.close();
    }
    await service.trimCacheToPlatformLimit();
    await IndexNodeThumbnailService(repository).rebuildForRoot(indexRoot);

    onProgress?.call(
      ScanProgress(
        phase: ScanPhase.completed,
        discovered: totalCandidates,
        total: totalCandidates,
        processed: totalCandidates,
        thumbnailTotal: previewTotal,
        thumbnailProcessed: previewTotal,
        message: '索引构建完成',
      ),
    );
    totalWatch.stop();
    final thumbnailTimings = service.timings.snapshot();
    return ScanSummary(
      indexRootId: writeResult.summary.indexRootId,
      scanned: writeResult.summary.scanned,
      imported: writeResult.summary.imported,
      updated: writeResult.summary.updated,
      skipped: writeResult.summary.skipped,
      thumbnailsBuilt: thumbnailsBuilt,
      timings: ScanTimingSummary(
        discoveryMs: discoveryWatch.elapsedMilliseconds,
        preparationMs: preparationWatch.elapsedMilliseconds,
        indexWriteMs: indexWriteWatch.elapsedMilliseconds,
        thumbnailWallMs: thumbnailWatch.elapsedMilliseconds,
        totalMs: totalWatch.elapsedMilliseconds,
        imageThumbnailMs: thumbnailTimings.imageMs,
        videoThumbnailMs: thumbnailTimings.videoMs,
        documentThumbnailMs: thumbnailTimings.documentMs,
        imageReadMs: thumbnailTimings.imageReadMs,
        imageDecodeMs: thumbnailTimings.imageDecodeMs,
        imageResizeMs: thumbnailTimings.imageResizeMs,
        imageEncodeMs: thumbnailTimings.imageEncodeMs,
        imageP95Ms: thumbnailTimings.imageP95Ms,
        imageAverageMegapixels: thumbnailTimings.imageCount == 0
            ? 0
            : thumbnailTimings.imageSourcePixels /
                thumbnailTimings.imageCount /
                1000000,
      ),
    );
  }

  IndexNode _ensureDirectoryNode({
    required IndexNode indexRoot,
    required String rootPath,
    required String filePath,
    required Map<String, IndexNode> cache,
  }) {
    var parent = indexRoot;
    final relativeDir = p.relative(p.dirname(filePath), from: rootPath);
    final segments = relativeDir == '.' ? <String>[] : p.split(relativeDir);
    var currentPath = p.normalize(rootPath);
    for (final segment in segments) {
      currentPath = p.join(currentPath, segment);
      parent = cache[currentPath] ??
          repository.ensureIndexNode(
            parentId: parent.id,
            name: segment,
            nodeType: NodeType.folder,
            viewType: ViewType.tree,
          );
      repository.setDirectoryNodeRelativePath(
        parent.id,
        p.relative(currentPath, from: rootPath),
      );
      cache[currentPath] = parent;
    }
    return parent;
  }

  IndexNode _ensureDirectoryNodeForRelativePath({
    required IndexNode indexRoot,
    required String relativePath,
    required Map<String, IndexNode> cache,
  }) {
    var parent = indexRoot;
    final normalized = relativePath.replaceAll('\\', '/');
    final separator = normalized.lastIndexOf('/');
    if (separator <= 0) return parent;
    final directory = normalized.substring(0, separator);
    var currentPath = '';
    for (final segment in directory.split('/')) {
      if (segment.isEmpty) continue;
      currentPath = currentPath.isEmpty ? segment : '$currentPath/$segment';
      parent = cache[currentPath] ??
          repository.ensureIndexNode(
            parentId: parent.id,
            name: segment,
            nodeType: NodeType.folder,
            viewType: ViewType.tree,
          );
      repository.setDirectoryNodeRelativePath(parent.id, currentPath);
      cache[currentPath] = parent;
    }
    return parent;
  }

  void _checkControl(String jobId, IndexScanControl? control) {
    if (control?._cancelRequested == true) {
      repository.updateIndexJob(jobId, status: IndexJobStatus.abandoned);
      throw const IndexScanCanceledException();
    }
    if (control?._pauseRequested == true) {
      repository.updateIndexJob(jobId, status: IndexJobStatus.paused);
      throw const IndexScanPausedException();
    }
  }
}

class ThumbnailPerformanceProfile {
  const ThumbnailPerformanceProfile({
    required this.smallImageConcurrency,
    required this.largeImageConcurrency,
    required this.videoConcurrency,
    required this.documentConcurrency,
    required this.audioConcurrency,
  });

  final int smallImageConcurrency;
  final int largeImageConcurrency;
  final int videoConcurrency;
  final int documentConcurrency;
  final int audioConcurrency;

  int get imageWorkerCount => smallImageConcurrency + largeImageConcurrency;

  factory ThumbnailPerformanceProfile.forCurrentPlatform() {
    final cores = max(4, Platform.numberOfProcessors);
    if (Platform.isAndroid || Platform.isIOS) {
      return const ThumbnailPerformanceProfile(
        smallImageConcurrency: 8,
        largeImageConcurrency: 8,
        videoConcurrency: 4,
        documentConcurrency: 8,
        audioConcurrency: 8,
      );
    }
    final imageBudget = min(18, max(10, cores - 2));
    final largeImageConcurrency = min(6, max(4, imageBudget ~/ 3));
    return ThumbnailPerformanceProfile(
      smallImageConcurrency: imageBudget - largeImageConcurrency,
      largeImageConcurrency: largeImageConcurrency,
      videoConcurrency: min(6, max(3, cores ~/ 4)),
      documentConcurrency: min(4, max(2, cores ~/ 6)),
      audioConcurrency: min(6, max(3, cores ~/ 4)),
    );
  }
}

ScanSummary _withTimings(ScanSummary summary, ScanTimingSummary timings) {
  return ScanSummary(
    indexRootId: summary.indexRootId,
    scanned: summary.scanned,
    imported: summary.imported,
    updated: summary.updated,
    skipped: summary.skipped,
    thumbnailsBuilt: summary.thumbnailsBuilt,
    timings: timings,
  );
}

String _formatDuration(int milliseconds) {
  if (milliseconds < 1000) return '${milliseconds}ms';
  return '${(milliseconds / 1000).toStringAsFixed(1)}s';
}

Future<List<R>> _mapConcurrently<T, R>(
  List<T> values, {
  required int maxConcurrent,
  required Future<R> Function(T value) mapper,
}) async {
  if (values.isEmpty) return const [];
  final results = List<R?>.filled(values.length, null);
  var nextIndex = 0;

  Future<void> worker() async {
    while (true) {
      final index = nextIndex++;
      if (index >= values.length) return;
      results[index] = await mapper(values[index]);
    }
  }

  await Future.wait(
    List.generate(
      maxConcurrent.clamp(1, values.length).toInt(),
      (_) => worker(),
    ),
  );
  return results.cast<R>();
}

bool _isUnchangedAndroidMedia({
  required Entity? entity,
  required FileFormatHandler handler,
  required SafCandidateSource source,
  required String fingerprint,
  required String indexRootId,
}) {
  final document = source.document;
  if (entity == null ||
      (handler.entityType != EntityType.image &&
          handler.entityType != EntityType.video)) {
    return false;
  }
  return entity.hash == fingerprint &&
      entity.name == document.name &&
      entity.format == handler.formatFor(document.name) &&
      entity.entityType == handler.entityType &&
      entity.size == document.size &&
      entity.directoryRootId == indexRootId &&
      entity.localPath == null &&
      entity.thumbnailStatus == ThumbnailStatus.success &&
      entity.thumbnailKey != null &&
      entity.thumbnailFormat != null &&
      entity.thumbnailPath != null &&
      File(entity.thumbnailPath!).existsSync();
}

class _ScanCandidate {
  const _ScanCandidate({
    required this.file,
    required this.handler,
  });

  final File file;
  final FileFormatHandler handler;
}

class _PreparedScanCandidate {
  const _PreparedScanCandidate({
    required this.file,
    required this.handler,
    required this.hash,
    required this.size,
    required this.sourceCreatedAtMs,
    required this.sourceModifiedAtMs,
    this.metadataPreview,
    this.durationMs,
  });

  final File file;
  final FileFormatHandler handler;
  final String hash;
  final int size;
  final int sourceCreatedAtMs;
  final int sourceModifiedAtMs;
  final String? metadataPreview;
  final int? durationMs;
}

class _PersistedScanFile {
  const _PersistedScanFile({
    required this.path,
    required this.format,
    required this.hash,
    required this.size,
    required this.sourceCreatedAtMs,
    required this.sourceModifiedAtMs,
    this.metadataPreview,
    this.durationMs,
  });

  factory _PersistedScanFile.fromCandidate(IndexJobCandidate candidate) =>
      _PersistedScanFile(
        path: candidate.sourcePath,
        format: candidate.format!,
        hash: candidate.fingerprint!,
        size: candidate.size!,
        sourceCreatedAtMs: candidate.sourceCreatedAtMs!,
        sourceModifiedAtMs: candidate.sourceModifiedAtMs!,
        metadataPreview: candidate.metadataPreview,
        durationMs: candidate.durationMs,
      );

  final String path;
  final String format;
  final String hash;
  final int size;
  final int sourceCreatedAtMs;
  final int sourceModifiedAtMs;
  final String? metadataPreview;
  final int? durationMs;
}

class _ScanWriteResult {
  const _ScanWriteResult({
    required this.summary,
    required this.mediaEntities,
    required this.audioEntities,
  });

  final ScanSummary summary;
  final List<Entity> mediaEntities;
  final List<Entity> audioEntities;
}

Future<String?> _buildMetadataPreview({
  required File file,
  required FileFormatHandler handler,
}) async {
  switch (handler.entityType) {
    case EntityType.text:
      final text = await readTextFile(file, maxBytes: 8 * 1024);
      final preview = _limitPreview(text);
      return preview.isEmpty ? null : preview;
    case EntityType.audio:
      return 'AUDIO ${handler.formatFor(file.path).toUpperCase()}';
    case EntityType.externalLink:
      final ext = handler.formatFor(file.path).toUpperCase();
      if (ext == 'DOCX') return _limitPreview(await readDocxText(file));
      if (ext == 'EPUB') {
        final book = await readEpubBook(file);
        return _limitPreview(
            book.chapters.map((chapter) => chapter.text).join('\n'));
      }
      if (ext == 'PDF') return 'PDF';
      return 'DOCUMENT $ext';
    case EntityType.image:
    case EntityType.video:
      return null;
  }
}

/// Preview extraction must not decide whether a supported file becomes an
/// entity. Some valid EPUB/DOCX archives contain optional broken resources.
Future<String?> _tryBuildMetadataPreview({
  required File file,
  required FileFormatHandler handler,
}) async {
  try {
    return await _buildMetadataPreview(file: file, handler: handler);
  } catch (_) {
    return null;
  }
}

String _limitPreview(String text) =>
    text.trim().substring(0, text.trim().length.clamp(0, 500));

bool _hasCorruptedTextPreview(String? preview) {
  if (preview == null || preview.isEmpty) return false;
  return preview.contains('\uFFFD') ||
      preview.contains('锟') ||
      preview.contains('ï¿½');
}

Future<int?> _buildDurationMs({
  required File file,
  required FileFormatHandler handler,
}) {
  if (handler.entityType != EntityType.audio) {
    return Future<int?>.value(null);
  }
  return probeMediaDurationMs(file);
}

Future<int?> _tryBuildDurationMs({
  required File file,
  required FileFormatHandler handler,
}) async {
  try {
    return await _buildDurationMs(file: file, handler: handler);
  } catch (_) {
    return null;
  }
}

String _normalizeScanRootPath(String path) {
  final trimmed = path.trim();
  if (SourceHandle.parse(trimmed).isAndroidContentUri) return trimmed;
  final normalized = p.normalize(trimmed);
  if (normalized.isEmpty || normalized == '.') {
    throw FileSystemException('Library root path cannot be empty', path);
  }
  return normalized;
}
