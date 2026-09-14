import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/domain/models.dart';
import '../modules/browser/original_image_budget.dart';
import '../modules/viewer/reading_position.dart';
import '../modules/viewer/viewer_sessions.dart';
import '../core/formats/file_format_handlers.dart';
import '../core/media/audio_waveform_service.dart';
import '../core/media/app_audio_controller.dart';
import '../core/media/media_player_lifecycle.dart';
import '../core/media/media_source_resolver.dart';
import '../core/readers/docx_decoder.dart';
import '../core/readers/epub_decoder.dart';
import '../core/readers/archive_session.dart';
import '../core/readers/reflow_document.dart';
import '../core/readers/reflow_text_decoder.dart';
import 'collapse_grip_icon.dart';

part 'viewer_text_reader.dart';
part 'viewer_pdf_epub_preview.dart';
part 'viewer_shared_overlays.dart';
part 'viewer_image_preview.dart';
part 'viewer_audio_player.dart';
part 'viewer_video_player.dart';
part 'viewer_chrome_ribbon.dart';
part 'viewer_document_preview.dart';

typedef PlaybackStateChanged = void Function(int positionMs, int durationMs);
typedef EntityPlaybackStateChanged = void Function(
  String entityId,
  int positionMs,
  int durationMs,
);
typedef ReaderStateChanged = void Function({
  double? scrollOffset,
  double? zoomScale,
  String? extraStateJson,
});
typedef EntityReaderStateChanged = void Function({
  required String entityId,
  double? scrollOffset,
  double? zoomScale,
  String? extraStateJson,
});
typedef MediaCompleted = Future<void> Function(Player player);

enum _PlaybackQueueMode {
  stop('播完停止', Icons.stop_circle_outlined),
  listLoop('列表循环', Icons.repeat),
  singleLoop('单项循环', Icons.repeat_one),
  shuffle('随机播放', Icons.shuffle);

  const _PlaybackQueueMode(this.label, this.icon);

  final String label;
  final IconData icon;
}

class EntityViewerPage extends StatefulWidget {
  const EntityViewerPage({
    super.key,
    required this.sessions,
    required this.entity,
    this.queue = const [],
    this.sourceNode,
    this.onEntityOpened,
    this.onShowDetails,
    this.onOpenDirectoryRoot,
    this.onPlaybackStateChanged,
    this.onReaderStateChanged,
    this.onClose,
    this.libraryOverlay = false,
    required this.audioWaveformService,
    required this.audioController,
  });

  final EntityListItem entity;
  final ViewerSessions sessions;
  final List<EntityListItem> queue;
  final IndexNode? sourceNode;
  final ValueChanged<EntityListItem>? onEntityOpened;
  final Future<void> Function(EntityListItem entity)? onShowDetails;
  final ValueChanged<EntityListItem>? onOpenDirectoryRoot;
  final EntityPlaybackStateChanged? onPlaybackStateChanged;
  final EntityReaderStateChanged? onReaderStateChanged;
  final VoidCallback? onClose;
  final bool libraryOverlay;
  final AudioWaveformService audioWaveformService;
  final AppAudioController audioController;

  @override
  State<EntityViewerPage> createState() => _EntityViewerPageState();
}

class _EntityViewerPageState extends State<EntityViewerPage> {
  late final ViewerSession _session;
  bool _closing = false;
  Future<void>? _prefetchDrain;
  final _retiredDocuments = <Future<void>>{};

  Future<void> _retireDocument(Future<ReflowDocument?> document) {
    late final Future<void> closing;
    closing = document
        .then<void>((value) => value?.close(), onError: (_, __) {})
        .whenComplete(() => _retiredDocuments.remove(closing));
    _retiredDocuments.add(closing);
    return closing;
  }

  // Keep the current original plus two predecessors and three successors.
  static const _imageWindowOffsets = <int>[0, 1, 2, 3, -1, -2];

