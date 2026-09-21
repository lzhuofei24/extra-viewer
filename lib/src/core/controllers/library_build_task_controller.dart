import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../modules/build/build_access.dart';
import '../../modules/build/periodic_checkpoint.dart';
import '../../modules/previews/archive_preview_pipeline.dart';
import '../../modules/previews/archive_document_preview.dart';
import '../../modules/library/library_access.dart';
import '../diagnostics/app_diagnostic_log.dart';
import '../domain/models.dart';
import '../formats/file_format_handlers.dart';
import '../formats/text_decoder.dart';
import '../../modules/sources/source_adapter.dart';
import '../sources/platform_directory_picker.dart';
import '../sources/source_handle.dart';
import '../thumbnails/android_image_thumbnail_backend.dart';
import '../thumbnails/android_video_thumbnail_backend.dart';
import '../thumbnails/node_preview_composite_service.dart';
import '../thumbnails/thumbnail_service.dart';
import '../thumbnails/thumbnail_cancellation.dart';
import '../thumbnails/cancellable_thumbnail_task.dart';
import '../utils/file_fingerprint.dart';
import '../sync/directory_diff_scanner.dart';

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
  final thumbnailCancellation = ThumbnailCancellationToken();
  bool _paused = false;
  bool _abandoned = false;

  bool get paused => _paused;
  bool get abandoned => _abandoned;

  void pause() {
    _paused = true;
    thumbnailCancellation.pause();
  }

  void abandon() {
    _abandoned = true;
    thumbnailCancellation.cancel();
  }

  void check() {
    if (_abandoned) throw const LibraryBuildAbandonedException();
    if (_paused) throw const LibraryBuildPausedException();
  }
}

/// Executes the only directory build lifecycle. A process interruption can
/// restart manifest/index/finalize safely and resumes derived assets at the
/// most recently committed group of at most 100 work rows.
class LibraryBuildTaskController extends ChangeNotifier {
  LibraryBuildTaskController(this.library, {required this.builds})
      : _thumbnails = ThumbnailService(
          library,
          androidImageBackend: AndroidImageThumbnailBackend(),
          androidVideoBackend: AndroidVideoThumbnailBackend(),
        );

  Future<void> initialize() async {
    await builds.markInterruptedRecoverable();
    await library.collectRetiredPreviewAssets();
    await refresh();
  }

  final LibraryAccess library;
  final BuildAccess builds;
  final ThumbnailService _thumbnails;

  LibraryBuildControl? _control;
  LibraryBuildProgress? _progress;
  LibraryBuildJob? _activeJob;
  List<LibraryBuildJob> _recoverable = const [];
  List<LibraryBuildJob> _history = const [];
  String? _error;
  Timer? _progressNotifyTimer;
  bool _disposed = false;
  bool _closing = false;
  Future<LibraryBuildJob?>? _activeRun;
  DateTime _lastProgressNotification = DateTime.fromMillisecondsSinceEpoch(0);

  static const _progressNotificationInterval = Duration(milliseconds: 150);

  bool get isRunning => _control != null || _closing || _disposed;
  LibraryBuildProgress? get progress => _progress;
  LibraryBuildJob? get activeJob => _activeJob;
  List<LibraryBuildJob> get recoverableJobs => _recoverable;
  List<LibraryBuildJob> get history => _history;
  String? get errorMessage => _error;

  Future<void> refresh() async {
    _recoverable = (await builds.listRecoverable());
    _history = (await builds.listHistory());
    final listed = <LibraryBuildJob>[];
    for (var offset = 0; offset < _taskLimit; offset += 100) {
      final page = await builds.listTasks(offset: offset);
      listed.addAll(page);
      if (page.length < 100) break;
    }
    _tasks = {
      for (final job in [...listed, ..._recoverable]) job.id: job
    }.values.toList();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _control?.pause();
    _progressNotifyTimer?.cancel();
    unawaited(completedTasks.close());
    super.dispose();
  }

  final Set<String> _eligible = {};
  Future<void>? _draining;
  Future<void>? _commands;
  List<LibraryBuildJob> _tasks = [];
  int _taskLimit = 100;
  List<LibraryBuildJob> get tasks => _tasks;
  Future<void> loadMoreTasks() async {
    _taskLimit += 100;
    await refresh();
  }

  int get attentionCount => _recoverable.length;
  final completedTasks = StreamController<LibraryBuildJob>.broadcast();

  Future<T> _command<T>(Future<T> Function() action) {
    final result = _commands?.then((_) => action()) ?? Future<T>.sync(action);
    late Future<void> tail;
    tail = result
        .then<void>((_) {}, onError: (Object e, StackTrace s) {})
        .whenComplete(() {
      if (identical(_commands, tail)) _commands = null;
    });
    _commands = tail;
    return result;
  }

  void pause() {
    final id = _activeJob?.id;
    if (id != null) unawaited(pauseTask(id));
  }

  void abandonActive() {
    final id = _activeJob?.id;
    if (id != null) unawaited(cancelTask(id));
  }

