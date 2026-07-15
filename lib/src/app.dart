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
import 'core/database/library_write_worker.dart';
import 'core/database/library_repository.dart';
import 'core/database/library_read_worker.dart';
import 'core/diagnostics/app_diagnostic_log.dart';
import 'core/controllers/library_build_task_controller.dart';
import 'core/controllers/selection_controller.dart';
import 'core/domain/models.dart';
import 'core/formats/file_format_handlers.dart';
import 'core/media/audio_waveform_service.dart';
import 'core/pet/pet_controller.dart';
import 'core/pet/pet_voice_player.dart';
import 'core/media/app_audio_controller.dart';
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
import 'ui/app_pet.dart';
import 'ui/builtin_media_page.dart';
import 'ui/collection_browser_page.dart';
import 'ui/collapse_grip_icon.dart';
import 'ui/design_tokens.dart';
import 'ui/entity_detail_sheet.dart';
import 'ui/graph_index_page.dart';
import 'ui/index_management_page.dart';
import 'ui/library_dashboard_page.dart';
import 'ui/music_page.dart';
import 'ui/media_shelf_page.dart';
import 'ui/now_playing_page.dart';
import 'ui/pet_page.dart';
import 'ui/node_preview_picker.dart';
import 'ui/settings_page.dart';
import 'ui/diagnostics_page.dart';

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
  static const _entityPageSize = 200;
  late final TextEditingController _indexPathController;

  AppDatabase? _database;
  LibraryWriteWorker? _writeWorker;
  LibraryRepository? _repository;
  LibraryReadWorker? _readWorker;
  BrowsingThumbnailController? _browsingThumbnails;
  AppAudioController? _audioController;
  LibraryBuildTaskController? _buildTasks;
  bool _loading = true;
  int? _incompatibleSchemaVersion;
  bool _resettingLocalIndex = false;
  String? _indexError;
  AppSection _section = AppSection.home;
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
  bool _petWasAudioPlaying = false;
  late final SelectionController _selection;
  late final PetController _petController;
  final PetVoicePlayer _petVoicePlayer = PetVoicePlayer();
  bool _petWasScanning = false;
  int _handledPetVoiceToken = 0;
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
    await _buildTasks?.rebuildNodePreview(nodeId);
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
        repository.directoryIndexRootForNode(node.id) != null;
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
    _indexPathController = TextEditingController();
    _selection = SelectionController();
    _petController = PetController()..addListener(_handlePetChanged);
    unawaited(_petController.restore());
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
    AppDiagnosticLog.instance.info('app_shell_dispose_started');
    _indexPathController.dispose();
    _buildTasks?.removeListener(_handleBuildTaskChanged);
    _buildTasks?.dispose();
    _petController
      ..removeListener(_handlePetChanged)
      ..dispose();
    unawaited(_petVoicePlayer.dispose());
    _taskScheduler.close();
    _thumbnailRefreshTimer?.cancel();
    _lifecycleListener.dispose();
    unawaited(_closeRuntimeResources());
    unawaited(AppDiagnosticLog.instance.close());
    super.dispose();
  }

  Future<void> _closeRuntimeResources() async {
    final audioController = _audioController;
    audioController?.removeListener(_handlePetAudioChanged);
    if (audioController != null) await audioController.close();
    await _browsingThumbnails?.close();
    final readWorker = _readWorker;
    if (readWorker != null) await readWorker.close();
    final writeWorker = _writeWorker;
    if (writeWorker != null) await writeWorker.close();
    _database?.close();
  }

  Future<void> _bootstrap() async {
    AppDiagnosticLog.instance.info('app_bootstrap_started');
    final AppDatabase database;
    try {
      database = await (widget.databaseFactory?.call() ?? AppDatabase.open());
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
    AppDiagnosticLog.instance.info('database_opened', fields: {
      'databasePath': database.databasePath,
      'storageDirectoryPath': database.storageDirectoryPath,
    });
    LibraryWriteWorker? writeWorker;
    if (database.databasePath != null) {
      try {
        writeWorker = await LibraryWriteWorker.start(
          databasePath: database.databasePath!,
        );
      } catch (error, stackTrace) {
        AppDiagnosticLog.instance.warning(
          'database_write_worker_unavailable',
          fields: {'error': '$error', 'stackTrace': '$stackTrace'},
        );
      }
    }
    final repository = LibraryRepository(
      database,
      writeWorker: writeWorker,
    );
    final browsingThumbnails = BrowsingThumbnailController(
      repository,
      onCacheChanged: (_) => _scheduleThumbnailRefresh(),
    );
    final buildTasks = LibraryBuildTaskController(repository);
    buildTasks.addListener(_handleBuildTaskChanged);
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.maximumSizeBytes =
        Platform.isAndroid ? 512 * 1024 * 1024 : 1024 * 1024 * 1024;
    // The byte limit remains authoritative. A higher item count prevents
    // small WebP thumbnails from being evicted merely because a gallery has
    // crossed an arbitrary card count.
    imageCache.maximumSize = Platform.isAndroid ? 5000 : 1200;
    final audioController = AppAudioController(
      onProgressSaved: (entityId, positionMs, durationMs) {
        repository.savePlaybackState(
          entityId: entityId,
          positionMs: positionMs,
          durationMs: durationMs,
        );
      },
      onSessionCreated: (
              {required entries,
              required currentIndex,
              sourceNodeId,
              sourceNodeName,
              required AudioPlaybackMode mode}) =>
          repository.createAudioPlaybackSession(
        entries: entries,
        currentIndex: currentIndex,
        sourceNodeId: sourceNodeId,
        sourceNodeName: sourceNodeName,
        mode: mode,
      ),
      onSessionUpdated: (
              {required id,
              currentIndex,
              positionMs,
              mode,
              shuffleRemaining,
              history,
              active}) =>
          repository.updateAudioPlaybackSession(
        id: id,
        currentIndex: currentIndex,
        positionMs: positionMs,
        mode: mode,
        shuffleRemaining: shuffleRemaining,
        history: history,
        active: active,
      ),
    );
    LibraryReadWorker? readWorker;
    if (database.databasePath != null) {
      try {
        readWorker = await LibraryReadWorker.start(
          databasePath: database.databasePath!,
          storageDirectoryPath: database.storageDirectoryPath,
        );
      } catch (_) {
        // The synchronous repository remains a functional fallback.
      }
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
    audioController.addListener(_handlePetAudioChanged);
    final activeSessions = repository.listAudioPlaybackSessions();
    final activeSession =
        activeSessions.where((session) => session.active).firstOrNull;
    if (activeSession != null) {
      await audioController.restoreSession(activeSession);
    }
    _reload();
    // Old completed builds may predate EPUB text excerpts. Repair those rows
    // after the first frame without rescanning the selected directory.
    unawaited(_repairMissingEpubPreviews(buildTasks));
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _petController.trigger(PetTrigger.appStarted),
    );
  }

  Future<void> _repairMissingEpubPreviews(
    LibraryBuildTaskController tasks,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final repaired = await tasks.repairMissingEpubMetadataPreviews();
    if (!mounted || !identical(_buildTasks, tasks) || repaired == 0) return;
    _reload(indexNodeId: _currentIndexNode?.id, invalidateBrowserCache: true);
  }

  void _handleBuildTaskChanged() {
    final tasks = _buildTasks;
    final scanning = tasks?.isRunning ?? false;
    if (scanning && !_petWasScanning) {
      _petController.trigger(PetTrigger.indexStarted);
    } else if (!scanning && _petWasScanning) {
      _petController.trigger(
        tasks?.errorMessage == null
            ? PetTrigger.indexCompleted
            : PetTrigger.indexFailed,
      );
    }
    _petWasScanning = scanning;
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

  Future<ThumbnailPreloadPage> _loadCurrentNodeThumbnailPreloadPage(
    String? afterEntityId,
  ) async {
    final repository = _repository;
    final node = _currentIndexNode;
    if (repository == null || node == null) {
      return const ThumbnailPreloadPage(paths: []);
    }
    return repository.listThumbnailPreloadPageUnderNode(
      node.id,
      afterEntityId: afterEntityId,
      recursive: _browserState.contentScope == BrowserContentScope.recursive,
    );
  }

  void _handlePetChanged() {
    final request = _petController.voiceRequest;
    if (_petController.muted) {
      unawaited(_petVoicePlayer.stop());
    } else if (request != null && request.token != _handledPetVoiceToken) {
      _handledPetVoiceToken = request.token;
      unawaited(_petVoicePlayer.play(request.asset));
    }
    if (mounted) setState(() {});
  }

  void _handlePetAudioChanged() {
    final playing = _audioController?.isPlaying ?? false;
    if (playing != _petWasAudioPlaying) {
      _petController.trigger(
        playing ? PetTrigger.musicStarted : PetTrigger.musicPaused,
      );
      _petWasAudioPlaying = playing;
    }
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
    setState(() {
      _loading = true;
      _resettingLocalIndex = true;
      _indexError = null;
    });
    try {
      _audioController?.removeListener(_handlePetAudioChanged);
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
      _database?.close();
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

    final roots = repository.listIndexRoots(sortMode: _browserState.sortMode);
    final selectedRoot = _resolveSelectedIndexRoot(roots);
    final selectedItem = _resolveSelectedItem(
      repository: repository,
      selectedIndexRoot: selectedRoot,
      indexNodeId: indexNodeId,
    );
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
      if (selectedRoot != null && cached == null) {
        final readWorker = _readWorker;
        if (readWorker != null) {
          try {
            final page = await readWorker.loadRecursivePage(
              nodeId: currentNode?.id ?? selectedRoot.id,
              sortMode: _browserState.sortMode,
              limit: _entityPageSize,
            );
            if (!mounted || generation != _reloadGeneration) return;
            uncachedPage = EntityPage(
              items: page.entities,
              hasMore: page.hasMore,
              recursiveCursor: page.recursiveCursor,
            );
          } catch (_) {
            uncachedPage = repository.listEntityPageRecursivelyUnderNode(
              currentNode?.id ?? selectedRoot.id,
              sortMode: _browserState.sortMode,
              limit: _entityPageSize,
            );
          }
        } else {
          uncachedPage = repository.listEntityPageRecursivelyUnderNode(
            currentNode?.id ?? selectedRoot.id,
            sortMode: _browserState.sortMode,
            limit: _entityPageSize,
          );
        }
      }
    } else if (currentNode == null) {
      childNodes = roots;
    } else if (cached != null) {
      childNodes = cached.childNodes;
    } else {
      final readWorker = _readWorker;
      if (readWorker != null) {
        try {
          final page = await readWorker.loadDirectPage(
            parentNodeId: currentNode.id,
            sortMode: _browserState.sortMode,
            limit: _entityPageSize,
          );
          if (!mounted || generation != _reloadGeneration) return;
          childNodes = page.childNodes;
          uncachedPage = EntityPage(
            items: page.entities,
            hasMore: page.hasMore,
          );
        } catch (_) {
          childNodes = repository.listChildNodes(
            selectedRoot!.id,
            parentId: currentNode.id,
            sortMode: _browserState.sortMode,
          );
          uncachedPage = repository.listEntityPageDirectlyUnderNode(
            currentNode.id,
            sortMode: _browserState.sortMode,
            limit: _entityPageSize,
          );
        }
      } else {
        childNodes = repository.listChildNodes(
          selectedRoot!.id,
          parentId: currentNode.id,
          sortMode: _browserState.sortMode,
        );
        uncachedPage = repository.listEntityPageDirectlyUnderNode(
          currentNode.id,
          sortMode: _browserState.sortMode,
          limit: _entityPageSize,
        );
      }
    }
    final nodePath = selectedRoot == null
        ? const <IndexNode>[]
        : repository.listNodePath(selectedRoot.id, currentNode!.id);
    final entities = selectedRoot == null
        ? const <EntityListItem>[]
        : cached?.entities ?? uncachedPage!.items;
    final entitiesHasMore = cached?.hasMore ?? uncachedPage?.hasMore ?? false;
    final recursiveCursor =
        cached?.recursiveCursor ?? uncachedPage?.recursiveCursor;
    final nodeSummaries = cached?.nodeSummaries ??
        repository.listIndexNodeSummaries(childNodes.map((node) => node.id));
    final nodePreviews = cached?.nodePreviews ??
        repository.listIndexNodePreviews(childNodes.map((node) => node.id));
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
    final detail = _detail == null ? null : repository.getEntity(_detail!.id);

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
    if (_section != AppSection.data) _reloadDashboardData();
  }

  void _reloadDashboardData() {
    final repository = _repository;
    if (repository == null) return;
    final roots = repository.listIndexRoots();
    final rootCounts = repository.countEntitiesUnderIndexNodes(
      roots.map((root) => root.id),
    );
    _refreshRecoverableIndexTasks();
    setState(() {
      _indexRoots = roots;
      _rootCounts = rootCounts;
    });
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
    final repository = _repository;
    if (repository == null) return;
    final node = pending.removeFirst();
    final key = BrowserNodeCacheKey(
      indexRootId: root.id,
      nodeId: node.id,
      sortMode: sortMode,
      recursive: false,
    );
    if (_browserNodeCache.canWarm(key)) {
      List<IndexNode> childNodes;
      List<EntityListItem> entities;
      bool hasMore;
      final readWorker = _readWorker;
      if (readWorker != null) {
        try {
          final page = await readWorker.loadDirectPage(
            parentNodeId: node.id,
            sortMode: sortMode,
            limit: _entityPageSize,
          );
          childNodes = page.childNodes;
          entities = page.entities;
          hasMore = page.hasMore;
        } catch (_) {
          childNodes = repository.listChildNodes(
            root.id,
            parentId: node.id,
            sortMode: sortMode,
          );
          final page = repository.listEntityPageDirectlyUnderNode(
            node.id,
            sortMode: sortMode,
            limit: _entityPageSize,
          );
          entities = page.items;
          hasMore = page.hasMore;
        }
      } else {
        childNodes = repository.listChildNodes(
          root.id,
          parentId: node.id,
          sortMode: sortMode,
        );
        final page = repository.listEntityPageDirectlyUnderNode(
          node.id,
          sortMode: sortMode,
          limit: _entityPageSize,
        );
        entities = page.items;
        hasMore = page.hasMore;
      }
      if (!mounted || generation != _cacheWarmupGeneration) return;
      final nodeSummaries =
          repository.listIndexNodeSummaries(childNodes.map((item) => item.id));
      final nodePreviews =
          repository.listIndexNodePreviews(childNodes.map((item) => item.id));
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
    final repository = _repository;
    final root = _selectedIndexRoot;
    final node = _currentIndexNode;
    if (repository == null ||
        root == null ||
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
      final readWorker = _readWorker;
      if (readWorker != null) {
        if (recursiveBrowsing) {
          final result = await readWorker.loadRecursivePage(
            nodeId: node.id,
            sortMode: sortMode,
            after: _recursiveEntityCursor,
            limit: _entityPageSize,
          );
          page = EntityPage(
            items: result.entities,
            hasMore: result.hasMore,
            recursiveCursor: result.recursiveCursor,
          );
        } else {
          final result = await readWorker.loadDirectPage(
            parentNodeId: node.id,
            sortMode: sortMode,
            after: after,
            limit: _entityPageSize,
          );
          page = EntityPage(items: result.entities, hasMore: result.hasMore);
        }
      } else {
        page = recursiveBrowsing
            ? repository.listEntityPageRecursivelyUnderNode(
                node.id,
                sortMode: sortMode,
                after: _recursiveEntityCursor,
                limit: _entityPageSize,
              )
            : repository.listEntityPageDirectlyUnderNode(
                node.id,
                sortMode: sortMode,
                after: after,
                limit: _entityPageSize,
              );
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

  IndexNode? _resolveSelectedItem({
    required LibraryRepository repository,
    required IndexNode? selectedIndexRoot,
    required String? indexNodeId,
  }) {
    if (selectedIndexRoot == null) return null;
    final targetId = indexNodeId ?? _selectedItem?.id;
    if (targetId == null || targetId == selectedIndexRoot.id) return null;
    final target = repository.getIndexNode(targetId);
    if (target == null) return null;
    final path = repository.listNodePath(selectedIndexRoot.id, target.id);
    return path.isEmpty ? null : target;
  }

  void _openIndexRoot(IndexNode root) {
    _exitImmersiveBrowsing();
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
    if (section == AppSection.home || section == AppSection.indexes) {
      _reloadDashboardData();
    }
    setState(() => _section = section);
  }

  void _openIndexNode(IndexNode node) {
    _exitImmersiveBrowsing();
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
        : _repository?.getIndexNode(result!.indexRootId!);
    if (result?.status == LibraryBuildStatus.completed &&
        createdIndex != null) {
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
    if (!mounted || result?.status != LibraryBuildStatus.completed) return;
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
    final tree = repository.listIndexTree(root.id);
    final selected = await showDialog<IndexNode>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('选择更新范围'),
        content: SizedBox(
          width: 440,
          height: 480,
          child: ListView(
            children: [
              _DirectoryUpdateNodeTile(
                node: IndexTreeNode(
                  item: root,
                  children: tree,
                  entityCount: repository.countEntitiesUnderIndexNode(root.id),
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
    await _refreshNodePreview(root.id, reason: 'manual_rebuild');
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
    final node = repository.getIndexNode(_selectedNodeIds.single);
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
    repository.setNodePreviewOverride(
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
    );
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
    repository.clearNodePreviewOverride(nodeId);
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
      builder: (_) => _DirectoryIndexDialog(
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
    if (result?.status != LibraryBuildStatus.completed) return;
    final targetNode = result?.indexRootId == null
        ? null
        : _repository?.getIndexNode(result!.indexRootId!);
    if (targetNode != null) _openIndexNode(targetNode);
    _reload(indexNodeId: targetNode?.id, invalidateBrowserCache: true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('索引任务完成。'),
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
    final repository = _repository;
    final audioController = _audioController;
    if (repository == null || audioController == null) return;
    repository.markOpened(entity.id);
    final detail = repository.getEntity(entity.id);
    setState(() => _detail = detail);
    final sourceNode = _currentIndexNode;
    final playbackQueue =
        entity.entityType == EntityType.audio && sourceNode != null
            ? repository.listEntitiesDirectlyUnderNode(
                sourceNode.id,
                sortMode: _browserState.sortMode,
              )
            : _entities;
    final libraryOverlay = entity.entityType == EntityType.image ||
        entity.entityType == EntityType.video;
    EntityViewerPage buildViewer() => EntityViewerPage(
          entity: entity,
          queue: playbackQueue,
          sourceNode: sourceNode,
          libraryOverlay: libraryOverlay,
          onClose: libraryOverlay ? _closeMediaOverlay : null,
          audioWaveformService: AudioWaveformService(
            AudioWaveformStore(repository.database.storageDirectoryPath),
          ),
          audioController: audioController,
          onEntityOpened: (opened) {
            repository.markOpened(opened.id);
            setState(() => _detail = repository.getEntity(opened.id));
          },
          onShowDetails: (opened) => _showEntityDetail(opened),
          onOpenDirectoryRoot: _openDirectoryRootForEntity,
          onPlaybackStateChanged: (entityId, positionMs, durationMs) {
            repository.savePlaybackState(
              entityId: entityId,
              positionMs: positionMs,
              durationMs: durationMs,
            );
          },
          onReaderStateChanged: ({
            required entityId,
            scrollOffset,
            zoomScale,
            extraStateJson,
          }) {
            repository.saveReaderState(
              entityId: entityId,
              scrollOffset: scrollOffset,
              zoomScale: zoomScale,
              extraStateJson: extraStateJson,
            );
          },
        );
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

  void _openDirectoryRootForEntity(EntityListItem item) {
    final repository = _repository;
    final rootId = repository?.getEntity(item.id)?.directoryRootId;
    if (rootId == null) return;
    final root = repository?.getIndexNode(rootId);
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
    if (_section != AppSection.home) {
      _navigateToSection(AppSection.home);
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
          AudioWaveformStore(repository.database.storageDirectoryPath),
        ),
      ),
    ));
  }

  Future<void> _showEntityDetail(EntityListItem entity) async {
    final repository = _repository;
    if (repository == null) return;
    final detail = repository.getEntity(entity.id);
    if (detail == null) return;
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
    final action = await showModalBottomSheet<_EntityMenuAction>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.checklist_rounded),
              title: const Text('选择此项'),
              onTap: () => Navigator.of(context).pop(_EntityMenuAction.select),
            ),
            if (canRegenerate)
              ListTile(
                leading: const Icon(Icons.refresh_rounded),
                title: const Text('重新生成缩略图'),
                subtitle: entity.thumbnailStatus == ThumbnailStatus.failed
                    ? const Text('重新尝试失败的缩略图任务')
                    : null,
                onTap: () => Navigator.of(context)
                    .pop(_EntityMenuAction.regenerateThumbnail),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _EntityMenuAction.select:
        _startEntitySelection(entity);
      case _EntityMenuAction.regenerateThumbnail:
        await _regenerateThumbnail(entity);
    }
  }

  Future<void> _regenerateThumbnail(EntityListItem item) async {
    final repository = _repository;
    if (repository == null || !_regeneratingThumbnailIds.add(item.id)) return;
    final entity = repository.getEntity(item.id);
    if (entity == null) {
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
      for (final nodeId in repository.listIndexNodeIdsForEntity(entity.id)) {
        await _refreshNodePreview(nodeId, reason: 'thumbnail_regenerated');
      }
      final refreshed = repository.getEntity(item.id);
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
      builder: (_) => _TextPromptDialog(
        title: '新建索引节点',
        label: '节点名称',
        confirmLabel: entityIds.isEmpty ? '创建' : '创建并加入',
      ),
    );
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    try {
      final node =
          repository.createCustomNode(parentId: parent.id, name: trimmed);
      if (entityIds.isNotEmpty) {
        repository.linkEntitiesToIndexNode(
            entityIds: entityIds, indexNodeId: node.id);
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
      builder: (_) => _TextPromptDialog(
        title: '新建自定义索引',
        label: '自定义索引名称',
        hintText: '例如：待读、银狼相关、睡前听',
        confirmLabel: entityIds.isEmpty ? '创建' : '创建并加入',
      ),
    );
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    try {
      final collection = repository.createCollectionWithEntities(
        name: trimmed,
        entityIds: entityIds,
      );
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
      builder: (_) => const _TextPromptDialog(
        title: '新建图索引',
        label: '图索引名称',
        confirmLabel: '创建',
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    final graph = repository.ensureGraphIndexRoot(name.trim());
    _browserNodeCache.clear();
    _openIndexRoot(graph);
  }

  Future<void> _showAddToCollection() async {
    final repository = _repository;
    if (repository == null ||
        (_selectedEntityIds.isEmpty && _selectedNodeIds.isEmpty)) {
      return;
    }
    final collections = repository
        .listIndexRoots()
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
      final collection = repository.createCollectionWithEntities(
        name: name.trim(),
        entityIds: _selectedEntityIds,
      );
      final previewRefreshes = <Future<void>>[
        _refreshNodePreview(
          collection.id,
          reason: 'collection_entities_added',
        ),
      ];
      for (final nodeId in _selectedNodeIds) {
        final cloned = repository.cloneIndexNodeTree(
          sourceNodeId: nodeId,
          targetParentId: collection.id,
        );
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
    final targets = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final trees = collections
              .map(
                (root) => IndexTreeNode(
                  item: root,
                  children: repository.listIndexTree(root.id),
                  entityCount: repository.countEntitiesUnderIndexNode(root.id),
                ),
              )
              .toList(growable: false);
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
                        final node = repository.createCustomNode(
                          parentId: selected.single,
                          name: name.trim(),
                        );
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
          repository.linkEntitiesToIndexNode(
            entityIds: _selectedEntityIds,
            indexNodeId: targetId,
          );
        }
        for (final nodeId in _selectedNodeIds) {
          final cloned = repository.cloneIndexNodeTree(
            sourceNodeId: nodeId,
            targetParentId: targetId,
          );
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
          (node) => _CollectionTargetNodeTile(
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
    final targets = repository
        .listIndexRoots()
        .where((node) => node.nodeType == NodeType.customIndexRoot)
        .toList(growable: false);
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
      final cloned = repository.cloneIndexNodeTree(
        sourceNodeId: source.id,
        targetParentId: targetId,
      );
      final target = repository.getIndexNode(targetId)!;
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
      repository.unlinkEntityFromIndexNode(
          entityId: entityId, indexNodeId: node.id);
    }
    for (final nodeId in _selectedNodeIds) {
      repository.deleteIndexNode(nodeId);
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
      builder: (_) => _TextPromptDialog(
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
      repository.renameIndexNode(index.id, trimmed);
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
      final report = repository.inspectDirectoryIndexDeletion(index.id);
      final force = await _confirmDirectoryIndexDeletion(report);
      if (force == null) return;
      repository.deleteDirectoryIndex(index.id, force: force);
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
    final deletesEntities = repository.willDeleteEntitiesWhenDeletingNode(
      index.id,
    );
    final message = deletesEntities
        ? '删除后会递归删除索引节点和索引关系；其中未被其它索引引用的实体数据库记录也会删除，不会删除真实源文件。确定删除“${index.name}”？'
        : '只会删除索引节点和索引关系，不会删除实体数据库记录。确定删除“${index.name}”？';
    final confirmed = await _confirm(title: '删除索引', message: message);
    if (!confirmed) return;
    final fallbackParent = index.parentId == null
        ? null
        : repository.getIndexNode(index.parentId!);
    repository.deleteIndexNode(index.id);
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

    final body = switch (_section) {
      AppSection.home => LibraryDashboardPage(
          rootsCount: _indexRoots.length,
          itemsCount: _rootCounts.values.fold<int>(0, (a, b) => a + b),
          onOpenSettings: () => setState(() => _section = AppSection.settings),
        ),
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
          onLoadThumbnailPreloadPage: _loadCurrentNodeThumbnailPreloadPage,
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
          sessions: _repository!.listAudioPlaybackSessions(),
          controller: _audioController!,
          onRestore: (session) async {
            await _audioController!.restoreSession(session, autoplay: true);
            if (mounted) setState(() {});
          },
          onPlayEntry: (session, index) async {
            await _audioController!.playSessionEntry(session, index);
            if (mounted) setState(() {});
          },
          onDelete: (session) {
            _repository!.deleteAudioPlaybackSession(session.id);
            setState(() {});
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
      AppSection.pet => PetPage(controller: _petController),
    };

    const navItems = <_FloatingNavItem>[
      _FloatingNavItem(
        section: AppSection.home,
        icon: Icons.home_outlined,
        selectedIcon: Icons.home_rounded,
        label: '首页',
      ),
      _FloatingNavItem(
        section: AppSection.data,
        icon: Icons.collections_bookmark_outlined,
        selectedIcon: Icons.collections_bookmark_rounded,
        label: '数据',
      ),
      _FloatingNavItem(
        section: AppSection.video,
        icon: Icons.movie_outlined,
        selectedIcon: Icons.movie_rounded,
        label: '视频',
      ),
      _FloatingNavItem(
        section: AppSection.gallery,
        icon: Icons.photo_library_outlined,
        selectedIcon: Icons.photo_library_rounded,
        label: '图库',
      ),
      _FloatingNavItem(
        section: AppSection.reading,
        icon: Icons.auto_stories_outlined,
        selectedIcon: Icons.auto_stories_rounded,
        label: '阅读',
      ),
      _FloatingNavItem(
        section: AppSection.music,
        icon: Icons.library_music_outlined,
        selectedIcon: Icons.library_music_rounded,
        label: '音乐',
      ),
      _FloatingNavItem(
        section: AppSection.indexes,
        icon: Icons.account_tree_outlined,
        selectedIcon: Icons.account_tree_rounded,
        label: '索引',
      ),
      _FloatingNavItem(
        section: AppSection.logs,
        icon: Icons.bug_report_outlined,
        selectedIcon: Icons.bug_report_rounded,
        label: '日志',
      ),
      _FloatingNavItem(
        section: AppSection.pet,
        icon: Icons.smart_toy_outlined,
        selectedIcon: Icons.smart_toy_rounded,
        label: '宠物',
      ),
      _FloatingNavItem(
        section: AppSection.settings,
        icon: Icons.tune_outlined,
        selectedIcon: Icons.tune_rounded,
        label: '设置',
      ),
    ];

    final desktopLayout = MediaQuery.sizeOf(context).width >= 900;
    final audioController = _audioController;
    final miniPlayer = audioController == null
        ? const SizedBox.shrink()
        : ListenableBuilder(
            listenable: audioController,
            builder: (context, _) => audioController.hasCurrent
                ? _MiniAudioPlayer(
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
              if (desktopLayout)
                SafeArea(
                  child: Row(
                    children: [
                      AppSidebar(
                        current: _section,
                        onChanged: _navigateToSection,
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
                )
              else
                Stack(
                  children: [
                    SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 92),
                        child: body,
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _FloatingGlassNavBar(
                        current: _section,
                        items: navItems,
                        onChanged: _navigateToSection,
                      ),
                    ),
                  ],
                ),
              if (_mediaOverlay case final overlay?)
                Positioned.fill(child: overlay),
              if (_petController.visible && _mediaOverlay == null)
                Positioned.fill(
                  child: AppPet(controller: _petController),
                ),
              Positioned(
                right: 0,
                bottom: desktopLayout ? 12 : 88,
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

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.label,
    required this.confirmLabel,
    this.hintText,
    this.initialValue,
  });

  final String title;
  final String label;
  final String confirmLabel;
  final String? hintText;
  final String? initialValue;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _DirectoryIndexDialog extends StatefulWidget {
  const _DirectoryIndexDialog({
    required this.source,
    required this.initialName,
  });

  final String source;
  final String initialName;

  @override
  State<_DirectoryIndexDialog> createState() => _DirectoryIndexDialogState();
}

class _DirectoryIndexDialogState extends State<_DirectoryIndexDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建目录索引'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.source,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '索引名称（可选）',
                hintText: '默认使用目录最后一级名称',
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('建立索引')),
      ],
    );
  }
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hintText,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _DirectoryUpdateNodeTile extends StatelessWidget {
  const _DirectoryUpdateNodeTile({
    required this.node,
    required this.initiallyExpanded,
    this.isRoot = false,
    required this.onSelected,
  });

  final IndexTreeNode node;
  final bool initiallyExpanded;
  final bool isRoot;
  final ValueChanged<IndexNode> onSelected;

  @override
  Widget build(BuildContext context) {
    final title = Text(
      isRoot ? '${node.item.name}（整个索引）' : node.item.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final subtitle = Text('${node.entityCount} 个实体');
    if (node.children.isEmpty) {
      return ListTile(
        dense: true,
        leading: IconButton(
          tooltip: isRoot ? '更新整个索引' : '更新此节点',
          onPressed: () => onSelected(node.item),
          icon: const Icon(Icons.sync_rounded),
        ),
        title: title,
        subtitle: subtitle,
        onTap: () => onSelected(node.item),
      );
    }
    return ExpansionTile(
      initiallyExpanded: initiallyExpanded,
      leading: IconButton(
        tooltip: isRoot ? '更新整个索引' : '更新此节点',
        onPressed: () => onSelected(node.item),
        icon: const Icon(Icons.sync_rounded),
      ),
      title: title,
      subtitle: subtitle,
      childrenPadding: const EdgeInsets.only(left: 18),
      children: node.children
          .map(
            (child) => _DirectoryUpdateNodeTile(
              node: child,
              initiallyExpanded: false,
              isRoot: false,
              onSelected: onSelected,
            ),
          )
          .toList(growable: false),
    );
  }
}

class _CollectionTargetNodeTile extends StatelessWidget {
  const _CollectionTargetNodeTile({
    required this.treeNode,
    required this.selectedIds,
    required this.initiallyExpanded,
    required this.onChanged,
  });

  final IndexTreeNode treeNode;
  final Set<String> selectedIds;
  final bool initiallyExpanded;
  final void Function(IndexNode node, bool checked) onChanged;

  @override
  Widget build(BuildContext context) {
    final node = treeNode.item;
    final selected = selectedIds.contains(node.id);
    final title = Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis);
    final subtitle = Text('${treeNode.entityCount} 个实体');
    if (treeNode.children.isEmpty) {
      return CheckboxListTile(
        key: PageStorageKey('collection-target-${node.id}'),
        dense: true,
        contentPadding: const EdgeInsets.only(left: 20, right: 8),
        value: selected,
        title: title,
        subtitle: subtitle,
        onChanged: (checked) => onChanged(node, checked ?? false),
      );
    }
    return ExpansionTile(
      key: PageStorageKey('collection-target-${node.id}'),
      initiallyExpanded: initiallyExpanded,
      leading: Checkbox(
        value: selected,
        onChanged: (checked) => onChanged(node, checked ?? false),
      ),
      title: title,
      subtitle: subtitle,
      tilePadding: const EdgeInsets.only(left: 8, right: 8),
      childrenPadding: const EdgeInsets.only(left: 22),
      children: treeNode.children
          .map(
            (child) => _CollectionTargetNodeTile(
              treeNode: child,
              selectedIds: selectedIds,
              initiallyExpanded: false,
              onChanged: onChanged,
            ),
          )
          .toList(growable: false),
    );
  }
}

class _MiniAudioPlayer extends StatelessWidget {
  const _MiniAudioPlayer({
    required this.controller,
    required this.onOpen,
    required this.collapsed,
    required this.onToggleCollapsed,
  });

  final AppAudioController controller;
  final VoidCallback onOpen;
  final bool collapsed;
  final VoidCallback onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final entity = controller.current!;
    final player = controller.player;
    final scheme = Theme.of(context).colorScheme;
    final title = p.basenameWithoutExtension(entity.title);
    final titleStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ) ??
        const TextStyle(fontWeight: FontWeight.w700);
    final titlePainter = TextPainter(
      text: TextSpan(text: title, style: titleStyle),
      textDirection: Directionality.of(context),
      maxLines: 1,
      ellipsis: '...',
    )..layout(maxWidth: 250);
    final titleWidth = titlePainter.width.clamp(72.0, 250.0).toDouble();
    final availableWidth =
        (MediaQuery.sizeOf(context).width - 8).clamp(280.0, 500.0).toDouble();
    final expandedWidth =
        (titleWidth + 224).clamp(280.0, availableWidth).toDouble();
    const attachedRadius = BorderRadius.only(
      topLeft: Radius.circular(10),
      bottomLeft: Radius.circular(10),
    );

    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignment: Alignment.centerRight,
      child: collapsed
          ? Material(
              color: scheme.surface.withValues(alpha: 0.92),
              elevation: 8,
              borderRadius: attachedRadius,
              clipBehavior: Clip.antiAlias,
              child: IconButton(
                tooltip: '展开播放器',
                onPressed: onToggleCollapsed,
                icon: const CollapseGripIcon(),
              ),
            )
          : Material(
              color: scheme.surface.withValues(alpha: 0.92),
              elevation: 8,
              borderRadius: attachedRadius,
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                width: expandedWidth,
                child: InkWell(
                  onTap: onOpen,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                    child: Row(
                      children: [
                        _MiniPlayerControl(
                          tooltip: '收起播放器',
                          onPressed: onToggleCollapsed,
                          iconWidget: const CollapseGripIcon(),
                        ),
                        Icon(Icons.graphic_eq_rounded, color: scheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: titleStyle,
                              ),
                              const SizedBox(height: 5),
                              StreamBuilder<Duration>(
                                stream: player.stream.position,
                                initialData: player.state.position,
                                builder: (context, snapshot) {
                                  final duration =
                                      player.state.duration.inMilliseconds;
                                  final position =
                                      snapshot.data?.inMilliseconds ?? 0;
                                  return LinearProgressIndicator(
                                    minHeight: 2,
                                    value: duration <= 0
                                        ? 0
                                        : (position / duration).clamp(0.0, 1.0),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        _MiniPlayerControl(
                          tooltip: '上一首',
                          onPressed: controller.previous,
                          icon: Icons.skip_previous_rounded,
                        ),
                        StreamBuilder<bool>(
                          stream: player.stream.playing,
                          initialData: player.state.playing,
                          builder: (context, snapshot) => _MiniPlayerControl(
                            tooltip: snapshot.data == true ? '暂停' : '播放',
                            onPressed: player.playOrPause,
                            filled: true,
                            icon: snapshot.data == true
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                        ),
                        _MiniPlayerControl(
                          tooltip: '下一首',
                          onPressed: controller.next,
                          icon: Icons.skip_next_rounded,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

class _MiniPlayerControl extends StatelessWidget {
  const _MiniPlayerControl({
    required this.tooltip,
    required this.onPressed,
    this.icon,
    this.iconWidget,
    this.filled = false,
  }) : assert(icon != null || iconWidget != null);

  final String tooltip;
  final VoidCallback onPressed;
  final IconData? icon;
  final Widget? iconWidget;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final button = filled
        ? IconButton.filled(
            tooltip: tooltip,
            onPressed: onPressed,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 34, height: 34),
            icon: iconWidget ?? Icon(icon, size: 19),
          )
        : IconButton(
            tooltip: tooltip,
            onPressed: onPressed,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 34, height: 34),
            visualDensity: VisualDensity.compact,
            icon: iconWidget ?? Icon(icon, size: 20),
          );
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: button,
    );
  }
}

enum _EntityMenuAction { select, regenerateThumbnail }

class _FloatingNavItem {
  const _FloatingNavItem({
    required this.section,
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final AppSection section;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

class _FloatingGlassNavBar extends StatelessWidget {
  const _FloatingGlassNavBar({
    required this.current,
    required this.items,
    required this.onChanged,
  });

  final AppSection current;
  final List<_FloatingNavItem> items;
  final ValueChanged<AppSection> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.clamp(1.0, 760.0).toDouble();
          // Keep the selected label visible on tablet-width windows even
          // after adding the debug entry to the bottom navigation.
          final showSelectedLabel = width / items.length >= 72;
          return Center(
            child: SizedBox(
              width: width,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.54),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant
                        .withValues(alpha: 0.32),
                  ),
                  boxShadow: [
                    BoxShadow(
                      blurRadius: 30,
                      offset: const Offset(0, 14),
                      color: Colors.black.withValues(alpha: 0.14),
                    ),
                  ],
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  child: Row(
                    children: [
                      for (final item in items)
                        Expanded(
                          child: _FloatingGlassNavButton(
                            item: item,
                            selected: current == item.section,
                            showLabel: showSelectedLabel,
                            onTap: () => onChanged(item.section),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FloatingGlassNavButton extends StatelessWidget {
  const _FloatingGlassNavButton({
    required this.item,
    required this.selected,
    required this.showLabel,
    required this.onTap,
  });

  final _FloatingNavItem item;
  final bool selected;
  final bool showLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = selected
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutQuart,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: EdgeInsets.symmetric(
          vertical: 9,
          horizontal: selected && showLabel ? 5 : 6,
        ),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.secondaryContainer.withValues(alpha: 0.9)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? item.selectedIcon : item.icon,
              color: foreground,
              size: 20,
            ),
            if (selected && showLabel) ...[
              const SizedBox(width: 6),
              Text(
                item.label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
