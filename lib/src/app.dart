import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'core/database/app_database.dart';
import 'modules/infrastructure/database_runtime.dart';
import 'modules/infrastructure/app_runtime.dart';
import 'modules/viewer/viewer_sessions.dart';
import 'modules/previews/dirty_preview_scheduler.dart';
import 'core/database/library_write_worker.dart';
import 'modules/library/library_client.dart';
import 'modules/build/build_client.dart';
import 'core/database/library_read_worker.dart';
import 'core/diagnostics/app_diagnostic_log.dart';
import 'core/controllers/library_build_task_controller.dart';
import 'core/controllers/selection_controller.dart';
import 'core/domain/models.dart';
import 'core/formats/file_format_handlers.dart';
import 'core/media/audio_waveform_service.dart';
import 'core/media/app_audio_controller.dart';
import 'core/media/media_source_resolver.dart';
import 'core/sources/platform_directory_picker.dart';
import 'core/tasks/task_scheduler.dart';
import 'core/thumbnails/thumbnail_service.dart';
import 'core/thumbnails/android_image_thumbnail_backend.dart';
import 'core/thumbnails/android_video_thumbnail_backend.dart';
import 'core/thumbnails/native_image_thumbnail_backend.dart';
import 'core/thumbnails/windows_wic_webp_thumbnail_backend.dart';
import 'core/thumbnails/browsing_thumbnail_controller.dart';
import 'ui/browser_state.dart';
import 'ui/browser_node_cache.dart';
import 'ui/app_sidebar.dart';
import 'ui/builtin_media_page.dart';
import 'ui/collection_browser_page.dart';
import 'ui/design_tokens.dart';
import 'ui/entity_detail_sheet.dart';
import 'ui/graph_index_page.dart';
import 'ui/index_management_page.dart';
import 'ui/music_page.dart';
import 'ui/media_shelf_page.dart';
import 'ui/now_playing_page.dart';
import 'ui/node_preview_picker.dart';
import 'ui/settings_page.dart';
import 'ui/diagnostics_page.dart';
import 'ui/dialogs/app_dialogs.dart';
import 'ui/widgets/app_widgets.dart';

class BestViewerApp extends StatefulWidget {
  const BestViewerApp({super.key, this.databaseFactory});

  final Future<AppDatabase> Function()? databaseFactory;

  @override
  State<BestViewerApp> createState() => _BestViewerAppState();
}