  Future<void> close() async {
    _closing = true;
    _eligible.clear();
    _control?.pause();
    if (_commands != null) await _commands;
    if (_activeRun != null) await _activeRun;
    if (_draining != null) await _draining;
    _progressNotifyTimer?.cancel();
  }

  Future<LibraryBuildJob?> startRoot(String sourcePath,
          {String? displayName}) =>
      createImportTask(sourcePath, displayName: displayName);
  Future<LibraryBuildJob?> updateNode(IndexNode node) => createUpdateTask(node);
  Future<LibraryBuildJob?> enqueueNodeUpdate(IndexNode node) =>
      createUpdateTask(node);

  Future<LibraryBuildJob> createImportTask(String sourcePath,
          {String? displayName}) =>
      _command(() async {
        if (_closing || _disposed) throw StateError('应用正在关闭');
        final source = _normalizeSource(sourcePath);
        if (sourcePath.trim().isEmpty) throw ArgumentError('目录来源不能为空');
        final duplicate = await _conflict(source, null, false);
        if (duplicate != null) return duplicate;
        final job = await builds.create(
            sourcePath: source, operation: LibraryBuildOperation.rootScan);
        await builds.configureTask(job.id,
            taskKind: 'import', priority: 70, displayName: displayName);
        await _admit(job.id);
        return (await builds.get(job.id))!;
      });

  Future<LibraryBuildJob> createUpdateTask(IndexNode node) =>
      _command(() async {
        if (_closing || _disposed) throw StateError('应用正在关闭');
        final root = await library.directoryIndexRootForNode(node.id);
        if (root?.sourcePath == null) throw StateError('目录来源已不存在');
        final source = SourceHandle.parse(root!.sourcePath!).isAndroidContentUri
            ? root.sourcePath!
            : p.join(root.sourcePath!,
                (await library.directoryNodeRelativePath(node.id)) ?? '');
        final duplicate =
            await _conflict(_normalizeSource(source), node.id, false);
        if (duplicate != null) return duplicate;
        final job = await builds.create(
            sourcePath: _normalizeSource(source),
            operation: LibraryBuildOperation.subtreeRefresh,
            targetNodeId: node.id);
        await builds.configureTask(job.id,
            taskKind: 'update',
            priority: node.id == root.id ? 70 : 80,
            displayName: node.name);
        await _admit(job.id);
        return (await builds.get(job.id))!;
      });

  Future<LibraryBuildJob?> _conflict(
      String source, String? nodeId, bool preview,
      {String? ignoreId}) async {
    final jobs = await builds.listRecoverable();
    final newAncestors = nodeId == null
        ? <String>{}
        : (await library.listIndexNodeAncestors(nodeId))
            .map((n) => n.id)
            .toSet();
    for (final job in jobs) {
      if (job.id == ignoreId) continue;
      final same = job.targetNodeId == nodeId &&
          _normalizeSource(job.sourcePath) == source;
      final oldAncestors = job.targetNodeId == null
          ? <String>{}
          : (await library.listIndexNodeAncestors(job.targetNodeId!))
              .map((n) => n.id)
              .toSet();
      final local = !SourceHandle.parse(source).isAndroidContentUri &&
          !source.startsWith('index://');
      final covers = nodeId != null && oldAncestors.contains(nodeId) ||
          local && p.isWithin(source, job.sourcePath);
      final covered =
          job.targetNodeId != null && newAncestors.contains(job.targetNodeId) ||
              local && p.isWithin(job.sourcePath, source);
      if (!same && !covers && !covered) continue;
      if (job.status == LibraryBuildStatus.cancelRequested) {
        throw StateError('同范围任务正在取消并释放资源');
      }
      if (!preview &&
          job.kind == LibraryBuildKind.rebuildPreviews &&
          job.status == LibraryBuildStatus.running) {
        throw StateError('同范围预览任务正在执行，请结束后更新目录');
      }
      if (same && (job.kind == LibraryBuildKind.rebuildPreviews) == preview) {
        return job;
      }
      if (covers &&
          job.status == LibraryBuildStatus.pending &&
          !preview &&
          job.kind == LibraryBuildKind.scanScope) {
        _eligible.remove(job.id);
        await builds.recordTaskOperation(job.id, '合并到父目录更新');
        await builds.abandon(job.id);
      }
    }
    return null;
  }

  Future<void> _admit(String id, {bool manualOnly = false}) async {
    if (!manualOnly) _eligible.add(id);
    await refresh();
    if (!manualOnly && !_closing && !_disposed) {
      unawaited(drainRecoverableQueue());
    }
  }

  Future<List<LibraryBuildJob>> enqueueDirectoryUpdates(
      Iterable<DirectorySyncRoot> roots) async {
    final result = <LibraryBuildJob>[];
    for (final root in roots) {
      final node = await library.getIndexNode(root.rootId);
      if (node != null) result.add(await createUpdateTask(node));
    }
    return result;
  }

