import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../database/library_build_repository.dart';
import '../database/library_repository.dart';
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
          case LibraryBuildStage.entityPreviews:
            await _buildEntityPreviews(job);
          case LibraryBuildStage.nodePreviews:
            await _buildNodePreviews(job);
          case LibraryBuildStage.completed:
            break;
        }
        job = builds.get(job.id)!;
        _activeJob = job;
        notifyListeners();
        // Let the progress UI paint the checkpoint before a fast following
        // stage completes synchronously (especially for text-only indexes).
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      return job;
    } on LibraryBuildPausedException {
      builds.releaseProcessingWork(
        job.id,
        entity: job.stage == LibraryBuildStage.entityPreviews,
      );
      builds.pause(job.id);
      return null;
    } on LibraryBuildAbandonedException {
      if (job.stage == LibraryBuildStage.entityPreviews ||
          job.stage == LibraryBuildStage.nodePreviews) {
        builds.releaseProcessingWork(
          job.id,
          entity: job.stage == LibraryBuildStage.entityPreviews,
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
        builds.upsertManifest(batch);
        batch = <LibraryBuildManifestItem>[];
        _report(job, sequence, 0, '正在建立清单：$sequence 个实体');
      }
    }
    if (batch.isNotEmpty) builds.upsertManifest(batch);
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
        if (items.isNotEmpty) builds.upsertManifest(items);
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
      final links = <({String entityId, String indexNodeId})>[];
      for (final item in page) {
        _control!.check();
        final handler = FileFormatRegistry.resolvePath(item.name);
        if (handler == null) continue;
        final details = await _inspectForIndex(item, handler);
        final node = await _ensureDirectoryNode(
          root: attachNode,
          relativePath: item.relativePath,
          cache: directoryCache,
        );
        final result = library.upsertEntity(
          path: item.sourcePath,
          name: item.name,
          format: item.format,
          entityType: item.entityType,
          hash: details.$1,
          size: details.$2,
          sourceCreatedAtMs: details.$3,
          sourceModifiedAtMs: details.$4,
          metadataPreview: details.$5,
          durationMs: details.$6,
          directoryRootId: root.id,
          knownExisting: existing[item.sourcePath],
          existingLookupCompleted: true,
        );
        links.add((entityId: result.entity.id, indexNodeId: node.id));
        written++;
        cursor = item.sequence;
      }
      library.linkEntitiesToIndexNodes(
        links,
        rebuildStats: false,
        markPreviewDirty: false,
      );
      // A whole manifest page is durable. Resuming never reprocesses it.
      builds.updateIndexedProgress(job.id, written);
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
    builds.prepareEntityPreviewWork(job.id, scopeId);
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
      await Future.wait([
        _forEachConcurrent(entityIds, 8, (id) async {
          final entity = entities[id];
          if (entity?.entityType != EntityType.image) return;
          await _buildOneEntityPreview(id, entity!, results);
        }),
        _forEachConcurrent(entityIds, 4, (id) async {
          final entity = entities[id];
          if (entity?.entityType != EntityType.video) return;
          await _buildOneEntityPreview(id, entity!, results);
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
    final entityComplete = builds.get(job.id)!;
    if (entityComplete.entityPreviewFailed > 0) {
      throw StateError('实体预览有 ${entityComplete.entityPreviewFailed} 项失败');
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
    String id,
    Entity entity,
    Map<String, ({LibraryBuildWorkState state, String? error})> results,
  ) async {
    try {
      _control!.check();
      await _thumbnails.ensureThumbnail(entity);
      _control!.check();
      final refreshed = library.getEntity(id);
      results[id] = refreshed?.thumbnailStatus == ThumbnailStatus.success
          ? (state: LibraryBuildWorkState.completed, error: null)
          : (
              state: LibraryBuildWorkState.failed,
              error: refreshed?.thumbnailError ?? '缩略图生成失败',
            );
    } on LibraryBuildPausedException {
      rethrow;
    } on LibraryBuildAbandonedException {
      rethrow;
    } catch (error) {
      results[id] = (state: LibraryBuildWorkState.failed, error: '$error');
    }
  }

  Future<void> _buildNodePreviews(LibraryBuildJob job) async {
    final rootId = job.indexRootId;
    if (rootId == null) throw StateError('索引根节点缺失');
    // Preview descriptions are computed bottom-up once before the composite
    // work. The asset writer then only reads existing entity WebPs.
    library.rebuildIndexNodePreviewCache(job.targetNodeId ?? rootId);
    final compositor = NodePreviewCompositeService(library);
    while (true) {
      _control!.check();
      final nodeIds = builds.claimNodePreviewWork(job.id);
      if (nodeIds.isEmpty) break;
      final results =
          <String, ({LibraryBuildWorkState state, String? error})>{};
      for (final nodeId in nodeIds) {
        try {
          _control!.check();
          compositor.rebuildNodes([nodeId]);
          results[nodeId] =
              (state: LibraryBuildWorkState.completed, error: null);
        } on LibraryBuildPausedException {
          rethrow;
        } on LibraryBuildAbandonedException {
          rethrow;
        } catch (error) {
          results[nodeId] =
              (state: LibraryBuildWorkState.failed, error: '$error');
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
    }
    final nodeComplete = builds.get(job.id)!;
    if (nodeComplete.nodePreviewFailed > 0) {
      throw StateError('节点预览有 ${nodeComplete.nodePreviewFailed} 项失败');
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
    try {
      final preview = switch (handler.entityType) {
        EntityType.text =>
          _limitPreview(await readTextFile(file, maxBytes: 8192)),
        EntityType.audio =>
          'AUDIO ${handler.formatFor(file.path).toUpperCase()}',
        EntityType.externalLink when handler.formatFor(file.path) == 'docx' =>
          _limitPreview(await readDocxText(file)),
        EntityType.externalLink when handler.formatFor(file.path) == 'epub' =>
          _limitPreview((await readEpubBook(file))
              .chapters
              .map((chapter) => chapter.text)
              .join('\n')),
        EntityType.externalLink when handler.formatFor(file.path) == 'pdf' =>
          'PDF',
        EntityType.externalLink =>
          'DOCUMENT ${handler.formatFor(file.path).toUpperCase()}',
        EntityType.image || EntityType.video => null,
      };
      final duration = handler.entityType == EntityType.audio
          ? await probeMediaDurationMs(file)
          : null;
      return (preview?.isEmpty == true ? null : preview, duration);
    } catch (_) {
      return (null, null);
    }
  }

  Future<(String, int, int, int, String?, int?)> _inspectForIndex(
    LibraryBuildManifestItem item,
    FileFormatHandler handler,
  ) async {
    final source = SourceHandle.parse(item.sourcePath);
    if (!source.isAndroidContentUri) {
      final file = File(item.sourcePath);
      final stat = await file.stat();
      final metadata = await _metadataForFile(file, handler);
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
    String? metadataPreview;
    int? durationMs;
    if (handler.entityType != EntityType.image &&
        handler.entityType != EntityType.video) {
      final localPath = await PlatformDirectoryPicker.materializeDocument(
        item.sourcePath,
        name: item.name,
        cacheScope: 'scan',
      );
      final file = File(localPath);
      try {
        (metadataPreview, durationMs) = await _metadataForFile(file, handler);
      } finally {
        if (await file.exists()) await file.delete();
      }
    }
    return (
      fingerprintFromPrefix(size: item.size, prefix: prefix),
      item.size,
      item.sourceCreatedAtMs,
      item.sourceModifiedAtMs,
      metadataPreview,
      durationMs,
    );
  }

  Future<void> _forEachConcurrent(
    List<String> values,
    int concurrency,
    Future<void> Function(String value) action,
  ) async {
    var next = 0;
    Future<void> worker() async {
      while (next < values.length) {
        _control!.check();
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
    _progress = LibraryBuildProgress(
      stage: current.stage,
      completed: completed,
      total: total,
      failed: failed,
      message: message,
    );
    notifyListeners();
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
  return trimmed.substring(0, trimmed.length.clamp(0, 500));
}