  final MediaSourceResolver _sourceResolver = const MediaSourceResolver();
  late int _currentIndex;
  late Future<ReflowDocument?> _documentFuture;
  final _PlaybackQueueMode _queueMode = _PlaybackQueueMode.stop;
  _TextReaderSettings _textSettings = const _TextReaderSettings();
  double _lastReaderOffset = 0;
  final _readingPositions = <String, ReadingPosition>{};

  String _readerStateJson(EntityListItem entity, [String? update]) {
    var position = ReadingPosition.fromJson(update) ??
        _readingPositions[entity.id] ??
        ReadingPosition.fromJson(entity.extraStateJson);
    if (position == null) {
      try {
        final legacy = jsonDecode(entity.extraStateJson ?? '{}');
        if (legacy is Map && legacy['epubChapter'] is num) {
          position = ReadingPosition(
              sourceRevision: entity.sourceRevision,
              chapter: max(0, (legacy['epubChapter'] as num).toInt()),
              scrollOffset: max(0, entity.readerScrollOffset ?? 0));
        }
      } catch (_) {
        // Old malformed preferences are ignored, not rewritten as an error.
      }
    }
    if (position != null) _readingPositions[entity.id] = position;
    final settings = jsonDecode(_textSettings.toJson()) as Map<String, dynamic>;
    if (position != null) settings['readingPosition'] = position.toMap();
    return jsonEncode(settings);
  }

  final Random _random = Random();
  bool _chromeVisible = true;
  int? _swipePointer;
  Offset? _swipeStartPosition;
  bool _imageInspectionActive = false;
  Queue<EntityListItem> _imagePrefetchQueue = Queue<EntityListItem>();
  Map<String, EntityListItem> _activePrefetchWindow =
      <String, EntityListItem>{};
  final Set<String> _readyPrefetchIds = <String>{};
  final Set<String> _inFlightPrefetchIds = <String>{};
  final Set<String> _failedImagePrefetchIds = <String>{};
  bool _imagePrefetchRunning = false;
  final _originalBytes = <String, int>{};
  final _originalProviders = <String, FileImage>{};