  // Only IDs admitted in this process may run. Loading old queued tasks never
  // grants execution permission.
  Future<void> drainRecoverableQueue() {
    if (_draining != null) return _draining!;
    if (_disposed || _closing) return Future.value();
    return _draining = _drain().whenComplete(() {
      _draining = null;
    });
  }

  Future<void> _drain() async {
    while (!_disposed && !_closing && _eligible.isNotEmpty) {
      if (isRunning) {
        await _activeRun;
        continue;
      }
      final candidates = (await builds.listRecoverable())
          .where((j) =>
              _eligible.contains(j.id) &&
              j.status == LibraryBuildStatus.pending)
          .toList()
        ..sort((a, b) {
          final priority = b.priority.compareTo(a.priority);
          return priority != 0
              ? priority
              : a.createdAtMs.compareTo(b.createdAtMs);
        });
      if (candidates.isEmpty) break;
      if (_closing || _disposed) break;
      final job = candidates.first;
      if (!_eligible.contains(job.id)) continue;
      _eligible.remove(job.id);
      final result =
          await _schedule(() => _run(job, displayName: job.displayName));
      if (result != null && !completedTasks.isClosed) {
        completedTasks.add(result);
      }
    }
  }

  Future<LibraryBuildJob?> resume(LibraryBuildJob job) async {
    await resumeTask(job.id);
    return builds.get(job.id);
  }

  Future<void> resumeTask(String id) => _command(() async {
        final job = await builds.get(id);
        if (job == null ||
            job.isTerminal ||
            job.status == LibraryBuildStatus.running) {
          return;
        }
        await builds.recordTaskOperation(id, '继续任务');
        await builds.validateTaskRevision(id);
        await builds.configureTask(id, priority: 60);
        await builds.setTaskStatus(id, LibraryBuildStatus.pending);
        await _admit(id);
      });
  Future<void> pauseTask(String id) => _command(() async {
        _eligible.remove(id);
        final activeRun = _activeJob?.id == id ? _activeRun : null;
        if (_activeJob?.id == id) _control?.pause();
        final job = await builds.get(id);
        if (job == null || job.isTerminal) return;
        await builds.recordTaskOperation(id, '暂停任务');
        if (_activeJob?.id == id) {
          await builds.setTaskStatus(id, LibraryBuildStatus.pauseRequested);
          _control?.pause();
        } else {
          await builds.pause(id);
        }
        if (activeRun != null) {
          await activeRun;
          if ((await builds.get(id))?.status ==
              LibraryBuildStatus.pauseRequested) {
            await builds.pause(id);
          }
        }
        await refresh();
      });

  Future<void> cancelTask(String id) => _command(() async {
        _eligible.remove(id);
        final activeRun = _activeJob?.id == id ? _activeRun : null;
        if (_activeJob?.id == id) _control?.abandon();
        final job = await builds.get(id);
        if (job == null ||
            job.status == LibraryBuildStatus.abandoned ||
            job.status == LibraryBuildStatus.completed) {
          return;
        }
        await builds.recordTaskOperation(id, '取消任务');
        if (_activeJob?.id == id) {
          await builds.setTaskStatus(id, LibraryBuildStatus.cancelRequested);
          _control?.abandon();
        } else {
          await builds.abandon(id);
        }
        if (activeRun != null) {
          await activeRun;
          if ((await builds.get(id))?.status ==
              LibraryBuildStatus.cancelRequested) {
            await builds.abandon(id);
          }
        }
        await refresh();
      });

  Future<void> abandon(LibraryBuildJob job) => cancelTask(job.id);

  Future<LibraryBuildJob?> retryFailed(LibraryBuildJob job) =>
      createPreviewRetryTask(job.id);
  Future<void> retryFailedItems(String id) async {
    await createPreviewRetryTask(id);
  }

  Future<LibraryBuildJob> createPreviewRetryTask(String id) =>
      _command(() async {
        final old = (await builds.get(id))!;
        if (old.indexFailed > 0) throw StateError('索引阶段失败，请重新读取目录');
        final duplicate = await _conflict(
            old.sourcePath, old.targetNodeId, true,
            ignoreId: id);
        if (duplicate != null && duplicate.id != id) return duplicate;
        final job = await builds.createRetryTask(id,
            nodesOnly: old.kind == LibraryBuildKind.rebuildPreviews &&
                old.taskKind != 'retryPreview');
        await _admit(job.id);
        return job;
      });

  Future<LibraryBuildJob?> recheck(LibraryBuildJob job) => _command(() async {
        await builds.validateScope(job);
        final duplicate = await _conflict(
            job.sourcePath, job.scopeNodeId, false,
            ignoreId: job.id);
        if (duplicate != null) return duplicate;
        await builds.recordTaskOperation(job.id, '重新读取目录');
        final replacement = await builds.create(
            sourcePath: job.sourcePath,
            operation: job.operation,
            targetNodeId: job.scopeNodeId);
        await builds.configureTask(replacement.id,
            taskKind: job.taskKind, priority: 90, retryOfTaskId: job.id);
        await _admit(replacement.id);
        return replacement;
      });