class _BestViewerAppState extends State<BestViewerApp> {
  ViewerThemeChoice _themeChoice = ViewerThemeChoice.galleryDark;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Best Viewer',
      debugShowCheckedModeBanner: false,
      theme: AppTokens.themeFor(_themeChoice),
      darkTheme: AppTokens.themeFor(ViewerThemeChoice.galleryDark),
      themeMode: _themeChoice == ViewerThemeChoice.galleryDark
          ? ThemeMode.dark
          : ThemeMode.light,
      builder: (context, child) {
        final appChild = child!;
        if (!Platform.isWindows) return appChild;
        final theme = Theme.of(context);
        return Column(
          children: [
            SizedBox(
              height: kWindowCaptionHeight,
              child: WindowCaption(
                backgroundColor: theme.scaffoldBackgroundColor,
                brightness: theme.brightness,
                title: const SizedBox.shrink(),
              ),
            ),
            Expanded(child: appChild),
          ],
        );
      },
      home: AppShell(
        databaseFactory: widget.databaseFactory,
        themeChoice: _themeChoice,
        onThemeChanged: (value) => setState(() => _themeChoice = value),
      ),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    this.databaseFactory,
    required this.themeChoice,
    required this.onThemeChanged,
  });

  final Future<AppDatabase> Function()? databaseFactory;
  final ViewerThemeChoice themeChoice;
  final ValueChanged<ViewerThemeChoice> onThemeChanged;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _viewerSessions = ViewerSessions();
  DirtyPreviewScheduler? _dirtyPreviews;
  Future<void>? _bootstrapFuture;
  final _runtime = AppRuntime(onFailure: (failure) {
    AppDiagnosticLog.instance.error(
        'runtime_service_close_failed', failure.error, failure.stackTrace,
        fields: {'service': failure.name});
  });
  static const _entityPageSize = 200;
  late final TextEditingController _indexPathController;

  DatabaseDescriptor? _database;
  LibraryWriteWorker? _writeWorker;
  LibraryClient? _repository;
  LibraryReadWorker? _readWorker;
  Future<LibraryReadWorker>? _readWorkerStart;
  BrowsingThumbnailController? _browsingThumbnails;
  AppAudioController? _audioController;
  List<AudioPlaybackSession> _audioSessions = const [];
  LibraryBuildTaskController? _buildTasks;
  bool _loading = true;
  int? _incompatibleSchemaVersion;
  bool _resettingLocalIndex = false;
  String? _indexError;
  String? _readError;
  bool _readRetrying = false;
  AppSection _section = AppSection.data;
  BrowserState _browserState = const BrowserState();
  IndexNode? _selectedIndexRoot;
  IndexNode? _selectedItem;
  List<IndexNode> _indexRoots = const [];
  List<IndexNode> _childNodes = const [];
  List<IndexNode> _nodePath = const [];
  List<EntityListItem> _entities = const [];
  bool _entitiesHasMore = false;
  RecursiveEntityPageCursor? _recursiveEntityCursor;
  bool _loadingMoreEntities = false;
  bool _sidebarCollapsed = false;
  bool _miniPlayerCollapsed = false;
  late final SelectionController _selection;
  final Set<String> _regeneratingThumbnailIds = <String>{};
  Timer? _thumbnailRefreshTimer;
  final BrowserNodeCache _browserNodeCache = BrowserNodeCache();
  final TaskScheduler _taskScheduler = TaskScheduler(maxConcurrent: 1);
  int _cacheWarmupGeneration = 0;
  int _reloadGeneration = 0;
  Map<String, int> _rootCounts = const {};
  Map<String, IndexNodeSummary> _nodeSummaries = const {};
  Map<String, IndexNodePreview> _nodePreviews = const {};
  Entity? _detail;
  EntityViewerPage? _mediaOverlay;
  bool _mediaOverlayRequiresLibraryRefresh = false;
  late final AppLifecycleListener _lifecycleListener;

  IndexNode? get _currentIndexNode => _selectedItem ?? _selectedIndexRoot;
  bool get _scanning => _buildTasks?.isRunning ?? false;
  LibraryBuildProgress? get _scanProgress => _buildTasks?.progress;
  LibraryBuildJob? get _activeBuildJob => _buildTasks?.activeJob;
  List<LibraryBuildJob> get _recoverableIndexJobs =>
      _buildTasks?.recoverableJobs ?? const [];
  List<LibraryBuildJob> get _indexTaskHistory =>
      _buildTasks?.history ?? const [];
  Set<String> get _selectedEntityIds => _selection.entityIds;
  Set<String> get _selectedNodeIds => _selection.nodeIds;
  bool get _selectionMode => _selection.enabled;

  Future<void> _refreshNodePreview(
    String nodeId, {
    IndexPreviewRebuildScope scope = IndexPreviewRebuildScope.node,
    String? reason,
  }) async {
    if (reason == 'manual_rebuild') {
      await _buildTasks?.rebuildNodePreview(nodeId, scope: scope);
    } else {
      await _dirtyPreviews?.tick();
    }
  }

  bool get _isInsideCustomIndex =>
      _selectedIndexRoot?.nodeType == NodeType.customIndexRoot &&
      (_currentIndexNode?.nodeType == NodeType.customIndexRoot ||
          _currentIndexNode?.nodeType == NodeType.customNode);

  bool get _canUpdateCurrentDirectoryNode {
    final repository = _repository;
    final node = _currentIndexNode;
    return repository != null &&
        node != null &&
        (node.nodeType == NodeType.directoryIndexRoot ||
            node.nodeType == NodeType.folder);
  }

  bool get _canRemoveEntityReferencesFromCurrentNode {
    final node = _currentIndexNode;
    return node != null &&
        node.nodeType != NodeType.directoryIndexRoot &&
        node.nodeType != NodeType.folder;
  }

  @override
  void initState() {
    super.initState();
    _registerRuntimeResources();
    _indexPathController = TextEditingController();
    _selection = SelectionController();
    _lifecycleListener = AppLifecycleListener(
      onStateChange: (state) {
        AppDiagnosticLog.instance.info('app_lifecycle_changed', fields: {
          'state': state.name,
        });
      },
    );
    AppDiagnosticLog.instance.info('app_shell_initialized');
    _bootstrap();
  }

  @override
  void dispose() {
    _dirtyPreviews?.stop();
    AppDiagnosticLog.instance.info('app_shell_dispose_started');
    _indexPathController.dispose();
    _buildTasks?.removeListener(_handleBuildTaskChanged);
    _buildTasks?.dispose();
    _thumbnailRefreshTimer?.cancel();
    _lifecycleListener.dispose();
    unawaited(_closeRuntimeResources());
    super.dispose();
  }

  void _registerRuntimeResources() {
    _runtime
      ..register(
          'viewer-stop', RuntimeClosePhase.stopWork, _viewerSessions.stop)
      ..register('source-reads', RuntimeClosePhase.stopWork,
          MediaSourceResolver.stopSessionReads)
      ..register('dirty-preview-stop', RuntimeClosePhase.stopWork,
          () => _dirtyPreviews?.stop())
      ..register('bootstrap', RuntimeClosePhase.stopWork, () async {
        await _bootstrapFuture;
      })
      ..register(
          'scheduler', RuntimeClosePhase.stopWork, () => _taskScheduler.close())
      ..register('build', RuntimeClosePhase.stopWork, () async {
        await _buildTasks?.close();
      })
      ..register('audio', RuntimeClosePhase.media, () async {
        await _audioController?.close();
      })
      ..register('viewers', RuntimeClosePhase.media, _viewerSessions.close)
      ..register('dirty-previews', RuntimeClosePhase.caches, () async {
        await _dirtyPreviews?.close();
      })
      ..register('thumbnails', RuntimeClosePhase.caches, () async {
        await _browsingThumbnails?.close();
      })
      ..register('source-cache', RuntimeClosePhase.caches,
          MediaSourceResolver.closeSessionCache)
      ..register('read-worker', RuntimeClosePhase.database, () async {
        try {
          await _readWorkerStart;
        } catch (_) {/* Failed startup owns its cleanup. */}
        await _readWorker?.close();
      })
      ..register('write-worker', RuntimeClosePhase.database, () async {
        await _writeWorker?.close();
      })
      ..register('diagnostics', RuntimeClosePhase.diagnostics,
          () => AppDiagnosticLog.instance.close());
  }

  Future<void> _closeRuntimeResources() async {
    final failures = await _runtime.close();
    for (final failure in failures) {
      debugPrint(
          'Runtime close failed (${failure.name}): ${failure.error}\n${failure.stackTrace}');
    }
  }

  Future<LibraryReadWorker> _ensureReadWorker() async {
    if (_runtime.isClosing) throw StateError('应用正在关闭，不能启动读取服务');
    final existing = _readWorker;
    if (existing != null) return existing;
    final database = _database;
    final databasePath = _writeWorker?.databasePath;
    if (database == null || databasePath == null) {
      throw StateError('读取服务不可用：当前数据库没有可供读 Isolate 使用的文件路径');
    }
    final pending = _readWorkerStart;
    if (pending != null) return pending;
    late final Future<LibraryReadWorker> start;
    start = LibraryReadWorker.start(
      databasePath: databasePath,
      storageDirectoryPath: database.storageDirectoryPath,
    ).then((worker) {
      if (!mounted || !identical(_database, database)) {
        unawaited(worker.close());
        throw StateError('读取服务启动时应用已经切换数据库');
      }
      _readWorker = worker;
      return worker;
    }).whenComplete(() {
      if (identical(_readWorkerStart, start)) _readWorkerStart = null;
    });
    _readWorkerStart = start;
    return start;
  }

  Future<void> _restartReadWorker(LibraryReadWorker failedWorker) async {
    if (!identical(_readWorker, failedWorker)) return;
    _readWorker = null;
    try {
      await failedWorker.close();
    } catch (_) {
      // The worker may already have terminated after a native/database error.
    }
  }

  Future<T> _read<T>(
    Future<T> Function(LibraryReadWorker worker) operation,
  ) async {
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 0; attempt < 2; attempt++) {
      LibraryReadWorker? worker;
      try {
        worker = await _ensureReadWorker();
        final result = await operation(worker);
        if (mounted && _readError != null) {
          setState(() => _readError = null);
        }
        return result;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        AppDiagnosticLog.instance.warning(
          'database_read_worker_failed',
          fields: {
            'attempt': attempt + 1,
            'error': '$error',
            'stackTrace': '$stackTrace',
          },
        );
        if (worker != null) await _restartReadWorker(worker);
      }
    }
    final error = StateError('读取服务暂时不可用：$lastError');
    _setReadError(error, lastStackTrace ?? StackTrace.current);
    throw error;
  }

  void _setReadError(Object error, StackTrace stackTrace) {
    AppDiagnosticLog.instance.error(
      'database_read_unavailable',
      error,
      stackTrace,
    );
    if (!mounted) return;
    setState(() => _readError = '$error');
  }

  Future<void> _retryReadWorker() async {
    if (_readRetrying) return;
    setState(() {
      _readRetrying = true;
      _readError = null;
    });
    try {
      final worker = _readWorker;
      _readWorker = null;
      if (worker != null) await worker.close();
      _readWorkerStart = null;
      await _ensureReadWorker();
      await _reloadAsync(
        indexNodeId: _currentIndexNode?.id,
        invalidateBrowserCache: true,
      );
      if (_section != AppSection.data) await _reloadDashboardDataAsync();
    } catch (error, stackTrace) {
      _setReadError(error, stackTrace);
    } finally {
      if (mounted) setState(() => _readRetrying = false);
    }
  }

  Future<void> _bootstrap() {
    if (_runtime.isClosing) return Future.value();
    return _bootstrapFuture ??= _bootstrapImpl().whenComplete(() {
      _bootstrapFuture = null;
    });
  }

  Future<void> _bootstrapImpl() async {
    AppDiagnosticLog.instance.info('app_bootstrap_started');
    final DatabaseRuntime runtime;
    try {
      runtime = await DatabaseRuntime.open(
          testDatabaseFactory: widget.databaseFactory);
    } on AppDatabaseResetRequired catch (error) {
      AppDiagnosticLog.instance.warning('database_reset_required', fields: {
        'foundSchemaVersion': error.foundVersion,
      });
      if (!mounted) return;
      setState(() {
        _incompatibleSchemaVersion = error.foundVersion;
        _loading = false;
      });
      return;
    } catch (error, stackTrace) {
      AppDiagnosticLog.instance.error(
        'database_open_failed',
        error,
        stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _indexError = '无法打开本地索引：$error';
        _loading = false;
      });
      return;
    }
    final database = runtime.descriptor;
    final writeWorker = runtime.host;
    if (!mounted || _runtime.isClosing) {
      await writeWorker.close();
      return;
    }
    AppDiagnosticLog.instance.info('database_opened', fields: {
      'databasePath': database.databasePath,
      'storageDirectoryPath': database.storageDirectoryPath,
    });
    final databasePath = database.databasePath;
    final repository = LibraryClient(writeWorker);
    final browsingThumbnails = BrowsingThumbnailController(
      repository,
      onCacheChanged: (_) => _scheduleThumbnailRefresh(),
    );
    final buildTasks = LibraryBuildTaskController(repository,
        builds: BuildClient(writeWorker));
    try {
      await buildTasks.initialize();
    } catch (error, stack) {
      await browsingThumbnails.close();
      buildTasks.dispose();
      await writeWorker.close();
      AppDiagnosticLog.instance
          .error('build_runtime_start_failed', error, stack);
      if (mounted) {
        setState(() {
          _indexError = '无法启动资料库服务：$error';
          _loading = false;
        });
      }
      return;
    }
    buildTasks.addListener(_handleBuildTaskChanged);
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.maximumSizeBytes =
        Platform.isAndroid ? 512 * 1024 * 1024 : 1024 * 1024 * 1024;
    // The byte limit remains authoritative. A higher item count prevents
    // small WebP thumbnails from being evicted merely because a gallery has
    // crossed an arbitrary card count.
    imageCache.maximumSize = Platform.isAndroid ? 5000 : 1200;
    final audioController = AppAudioController(
      onProgressSaved: (entityId, positionMs, durationMs) async {
        (await repository.savePlaybackState(
          entityId: entityId,
          positionMs: positionMs,
          durationMs: durationMs,
        ));
      },
      onSessionCreated: (
              {required entries,
              required currentIndex,
              sourceNodeId,
              sourceNodeName,
              required AudioPlaybackMode mode}) async =>
          (await repository.createAudioPlaybackSession(
        entries: entries,
        currentIndex: currentIndex,
        sourceNodeId: sourceNodeId,
        sourceNodeName: sourceNodeName,
        mode: mode,
      )),
      onSessionUpdated: (
              {required id,
              currentIndex,
              positionMs,
              mode,
              shuffleRemaining,
              history,
              active}) async =>
          (await repository.updateAudioPlaybackSession(
        id: id,
        currentIndex: currentIndex,
        positionMs: positionMs,
        mode: mode,
        shuffleRemaining: shuffleRemaining,
        history: history,
        active: active,
      )),
    );
    LibraryReadWorker? readWorker;
    if (databasePath.isNotEmpty) {
      try {
        readWorker = await LibraryReadWorker.start(
          databasePath: databasePath,
          storageDirectoryPath: database.storageDirectoryPath,
        );
      } catch (error, stackTrace) {
        _readError = '读取服务启动失败：$error';
        AppDiagnosticLog.instance.warning(
          'database_read_worker_unavailable',
          fields: {'error': '$error', 'stackTrace': '$stackTrace'},
        );
      }
    }
    if (!mounted || _runtime.isClosing) {
      await buildTasks.close();
      buildTasks.dispose();
      await audioController.close();
      await browsingThumbnails.close();
      await readWorker?.close();
      await writeWorker.close();
      return;
    }
    setState(() {
      _database = database;
      _writeWorker = writeWorker;
      _repository = repository;
      _audioController = audioController;
      _readWorker = readWorker;
      _browsingThumbnails = browsingThumbnails;
      _buildTasks = buildTasks;
      _loading = false;
    });
    _dirtyPreviews = DirtyPreviewScheduler(
      isBusy: () => !mounted || _runtime.isClosing || buildTasks.isRunning,
      load: () async => repository.listDirtyPreviewRoots(),
      rebuild: (rootId) async {
        await buildTasks.rebuildNodePreview(rootId,
            scope: IndexPreviewRebuildScope.subtree, force: false);
        if (mounted && !_runtime.isClosing) {
          _reload(
              indexNodeId: _currentIndexNode?.id, invalidateBrowserCache: true);
        }
      },
      onError: (error, stack) => AppDiagnosticLog.instance
          .error('dirty_preview_scheduler_failed', error, stack),
    )..start();
    final activeSessions = (await repository.listAudioPlaybackSessions());
    if (!mounted) return;
    setState(() => _audioSessions = activeSessions);
    final activeSession =
        activeSessions.where((session) => session.active).firstOrNull;
    if (activeSession != null) {
      await audioController.restoreSession(activeSession);
    }
    _reload();
  }

  void _handleBuildTaskChanged() {
    if (mounted) setState(() {});
  }

  void _scheduleThumbnailRefresh() {
    if (!mounted) return;
    _thumbnailRefreshTimer?.cancel();
    _thumbnailRefreshTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _reload(
        indexNodeId: _currentIndexNode?.id,
        invalidateBrowserCache: true,
      );
    });
  }

  void _requestBrowseThumbnail(EntityListItem entity) {
    _browsingThumbnails?.request(entity);
  }

  void _requestBrowseThumbnailById(String entityId) {
    _browsingThumbnails?.requestEntityId(entityId);
  }

  Future<void> _resetLocalIndexStorage() async {
    if (_resettingLocalIndex) return;
    if (_scanning) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先暂停或放弃正在进行的索引任务。')),
      );
      return;
    }
    final confirmed = await _confirm(
      title: '重置本地索引数据',
      message: '将删除本应用保存的索引、任务、缩略图和播放缓存。不会删除、移动或修改任何真实资料文件。',
    );
    if (!confirmed || !mounted) return;
    await _dirtyPreviews?.close();
    _dirtyPreviews = null;
    setState(() {
      _loading = true;
      _resettingLocalIndex = true;
      _indexError = null;
    });
    try {
      final audioController = _audioController;
      if (audioController != null) await audioController.close();
      await _browsingThumbnails?.close();
      _browsingThumbnails = null;
      final worker = _readWorker;
      _readWorker = null;
      if (worker != null) await worker.close();
      final writeWorker = _writeWorker;
      _writeWorker = null;
      if (writeWorker != null) await writeWorker.close();
      _audioController = null;
      _buildTasks?.removeListener(_handleBuildTaskChanged);
      _buildTasks?.dispose();
      _buildTasks = null;
      _database = null;
      _repository = null;
      await AppDatabase.resetLocalIndexStorage();
      if (!mounted) return;
      setState(() {
        _incompatibleSchemaVersion = null;
        _resettingLocalIndex = false;
      });
      await _bootstrap();
    } catch (error, stackTrace) {
      AppDiagnosticLog.instance.error(
        'local_index_reset_failed',
        error,
        stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _indexError = '重置本地索引失败：$error';
        _loading = false;
        _resettingLocalIndex = false;
      });
    }
  }

  void _reload({String? indexNodeId, bool invalidateBrowserCache = false}) {
    unawaited(_reloadAsync(
      indexNodeId: indexNodeId,
      invalidateBrowserCache: invalidateBrowserCache,
    ));
  }

  Future<void> _reloadAsync({
    String? indexNodeId,
    bool invalidateBrowserCache = false,
  }) async {
    final repository = _repository;
    if (repository == null) return;
    final generation = ++_reloadGeneration;
    if (invalidateBrowserCache) {
      _browserNodeCache.clear();
      _cacheWarmupGeneration++;
    }
    try {
      final roots = await _read(
        (worker) => worker.loadIndexRoots(sortMode: _browserState.sortMode),
      );
      if (!mounted || generation != _reloadGeneration) return;
      final selectedRoot = _resolveSelectedIndexRoot(roots);
      final targetId = indexNodeId ?? _selectedItem?.id;
      List<IndexNode> nodePath = const <IndexNode>[];
      IndexNode? selectedItem;
      if (selectedRoot != null) {
        final currentId = targetId ?? selectedRoot.id;
        nodePath = await _read(
          (worker) => worker.loadNodePath(
            indexRootId: selectedRoot.id,
            currentNodeId: currentId,
          ),
        );
        if (nodePath.isNotEmpty && currentId != selectedRoot.id) {
          selectedItem = nodePath.last;
        }
      }
      final currentNode = selectedItem ?? selectedRoot;
      final recursiveBrowsing =
          _browserState.contentScope == BrowserContentScope.recursive;
      final cacheKey = selectedRoot == null || currentNode == null
          ? null
          : BrowserNodeCacheKey(
              indexRootId: selectedRoot.id,
              nodeId: currentNode.id,
              sortMode: _browserState.sortMode,
              recursive: recursiveBrowsing,
            );
      final cached = cacheKey == null ? null : _browserNodeCache.get(cacheKey);
      List<IndexNode> childNodes;
      EntityPage? uncachedPage;
      if (recursiveBrowsing) {
        childNodes = const <IndexNode>[];
        if (selectedRoot != null && currentNode != null && cached == null) {
          final page = await _read(
            (worker) => worker.loadRecursivePage(
              nodeId: currentNode.id,
              sortMode: _browserState.sortMode,
              limit: _entityPageSize,
            ),
          );
          if (!mounted || generation != _reloadGeneration) return;
          uncachedPage = EntityPage(
            items: page.entities,
            hasMore: page.hasMore,
            recursiveCursor: page.recursiveCursor,
          );
        }
      } else if (currentNode == null) {
        childNodes = roots;
      } else if (cached != null) {
        childNodes = cached.childNodes;
        if (cached.nodePath.isNotEmpty) nodePath = cached.nodePath;
      } else {
        final page = await _read(
          (worker) => worker.loadDirectPage(
            parentNodeId: currentNode.id,
            sortMode: _browserState.sortMode,
            limit: _entityPageSize,
          ),
        );
        if (!mounted || generation != _reloadGeneration) return;
        childNodes = page.childNodes;
        uncachedPage = EntityPage(
          items: page.entities,
          hasMore: page.hasMore,
        );
      }
      final entities =
          cached?.entities ?? uncachedPage?.items ?? const <EntityListItem>[];
      final entitiesHasMore = cached?.hasMore ?? uncachedPage?.hasMore ?? false;
      final recursiveCursor =
          cached?.recursiveCursor ?? uncachedPage?.recursiveCursor;
      final Map<String, IndexNodeSummary> nodeSummaries;
      if (cached != null) {
        nodeSummaries = cached.nodeSummaries;
      } else {
        nodeSummaries = await _read(
          (worker) => worker.loadNodeSummaries(
            childNodes.map((node) => node.id),
          ),
        );
      }
      final Map<String, IndexNodePreview> nodePreviews;
      if (cached != null) {
        nodePreviews = cached.nodePreviews;
      } else {
        nodePreviews = await _read<Map<String, IndexNodePreview>>(
          (worker) => worker.loadNodePreviews(
            childNodes.map((node) => node.id),
          ),
        );
      }
      final detail = _detail == null
          ? null
          : await _read((worker) => worker.loadEntity(_detail!.id));
      if (!mounted || generation != _reloadGeneration) return;
      if (cacheKey != null && cached == null) {
        _browserNodeCache.put(
          cacheKey,
          EntityPageSnapshot(
            childNodes: List<IndexNode>.unmodifiable(childNodes),
            entities: List<EntityListItem>.unmodifiable(entities),
            nodePath: List<IndexNode>.unmodifiable(nodePath),
            nodeSummaries:
                Map<String, IndexNodeSummary>.unmodifiable(nodeSummaries),
            nodePreviews:
                Map<String, IndexNodePreview>.unmodifiable(nodePreviews),
            recursiveCursor: recursiveCursor,
            hasMore: entitiesHasMore,
          ),
          priority: BrowserNodeCachePriority.pinned,
        );
      }
      _updateNavigationCacheScope(
        root: selectedRoot,
        nodePath: nodePath,
        childNodes: childNodes,
        recursive: recursiveBrowsing,
      );

      setState(() {
        _indexRoots = roots;
        _selectedIndexRoot = selectedRoot;
        _selectedItem = selectedItem;
        _childNodes = childNodes;
        _nodePath = nodePath;
        _entities = entities;
        _entitiesHasMore = entitiesHasMore;
        _recursiveEntityCursor = recursiveCursor;
        _loadingMoreEntities = false;
        _detail = detail;
        _nodeSummaries = nodeSummaries;
        _nodePreviews = nodePreviews;
      });
      if (_section != AppSection.data) await _reloadDashboardDataAsync();
    } catch (error, stackTrace) {
      if (mounted && generation == _reloadGeneration) {
        _setReadError(error, stackTrace);
      }
    }
  }

  void _reloadDashboardData() {
    unawaited(_reloadDashboardDataAsync());
  }

  Future<void> _reloadDashboardDataAsync() async {
    if (_repository == null) return;
    try {
      final roots = await _read((worker) => worker.loadIndexRoots());
      final rootCounts = await _read(
        (worker) => worker.loadRootEntityCounts(roots.map((root) => root.id)),
      );
      _refreshRecoverableIndexTasks();
      if (!mounted) return;
      setState(() {
        _indexRoots = roots;
        _rootCounts = rootCounts;
      });
    } catch (error, stackTrace) {
      _setReadError(error, stackTrace);
    }
  }

  void _refreshRecoverableIndexTasks() {
    _buildTasks?.refresh();
  }

  void _updateNavigationCacheScope({
    required IndexNode? root,
    required List<IndexNode> nodePath,
    required List<IndexNode> childNodes,
    required bool recursive,
  }) {
    final generation = ++_cacheWarmupGeneration;
    _taskScheduler.cancelTag('page-warm');
    if (root == null) {
      _browserNodeCache.clear();
      return;
    }
    _browserNodeCache.setNavigationScope(
      indexRootId: root.id,
      path: nodePath,
      directChildren: childNodes,
      sortMode: _browserState.sortMode,
      recursive: recursive,
    );
    if (recursive) return;
    final pending = Queue<IndexNode>.from(
      childNodes.where(
        (node) => _browserNodeCache.canWarm(
          BrowserNodeCacheKey(
            indexRootId: root.id,
            nodeId: node.id,
            sortMode: _browserState.sortMode,
            recursive: false,
          ),
        ),
      ),
    );
    _scheduleNextPageWarmup(
      generation: generation,
      root: root,
      parentPath: nodePath,
      pending: pending,
      sortMode: _browserState.sortMode,
    );
  }

  /// Stop queued lookahead reads before an explicit navigation action. A
  /// running read may finish, but its generation check will discard the stale
  /// result instead of competing with the newly requested page.
  void _cancelPageWarmup() {
    _cacheWarmupGeneration++;
    _taskScheduler.cancelTag('page-warm');
  }

  void _scheduleNextPageWarmup({
    required int generation,
    required IndexNode root,
    required List<IndexNode> parentPath,
    required Queue<IndexNode> pending,
    required EntitySortMode sortMode,
  }) {
    if (pending.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        _taskScheduler
            .schedule<void>(
              key: 'page-warm:$generation:${pending.first.id}',
              tag: 'page-warm',
              priority: TaskPriority.prefetch,
              action: () => _warmNextPage(
                generation: generation,
                root: root,
                parentPath: parentPath,
                pending: pending,
                sortMode: sortMode,
              ),
            )
            .catchError((_) {}),
      );
    });
  }

  Future<void> _warmNextPage({
    required int generation,
    required IndexNode root,
    required List<IndexNode> parentPath,
    required Queue<IndexNode> pending,
    required EntitySortMode sortMode,
  }) async {
    if (!mounted || generation != _cacheWarmupGeneration || pending.isEmpty) {
      return;
    }
    final node = pending.removeFirst();
    final key = BrowserNodeCacheKey(
      indexRootId: root.id,
      nodeId: node.id,
      sortMode: sortMode,
      recursive: false,
    );
    if (_browserNodeCache.canWarm(key)) {
      late final List<IndexNode> childNodes;
      late final List<EntityListItem> entities;
      late final bool hasMore;
      try {
        final page = await _read(
          (worker) => worker.loadDirectPage(
            parentNodeId: node.id,
            sortMode: sortMode,
            limit: _entityPageSize,
          ),
        );
        childNodes = page.childNodes;
        entities = page.entities;
        hasMore = page.hasMore;
      } catch (error, stackTrace) {
        _setReadError(error, stackTrace);
        return;
      }
      if (!mounted || generation != _cacheWarmupGeneration) return;
      final nodeSummaries = await _read(
        (worker) => worker.loadNodeSummaries(
          childNodes.map((item) => item.id),
        ),
      );
      final nodePreviews = await _read(
        (worker) => worker.loadNodePreviews(
          childNodes.map((item) => item.id),
        ),
      );
      final stored = _browserNodeCache.put(
        key,
        EntityPageSnapshot(
          childNodes: List<IndexNode>.unmodifiable(childNodes),
          entities: List<EntityListItem>.unmodifiable(entities),
          nodePath: List<IndexNode>.unmodifiable([...parentPath, node]),
          nodeSummaries:
              Map<String, IndexNodeSummary>.unmodifiable(nodeSummaries),
          nodePreviews:
              Map<String, IndexNodePreview>.unmodifiable(nodePreviews),
          recursiveCursor: null,
          hasMore: hasMore,
        ),
        priority: BrowserNodeCachePriority.lookahead,
      );
      if (!stored) return;
    }
    _scheduleNextPageWarmup(
      generation: generation,
      root: root,
      parentPath: parentPath,
      pending: pending,
      sortMode: sortMode,
    );
  }

  Future<void> _loadMoreEntities() async {
    final root = _selectedIndexRoot;
    final node = _currentIndexNode;
    if (root == null ||
        node == null ||
        !_entitiesHasMore ||
        _loadingMoreEntities) {
      return;
    }
    setState(() => _loadingMoreEntities = true);
    final sortMode = _browserState.sortMode;
    final recursiveBrowsing =
        _browserState.contentScope == BrowserContentScope.recursive;
    final after = _entities.isEmpty
        ? null
        : EntityPageCursor.fromEntity(_entities.last, sortMode);
    try {
      EntityPage page;
      if (recursiveBrowsing) {
        final result = await _read(
          (worker) => worker.loadRecursivePage(
            nodeId: node.id,
            sortMode: sortMode,
            after: _recursiveEntityCursor,
            limit: _entityPageSize,
          ),
        );
        page = EntityPage(
          items: result.entities,
          hasMore: result.hasMore,
          recursiveCursor: result.recursiveCursor,
        );
      } else {
        final result = await _read(
          (worker) => worker.loadDirectPage(
            parentNodeId: node.id,
            sortMode: sortMode,
            after: after,
            limit: _entityPageSize,
          ),
        );
        page = EntityPage(items: result.entities, hasMore: result.hasMore);
      }
      if (!mounted ||
          node.id != _currentIndexNode?.id ||
          sortMode != _browserState.sortMode ||
          recursiveBrowsing !=
              (_browserState.contentScope == BrowserContentScope.recursive)) {
        return;
      }
      final combined =
          List<EntityListItem>.unmodifiable([..._entities, ...page.items]);
      final key = BrowserNodeCacheKey(
        indexRootId: root.id,
        nodeId: node.id,
        sortMode: sortMode,
        recursive: recursiveBrowsing,
      );
      final existing = _browserNodeCache.get(key);
      if (existing != null) {
        _browserNodeCache.put(
          key,
          EntityPageSnapshot(
            childNodes: existing.childNodes,
            entities: combined,
            nodePath: existing.nodePath,
            nodeSummaries: existing.nodeSummaries,
            nodePreviews: existing.nodePreviews,
            recursiveCursor: page.recursiveCursor ?? existing.recursiveCursor,
            hasMore: page.hasMore,
          ),
          priority: BrowserNodeCachePriority.pinned,
        );
      }
      setState(() {
        _entities = combined;
        _entitiesHasMore = page.hasMore;
        _recursiveEntityCursor = page.recursiveCursor ?? _recursiveEntityCursor;
      });
    } catch (error, stackTrace) {
      _setReadError(error, stackTrace);
    } finally {
      if (mounted) setState(() => _loadingMoreEntities = false);
    }
  }

  IndexNode? _resolveSelectedIndexRoot(List<IndexNode> roots) {
    final selected = _selectedIndexRoot;
    if (selected != null) {
      for (final root in roots) {
        if (root.id == selected.id) return root;
      }
    }
    return null;
  }

  void _openIndexRoot(IndexNode root) {
    _exitImmersiveBrowsing();
    _cancelPageWarmup();
    final cached = _browserNodeCache.get(
      BrowserNodeCacheKey(
        indexRootId: root.id,
        nodeId: root.id,
        sortMode: _browserState.sortMode,
        recursive: false,
      ),
    );
    if (cached != null) {
      setState(() {
        _section = AppSection.data;
        _selectedIndexRoot = root;
        _selectedItem = null;
        _detail = null;
        _childNodes = cached.childNodes;
        _entities = cached.entities;
        _entitiesHasMore = cached.hasMore;
        _recursiveEntityCursor = cached.recursiveCursor;
        _nodePath = cached.nodePath;
        _nodeSummaries = cached.nodeSummaries;
        _nodePreviews = cached.nodePreviews;
      });
      _updateNavigationCacheScope(
        root: root,
        nodePath: cached.nodePath,
        childNodes: cached.childNodes,
        recursive: false,
      );
      return;
    }
    setState(() {
      _section = AppSection.data;
      _selectedIndexRoot = root;
      _selectedItem = null;
      _detail = null;
    });
    _reload(indexNodeId: root.id);
  }

  void _openRootIndex() {
    _exitImmersiveBrowsing();
    _cancelPageWarmup();
    setState(() {
      _section = AppSection.data;
      _selectedIndexRoot = null;
      _selectedItem = null;
      _detail = null;
    });
    _reload();
  }

  void _navigateToSection(AppSection section) {
    if (section == AppSection.data) {
      _openRootIndex();
      return;
    }
    if (section == AppSection.indexes) {
      _reloadDashboardData();
    }
    setState(() => _section = section);
  }

  void _selectDataRootTab(BrowserRootTab tab) {
    _exitImmersiveBrowsing();
    _cancelPageWarmup();
    setState(() {
      _browserState = _browserState.copyWith(rootTab: tab);
      _section = AppSection.data;
      _selectedIndexRoot = null;
      _selectedItem = null;
      _detail = null;
    });
    _reload();
  }

  void _openIndexNode(IndexNode node) {
    _exitImmersiveBrowsing();
    _cancelPageWarmup();
    // 一级索引根是索引首页的直属节点；进入它时必须先切换索引上下文。
    if (_isIndexRoot(node)) {
      _openIndexRoot(node);
      return;
    }
    if (_activateCachedNodePage(node)) return;
    setState(() {
      _selectedItem = node;
      _detail = null;
      _section = AppSection.data;
    });
    _reload(indexNodeId: node.id);
  }

  bool _isIndexRoot(IndexNode node) {
    return node.nodeType == NodeType.directoryIndexRoot ||
        node.nodeType == NodeType.customIndexRoot ||
        node.nodeType == NodeType.graphIndexRoot;
  }

  void _handlePathSelection(IndexNode node) {
    _exitImmersiveBrowsing();
    if (_selectedIndexRoot?.id == node.id) {
      _openIndexRoot(node);
      return;
    }
    if (_activateCachedNodePage(node)) return;
    _openIndexNode(node);
  }

  bool _activateCachedNodePage(IndexNode node) {
    final root = _selectedIndexRoot;
    if (root == null) return false;
    final cached = _browserNodeCache.get(
      BrowserNodeCacheKey(
        indexRootId: root.id,
        nodeId: node.id,
        sortMode: _browserState.sortMode,
        recursive: false,
      ),
    );
    if (cached == null) return false;
    setState(() {
      _section = AppSection.data;
      _selectedItem = node;
      _detail = null;
      _childNodes = cached.childNodes;
      _entities = cached.entities;
      _entitiesHasMore = cached.hasMore;
      _recursiveEntityCursor = cached.recursiveCursor;
      _nodePath = cached.nodePath;
      _nodeSummaries = cached.nodeSummaries;
      _nodePreviews = cached.nodePreviews;
    });
    _updateNavigationCacheScope(
      root: root,
      nodePath: cached.nodePath,
      childNodes: cached.childNodes,
      recursive: false,
    );
    return true;
  }

  void _toggleImmersiveBrowsing() {
    if (_currentIndexNode == null) return;
    final enteringImmersive =
        _browserState.contentScope != BrowserContentScope.recursive;
    setState(() {
      _browserState = _browserState.copyWith(
        contentScope: enteringImmersive
            ? BrowserContentScope.recursive
            : BrowserContentScope.direct,
      );
      if (enteringImmersive) {
        _sidebarCollapsed = true;
        _selection.exit();
      }
    });
    try {
      _reload(indexNodeId: _currentIndexNode?.id);
    } catch (_) {
      if (enteringImmersive && mounted) {
        setState(() {
          _browserState = _browserState.copyWith(
            contentScope: BrowserContentScope.direct,
          );
        });
        _reload(indexNodeId: _currentIndexNode?.id);
      }
      rethrow;
    }
  }

  void _exitImmersiveBrowsing() {
    if (_browserState.contentScope != BrowserContentScope.recursive) return;
    setState(() {
      _browserState = _browserState.copyWith(
        contentScope: BrowserContentScope.direct,
      );
    });
  }

  void _setShelfImmersive(bool enabled) {
    if (!mounted) return;
    setState(() => _sidebarCollapsed = enabled);
  }

  Future<void> _scan({String? rootDisplayName}) async {
    final rootPath = _indexPathController.text.trim();
    final tasks = _buildTasks;
    if (tasks == null || tasks.isRunning) return;
    setState(() => _indexError = null);
    final result = await tasks.startRoot(
      rootPath,
      displayName: rootDisplayName,
    );
    if (!mounted) return;
    final createdIndex = result?.indexRootId == null
        ? null
        : (await _repository?.getIndexNode(result!.indexRootId!));
    if (result?.isCompleted == true && createdIndex != null) {
      if (!mounted) return;
      setState(() {
        _selectedIndexRoot = createdIndex;
        _selectedItem = null;
        _section = AppSection.indexes;
      });
      _reload(indexNodeId: createdIndex.id, invalidateBrowserCache: true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('索引完成，实体与节点预览已写入应用存储。'),
        ),
      );
    }
  }

  Future<void> _updateDirectoryNode(IndexNode node) async {
    final tasks = _buildTasks;
    if (tasks == null || tasks.isRunning) return;
    setState(() => _indexError = null);
    final result = await tasks.updateNode(node);
    if (!mounted || result?.isCompleted != true) return;
    _reload(indexNodeId: node.id, invalidateBrowserCache: true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已更新“${node.name}”及其下级，并完成预览资产构建。',
        ),
      ),
    );
  }

  Future<void> _updateCurrentDirectoryNode() async {
    final node = _currentIndexNode;
    if (node == null) return;
    await _updateDirectoryNode(node);
  }

  Future<void> _chooseDirectoryUpdateNode(IndexNode root) async {
    final repository = _repository;
    if (repository == null || _scanning) return;
    final tree = (await repository.listIndexTree(root.id));
    final entityCount = await repository.countEntitiesUnderIndexNode(root.id);
    if (!mounted) return;
    final selected = await showDialog<IndexNode>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('选择更新范围'),
        content: SizedBox(
          width: 440,
          height: 480,
          child: ListView(
            children: [
              DirectoryUpdateNodeTile(
                node: IndexTreeNode(
                  item: root,
                  children: tree,
                  entityCount: entityCount,
                ),
                initiallyExpanded: true,
                isRoot: true,
                onSelected: (node) => Navigator.of(dialogContext).pop(node),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (selected == null) return;
    await _updateDirectoryNode(selected);
  }

  Future<void> _showRebuildNodePreviews(IndexNode root) async {
    final repository = _repository;
    if (repository == null || _scanning) return;
    final confirmed = await _confirm(
      title: '重新生成节点预览',
      message: '将重新生成“${root.name}”及全部下级节点的预览图描述。',
    );
    if (!confirmed) return;
    await _refreshNodePreview(
      root.id,
      scope: IndexPreviewRebuildScope.subtree,
      reason: 'manual_rebuild',
    );
    _reload(invalidateBrowserCache: true);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('节点预览图已重新构建')));
    }
  }

  Future<void> _rebuildSelectedNodePreview() async {
    final repository = _repository;
    if (repository == null ||
        _selectedEntityIds.isNotEmpty ||
        _selectedNodeIds.length != 1) {
      return;
    }
    final node = (await repository.getIndexNode(_selectedNodeIds.single));
    if (node == null) {
      return;
    }
    await _refreshNodePreview(node.id, reason: 'manual_rebuild');
    _reload(indexNodeId: _currentIndexNode?.id, invalidateBrowserCache: true);
  }

  Future<void> _customizeSelectedNodePreview() async {
    final repository = _repository;
    if (repository == null ||
        _selectedEntityIds.isNotEmpty ||
        _selectedNodeIds.length != 1) {
      return;
    }
    final nodeId = _selectedNodeIds.single;
    final selected = await NodePreviewPicker.show(
      context,
      repository: repository,
      nodeId: nodeId,
    );
    if (selected == null || selected.isEmpty) return;
    (await repository.setNodePreviewOverride(
      nodeId,
      jsonEncode(selected
          .map((tile) => {
                'kind': tile.kind.name,
                'title': tile.title,
                'thumbnailKey': tile.thumbnailKey,
                'thumbnailFormat': tile.thumbnailFormat,
                'entityId': tile.entityId,
                'nodeId': tile.nodeId,
                'aspectRatio': tile.aspectRatio,
              })
          .toList()),
    ));
    await _refreshNodePreview(nodeId, reason: 'override_set');
    _reload(indexNodeId: _currentIndexNode?.id, invalidateBrowserCache: true);
  }

  Future<void> _clearSelectedNodePreviewOverride() async {
    final repository = _repository;
    if (repository == null ||
        _selectedEntityIds.isNotEmpty ||
        _selectedNodeIds.length != 1) {
      return;
    }
    final nodeId = _selectedNodeIds.single;
    (await repository.clearNodePreviewOverride(nodeId));
    await _refreshNodePreview(nodeId, reason: 'override_cleared');
    _reload(indexNodeId: _currentIndexNode?.id, invalidateBrowserCache: true);
  }

  Future<void> _showCreateDirectoryIndex() async {
    DirectorySelection? androidSelection;
    String? desktopPath;
    if (PlatformDirectoryPicker.isSupported) {
      androidSelection = await PlatformDirectoryPicker.pickDirectory();
      if (androidSelection == null || !mounted) return;
    } else {
      desktopPath = await getDirectoryPath();
      if (desktopPath == null || desktopPath.isEmpty || !mounted) return;
    }

    final source = androidSelection?.source ?? desktopPath!;
    final fallbackName = androidSelection?.displayName ?? p.basename(source);
    // Android returns from the system DocumentsUI route asynchronously. Wait
    // until its inherited widgets are reattached before pushing our dialog.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final displayName = await showDialog<String>(
      context: context,
      builder: (_) => DirectoryIndexDialog(
        source: source,
        initialName: fallbackName,
      ),
    );
    if (displayName == null || !mounted) return;
    _indexPathController.text = source;
    await _scan(
      rootDisplayName:
          displayName.trim().isEmpty ? fallbackName : displayName.trim(),
    );
  }

  void _pauseScan() => _buildTasks?.pause();

  void _cancelScan() => _buildTasks?.abandonActive();

  void _resumeIndexJob(LibraryBuildJob job) =>
      unawaited(_executeRecoverableIndexJob(job, resume: true));

  void _retryFailedIndexJob(LibraryBuildJob job) =>
      unawaited(_executeRecoverableIndexJob(job, retryFailed: true));

  void _recheckIndexJob(LibraryBuildJob job) =>
      unawaited(_executeRecoverableIndexJob(job, recheck: true));

  Future<void> _executeRecoverableIndexJob(
    LibraryBuildJob job, {
    bool resume = false,
    bool retryFailed = false,
    bool recheck = false,
  }) async {
    final tasks = _buildTasks;
    if (tasks == null || tasks.isRunning) return;
    setState(() => _indexError = null);
    final result = recheck
        ? await tasks.recheck(job)
        : retryFailed
            ? await tasks.retryFailed(job)
            : await tasks.resume(job);
    if (!mounted) return;
    if (result?.status == LibraryBuildStatus.completedWithErrors) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '重试已执行，但仍有失败项：实体 ${result!.entityPreviewFailed}，节点 ${result.nodePreviewFailed}。',
          ),
        ),
      );
      return;
    }
    if (result?.status != LibraryBuildStatus.completed) return;
    final targetNode = result?.indexRootId == null
        ? null
        : (await _repository?.getIndexNode(result!.indexRootId!));
    if (!mounted) return;
    if (targetNode != null) _openIndexNode(targetNode);
    _reload(indexNodeId: targetNode?.id, invalidateBrowserCache: true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(retryFailed ? '失败项重试完成。' : '索引任务完成。'),
      ),
    );
  }

  void _discardRecoverableIndexJob(LibraryBuildJob job) {
    _buildTasks?.abandon(job);
  }

  Future<String?> _askText({
    required String title,
    required String label,
    required String initialValue,
    required String confirmLabel,
  }) async {
    final controller = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(labelText: label),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _openEntity(EntityListItem entity) async {
    if (!mounted || _viewerSessions.isStopped) return;
    final repository = _repository;
    final audioController = _audioController;
    if (repository == null || audioController == null) return;
    (await repository.markOpened(entity.id));
    final detail = (await repository.getEntity(entity.id));
    if (!mounted || _viewerSessions.isStopped) return;
    setState(() => _detail = detail);
    final sourceNode = _currentIndexNode;
    final playbackQueue =
        entity.entityType == EntityType.audio && sourceNode != null
            ? (await repository.listEntitiesDirectlyUnderNode(
                sourceNode.id,
                sortMode: _browserState.sortMode,
              ))
            : _entities;
    final libraryOverlay = entity.entityType == EntityType.image ||
        entity.entityType == EntityType.video;
    if (!mounted || _viewerSessions.isStopped) return;
    EntityViewerPage buildViewer() => EntityViewerPage(
          sessions: _viewerSessions,
          entity: entity,
          queue: playbackQueue,
          sourceNode: sourceNode,
          libraryOverlay: libraryOverlay,
          onClose: libraryOverlay ? _closeMediaOverlay : null,
          audioWaveformService: AudioWaveformService(
            AudioWaveformStore(repository.storageDirectoryPath),
          ),
          audioController: audioController,
          onEntityOpened: (opened) async {
            (await repository.markOpened(opened.id));
            final detail = await repository.getEntity(opened.id);
            if (mounted) setState(() => _detail = detail);
          },
          onShowDetails: (opened) => _showEntityDetail(opened),
          onOpenDirectoryRoot: _openDirectoryRootForEntity,
          onPlaybackStateChanged: (entityId, positionMs, durationMs) async {
            (await repository.savePlaybackState(
              entityId: entityId,
              positionMs: positionMs,
              durationMs: durationMs,
            ));
          },
          onReaderStateChanged: ({
            required entityId,
            scrollOffset,
            zoomScale,
            extraStateJson,
          }) async {
            (await repository.saveReaderState(
              entityId: entityId,
              scrollOffset: scrollOffset,
              zoomScale: zoomScale,
              extraStateJson: extraStateJson,
            ));
          },
        );
    if (!mounted) return;
    if (libraryOverlay) {
      setState(() {
        _mediaOverlayRequiresLibraryRefresh = false;
        _mediaOverlay = buildViewer();
      });
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => buildViewer()),
    );
  }

  Future<void> _openDirectoryRootForEntity(EntityListItem item) async {
    final repository = _repository;
    final rootId = (await repository?.getEntity(item.id))?.directoryRootId;
    if (rootId == null) return;
    final root = (await repository?.getIndexNode(rootId));
    if (root?.nodeType != NodeType.directoryIndexRoot) return;
    _closeMediaOverlay();
    _openIndexRoot(root!);
  }

  void _closeMediaOverlay() {
    final requiresRefresh = _mediaOverlayRequiresLibraryRefresh;
    setState(() {
      _mediaOverlay = null;
      _mediaOverlayRequiresLibraryRefresh = false;
    });
    if (!requiresRefresh) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reload(
        indexNodeId: _currentIndexNode?.id,
        invalidateBrowserCache: true,
      );
    });
  }

  void _handleSystemBack() {
    if (_mediaOverlay != null) {
      _closeMediaOverlay();
      return;
    }
    if (_selectionMode) {
      _toggleSelectionMode();
      return;
    }
    if (_detail != null) {
      setState(() => _detail = null);
      return;
    }
    if (_section == AppSection.data) {
      final selectedItem = _selectedItem;
      if (selectedItem != null) {
        final index =
            _nodePath.indexWhere((node) => node.id == selectedItem.id);
        final parent = index > 0 ? _nodePath[index - 1] : _selectedIndexRoot;
        if (parent != null) {
          _handlePathSelection(parent);
        } else {
          _openRootIndex();
        }
        return;
      }
      if (_selectedIndexRoot != null) {
        _openRootIndex();
        return;
      }
    }
    if (_section != AppSection.data ||
        _browserState.rootTab != BrowserRootTab.directory) {
      _selectDataRootTab(BrowserRootTab.directory);
      return;
    }
    SystemNavigator.pop();
  }

  Future<void> _openNowPlaying() async {
    final repository = _repository;
    final controller = _audioController;
    if (repository == null || controller == null || !controller.hasCurrent) {
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NowPlayingPage(
        controller: controller,
        waveformService: AudioWaveformService(
          AudioWaveformStore(repository.storageDirectoryPath),
        ),
      ),
    ));
  }

  Future<void> _showEntityDetail(EntityListItem entity) async {
    final repository = _repository;
    if (repository == null) return;
    final detail = (await repository.getEntity(entity.id));
    if (detail == null || !mounted) return;
    setState(() => _detail = detail);
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭详情',
      barrierColor: Colors.black.withValues(alpha: .38),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (context, _, __) => Align(
        alignment: Alignment.centerRight,
        child: SafeArea(
          child: SizedBox(
            width: 390,
            height: double.infinity,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              elevation: 24,
              child: EntityDetailSheet(
                detail: detail,
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (context, animation, _, child) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
    _reload(indexNodeId: _currentIndexNode?.id);
  }

  void _toggleEntitySelection(EntityListItem entity) {
    setState(() => _selection.toggleEntity(entity.id));
  }

  void _toggleNodeSelection(IndexNode node) {
    setState(() => _selection.toggleNode(node.id));
  }

  void _toggleSelectionMode() {
    setState(() {
      _selection.toggleMode();
      if (_selection.enabled) {
        _browserState = _browserState.copyWith(
          displayMode: BrowserDisplayMode.grid,
        );
      }
    });
  }

  void _startEntitySelection(EntityListItem entity) {
    setState(() {
      _browserState = _browserState.copyWith(
        displayMode: BrowserDisplayMode.grid,
      );
      _selection.startEntity(entity.id);
    });
  }

  void _startNodeSelection(IndexNode node) {
    setState(() {
      _selection.startNode(node.id);
    });
  }

  void _selectEntitiesByDrag(Iterable<EntityListItem> entities) {
    final items = entities.toList(growable: false);
    if (items.isEmpty) return;
    setState(() {
      _browserState = _browserState.copyWith(
        displayMode: BrowserDisplayMode.grid,
      );
      _selection.addDraggedEntities(items.map((entity) => entity.id));
    });
  }

  void _selectAllVisibleEntities() {
    setState(
      () => _selection.selectAll(
        visibleEntityIds: _entities.map((entity) => entity.id),
        visibleNodeIds: _childNodes.map((node) => node.id),
      ),
    );
  }

  void _invertVisibleEntitySelection() {
    setState(
      () => _selection.invert(
        visibleEntityIds: _entities.map((entity) => entity.id),
        visibleNodeIds: _childNodes.map((node) => node.id),
      ),
    );
  }

  void _selectEntityRange() {
    setState(
      () => _selection.selectRange(
        visibleEntityIds: _entities.map((entity) => entity.id).toList(),
        visibleNodeIds: _childNodes.map((node) => node.id).toList(),
      ),
    );
  }

  Future<void> _showEntityContextMenu(EntityListItem entity) async {
    final handler = FileFormatRegistry.resolveFormat(entity.format);
    final canRegenerate = handler?.supportsGeneratedThumbnail ?? false;
    final action = await showModalBottomSheet<EntityMenuAction>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.checklist_rounded),
              title: const Text('选择此项'),
              onTap: () => Navigator.of(context).pop(EntityMenuAction.select),
            ),
            if (canRegenerate)
              ListTile(
                leading: const Icon(Icons.refresh_rounded),
                title: const Text('重新生成缩略图'),
                subtitle: entity.thumbnailStatus == ThumbnailStatus.failed
                    ? const Text('重新尝试失败的缩略图任务')
                    : null,
                onTap: () => Navigator.of(context)
                    .pop(EntityMenuAction.regenerateThumbnail),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case EntityMenuAction.select:
        _startEntitySelection(entity);
      case EntityMenuAction.regenerateThumbnail:
        await _regenerateThumbnail(entity);
    }
  }

  Future<void> _regenerateThumbnail(EntityListItem item) async {
    final repository = _repository;
    if (repository == null || !_regeneratingThumbnailIds.add(item.id)) return;
    final entity = (await repository.getEntity(item.id));
    if (entity == null || !mounted) {
      _regeneratingThumbnailIds.remove(item.id);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在重新生成缩略图')),
    );
    try {
      await ThumbnailService(
        repository,
        androidImageBackend: AndroidImageThumbnailBackend(),
        androidVideoBackend: AndroidVideoThumbnailBackend(),
        nativeImageBackend: NativeImageThumbnailBackend(),
        windowsWicBackend: WindowsWicWebpThumbnailBackend(),
      ).regenerateThumbnail(entity);
      for (final nodeId
          in (await repository.listIndexNodeIdsForEntity(entity.id))) {
        await _refreshNodePreview(nodeId, reason: 'thumbnail_regenerated');
      }
      final refreshed = (await repository.getEntity(item.id));
      if (!mounted) return;
      final message = refreshed?.thumbnailStatus == ThumbnailStatus.success
          ? '缩略图已重新生成'
          : '缩略图生成失败：${refreshed?.thumbnailError ?? '未知错误'}';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } finally {
      _regeneratingThumbnailIds.remove(item.id);
      if (mounted) {
        _reload(
          indexNodeId: _currentIndexNode?.id,
          invalidateBrowserCache: true,
        );
      }
    }
  }

  void _clearEntitySelection() => setState(_selection.clear);

  void _exitSelectionMode() => setState(_selection.exit);

  Future<void> _showCreateCollectionFromSelection() async {
    if (_isInsideCustomIndex && _currentIndexNode != null) {
      await _showCreateCustomNode(entityIds: _selectedEntityIds);
      return;
    }
    await _showCreateCollection(entityIds: _selectedEntityIds);
  }

  Future<void> _showCreateCustomNode({
    Iterable<String> entityIds = const [],
    IndexNode? parentOverride,
  }) async {
    final repository = _repository;
    final parent = parentOverride ?? _currentIndexNode;
    if (repository == null ||
        _scanning ||
        parent == null ||
        (parent.nodeType != NodeType.customIndexRoot &&
            parent.nodeType != NodeType.customNode)) {
      return;
    }
    final name = await showDialog<String>(
      context: context,
      builder: (_) => TextPromptDialog(
        title: '新建索引节点',
        label: '节点名称',
        confirmLabel: entityIds.isEmpty ? '创建' : '创建并加入',
      ),
    );
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    try {
      final node = (await repository.createCustomNode(
          parentId: parent.id, name: trimmed));
      if (entityIds.isNotEmpty) {
        (await repository.linkEntitiesToIndexNode(
            entityIds: entityIds, indexNodeId: node.id));
      }
      await _refreshNodePreview(node.id, reason: 'custom_node_created');
      setState(_selection.exit);
      _browserNodeCache.clear();
      _cacheWarmupGeneration++;
      if (parentOverride != null) {
        setState(() {
          _selectedIndexRoot = parentOverride;
          _selectedItem = null;
          _detail = null;
          _section = AppSection.data;
        });
      }
      _openIndexNode(node);
    } on ArgumentError catch (error) {
      if (mounted) setState(() => _indexError = '创建索引节点失败：${error.message}');
    }
  }

  Future<void> _showCreateCollection(
      {Iterable<String> entityIds = const []}) async {
    final repository = _repository;
    if (repository == null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => TextPromptDialog(
        title: '新建自定义索引',
        label: '自定义索引名称',
        hintText: '例如：待读、银狼相关、睡前听',
        confirmLabel: entityIds.isEmpty ? '创建' : '创建并加入',
      ),
    );
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    try {
      final collection = (await repository.createCollectionWithEntities(
        name: trimmed,
        entityIds: entityIds,
      ));
      await _refreshNodePreview(
        collection.id,
        scope: IndexPreviewRebuildScope.subtree,
        reason: 'collection_created',
      );
      setState(_selection.exit);
      _browserNodeCache.clear();
      _cacheWarmupGeneration++;
      _openIndexRoot(collection);
    } on ArgumentError catch (error) {
      if (mounted) setState(() => _indexError = '创建自定义索引失败：${error.message}');
    }
  }

  Future<void> _showCreateGraphIndex() async {
    final repository = _repository;
    if (repository == null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const TextPromptDialog(
        title: '新建图索引',
        label: '图索引名称',
        confirmLabel: '创建',
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    final graph = (await repository.ensureGraphIndexRoot(name.trim()));
    _browserNodeCache.clear();
    _openIndexRoot(graph);
  }

  Future<void> _showAddToCollection() async {
    final repository = _repository;
    if (repository == null ||
        (_selectedEntityIds.isEmpty && _selectedNodeIds.isEmpty)) {
      return;
    }
    final collections = (await repository.listIndexRoots())
        .where((node) => node.nodeType == NodeType.customIndexRoot)
        .toList(growable: false);
    if (collections.isEmpty) {
      final name = await _askText(
        title: '新建自定义索引',
        label: '自定义索引名称',
        confirmLabel: '创建并加入',
        initialValue: '',
      );
      if (name == null || name.trim().isEmpty) return;
      final collection = (await repository.createCollectionWithEntities(
        name: name.trim(),
        entityIds: _selectedEntityIds,
      ));
      final previewRefreshes = <Future<void>>[
        _refreshNodePreview(
          collection.id,
          reason: 'collection_entities_added',
        ),
      ];
      for (final nodeId in _selectedNodeIds) {
        final cloned = (await repository.cloneIndexNodeTree(
          sourceNodeId: nodeId,
          targetParentId: collection.id,
        ));
        previewRefreshes.add(
          _refreshNodePreview(
            cloned.id,
            scope: IndexPreviewRebuildScope.subtree,
            reason: 'node_tree_cloned',
          ),
        );
      }
      await Future.wait(previewRefreshes);
      _exitSelectionMode();
      _browserNodeCache.clear();
      _cacheWarmupGeneration++;
      _openIndexRoot(collection);
      return;
    }
    final selected = <String>{};
    final trees =
        await Future.wait(collections.map((root) async => IndexTreeNode(
              item: root,
              children: await repository.listIndexTree(root.id),
              entityCount:
                  await repository.countEntitiesUnderIndexNode(root.id),
            )));
    if (!mounted) return;
    final targets = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('加入自定义索引'),
            content: SizedBox(
              width: 460,
              height: 500,
              child: ListView(
                children: _buildCollectionTargetTiles(
                  trees,
                  selected: selected,
                  onChanged: (node, checked) => setDialogState(() {
                    if (checked) {
                      selected.add(node.id);
                    } else {
                      selected.remove(node.id);
                    }
                  }),
                ),
              ),
            ),
            actions: [
              OutlinedButton.icon(
                onPressed: selected.length != 1
                    ? null
                    : () async {
                        final name = await _askText(
                          title: '新建索引节点',
                          label: '节点名称',
                          confirmLabel: '创建并选择',
                          initialValue: '',
                        );
                        if (name == null || name.trim().isEmpty) return;
                        final node = (await repository.createCustomNode(
                          parentId: selected.single,
                          name: name.trim(),
                        ));
                        setDialogState(() {
                          selected
                            ..clear()
                            ..add(node.id);
                        });
                      },
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('新建节点'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: selected.isEmpty
                    ? null
                    : () => Navigator.of(context).pop(selected),
                child: Text(
                  '加入 ${_selectedEntityIds.length} 个实体 | ${_selectedNodeIds.length} 个节点',
                ),
              ),
            ],
          );
        },
      ),
    );
    if (targets == null || targets.isEmpty) return;
    try {
      final previewRefreshes = <Future<void>>[];
      for (final targetId in targets) {
        if (_selectedEntityIds.isNotEmpty) {
          (await repository.linkEntitiesToIndexNode(
            entityIds: _selectedEntityIds,
            indexNodeId: targetId,
          ));
        }
        for (final nodeId in _selectedNodeIds) {
          final cloned = (await repository.cloneIndexNodeTree(
            sourceNodeId: nodeId,
            targetParentId: targetId,
          ));
          previewRefreshes.add(
            _refreshNodePreview(
              cloned.id,
              scope: IndexPreviewRebuildScope.subtree,
              reason: 'node_tree_added_to_collection',
            ),
          );
        }
        previewRefreshes.add(
          _refreshNodePreview(targetId, reason: 'collection_content_added'),
        );
      }
      await Future.wait(previewRefreshes);
    } on ArgumentError catch (error) {
      if (mounted) setState(() => _indexError = '添加到索引失败：${error.message}');
      return;
    }
    _exitSelectionMode();
    _reload(
      indexNodeId: _currentIndexNode?.id,
      invalidateBrowserCache: true,
    );
  }

  List<Widget> _buildCollectionTargetTiles(
    List<IndexTreeNode> nodes, {
    required Set<String> selected,
    required void Function(IndexNode node, bool checked) onChanged,
  }) {
    return nodes
        .map(
          (node) => CollectionTargetNodeTile(
            treeNode: node,
            selectedIds: selected,
            initiallyExpanded: true,
            onChanged: onChanged,
          ),
        )
        .toList(growable: false);
  }

  Future<void> _cloneCurrentNodeTreeToCustomIndex() async {
    final repository = _repository;
    final source = _currentIndexNode;
    if (repository == null || source == null) return;
    final targets = (await repository.listIndexRoots())
        .where((node) => node.nodeType == NodeType.customIndexRoot)
        .toList(growable: false);
    if (!mounted) return;
    if (targets.isEmpty) {
      setState(() => _indexError = '请先创建一个自定义索引作为复制目标。');
      return;
    }
    final targetId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('复制节点树到自定义索引'),
        content: SizedBox(
          width: 380,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final target in targets)
                ListTile(
                  leading: const Icon(Icons.account_tree_outlined),
                  title: Text(target.name),
                  onTap: () => Navigator.of(context).pop(target.id),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (targetId == null) return;
    if (!mounted) return;
    final overlay = OverlayEntry(
      builder: (context) => const Stack(
        children: [
          ModalBarrier(dismissible: false, color: Color(0x88000000)),
          Center(
            child: SizedBox(
              width: 216,
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                      SizedBox(width: 14),
                      Expanded(child: Text('正在复制节点树...')),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(overlay);
    await WidgetsBinding.instance.endOfFrame;
    try {
      final cloned = (await repository.cloneIndexNodeTree(
        sourceNodeId: source.id,
        targetParentId: targetId,
      ));
      final target = (await repository.getIndexNode(targetId))!;
      await _refreshNodePreview(
        cloned.id,
        scope: IndexPreviewRebuildScope.subtree,
        reason: 'node_tree_cloned',
      );
      _browserNodeCache.clear();
      _cacheWarmupGeneration++;
      _reloadDashboardData();
      _openIndexRoot(target);
      _openIndexNode(cloned);
    } on ArgumentError catch (error) {
      if (mounted) setState(() => _indexError = '复制节点树失败：${error.message}');
    } finally {
      overlay.remove();
    }
  }

  Future<void> _removeSelectedFromCurrentNode() async {
    final repository = _repository;
    final node = _currentIndexNode;
    if (repository == null ||
        node == null ||
        !_canRemoveEntityReferencesFromCurrentNode ||
        (_selectedEntityIds.isEmpty && _selectedNodeIds.isEmpty)) {
      return;
    }
    final entityCount = _selectedEntityIds.length;
    final nodeCount = _selectedNodeIds.length;
    final confirmed = await _confirm(
      title: '从当前节点移除',
      message: [
        if (entityCount > 0) '将移除 $entityCount 项实体引用。',
        if (nodeCount > 0) '将递归删除 $nodeCount 个节点及其下级节点、关联边和实体引用。',
        '不会删除实体、源文件或缩略图。',
      ].join('\n'),
    );
    if (!confirmed) return;
    for (final entityId in _selectedEntityIds) {
      (await repository.unlinkEntityFromIndexNode(
          entityId: entityId, indexNodeId: node.id));
    }
    for (final nodeId in _selectedNodeIds) {
      (await repository.deleteIndexNode(nodeId));
    }
    await _refreshNodePreview(node.id, reason: 'references_removed');
    _clearEntitySelection();
    _reload(indexNodeId: node.id, invalidateBrowserCache: true);
  }

  Future<void> _renameIndexNode(IndexNode index) async {
    final repository = _repository;
    if (repository == null || _scanning) return;
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => TextPromptDialog(
        title: '重命名索引',
        label: '索引名称',
        confirmLabel: '保存',
        initialValue: index.name,
      ),
    );
    if (!mounted) return;
    final trimmed = newName?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == index.name) return;
    try {
      (await repository.renameIndexNode(index.id, trimmed));
      await _refreshNodePreview(index.id, reason: 'node_renamed');
      _reload(
        indexNodeId: _currentIndexNode?.id,
        invalidateBrowserCache: true,
      );
    } on ArgumentError catch (error) {
      setState(() => _indexError = '重命名失败：${error.message}');
    }
  }

  Future<void> _deleteIndexNode(IndexNode index) async {
    final repository = _repository;
    if (repository == null || _scanning) return;
    if (index.nodeType == NodeType.directoryIndexRoot) {
      final report = (await repository.inspectDirectoryIndexDeletion(index.id));
      final force = await _confirmDirectoryIndexDeletion(report);
      if (force == null) return;
      (await repository.deleteDirectoryIndex(index.id, force: force));
      setState(() {
        if (_selectedIndexRoot?.id == index.id) {
          _selectedIndexRoot = null;
          _selectedItem = null;
          _detail = null;
        }
      });
      _reload(invalidateBrowserCache: true);
      return;
    }
    final deletesEntities =
        (await repository.willDeleteEntitiesWhenDeletingNode(
      index.id,
    ));
    final message = deletesEntities
        ? '删除后会递归删除索引节点和索引关系；其中未被其它索引引用的实体数据库记录也会删除，不会删除真实源文件。确定删除“${index.name}”？'
        : '只会删除索引节点和索引关系，不会删除实体数据库记录。确定删除“${index.name}”？';
    final confirmed = await _confirm(title: '删除索引', message: message);
    if (!confirmed) return;
    final fallbackParent = index.parentId == null
        ? null
        : (await repository.getIndexNode(index.parentId!));
    (await repository.deleteIndexNode(index.id));
    if (fallbackParent != null) {
      await _refreshNodePreview(fallbackParent.id, reason: 'node_deleted');
    }
    setState(() {
      if (_selectedIndexRoot?.id == index.id) {
        _selectedIndexRoot = null;
        _selectedItem = null;
        _detail = null;
      } else if (_selectedItem?.id == index.id) {
        _selectedItem = fallbackParent?.id == _selectedIndexRoot?.id
            ? null
            : fallbackParent;
        _detail = null;
      }
    });
    _reload(invalidateBrowserCache: true);
  }

  Future<bool?> _confirmDirectoryIndexDeletion(
    DirectoryIndexDeletionReport report,
  ) async {
    final theme = Theme.of(context);
    final conflicts = report.conflicts;
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除目录索引'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 420),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('“${report.root.name}”包含 ${report.entityCount} 个实体。'),
                const SizedBox(height: 10),
                const Text('不会删除、移动或修改硬盘中的真实源文件。'),
                if (conflicts.isEmpty) ...[
                  const SizedBox(height: 10),
                  const Text('将删除本应用中的目录索引、实体记录和衍生预览资源。'),
                ] else ...[
                  const SizedBox(height: 10),
                  Text(
                    '${report.conflictCount} 个实体仍被其它索引引用。普通删除已阻止；强制删除会同时移除下列引用。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final conflict in conflicts)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '${conflict.entityName}\n${conflict.indexNames.join('、')}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (report.conflictCount > conflicts.length)
                    Text(
                        '另有 ${report.conflictCount - conflicts.length} 个实体未展开。'),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          if (conflicts.isEmpty)
            FilledButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('删除索引'),
            )
          else
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('强制删除'),
            ),
        ],
      ),
    );
  }

  Future<void> _deleteCurrentNodeFromTree() async {
    final node = _currentIndexNode;
    if (node == null || !_isInsideCustomIndex) return;
    await _deleteIndexNode(node);
  }

  Future<bool> _confirm({
    required String title,
    required String message,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('确认'),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final incompatibleSchemaVersion = _incompatibleSchemaVersion;
    if (incompatibleSchemaVersion != null) {
      final theme = Theme.of(context);
      return Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.storage_rounded,
                    size: 36,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 18),
                  Text('需要重置本地索引', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 10),
                  Text(
                    '当前本地索引的数据结构（版本 $incompatibleSchemaVersion）与当前版本不兼容，需要重新建立应用索引。',
                    style: theme.textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '此操作仅清理应用数据库与生成缓存，不会删除、移动或修改硬盘、TF 卡中的真实资料文件。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 22),
                  FilledButton.icon(
                    onPressed:
                        _resettingLocalIndex ? null : _resetLocalIndexStorage,
                    icon: const Icon(Icons.delete_sweep_outlined),
                    label: const Text('重置并重新开始'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final pageBody = switch (_section) {
      AppSection.data
          when _currentIndexNode?.nodeType == NodeType.graphIndexRoot =>
        GraphIndexPage(
          repository: _repository!,
          graphRoot: _currentIndexNode!,
          onOpenNode: _openIndexNode,
          onReturnToRootIndex: _openRootIndex,
          onPreviewDirty: _refreshNodePreview,
          onThumbnailEntityNeeded: _requestBrowseThumbnailById,
        ),
      AppSection.data => CollectionBrowserPage(
          currentNode: _currentIndexNode,
          nodePath: _nodePath,
          childNodes: _childNodes,
          nodeSummaries: _nodeSummaries,
          nodePreviews: _nodePreviews,
          entities: _entities,
          hasMoreEntities: _entitiesHasMore,
          loadingMoreEntities: _loadingMoreEntities,
          browserState: _browserState,
          onOpenRootIndex: _openRootIndex,
          onSortChanged: (value) {
            setState(
                () => _browserState = _browserState.copyWith(sortMode: value));
            _reload(indexNodeId: _currentIndexNode?.id);
          },
          onDisplayModeChanged: (value) {
            setState(() =>
                _browserState = _browserState.copyWith(displayMode: value));
          },
          onGridLayoutChanged: (value) {
            setState(() => _browserState = _browserState.copyWith(
                  gridLayout: value,
                ));
          },
          immersiveBrowsing:
              _browserState.contentScope == BrowserContentScope.recursive,
          onToggleImmersiveBrowsing: _toggleImmersiveBrowsing,
          selectionMode: _selectionMode,
          onToggleSelectionMode: _toggleSelectionMode,
          onCloneCurrentNodeTree: _cloneCurrentNodeTreeToCustomIndex,
          canUpdateDirectoryNode: _canUpdateCurrentDirectoryNode,
          onUpdateDirectoryNode: _updateCurrentDirectoryNode,
          canDeleteCurrentNode: _isInsideCustomIndex,
          onDeleteCurrentNode: _deleteCurrentNodeFromTree,
          onOpenNode:
              _currentIndexNode == null ? _openIndexRoot : _openIndexNode,
          onPathNodeSelected: _handlePathSelection,
          onOpenEntity: (entity) => _openEntity(entity),
          onShowEntityMenu: _showEntityContextMenu,
          onThumbnailNeeded: _requestBrowseThumbnail,
          onThumbnailEntityNeeded: _requestBrowseThumbnailById,
          onLoadMoreEntities: _loadMoreEntities,
          selectedEntityIds: _selectedEntityIds,
          onToggleEntitySelection: _toggleEntitySelection,
          onStartEntitySelection: _startEntitySelection,
          onSelectEntitiesByDrag: _selectEntitiesByDrag,
          selectedNodeIds: _selectedNodeIds,
          onToggleNodeSelection: _toggleNodeSelection,
          onStartNodeSelection: _startNodeSelection,
          onClearEntitySelection: _clearEntitySelection,
          onSelectAllVisible: _selectAllVisibleEntities,
          onInvertVisibleSelection: _invertVisibleEntitySelection,
          onSelectRange: _selectEntityRange,
          onAddToCollection: _showAddToCollection,
          onCreateCollection: _showCreateCollectionFromSelection,
          onRemoveFromCurrentNode: _removeSelectedFromCurrentNode,
          canRemoveFromCurrentNode: _canRemoveEntityReferencesFromCurrentNode,
          canManageCurrentCustomIndex: _isInsideCustomIndex,
          onRebuildSelectedNodePreview: _rebuildSelectedNodePreview,
          onCustomizeSelectedNodePreview: _customizeSelectedNodePreview,
          onClearSelectedNodePreviewOverride: _clearSelectedNodePreviewOverride,
        ),
      AppSection.video => MediaShelfPage(
          kind: MediaShelfKind.video,
          repository: _repository!,
          onOpenEntity: _openEntity,
          onThumbnailNeeded: _requestBrowseThumbnail,
          onImmersiveChanged: _setShelfImmersive,
        ),
      AppSection.gallery => MediaShelfPage(
          kind: MediaShelfKind.gallery,
          repository: _repository!,
          onOpenEntity: _openEntity,
          onThumbnailNeeded: _requestBrowseThumbnail,
          onImmersiveChanged: _setShelfImmersive,
        ),
      AppSection.reading => MediaShelfPage(
          kind: MediaShelfKind.reading,
          repository: _repository!,
          onOpenEntity: _openEntity,
          onThumbnailNeeded: _requestBrowseThumbnail,
        ),
      AppSection.music => MusicPage(
          sessions: _audioSessions,
          controller: _audioController!,
          onRestore: (session) async {
            await _audioController!.restoreSession(session, autoplay: true);
            if (mounted) setState(() {});
          },
          onPlayEntry: (session, index) async {
            await _audioController!.playSessionEntry(session, index);
            if (mounted) setState(() {});
          },
          onDelete: (session) async {
            await _repository!.deleteAudioPlaybackSession(session.id);
            final sessions = await _repository!.listAudioPlaybackSessions();
            if (mounted) setState(() => _audioSessions = sessions);
          },
        ),
      AppSection.indexes => IndexManagementPage(
          roots: _indexRoots,
          rootCounts: _rootCounts,
          scanning: _scanning,
          progress: _scanProgress,
          activeBuildJob: _activeBuildJob,
          recoverableJobs: _recoverableIndexJobs,
          errorMessage: _indexError ?? _buildTasks?.errorMessage,
          taskHistory: _indexTaskHistory,
          actions: IndexManagementActions(
            onCreateDirectoryIndex: _showCreateDirectoryIndex,
            onPause: _pauseScan,
            onCancel: _cancelScan,
            onResume: _resumeIndexJob,
            onRecheck: _recheckIndexJob,
            onRetryFailed: _retryFailedIndexJob,
            onAbandon: _discardRecoverableIndexJob,
            onRename: _renameIndexNode,
            onDelete: _deleteIndexNode,
            onUpdateDirectoryIndex: _chooseDirectoryUpdateNode,
            onRebuildNodePreviews: _showRebuildNodePreviews,
            onCreateCollection: () => _showCreateCollection(),
            onCreateGraph: _showCreateGraphIndex,
            onCreateNodeAtRoot: (root) =>
                _showCreateCustomNode(parentOverride: root),
            onOpenRoot: _openIndexRoot,
          ),
        ),
      AppSection.settings => SettingsPage(
          onOpenDiagnostics: () => _navigateToSection(AppSection.logs),
          themeChoice: widget.themeChoice,
          sortMode: _browserState.sortMode,
          onThemeChanged: widget.onThemeChanged,
          onResetLocalIndex: _resetLocalIndexStorage,
          onSortChanged: (value) {
            setState(
                () => _browserState = _browserState.copyWith(sortMode: value));
            _reload(indexNodeId: _currentIndexNode?.id);
          },
        ),
      AppSection.logs => DiagnosticsPage(
          database: _database!,
          log: AppDiagnosticLog.instance,
          recoverableJobs: _recoverableIndexJobs,
          history: _indexTaskHistory,
          progress: _scanProgress,
        ),
    };
    final recentSections = <AppSection, String>{
      AppSection.gallery: '图片',
      AppSection.video: '视频',
      AppSection.reading: '阅读',
      AppSection.music: '音乐',
    };
    final tabs = <Widget>[];
    if (recentSections.containsKey(_section)) {
      tabs.add(Wrap(spacing: 8, children: [
        for (final entry in recentSections.entries)
          ChoiceChip(
              label: Text(entry.value),
              selected: _section == entry.key,
              onSelected: (_) => _navigateToSection(entry.key)),
      ]));
    } else if (_section == AppSection.data &&
        _browserState.rootTab != BrowserRootTab.directory) {
      tabs.add(Wrap(spacing: 8, children: [
        for (final tab in [BrowserRootTab.tree, BrowserRootTab.graph])
          ChoiceChip(
              label: Text(tab == BrowserRootTab.tree ? '自定义资料集' : '图画布'),
              selected: _browserState.rootTab == tab,
              onSelected: (_) => _selectDataRootTab(tab)),
      ]));
    } else if (_section == AppSection.logs) {
      tabs.add(TextButton.icon(
          onPressed: () => _navigateToSection(AppSection.settings),
          icon: const Icon(Icons.arrow_back),
          label: const Text('返回设置')));
    }
    final presentedPage = tabs.isEmpty
        ? pageBody
        : Column(children: [
            Padding(
                padding: const EdgeInsets.all(12),
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: Column(
                        mainAxisSize: MainAxisSize.min, children: tabs))),
            Expanded(child: pageBody),
          ]);
    final body = _readError == null ||
            _section == AppSection.settings ||
            _section == AppSection.logs
        ? presentedPage
        : Column(
            children: [
              ReadUnavailableBanner(
                message: _readError!,
                retrying: _readRetrying,
                onRetry: _retryReadWorker,
              ),
              Expanded(child: presentedPage),
            ],
          );

    final audioController = _audioController;
    final miniPlayer = audioController == null
        ? const SizedBox.shrink()
        : ListenableBuilder(
            listenable: audioController,
            builder: (context, _) => audioController.hasCurrent
                ? MiniAudioPlayer(
                    controller: audioController,
                    onOpen: _openNowPlaying,
                    collapsed: _miniPlayerCollapsed,
                    onToggleCollapsed: () => setState(
                      () => _miniPlayerCollapsed = !_miniPlayerCollapsed,
                    ),
                  )
                : const SizedBox.shrink(),
          );
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleSystemBack();
      },
      child: Scaffold(
        extendBody: true,
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Theme.of(context).scaffoldBackgroundColor,
                Theme.of(context).colorScheme.surface,
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: Stack(
            children: [
              SafeArea(
                child: Row(
                  children: [
                    AppSidebar(
                      current: _section,
                      onChanged: _navigateToSection,
                      rootTab: _browserState.rootTab,
                      onRootTabChanged: _selectDataRootTab,
                      collapsed: _sidebarCollapsed,
                      onToggleCollapsed: () => setState(
                        () => _sidebarCollapsed = !_sidebarCollapsed,
                      ),
                    ),
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    Expanded(child: body),
                  ],
                ),
              ),
              if (_mediaOverlay case final overlay?)
                Positioned.fill(child: overlay),
              Positioned(
                right: 0,
                bottom: 12,
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: miniPlayer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