  Future<int> _originalDecodeBytes(File file) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        return descriptor.width * descriptor.height * 4;
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  Future<int> _warmOriginal(FileImage provider) async {
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final loaded = Completer<int>();
    late ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      if (!loaded.isCompleted) {
        loaded.complete(info.image.width * info.image.height * 4);
      }
      info.dispose();
    }, onError: (Object error, StackTrace? stack) {
      if (!loaded.isCompleted) loaded.completeError(error, stack);
    });
    stream.addListener(listener);
    try {
      return await loaded.future;
    } finally {
      stream.removeListener(listener);
    }
  }

  void _enforceOriginalBudget() {
    final removals = originalImageEvictions(
      currentId: _current.id,
      budgetBytes: PaintingBinding.instance.imageCache.maximumSizeBytes ~/ 2,
      decodedBytes: _originalBytes,
      distances: {
        for (final entity in _activePrefetchWindow.values)
          entity.id:
              (_navigationQueue.indexWhere((item) => item.id == entity.id) -
                      _currentIndex)
                  .abs()
      },
    );
    for (final id in removals) {
      final entity = _activePrefetchWindow[id];
      if (entity != null) _evictPrefetchedImage(entity);
      _imagePrefetchQueue.removeWhere((item) => item.id == id);
    }
  }

  EntityListItem get _current => _navigationQueue[_currentIndex];
  List<EntityListItem> get _navigationQueue =>
      widget.queue.isEmpty ? [widget.entity] : widget.queue;

  bool get _usesLibraryOverlay =>
      widget.libraryOverlay && _isVisualMedia(_current);
  int? get _previousIndex => _usesLibraryOverlay
      ? _findVisualMediaIndex(_currentIndex, -1)
      : _currentIndex > 0
          ? _currentIndex - 1
          : null;
  int? get _nextIndex => _usesLibraryOverlay
      ? _findVisualMediaIndex(_currentIndex, 1)
      : _currentIndex < _navigationQueue.length - 1
          ? _currentIndex + 1
          : null;
  bool get _isTextReader {
    final kind = FileFormatRegistry.viewerKindForFormat(_current.format);
    return kind == ViewerKind.textReader ||
        kind == ViewerKind.docxReader ||
        kind == ViewerKind.epubReader;
  }

  static bool _isVisualMedia(EntityListItem entity) =>
      entity.entityType == EntityType.image ||
      entity.entityType == EntityType.video;

  int? _findVisualMediaIndex(int from, int direction) {
    for (var index = from + direction;
        index >= 0 && index < _navigationQueue.length;
        index += direction) {
      if (_isVisualMedia(_navigationQueue[index])) return index;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final queue = _navigationQueue;
    final index = queue.indexWhere((entity) => entity.id == widget.entity.id);
    _currentIndex = index < 0 ? 0 : index;
    _textSettings = _TextReaderSettings.fromJson(_current.extraStateJson);
    _documentFuture = _loadDocument();
    _session = widget.sessions.register(_closeResources);
    _scheduleImageWindowPrefetch();
    if (_current.entityType == EntityType.video) {
      widget.audioController.pause();
    }
  }

  @override
  void dispose() {
    unawaited(_session.close().catchError((Object error, StackTrace stack) {
      debugPrint('Viewer close failed: $error\n$stack');
    }));
    super.dispose();
  }

  Future<void> _closeResources() async {
    _closing = true;
    _imagePrefetchQueue.clear();
    _activePrefetchWindow.clear();
    _persistCurrentReaderState();
    await Future.wait([
      _documentFuture.then<void>((document) => document?.close(),
          onError: (_, __) {}),
      ..._retiredDocuments,
      if (_prefetchDrain != null) _prefetchDrain!,
    ]);
  }

  void _persistCurrentReaderState() {
    if (!_isTextReader) return;
    widget.onReaderStateChanged?.call(
      entityId: _current.id,
      scrollOffset: _lastReaderOffset,
      extraStateJson: _readerStateJson(_current),
    );
  }

  Future<ReflowDocument?> _loadDocument() async {
    final entity = _current;
    final viewerKind = FileFormatRegistry.viewerKindForFormat(entity.format);
    if (viewerKind != ViewerKind.textReader &&
        viewerKind != ViewerKind.docxReader &&
        viewerKind != ViewerKind.epubReader) {
      return null;
    }
    final lease = await _sourceResolver.acquireFile(entity);
    final file = lease.file;
    try {
      if (!await file.exists()) {
        throw FileSystemException(
          '文件不存在',
          _sourceResolver.displayLocation(entity),
        );
      }
      if (viewerKind == ViewerKind.docxReader) {
        final document = await openDocxDocumentSession(file);
        return ReflowDocument(
            title: document.title,
            chapters: document.chapters,
            archiveSession: document.archiveSession,
            releaseSource: lease.close);
      }
      if (viewerKind == ViewerKind.epubReader) {
        final document = await openEpubDocumentSession(file);
        return ReflowDocument(
            title: document.title,
            chapters: document.chapters,
            archiveSession: document.archiveSession,
            releaseSource: lease.close);
      }
      final document = await readReflowTextDocument(file);
      await lease.close();
      return document;
    } catch (_) {
      await lease.close();
      rethrow;
    }
  }

  void _goTo(int index) {
    if (_closing || widget.sessions.isStopped) return;
    if (index < 0 || index >= _navigationQueue.length) return;
    unawaited(_retireDocument(_documentFuture)
        .catchError((Object error, StackTrace stack) {
      debugPrint('Retired document close failed: $error\n$stack');
    }));
    _persistCurrentReaderState();
    setState(() {
      _currentIndex = index;
      _imageInspectionActive = false;
      _textSettings = _TextReaderSettings.fromJson(_current.extraStateJson);
      _documentFuture = _loadDocument();
    });
    widget.onEntityOpened?.call(_current);
    if (_current.entityType == EntityType.video) {
      widget.audioController.pause();
    }
    _scheduleImageWindowPrefetch();
  }

  void _scheduleImageWindowPrefetch() {
    if (_closing || widget.sessions.isStopped) return;
    if (_current.entityType != EntityType.image) {
      _replaceImagePrefetchWindow(const <EntityListItem>[]);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _current.entityType != EntityType.image) return;
      _replaceImagePrefetchWindow(_orderedImageWindow());
    });
  }

  List<EntityListItem> _orderedImageWindow() {
    final queue = _navigationQueue;
    final result = <EntityListItem>[];
    final seen = <String>{};
    for (final offset in _imageWindowOffsets) {
      final index = _currentIndex + offset;
      if (index < 0 || index >= queue.length) continue;
      final entity = queue[index];
      if (entity.entityType == EntityType.image && seen.add(entity.id)) {
        result.add(entity);
      }
    }
    return result;
  }

  void _replaceImagePrefetchWindow(List<EntityListItem> orderedWindow) {
    final nextWindow = <String, EntityListItem>{
      for (final entity in orderedWindow) entity.id: entity,
    };
    final leaving = _activePrefetchWindow.values
        .where((entity) => !nextWindow.containsKey(entity.id))
        .toList(growable: false);
    for (final entity in leaving) {
      _readyPrefetchIds.remove(entity.id);
      if (!_inFlightPrefetchIds.contains(entity.id)) {
        _evictPrefetchedImage(entity);
      }
    }
    _activePrefetchWindow = nextWindow;
    _imagePrefetchQueue = Queue<EntityListItem>.from(
      orderedWindow.where(
        (entity) =>
            !_readyPrefetchIds.contains(entity.id) &&
            !_inFlightPrefetchIds.contains(entity.id) &&
            !_failedImagePrefetchIds.contains(entity.id),
      ),
    );
    if (!_imagePrefetchRunning) {
      _prefetchDrain = _drainImagePrefetchQueue();
      unawaited(_prefetchDrain);
    }
  }

  Future<void> _drainImagePrefetchQueue() async {
    if (_imagePrefetchRunning) return;
    _imagePrefetchRunning = true;
    try {
      while (mounted && !_closing && _imagePrefetchQueue.isNotEmpty) {
        final entity = _imagePrefetchQueue.removeFirst();
        if (!_activePrefetchWindow.containsKey(entity.id)) continue;
        _inFlightPrefetchIds.add(entity.id);
        SourceFileLease? lease;
        try {
          lease = await _sourceResolver.acquireFile(entity);
          final file = lease.file;
          if (!mounted || _closing) return;
          if (!_activePrefetchWindow.containsKey(entity.id)) continue;
          if (await file.exists()) {
            if (!mounted || _closing) return;
            final expected = await _originalDecodeBytes(file);
            if (!mounted ||
                _closing ||
                !_activePrefetchWindow.containsKey(entity.id)) {
              continue;
            }
            _originalBytes[entity.id] = expected;
            _enforceOriginalBudget();
            if (!_originalBytes.containsKey(entity.id)) continue;
            final provider = FileImage(file);
            _originalProviders[entity.id] = provider;
            _originalBytes[entity.id] = await _warmOriginal(provider);
            if (mounted) _enforceOriginalBudget();
          } else {
            _failedImagePrefetchIds.add(entity.id);
          }
        } catch (_) {
          _failedImagePrefetchIds.add(entity.id);
        } finally {
          await lease?.close();
          _inFlightPrefetchIds.remove(entity.id);
        }
        if (_originalProviders.containsKey(entity.id) &&
            _activePrefetchWindow.containsKey(entity.id) &&
            !_failedImagePrefetchIds.contains(entity.id)) {
          _readyPrefetchIds.add(entity.id);
        } else {
          _evictPrefetchedImage(entity);
        }
      }
    } finally {
      _imagePrefetchRunning = false;
    }
  }

  void _evictPrefetchedImage(EntityListItem entity) {
    _originalBytes.remove(entity.id);
    _readyPrefetchIds.remove(entity.id);
    final provider = _originalProviders.remove(entity.id);
    if (provider != null) PaintingBinding.instance.imageCache.evict(provider);
  }

  void _startEntitySwipe(PointerDownEvent event) {
    if (_swipePointer != null) return;
    _swipePointer = event.pointer;
    _swipeStartPosition = event.position;
  }

  void _finishEntitySwipe(PointerEvent event) {
    if (_swipePointer != event.pointer) return;
    final start = _swipeStartPosition;
    _swipePointer = null;
    _swipeStartPosition = null;
    if (start == null) return;
    final delta = event.position - start;
    // Treat swipes within +/-30 degrees of the horizontal axis as navigation.
    // Listener observes the pointer without competing with vertical readers.
    if (delta.dx.abs() < 72 ||
        delta.dx.abs() < 1.7320508075688772 * delta.dy.abs()) {
      return;
    }
    if (delta.dx > 0 && _previousIndex != null) {
      _goTo(_previousIndex!);
    } else if (delta.dx < 0 && _nextIndex != null) {
      _goTo(_nextIndex!);
    }
  }

  void _cancelEntitySwipe(PointerCancelEvent event) {
    if (_swipePointer != event.pointer) return;
    _swipePointer = null;
    _swipeStartPosition = null;
  }

  void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

  void _closeViewer() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _handleMediaCompleted(Player player) async {
    switch (_queueMode) {
      case _PlaybackQueueMode.stop:
        return;
      case _PlaybackQueueMode.singleLoop:
        await player.seek(Duration.zero);
        await player.play();
        return;
      case _PlaybackQueueMode.listLoop:
        final next = _nextPlayableIndex(wrap: true);
        if (next != null) _goTo(next);
        return;
      case _PlaybackQueueMode.shuffle:
        final next = _randomPlayableIndex();
        if (next != null) _goTo(next);
        return;
    }
  }

  int? _nextPlayableIndex({required bool wrap}) {
    final queue = _navigationQueue;
    for (var i = _currentIndex + 1; i < queue.length; i++) {
      if (_isPlayableMedia(queue[i])) return i;
    }
    if (!wrap) return null;
    for (var i = 0; i < _currentIndex; i++) {
      if (_isPlayableMedia(queue[i])) return i;
    }
    return _isPlayableMedia(_current) ? _currentIndex : null;
  }

  int? _randomPlayableIndex() {
    final candidates = <int>[];
    final queue = _navigationQueue;
    for (var i = 0; i < queue.length; i++) {
      if (i != _currentIndex && _isPlayableMedia(queue[i])) {
        candidates.add(i);
      }
    }
    if (candidates.isEmpty) {
      return _isPlayableMedia(_current) ? _currentIndex : null;
    }
    return candidates[_random.nextInt(candidates.length)];
  }

  @override
  Widget build(BuildContext context) {
    final entity = _current;
    final viewerKind = FileFormatRegistry.viewerKindForFormat(entity.format);
    final libraryOverlay = _usesLibraryOverlay;
    final previousIndex = _previousIndex;
    final nextIndex = _nextIndex;
    final allowEntitySwipe =
        entity.entityType != EntityType.image || !_imageInspectionActive;
    return Focus(
      autofocus: true,
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowLeft):
              _PreviousEntityIntent(),
          SingleActivator(LogicalKeyboardKey.arrowRight): _NextEntityIntent(),
        },
        child: Actions(
          actions: {
            _PreviousEntityIntent: CallbackAction<_PreviousEntityIntent>(
              onInvoke: (_) {
                final previous = _previousIndex;
                if (previous != null) _goTo(previous);
                return null;
              },
            ),
            _NextEntityIntent: CallbackAction<_NextEntityIntent>(
              onInvoke: (_) {
                final next = _nextIndex;
                if (next != null) _goTo(next);
                return null;
              },
            ),
          },
          child: Scaffold(
            backgroundColor: libraryOverlay ? Colors.transparent : null,
            body: Stack(
              fit: StackFit.expand,
              children: [
                if (libraryOverlay) const _LibraryOverlayBackdrop(),
                Listener(
                  onPointerDown: allowEntitySwipe ? _startEntitySwipe : null,
                  onPointerUp: allowEntitySwipe ? _finishEntitySwipe : null,
                  onPointerCancel: allowEntitySwipe ? _cancelEntitySwipe : null,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _toggleChrome,
                    child: _LibraryOverlayCenterStage(
                      enabled: libraryOverlay,
                      child: switch (viewerKind) {
                        ViewerKind.pdfReader => _PdfPreview(
                            key: ValueKey(entity.id),
                            entity: entity,
                            sourceResolver: _sourceResolver,
                            onReaderStateChanged: (
                                {scrollOffset, zoomScale, extraStateJson}) {
                              _lastReaderOffset =
                                  scrollOffset ?? _lastReaderOffset;
                              widget.onReaderStateChanged?.call(
                                entityId: entity.id,
                                scrollOffset: scrollOffset,
                                zoomScale: zoomScale,
                                extraStateJson: extraStateJson ??
                                    jsonEncode({
                                      'pdfPage': (scrollOffset ?? 1).round(),
                                    }),
                              );
                            },
                          ),
                        ViewerKind.epubReader => _ReflowDocumentPreview(
                            sessions: widget.sessions,
                            key: ValueKey(entity.id),
                            documentFuture: _documentFuture,
                            initialScrollOffset: entity.readerScrollOffset,
                            initialPosition: ReadingPosition.fromJson(
                                _readerStateJson(entity)),
                            sourceRevision: entity.sourceRevision,
                            settings: _textSettings,
                            onReaderStateChanged: (
                                {scrollOffset, zoomScale, extraStateJson}) {
                              _lastReaderOffset =
                                  scrollOffset ?? _lastReaderOffset;
                              widget.onReaderStateChanged?.call(
                                entityId: entity.id,
                                scrollOffset: scrollOffset,
                                zoomScale: zoomScale,
                                extraStateJson:
                                    _readerStateJson(entity, extraStateJson),
                              );
                            },
                          ),
                        ViewerKind.docxReader => _ReflowDocumentPreview(
                            sessions: widget.sessions,
                            key: ValueKey(entity.id),
                            documentFuture: _documentFuture,
                            initialScrollOffset: entity.readerScrollOffset,
                            initialPosition: ReadingPosition.fromJson(
                                _readerStateJson(entity)),
                            sourceRevision: entity.sourceRevision,
                            settings: _textSettings,
                            onReaderStateChanged: (
                                {scrollOffset, zoomScale, extraStateJson}) {
                              widget.onReaderStateChanged?.call(
                                entityId: entity.id,
                                scrollOffset: scrollOffset,
                                zoomScale: zoomScale,
                                extraStateJson:
                                    _readerStateJson(entity, extraStateJson),
                              );
                            },
                          ),
                        _ => switch (entity.entityType) {
                            EntityType.image => _ImagePreview(
                                sessions: widget.sessions,
                                key: ValueKey(entity.id),
                                entity: entity,
                                sourceResolver: _sourceResolver,
                                transparentStage: libraryOverlay,
                                onReturnToSource: _closeViewer,
                                onPrevious: previousIndex == null
                                    ? null
                                    : () => _goTo(previousIndex),
                                onNext: nextIndex == null
                                    ? null
                                    : () => _goTo(nextIndex),
                                currentIndex: _currentIndex,
                                total: _navigationQueue.length,
                                onDirectoryRoot:
                                    widget.onOpenDirectoryRoot == null
                                        ? null
                                        : () => widget.onOpenDirectoryRoot
                                            ?.call(entity),
                                onShowDetails: widget.onShowDetails == null
                                    ? null
                                    : () async {
                                        await widget.onShowDetails!(entity);
                                      },
                                onInteractionModeChanged: (isInspecting) {
                                  if (_imageInspectionActive == isInspecting) {
                                    return;
                                  }
                                  setState(() {
                                    _imageInspectionActive = isInspecting;
                                  });
                                },
                                onReaderStateChanged: (
                                    {scrollOffset, zoomScale, extraStateJson}) {
                                  _lastReaderOffset =
                                      scrollOffset ?? _lastReaderOffset;
                                  widget.onReaderStateChanged?.call(
                                    entityId: entity.id,
                                    scrollOffset: scrollOffset,
                                    zoomScale: zoomScale,
                                    extraStateJson: null,
                                  );
                                },
                              ),
                            EntityType.text => _ReflowDocumentPreview(
                                sessions: widget.sessions,
                                key: ValueKey(entity.id),
                                documentFuture: _documentFuture,
                                initialScrollOffset: entity.readerScrollOffset,
                                initialPosition: ReadingPosition.fromJson(
                                    _readerStateJson(entity)),
                                sourceRevision: entity.sourceRevision,
                                settings: _textSettings,
                                onReaderStateChanged: (
                                    {scrollOffset, zoomScale, extraStateJson}) {
                                  widget.onReaderStateChanged?.call(
                                    entityId: entity.id,
                                    scrollOffset: scrollOffset,
                                    zoomScale: zoomScale,
                                    extraStateJson: _readerStateJson(
                                        entity, extraStateJson),
                                  );
                                },
                              ),
                            EntityType.audio => _AudioPlayerPreview(
                                key: ValueKey(entity.id),
                                entity: entity,
                                sourceResolver: _sourceResolver,
                                waveformService: widget.audioWaveformService,
                                controller: widget.audioController,
                                queue: _navigationQueue,
                                sourceNode: widget.sourceNode,
                              ),
                            EntityType.video => _VideoPlayerPreview(
                                sessions: widget.sessions,
                                key: ValueKey(entity.id),
                                entity: entity,
                                sourceResolver: _sourceResolver,
                                transparentStage: libraryOverlay,
                                onClose: _closeViewer,
                                onReturnToSource: _closeViewer,
                                onPrevious: previousIndex == null
                                    ? null
                                    : () => _goTo(previousIndex),
                                onNext: nextIndex == null
                                    ? null
                                    : () => _goTo(nextIndex),
                                onDirectoryRoot:
                                    widget.onOpenDirectoryRoot == null
                                        ? null
                                        : () => widget.onOpenDirectoryRoot
                                            ?.call(entity),
                                onShowDetails: widget.onShowDetails == null
                                    ? null
                                    : () => unawaited(
                                          widget.onShowDetails!.call(entity),
                                        ),
                                onCompleted: _handleMediaCompleted,
                                onPlaybackStateChanged:
                                    (positionMs, durationMs) {
                                  widget.onPlaybackStateChanged?.call(
                                    entity.id,
                                    positionMs,
                                    durationMs,
                                  );
                                },
                              ),
                            EntityType.document => _DocumentInfoPreview(
                                entity: entity,
                                sourceResolver: _sourceResolver,
                              ),
                          },
                      },
                    ),
                  ),
                ),
                if (_chromeVisible &&
                    entity.entityType != EntityType.image &&
                    entity.entityType != EntityType.video)
                  _ViewerChrome(
                    entity: entity,
                    currentIndex: _currentIndex,
                    total: _navigationQueue.length,
                    isTextReader: _isTextReader,
                    onBack: _closeViewer,
                    onDetails: widget.onShowDetails == null
                        ? null
                        : () => widget.onShowDetails?.call(entity),
                    onDirectoryRoot: (entity.entityType == EntityType.image ||
                                entity.entityType == EntityType.video) &&
                            widget.onOpenDirectoryRoot != null
                        ? () => widget.onOpenDirectoryRoot?.call(entity)
                        : null,
                    onPrevious: libraryOverlay || previousIndex == null
                        ? null
                        : () => _goTo(previousIndex),
                    onNext: libraryOverlay || nextIndex == null
                        ? null
                        : () => _goTo(nextIndex),
                    onTextSettings:
                        _isTextReader ? _openTextSettingsPanel : null,
                    onBookmark: _isTextReader ? _toggleReaderBookmark : null,
                    showMetadataActions: entity.entityType != EntityType.image,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _updateTextSettings(_TextReaderSettings next) {
    setState(() => _textSettings = next);
    if (_isTextReader) {
      widget.onReaderStateChanged?.call(
        entityId: _current.id,
        extraStateJson: _readerStateJson(_current),
      );
    }
  }

  void _toggleReaderBookmark() {
    final offset = _lastReaderOffset.round();
    final bookmarks = List<int>.from(_textSettings.bookmarks);
    if (bookmarks.contains(offset)) {
      bookmarks.remove(offset);
    } else {
      bookmarks.add(offset);
    }
    _updateTextSettings(_textSettings._copyWith(bookmarks: bookmarks));
  }

  Future<void> _openTextSettingsPanel() async {
    if (!_isTextReader) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(builder: (context, panelSetState) {
        void update(_TextReaderSettings value) {
          _updateTextSettings(value);
          panelSetState(() {});
        }

        final settings = _textSettings;
        Widget label(String text) => Padding(
              padding: const EdgeInsets.only(top: 18, bottom: 8),
              child: Text(text, style: Theme.of(context).textTheme.labelLarge),
            );
        return SafeArea(
            child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .72,
          child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 6, 22, 30),
              children: [
                Text('阅读设置', style: Theme.of(context).textTheme.titleLarge),
                label('字号 ${settings.fontSize.toStringAsFixed(0)}'),
                Row(children: [
                  IconButton(
                      tooltip: '减小字号',
                      onPressed: () => update(settings.withFontSizeDelta(-1)),
                      icon: const Icon(Icons.text_decrease_rounded)),
                  Expanded(
                      child: Slider(
                          min: 12,
                          max: 28,
                          divisions: 16,
                          value: settings.fontSize,
                          onChanged: (value) =>
                              update(settings._copyWith(fontSize: value)))),
                  IconButton(
                      tooltip: '增大字号',
                      onPressed: () => update(settings.withFontSizeDelta(1)),
                      icon: const Icon(Icons.text_increase_rounded)),
                ]),
                label('字体'),
                Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: List.generate(
                        _TextReaderSettings._fontFamilies.length,
                        (index) => ChoiceChip(
                              label: Text(
                                  _TextReaderSettings._fontFamilies[index]),
                              selected: settings.fontFamilyIndex == index,
                              onSelected: (_) => update(
                                  settings._copyWith(fontFamilyIndex: index)),
                            ))),
                label('行距'),
                Wrap(
                    spacing: 8,
                    children: List.generate(
                        _TextReaderSettings._lineHeights.length,
                        (index) => ChoiceChip(
                              label: Text(
                                  '${_TextReaderSettings._lineHeights[index]}'),
                              selected: settings.lineHeight ==
                                  _TextReaderSettings._lineHeights[index],
                              onSelected: (_) => update(settings._copyWith(
                                  lineHeight:
                                      _TextReaderSettings._lineHeights[index])),
                            ))),
                label('页边距'),
                Wrap(
                    spacing: 8,
                    children: List.generate(
                        _TextReaderSettings._paddings.length,
                        (index) => ChoiceChip(
                              label: Text(['窄', '默认', '宽'][index]),
                              selected: settings.padding ==
                                  _TextReaderSettings._paddings[index],
                              onSelected: (_) => update(settings._copyWith(
                                  padding:
                                      _TextReaderSettings._paddings[index])),
                            ))),
                label('主题'),
                Wrap(
                    spacing: 8,
                    children: List.generate(
                        _TextReaderSettings._backgrounds.length,
                        (index) => ChoiceChip(
                              avatar: CircleAvatar(
                                  backgroundColor:
                                      _TextReaderSettings._backgrounds[index],
                                  radius: 9),
                              label: Text(['深绿', '亮纸', '暖纸', '暗色'][index]),
                              selected: settings.backgroundIndex == index,
                              onSelected: (_) => update(
                                  settings._copyWith(backgroundIndex: index)),
                            ))),
                label('横屏阅读模式'),
                Wrap(
                    spacing: 8,
                    children: [
                      (_ReaderLayoutMode.scroll, '滚动'),
                      (_ReaderLayoutMode.book, '书页'),
                    ]
                        .map((item) => ChoiceChip(
                            label: Text(item.$2),
                            selected: settings.layoutMode == item.$1,
                            onSelected: (_) => update(
                                settings._copyWith(layoutMode: item.$1))))
                        .toList()),
              ]),
        ));
      }),
    );
  }
}