  Future<void> restartScan(String id) async {
    await recheck((await builds.get(id))!);
  }

  Future<List<LibraryBuildJob>> listTasks({int offset = 0}) =>
      Future.value(builds.listTasks(offset: offset));
  Future<Map<String, Object?>> loadTaskDetails(String id) =>
      Future.value(builds.loadTaskDetails(id));

  Future<LibraryBuildJob?> rebuildNodePreview(
    String nodeId, {
    IndexPreviewRebuildScope scope = IndexPreviewRebuildScope.node,
    bool force = true,
  }) =>
      createNodePreviewRetryTask(nodeId, scope: scope, manualOnly: !force);

  Future<LibraryBuildJob> createNodePreviewRetryTask(
    String nodeId, {
    IndexPreviewRebuildScope scope = IndexPreviewRebuildScope.subtree,
    bool manualOnly = false,
  }) =>
      _command(() async {
        final root = await library.owningIndexRootForNode(nodeId);
        if (root == null) throw StateError('目录已不存在');
        final source = root.sourcePath ?? 'index://${root.id}';
        final duplicate = await _conflict(source, nodeId, true);
        if (duplicate != null) return duplicate;
        final job = await builds.create(
            sourcePath: source,
            kind: LibraryBuildKind.rebuildPreviews,
            operation: LibraryBuildOperation.subtreeRefresh,
            targetNodeId: nodeId);
        await builds.configureTask(job.id,
            taskKind: 'retryNodePreview',
            priority: manualOnly ? 10 : 20,
            displayName: root.name,
            userActionRequired: manualOnly);
        await builds.setRoots(jobId: job.id, indexRootId: root.id);
        await builds.prepareNodePreviewWork(job.id,
            scopeNodeId: nodeId,
            rootNodeId: root.id,
            scope: scope,
            force: !manualOnly);
        await builds.checkpointStage(
            jobId: job.id, stage: LibraryBuildStage.nodePreviews);
        await builds.setTaskStatus(job.id, LibraryBuildStatus.pending);
        await _admit(job.id, manualOnly: manualOnly);
        return (await builds.get(job.id))!;
      });
  Future<LibraryBuildJob?> _run(
    LibraryBuildJob initial, {
    String? displayName,
  }) {
    return _execute(initial, displayName: displayName);
  }

  Future<LibraryBuildJob?> _schedule(
      Future<LibraryBuildJob?> Function() action) {
    if (isRunning) return Future.value(null);
    // Reserve ownership before the first database await, including task creation.
    _control = LibraryBuildControl();
    _error = null;
    _notifyProgress(force: true);
    return _activeRun = Future<LibraryBuildJob?>.sync(action).whenComplete(() {
      _control = null;
      _notifyProgress(force: true);
    });
  }

  Future<LibraryBuildJob?> _execute(
    LibraryBuildJob initial, {
    String? displayName,
  }) async {
    _error = null;
    var job = initial;
    _activeJob = initial;
    try {
      job = await builds.setRunning(initial.id);
      _activeJob = job;
      _report(
        job,
        await _storedStageCompleted(job),
        _storedStageTotal(job),
        initial.status == LibraryBuildStatus.paused
            ? '正在继续任务：已恢复已保存进度'
            : '正在启动索引任务',
      );
      while (job.stage != LibraryBuildStage.completed) {
        _control!.check();
        try {
          (await builds.validateScope(job));
          await builds.validateTaskRevision(job.id);
        } catch (error) {
          (await builds.block(job.id, error));
          return (await builds.get(job.id));
        }
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
        job = (await builds.get(job.id))!;
        _control!.check();
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
      (await builds.releaseProcessingWork(
        job.id,
        stage: job.stage,
      ));
      await builds.setTaskStatus(
          job.id,
          _closing || _disposed
              ? LibraryBuildStatus.interrupted
              : LibraryBuildStatus.paused);
      return null;
    } on LibraryBuildAbandonedException {
      if (job.stage == LibraryBuildStage.documentPreviews ||
          job.stage == LibraryBuildStage.entityPreviews ||
          job.stage == LibraryBuildStage.nodePreviews) {
        (await builds.releaseProcessingWork(
          job.id,
          stage: job.stage,
        ));
      }
      (await builds.abandon(job.id));
      return null;
    } catch (error) {
      if (_control?.abandoned == true) {
        await builds.abandon(job.id);
        return null;
      }
      if (_control?.paused == true) {
        await builds.releaseProcessingWork(job.id, stage: job.stage);
        await builds.setTaskStatus(
            job.id,
            _closing || _disposed
                ? LibraryBuildStatus.interrupted
                : LibraryBuildStatus.paused);
        return null;
      }
      _error = '目录扫描失败：$error';
      (await builds.fail(job.id, _error!));
      return null;
    } finally {
      _progress = null;
      _activeJob = null;
      await refresh();
    }
  }

  Future<void> _buildManifest(LibraryBuildJob job) async {
    final source = SourceHandle.parse(job.sourcePath);
    final SourceAdapter adapter =
        source.isAndroidContentUri ? SafSourceAdapter() : LocalSourceAdapter();
    final scope = job.scopeNodeId == null
        ? null
        : (await library.directoryNodeRelativePath(job.scopeNodeId!));
    _report(job, (await builds.manifestItemCount(job.id)), 0, '正在校验来源并恢复目录队列');
    try {
      final root =
          await adapter.resolveRoot(job.sourcePath, relativeScope: scope);
      if ((await builds.nextDirectory(job.id)) == null &&
          !job.manifestComplete) {
        if (!await builds.hasDirectoryFrontier(job.id)) {
          (await builds.resetManifest(job.id));
          (await builds.seedDirectory(job.id, root));
        }
      }
      while (true) {
        _control!.check();
        final directory = (await builds.nextDirectory(job.id));
        if (directory == null) break;
        var sequence = (await builds.beginDirectory(
            job.id, directory.locator, directory.relativePath));
        await builds.setCurrentItem(job.id, directory.relativePath);
        await for (final entries in adapter
            .listDirectory(directory.locator)
            .timeout(const Duration(seconds: 60))) {
          _control!.check();
          final items = <LibraryBuildManifestItem>[];
          final children = <({String locator, String relativePath})>[];
          for (final entry in entries) {
            final relative = directory.relativePath.isEmpty
                ? entry.name
                : '${directory.relativePath}/${entry.name}';
            if (entry.isDirectory) {
              children.add((locator: entry.locator, relativePath: relative));
              continue;
            }
            final handler = FileFormatRegistry.resolvePath(entry.name);
            if (handler == null) continue;
            items.add(LibraryBuildManifestItem(
                jobId: job.id,
                sourcePath: entry.locator,
                relativePath: relative,
                sequence: sequence++,
                name: entry.name,
                format: handler.formatFor(entry.name),
                entityType: handler.entityType,
                size: entry.size,
                sourceCreatedAtMs: entry.modifiedAtMs,
                sourceModifiedAtMs: entry.modifiedAtMs));
          }
          (await builds.commitDirectoryPage(
              job.id, directory.locator, items, children));
          _report(job, sequence, 0,
              '已发现 $sequence 项，正在枚举 ${directory.relativePath}');
          await Future<void>.delayed(Duration.zero);
        }
        _control!.check();
        (await builds.completeDirectory(job.id, directory.locator));
      }
      (await builds.completeManifest(
          job.id, (await builds.manifestItemCount(job.id))));
    } on LibraryBuildPausedException {
      rethrow;
    } on LibraryBuildAbandonedException {
      rethrow;
    } catch (error) {
      (await builds.block(job.id, '目录枚举未完成：$error'));
    }
  }

  Future<void> _writeIndex(
    LibraryBuildJob job, {
    String? displayName,
  }) async {
    _control!.check();
    final target = job.targetNodeId == null
        ? null
        : (await library.getIndexNode(job.targetNodeId!));
    if (job.targetNodeId != null && target == null) {
      throw StateError('目录或文件夹已不存在');
    }
    final existingRoot = target == null
        ? (await library.directoryIndexRootForSource(job.sourcePath))
        : (await library.directoryIndexRootForNode(target.id));
    final root = existingRoot ??
        (await library.ensureDirectoryIndexRoot(
          job.sourcePath,
          staging: target == null,
          displayName: displayName,
        ));
    (await builds.setRoots(
      jobId: job.id,
      indexRootId: root.id,
      stagingRootId: target == null && existingRoot == null ? root.id : null,
    ));
    final attachNode = target ?? root;
    await builds.prepareChangeSet(job.id, root.id, attachNode.id);
    final directoryCache = <String, IndexNode>{'': attachNode};
    for (final relative in await builds.listAddedDirectories(job.id)) {
      _control!.check();
      await _ensureDirectoryNode(
          root: attachNode,
          relativePath: '$relative/__directory__',
          cache: directoryCache);
    }
    var cursor = job.indexCursor;
    var written = (await builds.get(job.id))!.indexedTotal;
    while (true) {
      _control!.check();
      final page = (await builds.listManifestPage(job.id,
          afterSequence: cursor, pendingOnly: true));
      if (page.isEmpty) break;
      final existing = (await library
          .getEntitiesByPaths(page.map((item) => item.sourcePath)));
      await builds.setCurrentItem(job.id, page.first.name);
      final detailsBySequence = <int, (String, int, int, int, String?, int?)>{};
      // SAF reads are latency-bound. Keep up to eight in flight, then leave
      // all SQLite work to the single writer transaction below.
      final inspectionErrors = <int, String>{};
      await _forEachConcurrent(page, 8, (item) async {
        _control!.check();
        final handler = FileFormatRegistry.resolvePath(item.name);
        if (handler == null) return;
        try {
          detailsBySequence[item.sequence] =
              await _inspectForIndex(item, handler)
                  .timeout(const Duration(seconds: 60));
        } catch (error, stack) {
          inspectionErrors[item.sequence] = '$error';
          AppDiagnosticLog.instance.error(
              'index_file_inspection_failed', error, stack,
              fields: {'jobId': job.id, 'path': item.sourcePath});
        }
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
      final indexedInPage = await library.commitInspectedPage(
        job: job,
        page: page,
        rootId: root.id,
        existing: existing,
        detailsBySequence: detailsBySequence,
        nodesBySequence: nodesBySequence,
        indexedBefore: written,
        inspectionErrors: inspectionErrors,
      );
      written += indexedInPage;
      cursor = page.last.sequence;
      _report(job, written, job.manifestTotal,
          '正在写入索引：$written/${job.manifestTotal}');
    }
    _control!.check();
    (await builds.checkpointStage(
      jobId: job.id,
      stage: LibraryBuildStage.finalize,
      indexedTotal: written,
    ));
  }

  Future<void> _finalizeIndex(LibraryBuildJob job) async {
    _report(job, 0, 1, '正在整理并提交索引');
    _control!.check();
    await builds.finalizeIndex(job);
  }

  Future<void> _reportPreviewProgress(String jobId) async {
    final job = await builds.get(jobId);
    if (job == null) return;
    final (done, total, failed, label) = switch (job.stage) {
      LibraryBuildStage.documentPreviews => (
          job.documentPreviewDone,
          job.documentPreviewTotal,
          job.documentPreviewFailed,
          '正在解析文档预览'
        ),
      LibraryBuildStage.entityPreviews => (
          job.entityPreviewDone,
          job.entityPreviewTotal,
          job.entityPreviewFailed,
          '正在生成文件预览'
        ),
      LibraryBuildStage.nodePreviews => (
          job.nodePreviewDone,
          job.nodePreviewTotal,
          job.nodePreviewFailed,
          '正在生成目录封面'
        ),
      _ => (0, 0, 0, ''),
    };
    if (label.isNotEmpty) {
      _report(job, done + failed, total, '$label：$done/$total', failed: failed);
    }
  }

  Future<void> _buildDocumentPreviews(LibraryBuildJob job) async {
    while (true) {
      _control!.check();
      final attempts = await builds.claimDocumentPreviewWork(job.id);
      final entityIds = attempts.keys.toList(growable: false);
      final metadataResults = <String, DocumentPreviewMetadata>{};
      if (entityIds.isEmpty) break;
      final entities = (await library.getEntitiesByIds(entityIds));
      final results =
          <String, ({LibraryBuildWorkState state, String? error})>{};
      final checkpoint = PeriodicCheckpoint(() async {
        if (results.isEmpty) return;
        final pending = Map.of(results);
        results.clear();
        final metadata = <String, DocumentPreviewMetadata>{
          for (final id in pending.keys)
            if (metadataResults.containsKey(id))
              id: metadataResults.remove(id)!,
        };
        await builds.completeDocumentPreviewWork(job.id, pending,
            attempts: attempts, metadata: metadata);
        await _reportPreviewProgress(job.id);
      });
      try {
        await _forEachConcurrent(entityIds, 2, (id) async {
          final entity = entities[id];
          if (entity == null) {
            results[id] = (state: LibraryBuildWorkState.failed, error: '文件不存在');
            return;
          }
          try {
            final handler = FileFormatRegistry.resolveFormat(entity.format);
            if (handler == null) {
              results[id] = (state: LibraryBuildWorkState.skipped, error: null);
              return;
            }
            await builds.setCurrentItem(job.id, '读取/解析文档：${entity.name}');
            metadataResults[id] = await _metadataForEntity(entity, handler);
            results[id] = (state: LibraryBuildWorkState.completed, error: null);
          } on LibraryBuildPausedException {
            rethrow;
          } on LibraryBuildAbandonedException {
            rethrow;
          } on ThumbnailTaskPausedException {
            throw const LibraryBuildPausedException();
          } on ThumbnailTaskCanceledException {
            throw const LibraryBuildAbandonedException();
          } catch (error, stack) {
            AppDiagnosticLog.instance.error(
                'document_preview_failed', error, stack, fields: {
              'jobId': job.id,
              'entityId': entity.id,
              'path': entity.path
            });
            results[id] =
                (state: LibraryBuildWorkState.failed, error: '$error');
          }
        });
      } finally {
        await checkpoint.close();
      }
      final current = (await builds.get(job.id))!;
      _report(
        current,
        current.documentPreviewDone + current.documentPreviewFailed,
        current.documentPreviewTotal,
        '正在解析文档预览：${current.documentPreviewDone}/${current.documentPreviewTotal}',
        failed: current.documentPreviewFailed,
      );
    }
    final rootId = job.indexRootId;
    if (rootId == null) throw StateError('目录已不存在');
    final refreshed = (await builds.get(job.id))!;
    (await builds.checkpointStage(
      jobId: job.id,
      stage: LibraryBuildStage.entityPreviews,
      entityPreviewTotal: refreshed.entityPreviewTotal,
    ));
  }

  Future<void> _buildEntityPreviews(LibraryBuildJob job) async {
    if (await builds.handoffLegacyArchivePreviewWork(job.id)) return;
    if (job.kind == LibraryBuildKind.scanScope) {
      final rootId = job.indexRootId;
      if (rootId == null) throw StateError('目录已不存在');
      while (true) {
        _control!.check();
        final preparation = await builds.prepareEntityPreviewWorkBatch(
          job.id,
          job.targetNodeId ?? rootId,
        );
        final current = (await builds.get(job.id))!;
        _report(
          current,
          preparation.queued,
          0,
          '正在准备文件预览队列：已加入 ${preparation.queued} 项',
        );
        if (preparation.complete) break;
        await Future<void>.delayed(Duration.zero);
      }
    }
    while (true) {
      _control!.check();
      final attempts = await builds.claimEntityPreviewWork(job.id);
      final entityIds = attempts.keys.toList(growable: false);
      if (entityIds.isEmpty) break;
      final entities = (await library.getEntitiesByIds(entityIds));
      final results =
          <String, ({LibraryBuildWorkState state, String? error})>{};
      final imageConcurrency = _thumbnails.recommendedImageConcurrency;
      final videoConcurrency = _thumbnails.recommendedVideoConcurrency;
      final recorded = <String>{};
      final checkpoint = PeriodicCheckpoint(() async {
        if (results.isEmpty) return;
        final pending = Map.of(results);
        results.clear();
        recorded.addAll(pending.keys);
        await builds.completeEntityPreviewWork(job.id, pending,
            attempts: attempts);
        await _reportPreviewProgress(job.id);
      });
      try {
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
        ]);
        for (final id in entityIds) {
          if (recorded.contains(id)) continue;
          results.putIfAbsent(
            id,
            () => (state: LibraryBuildWorkState.failed, error: '文件不存在或类型不支持'),
          );
        }
      } finally {
        await checkpoint.close();
      }
      final current = (await builds.get(job.id))!;
      _report(
        current,
        current.entityPreviewDone + current.entityPreviewFailed,
        current.entityPreviewTotal,
        '正在生成文件预览：${current.entityPreviewDone}/${current.entityPreviewTotal}',
        failed: current.entityPreviewFailed,
      );
    }
    final rootId = job.indexRootId;
    if (rootId == null) throw StateError('目录已不存在');
    (await builds.prepareNodePreviewWork(
      job.id,
      scopeNodeId: job.targetNodeId ?? rootId,
      rootNodeId: rootId,
      scope: IndexPreviewRebuildScope.subtree,
    ));
    final refreshed = (await builds.get(job.id))!;
    (await builds.checkpointStage(
      jobId: job.id,
      stage: LibraryBuildStage.nodePreviews,
      nodePreviewTotal: refreshed.nodePreviewTotal,
    ));
  }

  Future<void> _buildOneEntityPreview(
    String jobId,
    String id,
    Entity entity,
    Map<String, ({LibraryBuildWorkState state, String? error})> results,
  ) async {
    try {
      _control!.check();
      await builds.setCurrentItem(jobId, entity.name);
      await _thumbnails.ensureThumbnail(entity,
          cancellationToken: _control!.thumbnailCancellation);
      final refreshed = (await library.getEntity(id));
      if (refreshed?.thumbnailStatus == ThumbnailStatus.success) {
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
    } on ThumbnailTaskPausedException {
      throw const LibraryBuildPausedException();
    } on ThumbnailTaskCanceledException {
      throw const LibraryBuildAbandonedException();
    } catch (error, stackTrace) {
      results[id] = (state: LibraryBuildWorkState.failed, error: '$error');
      _logThumbnailFailure(jobId, entity, '$error', stackTrace);
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
    if (rootId == null) throw StateError('目录已不存在');
    _report(job, job.nodePreviewDone, job.nodePreviewTotal, '正在更新目录封面');
    final compositor = NodePreviewCompositeService(library);
    while (true) {
      _control!.check();
      final attempts = await builds.claimNodePreviewWork(job.id);
      final nodeIds = attempts.keys.toList(growable: false);
      if (nodeIds.isEmpty) break;
      final results =
          <String, ({LibraryBuildWorkState state, String? error})>{};
      final received = <String>{};
      void record(String nodeId, NodePreviewCompositeOutcome? outcome) {
        received.add(nodeId);
        if (outcome == null) {
          const message = '目录封面任务未返回结果';
          AppDiagnosticLog.instance.error(
            'node_preview_build_missing_result',
            StateError(message),
            StackTrace.current,
            fields: {'jobId': job.id, 'nodeId': nodeId},
          );
          results[nodeId] = (
            state: LibraryBuildWorkState.failed,
            error: message,
          );
        } else if (outcome.error != null) {
          AppDiagnosticLog.instance.error(
            'node_preview_build_failed',
            StateError(outcome.error!),
            StackTrace.current,
            fields: {'jobId': job.id, 'nodeId': nodeId},
          );
          results[nodeId] = (
            state: LibraryBuildWorkState.failed,
            error: outcome.error,
          );
        } else {
          results[nodeId] =
              (state: LibraryBuildWorkState.completed, error: null);
        }
      }

      final checkpoint = PeriodicCheckpoint(() async {
        if (results.isEmpty) return;
        final pending = Map.of(results);
        results.clear();
        await builds.completeNodePreviewWork(job.id, pending,
            attempts: attempts);
        await _reportPreviewProgress(job.id);
      });
      try {
        await compositor.rebuildNodesAsync(nodeIds,
            cancellationToken: _control!.thumbnailCancellation,
            onCompleted: record);
        for (final id in nodeIds) {
          if (!received.contains(id)) record(id, null);
        }
      } on ThumbnailTaskPausedException {
        throw const LibraryBuildPausedException();
      } on ThumbnailTaskCanceledException {
        throw const LibraryBuildAbandonedException();
      } finally {
        await checkpoint.close();
      }
      final current = (await builds.get(job.id))!;
      _report(
        current,
        current.nodePreviewDone + current.nodePreviewFailed,
        current.nodePreviewTotal,
        '正在生成目录封面：${current.nodePreviewDone}/${current.nodePreviewTotal}',
        failed: current.nodePreviewFailed,
      );
      // The bounded background batch has returned; yield before the next
      // database claim so taps and the progress card remain responsive.
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    (await builds.checkpointStage(
      jobId: job.id,
      stage: LibraryBuildStage.completed,
    ));
    await builds.checkpoint();
    await library.collectRetiredPreviewAssets();
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
    final rootRelative = await library.directoryNodeRelativePath(root.id) ?? '';
    var current = '';
    for (final segment in normalized.substring(0, slash).split('/')) {
      if (segment.isEmpty) continue;
      current = current.isEmpty ? segment : '$current/$segment';
      parent = cache[current] ??= await library.ensureDirectoryFolderAsync(
        parentId: parent.id,
        name: segment,
        relativePath: rootRelative.isEmpty ? current : '$rootRelative/$current',
      );
    }
    return parent;
  }

  Future<(String?, int?)> _metadataForFile(
    File file,
    FileFormatHandler handler,
  ) async {
    final format = handler.formatFor(file.path);
    if (format == 'epub' || format == 'docx') {
      final preview = await runCancellableThumbnailTask(
          archiveDocumentPreviewAction(file.path, format, includeCover: false),
          cancellationToken: _control?.thumbnailCancellation);
      return (preview.excerpt, null);
    }
    final preview = switch (handler.entityType) {
      EntityType.text =>
        _limitPreview(await readTextFile(file, maxBytes: 8192)),
      EntityType.audio => 'AUDIO ${handler.formatFor(file.path).toUpperCase()}',
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
        cancellationToken: _control?.thumbnailCancellation,
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

  Future<DocumentPreviewMetadata> _metadataForEntity(
    Entity entity,
    FileFormatHandler handler,
  ) async {
    final token = ThumbnailCancellationToken();
    final parent = _control!.thumbnailCancellation;
    void stop() {
      if (parent.isPaused) {
        token.pause();
      } else {
        token.cancel();
      }
    }

    parent.addListener(stop);
    Future<T> bounded<T>(Future<T> future, String phase) =>
        future.timeout(const Duration(seconds: 60), onTimeout: () {
          token.cancel();
          throw TimeoutException('$phase 超时');
        });
    Future<DocumentPreviewMetadata> parse(File file) async {
      if (entity.format == 'epub' || entity.format == 'docx') {
        return bounded(
            ArchivePreviewPipeline(library)
                .prepare(entity, file, cancellationToken: token),
            '解析文档/写入预览');
      }
      final metadata = await bounded(_metadataForFile(file, handler), '读取文档');
      return DocumentPreviewMetadata(
          sourceRevision: entity.sourceRevision,
          excerpt: metadata.$1,
          durationMs: metadata.$2);
    }

    try {
      final source = SourceHandle.parse(entity.path);
      if (!source.isAndroidContentUri) {
        return await parse(File(entity.path));
      }
      final path = await bounded(
          PlatformDirectoryPicker.materializeDocument(
            entity.path,
            name: entity.name,
            cacheScope: 'scan',
            cancellationToken: token,
          ),
          '等待来源资源/读取文档');
      final file = File(path);
      try {
        return await parse(file);
      } finally {
        if (await file.exists()) await file.delete();
      }
    } finally {
      parent.removeListener(stop);
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

  Future<int> _storedStageCompleted(LibraryBuildJob job) async =>
      switch (job.stage) {
        LibraryBuildStage.manifest => (await builds.manifestItemCount(job.id)),
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
    if (_disposed || _closing) return;
    final current = job;
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
    if (_disposed || _closing) return;
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
