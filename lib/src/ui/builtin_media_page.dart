import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/domain/models.dart';
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
import '../core/sources/source_handle.dart';
import 'collapse_grip_icon.dart';

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
  // Keep the current original plus two predecessors and three successors.
  static const _imageWindowOffsets = <int>[0, 1, 2, 3, -1, -2];

  final MediaSourceResolver _sourceResolver = const MediaSourceResolver();
  late int _currentIndex;
  late Future<ReflowDocument?> _documentFuture;
  final _PlaybackQueueMode _queueMode = _PlaybackQueueMode.stop;
  _TextReaderSettings _textSettings = const _TextReaderSettings();
  double _lastReaderOffset = 0;
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
    _configureImageCacheBudget();
    _scheduleImageWindowPrefetch();
    if (_current.entityType == EntityType.video) {
      widget.audioController.pause();
    }
  }

  @override
  void dispose() {
    _persistCurrentReaderState();
    super.dispose();
  }

  void _persistCurrentReaderState() {
    if (!_isTextReader) return;
    widget.onReaderStateChanged?.call(
      entityId: _current.id,
      scrollOffset: _lastReaderOffset,
      extraStateJson: _textSettings.toJson(),
    );
  }

  Future<ReflowDocument?> _loadDocument() async {
    final viewerKind = FileFormatRegistry.viewerKindForFormat(_current.format);
    if (viewerKind != ViewerKind.textReader &&
        viewerKind != ViewerKind.docxReader &&
        viewerKind != ViewerKind.epubReader) {
      return null;
    }
    final file = await _sourceResolver.localFileAsync(_current);
    if (!await file.exists()) {
      throw FileSystemException(
        '文件不存在',
        _sourceResolver.displayLocation(_current),
      );
    }
    if (viewerKind == ViewerKind.docxReader) {
      return openDocxDocumentSession(file);
    }
    if (viewerKind == ViewerKind.epubReader) {
      return openEpubDocumentSession(file);
    }
    return readReflowTextDocument(file);
  }

  void _goTo(int index) {
    if (index < 0 || index >= _navigationQueue.length) return;
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
    unawaited(_drainImagePrefetchQueue());
  }

  Future<void> _drainImagePrefetchQueue() async {
    if (_imagePrefetchRunning) return;
    _imagePrefetchRunning = true;
    try {
      while (mounted && _imagePrefetchQueue.isNotEmpty) {
        final entity = _imagePrefetchQueue.removeFirst();
        if (!_activePrefetchWindow.containsKey(entity.id)) continue;
        _inFlightPrefetchIds.add(entity.id);
        final file = await _sourceResolver.localFileAsync(entity);
        try {
          if (file.existsSync()) {
            if (!mounted) return;
            final provider = FileImage(file);
            await precacheImage(
              provider,
              context,
              onError: (_, __) {
                _failedImagePrefetchIds.add(entity.id);
                _readyPrefetchIds.remove(entity.id);
                PaintingBinding.instance.imageCache.evict(provider);
              },
            );
          }
        } finally {
          _inFlightPrefetchIds.remove(entity.id);
        }
        if (_activePrefetchWindow.containsKey(entity.id) &&
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
    if (SourceHandle.parse(entity.path).isAndroidContentUri) return;
    final file = _sourceResolver.localFile(entity);
    PaintingBinding.instance.imageCache.evict(FileImage(file));
  }

  void _configureImageCacheBudget() {
    final imageCache = PaintingBinding.instance.imageCache;
    final desiredBytes =
        Platform.isAndroid ? 512 * 1024 * 1024 : 1024 * 1024 * 1024;
    if (imageCache.maximumSizeBytes < desiredBytes) {
      imageCache.maximumSizeBytes = desiredBytes;
    }
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
                            key: ValueKey(entity.id),
                            documentFuture: _documentFuture,
                            initialScrollOffset: entity.readerScrollOffset,
                            settings: _textSettings,
                            onReaderStateChanged: (
                                {scrollOffset, zoomScale, extraStateJson}) {
                              _lastReaderOffset =
                                  scrollOffset ?? _lastReaderOffset;
                              widget.onReaderStateChanged?.call(
                                entityId: entity.id,
                                scrollOffset: scrollOffset,
                                zoomScale: zoomScale,
                                extraStateJson: _textSettings.toJson(),
                              );
                            },
                          ),
                        ViewerKind.docxReader => _ReflowDocumentPreview(
                            key: ValueKey(entity.id),
                            documentFuture: _documentFuture,
                            initialScrollOffset: entity.readerScrollOffset,
                            settings: _textSettings,
                            onReaderStateChanged: (
                                {scrollOffset, zoomScale, extraStateJson}) {
                              widget.onReaderStateChanged?.call(
                                entityId: entity.id,
                                scrollOffset: scrollOffset,
                                zoomScale: zoomScale,
                                extraStateJson: _textSettings.toJson(),
                              );
                            },
                          ),
                        _ => switch (entity.entityType) {
                            EntityType.image => _ImagePreview(
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
                                key: ValueKey(entity.id),
                                documentFuture: _documentFuture,
                                initialScrollOffset: entity.readerScrollOffset,
                                settings: _textSettings,
                                onReaderStateChanged: (
                                    {scrollOffset, zoomScale, extraStateJson}) {
                                  widget.onReaderStateChanged?.call(
                                    entityId: entity.id,
                                    scrollOffset: scrollOffset,
                                    zoomScale: zoomScale,
                                    extraStateJson: _textSettings.toJson(),
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
        extraStateJson: _textSettings.toJson(),
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

enum _ReaderLayoutMode { scroll, book }

class _PreviousEntityIntent extends Intent {
  const _PreviousEntityIntent();
}

class _NextEntityIntent extends Intent {
  const _NextEntityIntent();
}

class _TextReaderSettings {
  const _TextReaderSettings({
    this.fontSize = 16,
    this.lineHeight = 1.65,
    this.padding = 24,
    this.backgroundIndex = 0,
    this.fontFamilyIndex = 0,
    this.layoutMode = _ReaderLayoutMode.scroll,
    this.bookmarks = const [],
  });

  final double fontSize;
  final double lineHeight;
  final double padding;
  final int backgroundIndex;
  final int fontFamilyIndex;
  final _ReaderLayoutMode layoutMode;
  final List<int> bookmarks;

  static const _lineHeights = [1.45, 1.65, 1.9];
  static const _paddings = [16.0, 24.0, 36.0];
  static const _fontFamilies = ['KaiTi', 'SimSun', 'Microsoft YaHei'];
  static const _backgrounds = [
    // Keep the default reader surface visually continuous with the gallery.
    Color(0xff1f2621),
    Color(0xffffffff),
    Color(0xfff7f0df),
    Color(0xff181b1a),
  ];
  static const _foregrounds = [
    Color(0xffe7e2d4),
    Color(0xff1f2520),
    Color(0xff3f3323),
    Color(0xffe6ece5),
  ];

  factory _TextReaderSettings.fromJson(String? json) {
    if (json == null || json.trim().isEmpty) {
      return const _TextReaderSettings();
    }
    try {
      final value = jsonDecode(json);
      if (value is! Map<String, Object?>) {
        return const _TextReaderSettings();
      }
      return _TextReaderSettings(
        fontSize: _clampDouble(value['fontSize'], 16, 12, 28),
        lineHeight: _knownDouble(value['lineHeight'], _lineHeights, 1.65),
        padding: _knownDouble(value['padding'], _paddings, 24),
        backgroundIndex: _clampIndex(value['backgroundIndex'], _backgrounds),
        fontFamilyIndex: _clampIndex(value['fontFamilyIndex'], _fontFamilies),
        layoutMode: _ReaderLayoutMode.values.firstWhere(
          (mode) => mode.name == value['layoutMode'],
          orElse: () => _ReaderLayoutMode.scroll,
        ),
        bookmarks: (value['bookmarks'] as List? ?? const [])
            .whereType<num>()
            .map((item) => item.round())
            .toList(),
      );
    } catch (_) {
      return const _TextReaderSettings();
    }
  }

  String toJson() {
    return jsonEncode({
      'fontSize': fontSize,
      'lineHeight': lineHeight,
      'padding': padding,
      'backgroundIndex': backgroundIndex,
      'fontFamilyIndex': fontFamilyIndex,
      'layoutMode': layoutMode.name,
      'bookmarks': bookmarks,
    });
  }

  _TextReaderSettings withFontSizeDelta(double delta) {
    return _TextReaderSettings(
      fontSize: (fontSize + delta).clamp(12, 28).toDouble(),
      lineHeight: lineHeight,
      padding: padding,
      backgroundIndex: backgroundIndex,
      fontFamilyIndex: fontFamilyIndex,
      layoutMode: layoutMode,
      bookmarks: bookmarks,
    );
  }

  Color get background => _backgrounds[backgroundIndex];
  Color get foreground => _foregrounds[backgroundIndex];
  String get fontFamily => _fontFamilies[fontFamilyIndex];
  bool get isDark => backgroundIndex == 0 || backgroundIndex == 3;

  _TextReaderSettings _copyWith({
    double? lineHeight,
    double? padding,
    int? backgroundIndex,
    int? fontFamilyIndex,
    _ReaderLayoutMode? layoutMode,
    List<int>? bookmarks,
    double? fontSize,
  }) {
    return _TextReaderSettings(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      padding: padding ?? this.padding,
      backgroundIndex: backgroundIndex ?? this.backgroundIndex,
      fontFamilyIndex: fontFamilyIndex ?? this.fontFamilyIndex,
      layoutMode: layoutMode ?? this.layoutMode,
      bookmarks: bookmarks ?? this.bookmarks,
    );
  }
}

double _clampDouble(
  Object? value,
  double fallback,
  double min,
  double max,
) {
  final number = value is num ? value.toDouble() : fallback;
  return number.clamp(min, max).toDouble();
}

double _knownDouble(Object? value, List<double> allowed, double fallback) {
  final number = value is num ? value.toDouble() : fallback;
  return allowed.contains(number) ? number : fallback;
}

int _clampIndex(Object? value, List<Object> list) {
  final index = value is int ? value : 0;
  if (index < 0 || index >= list.length) return 0;
  return index;
}

class _PdfPreview extends StatefulWidget {
  const _PdfPreview({
    super.key,
    required this.entity,
    required this.sourceResolver,
    required this.onReaderStateChanged,
  });

  final EntityListItem entity;
  final MediaSourceResolver sourceResolver;
  final ReaderStateChanged onReaderStateChanged;

  @override
  State<_PdfPreview> createState() => _PdfPreviewState();
}

class _EpubPreview extends StatefulWidget {
  const _EpubPreview({
    required this.entity,
    required this.sourceResolver,
    required this.onReaderStateChanged,
  });

  final EntityListItem entity;
  final MediaSourceResolver sourceResolver;
  final void Function(int chapter, double scrollOffset) onReaderStateChanged;

  @override
  State<_EpubPreview> createState() => _EpubPreviewState();
}

class _EpubPreviewState extends State<_EpubPreview> {
  late Future<EpubBook> _bookFuture;
  late ScrollController _scrollController;
  Timer? _saveDebounce;
  late int _chapterIndex;

  @override
  void initState() {
    super.initState();
    _chapterIndex = _restoredEpubChapter(widget.entity);
    _bookFuture = readEpubBook(widget.sourceResolver.localFile(widget.entity));
    _scrollController = ScrollController(
      initialScrollOffset: widget.entity.readerScrollOffset ?? 0,
    )..addListener(_queueStateSave);
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _persistState();
    _scrollController
      ..removeListener(_queueStateSave)
      ..dispose();
    super.dispose();
  }

  void _queueStateSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), _persistState);
  }

  void _persistState() {
    final offset =
        _scrollController.hasClients ? _scrollController.offset : 0.0;
    widget.onReaderStateChanged(_chapterIndex, offset);
  }

  void _selectChapter(int chapter) {
    if (chapter == _chapterIndex) return;
    _persistState();
    _scrollController
      ..removeListener(_queueStateSave)
      ..dispose();
    _scrollController = ScrollController()..addListener(_queueStateSave);
    setState(() => _chapterIndex = chapter);
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.sourceResolver.localFile(widget.entity);
    if (!file.existsSync()) {
      return _MissingSourceNotice(
        path: widget.sourceResolver.displayLocation(widget.entity),
      );
    }
    return FutureBuilder<EpubBook>(
      future: _bookFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('无法读取 EPUB：${snapshot.error}'),
            ),
          );
        }
        final book = snapshot.data!;
        final chapterIndex =
            _chapterIndex.clamp(0, book.chapters.length - 1).toInt();
        final chapter = book.chapters[chapterIndex];
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  const SizedBox(width: 12),
                  DropdownButton<int>(
                    value: chapterIndex,
                    items: [
                      for (var index = 0; index < book.chapters.length; index++)
                        DropdownMenuItem(
                          value: index,
                          child: Text('章节 ${index + 1}'),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) _selectChapter(value);
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Scrollbar(
                controller: _scrollController,
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(chapter.title,
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 20),
                      SelectableText(
                        chapter.text,
                        style: Theme.of(context)
                            .textTheme
                            .bodyLarge
                            ?.copyWith(height: 1.75),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

int _restoredEpubChapter(EntityListItem entity) {
  final rawState = entity.extraStateJson;
  if (rawState != null) {
    try {
      final decoded = jsonDecode(rawState);
      if (decoded is Map<String, dynamic>) {
        final stored = decoded['epubChapter'];
        if (stored is num && stored >= 0) return stored.round();
      }
    } catch (_) {
      // Ignore malformed legacy state and reopen at the first chapter.
    }
  }
  return 0;
}

class _PdfPreviewState extends State<_PdfPreview> {
  PdfViewerController? _controller;
  late final Future<File> _sourceFile;
  late int _currentPage;
  int? _pageCount;
  late final Set<int> _bookmarks;

  @override
  void initState() {
    super.initState();
    _currentPage = _restoredPdfPage(widget.entity);
    _bookmarks = _restoredPdfBookmarks(widget.entity);
    _sourceFile = widget.sourceResolver.localFileAsync(widget.entity);
  }

  @override
  void dispose() {
    _persistReaderState();
    super.dispose();
  }

  void _persistReaderState() {
    widget.onReaderStateChanged(
      scrollOffset: _currentPage.toDouble(),
      zoomScale: _controller?.isReady == true ? _controller!.currentZoom : null,
      extraStateJson: jsonEncode({
        'pdfPage': _currentPage,
        'pdfBookmarks': _bookmarks.toList()..sort()
      }),
    );
  }

  void _toggleBookmark() {
    setState(() {
      if (!_bookmarks.add(_currentPage)) _bookmarks.remove(_currentPage);
    });
    _persistReaderState();
  }

  void _onPageChanged(int? pageNumber) {
    if (pageNumber == null || pageNumber < 1) return;
    setState(() => _currentPage = pageNumber);
    _persistReaderState();
  }

  Future<void> _goToPage(int page) async {
    final controller = _controller;
    final count = _pageCount;
    if (controller == null || count == null) return;
    await controller.goToPage(pageNumber: page.clamp(1, count));
  }

  Future<void> _promptPage() async {
    final controller = TextEditingController(text: '$_currentPage');
    final result = await showDialog<int>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('跳转页码'),
              content: TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  onSubmitted: (value) =>
                      Navigator.pop(context, int.tryParse(value))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, int.tryParse(controller.text)),
                    child: const Text('跳转'))
              ],
            ));
    controller.dispose();
    if (result != null) await _goToPage(result);
  }

  Future<void> _changePdfZoom(bool increase) async {
    final controller = _controller;
    if (controller == null || !controller.isReady) return;
    final zoom = increase
        ? controller.getNextZoom(loop: false)
        : controller.getPreviousZoom(loop: false);
    await controller.zoomOnLocalPosition(
      localPosition: controller.viewSize.center(Offset.zero),
      newZoom: zoom,
    );
    _persistReaderState();
  }

  Future<void> _resetPdfZoom() async {
    final controller = _controller;
    if (controller == null || !controller.isReady) return;
    final zoom = controller.alternativeFitScale ?? controller.minScale;
    await controller.zoomOnLocalPosition(
      localPosition: controller.viewSize.center(Offset.zero),
      newZoom: zoom,
    );
    _persistReaderState();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File>(
      future: _sourceFile,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError ||
            !snapshot.hasData ||
            !snapshot.data!.existsSync()) {
          return _MissingSourceNotice(
            path:
                '${snapshot.error ?? widget.sourceResolver.displayLocation(widget.entity)}',
          );
        }
        return _buildLoaded(context, snapshot.data!);
      },
    );
  }

  Widget _buildLoaded(BuildContext context, File file) {
    final pageLabel = _pageCount == null
        ? '第 $_currentPage 页'
        : '第 $_currentPage / $_pageCount 页';
    return ColoredBox(
        color: const Color(0xff102c28),
        child: Stack(
          children: [
            PdfViewer.file(
              file.path,
              initialPageNumber: _currentPage,
              params: PdfViewerParams(
                onPageChanged: _onPageChanged,
                onViewerReady: (document, controller) {
                  _controller = controller;
                  if (!mounted) return;
                  setState(() => _pageCount = document.pages.length);
                },
              ),
            ),
            Positioned(
              right: 16,
              bottom: 16,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surface
                      .withValues(alpha: 0.88),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                      tooltip: '上一页',
                      onPressed: _currentPage > 1
                          ? () => _goToPage(_currentPage - 1)
                          : null,
                      icon: const Icon(Icons.chevron_left_rounded)),
                  TextButton(
                      onPressed: _promptPage,
                      child: Text(pageLabel,
                          style: Theme.of(context).textTheme.labelMedium)),
                  IconButton(
                      tooltip: '下一页',
                      onPressed:
                          _pageCount != null && _currentPage < _pageCount!
                              ? () => _goToPage(_currentPage + 1)
                              : null,
                      icon: const Icon(Icons.chevron_right_rounded)),
                  IconButton(
                      tooltip: '缩小',
                      onPressed: () => _changePdfZoom(false),
                      icon: const Icon(Icons.zoom_out_rounded)),
                  IconButton(
                      tooltip: '适应页面',
                      onPressed: _resetPdfZoom,
                      icon: const Icon(Icons.fit_screen_rounded)),
                  IconButton(
                      tooltip: '放大',
                      onPressed: () => _changePdfZoom(true),
                      icon: const Icon(Icons.zoom_in_rounded)),
                  IconButton(
                      tooltip:
                          _bookmarks.contains(_currentPage) ? '移除书签' : '添加书签',
                      onPressed: _toggleBookmark,
                      icon: Icon(_bookmarks.contains(_currentPage)
                          ? Icons.bookmark_rounded
                          : Icons.bookmark_add_outlined)),
                  if (_bookmarks.isNotEmpty)
                    PopupMenuButton<int>(
                      tooltip: '书签列表',
                      icon: const Icon(Icons.bookmarks_outlined),
                      onSelected: _goToPage,
                      itemBuilder: (context) {
                        final pages = _bookmarks.toList()..sort();
                        return pages
                            .map((page) => PopupMenuItem(
                                value: page, child: Text('第 $page 页')))
                            .toList();
                      },
                    ),
                ]),
              ),
            ),
          ],
        ));
  }
}

int _restoredPdfPage(EntityListItem entity) {
  final rawState = entity.extraStateJson;
  if (rawState != null) {
    try {
      final decoded = jsonDecode(rawState);
      if (decoded is Map<String, dynamic>) {
        final stored = decoded['pdfPage'];
        if (stored is num && stored >= 1) return stored.round();
      }
    } catch (_) {
      // A malformed prior state must not prevent the document from opening.
    }
  }
  final legacyPage = entity.readerScrollOffset?.round() ?? 1;
  return max(1, legacyPage);
}

Set<int> _restoredPdfBookmarks(EntityListItem entity) {
  try {
    final value = jsonDecode(entity.extraStateJson ?? '{}');
    return value is Map && value['pdfBookmarks'] is List
        ? (value['pdfBookmarks'] as List)
            .whereType<num>()
            .map((item) => item.toInt())
            .toSet()
        : <int>{};
  } catch (_) {
    return <int>{};
  }
}

class _MissingSourceNotice extends StatelessWidget {
  const _MissingSourceNotice({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text('文件不存在：$path', textAlign: TextAlign.center),
      ),
    );
  }
}

class _LibraryOverlayBackdrop extends StatelessWidget {
  const _LibraryOverlayBackdrop();

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: ColoredBox(color: Color(0xc9000000)),
    );
  }
}

class _LibraryOverlayCenterStage extends StatelessWidget {
  const _LibraryOverlayCenterStage({
    required this.enabled,
    required this.child,
  });

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    // The image starts with a contain fit, but its interactive canvas must
    // remain viewport-sized so zooming is never clipped to that initial fit.
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 1.2,
                colors: [Color(0x00000000), Color(0x4a000000)],
                stops: [.62, 1],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ImagePreview extends StatefulWidget {
  const _ImagePreview({
    super.key,
    required this.entity,
    required this.sourceResolver,
    this.transparentStage = false,
    this.onReturnToSource,
    this.onPrevious,
    this.onNext,
    required this.currentIndex,
    required this.total,
    this.onDirectoryRoot,
    this.onShowDetails,
    required this.onInteractionModeChanged,
    required this.onReaderStateChanged,
  });

  final EntityListItem entity;
  final MediaSourceResolver sourceResolver;
  final bool transparentStage;
  final VoidCallback? onReturnToSource;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final int currentIndex;
  final int total;
  final VoidCallback? onDirectoryRoot;
  final Future<void> Function()? onShowDetails;
  final ValueChanged<bool> onInteractionModeChanged;
  final ReaderStateChanged? onReaderStateChanged;

  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview> {
  late final TransformationController _controller;
  late final Future<File> _sourceFile;
  int _backgroundIndex = 0;
  bool _isInspecting = false;
  bool _toolbarCollapsed = false;

  static const _backgrounds = [
    Colors.black,
    Colors.white,
    Color(0xff444444),
  ];

  @override
  void initState() {
    super.initState();
    _controller = TransformationController();
    _sourceFile = widget.sourceResolver.localFileAsync(widget.entity);
  }

  @override
  void dispose() {
    widget.onReaderStateChanged
        ?.call(zoomScale: _controller.value.getMaxScaleOnAxis());
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final location = widget.sourceResolver.displayLocation(widget.entity);
    return FutureBuilder<File>(
      future: _sourceFile,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError ||
            !snapshot.hasData ||
            !snapshot.data!.existsSync()) {
          return _ImageErrorMessage(
            title: '图片路径失效',
            path: '${snapshot.error ?? location}',
          );
        }
        return _buildLoaded(context, snapshot.data!, location);
      },
    );
  }

  Widget _buildLoaded(BuildContext context, File file, String location) {
    Widget toolbarButton({
      required String tooltip,
      required VoidCallback? onPressed,
      IconData? icon,
      Widget? iconWidget,
    }) =>
        IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          icon: iconWidget ?? Icon(icon!),
          iconSize: 24,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
        );
    return Stack(
      children: [
        ColoredBox(
          color: widget.transparentStage
              ? Colors.transparent
              : _backgrounds[_backgroundIndex],
          child: Center(
            child: GestureDetector(
              onDoubleTapDown: (details) =>
                  _toggleInspectionMode(details.localPosition),
              child: InteractiveViewer(
                transformationController: _controller,
                panEnabled: _isInspecting,
                scaleEnabled: _isInspecting,
                minScale: 1,
                maxScale: 6,
                child: SizedBox.expand(
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: Image(
                      image: FileImage(file),
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.high,
                      errorBuilder: (_, __, ___) => _ImageErrorMessage(
                        title: '图片读取失败',
                        path: location,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: 0,
          // Keep the viewer drawer directly above the app-shell music drawer.
          // It remains local to this image preview and disappears with it.
          bottom: MediaQuery.sizeOf(context).width >= 900 ? 84 : 160,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface.withValues(
                    alpha: 0.86,
                  ),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(10),
                bottomLeft: Radius.circular(10),
              ),
              boxShadow: const [
                BoxShadow(blurRadius: 10, color: Color(0x33000000)),
              ],
            ),
            child: SizedBox(
              height: 48,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  toolbarButton(
                    tooltip: _toolbarCollapsed ? '展开工具栏' : '收起工具栏',
                    onPressed: () => setState(
                      () => _toolbarCollapsed = !_toolbarCollapsed,
                    ),
                    iconWidget: const CollapseGripIcon(),
                  ),
                  if (!_toolbarCollapsed) ...[
                    if (widget.onReturnToSource != null)
                      toolbarButton(
                        tooltip: '返回所在节点',
                        onPressed: widget.onReturnToSource,
                        icon: Icons.arrow_back_rounded,
                      ),
                    if (widget.onDirectoryRoot != null)
                      toolbarButton(
                        tooltip: '返回目录索引',
                        onPressed: widget.onDirectoryRoot,
                        icon: Icons.account_tree_outlined,
                      ),
                    if (widget.onShowDetails != null)
                      toolbarButton(
                        tooltip: '详情',
                        onPressed: () => widget.onShowDetails?.call(),
                        icon: Icons.info_outline_rounded,
                      ),
                    SizedBox(
                      width: 48,
                      child: Center(
                        child:
                            Text('${widget.currentIndex + 1}/${widget.total}'),
                      ),
                    ),
                    if (!widget.transparentStage)
                      toolbarButton(
                        tooltip: '切换背景',
                        onPressed: _nextBackground,
                        icon: Icons.contrast,
                      ),
                    if (widget.onPrevious != null)
                      toolbarButton(
                        tooltip: '上一项',
                        onPressed: widget.onPrevious,
                        icon: Icons.skip_previous_rounded,
                      ),
                    if (widget.onNext != null)
                      toolbarButton(
                        tooltip: '下一项',
                        onPressed: widget.onNext,
                        icon: Icons.skip_next_rounded,
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _nextBackground() {
    setState(() {
      _backgroundIndex = (_backgroundIndex + 1) % _backgrounds.length;
    });
  }

  void _toggleInspectionMode(Offset localPosition) {
    if (_isInspecting) {
      _exitInspectionMode();
      return;
    }
    const targetScale = 2.5;
    setState(() {
      _isInspecting = true;
      _controller.value = Matrix4.identity()
        ..translateByDouble(
          -localPosition.dx * (targetScale - 1),
          -localPosition.dy * (targetScale - 1),
          0,
          1,
        )
        ..scaleByDouble(targetScale, targetScale, 1, 1);
    });
    widget.onInteractionModeChanged(true);
  }

  void _exitInspectionMode() {
    if (!_isInspecting) return;
    setState(() {
      _isInspecting = false;
      _controller.value = Matrix4.identity();
    });
    widget.onInteractionModeChanged(false);
  }
}

class _ImageErrorMessage extends StatelessWidget {
  const _ImageErrorMessage({
    required this.title,
    required this.path,
  });

  final String title;
  final String path;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  path,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AudioPlayerPreview extends StatefulWidget {
  const _AudioPlayerPreview({
    super.key,
    required this.entity,
    required this.sourceResolver,
    required this.waveformService,
    required this.controller,
    required this.queue,
    this.sourceNode,
  });

  final EntityListItem entity;
  final MediaSourceResolver sourceResolver;
  final AudioWaveformService waveformService;
  final AppAudioController controller;
  final List<EntityListItem> queue;
  final IndexNode? sourceNode;

  @override
  State<_AudioPlayerPreview> createState() => _AudioPlayerPreviewState();
}

class _AudioPlayerPreviewState extends State<_AudioPlayerPreview> {
  late Future<Uint8List?> _waveformFuture;
  final AudioTimelineScrubController _scrubController =
      AudioTimelineScrubController();
  String? _waveformEntityId;

  @override
  void initState() {
    super.initState();
    _syncWaveform(widget.entity);
    widget.controller.addListener(_handlePlaybackChange);
    widget.controller.open(
      widget.entity,
      contextQueue: widget.queue,
      sourceNodeId: widget.sourceNode?.id,
      sourceNodeName: widget.sourceNode?.name,
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handlePlaybackChange);
    widget.controller.saveProgress();
    _scrubController.dispose();
    super.dispose();
  }

  void _handlePlaybackChange() {
    final current = widget.controller.current;
    if (current != null && current.id != _waveformEntityId && mounted) {
      _scrubController.clear();
      setState(() => _syncWaveform(current));
    }
  }

  void _syncWaveform(EntityListItem entity) {
    _waveformEntityId = entity.id;
    _waveformFuture = widget.waveformService.ensure(
      path: entity.path,
      fingerprint: entity.hash,
      durationMs: entity.durationMs,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final loadError = widget.controller.error;
        if (loadError != null) {
          return Center(child: Text('内置播放器打开失败：$loadError'));
        }
        final current = widget.controller.current ?? widget.entity;
        return SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final horizontalPadding =
                  constraints.maxWidth >= 720 ? 72.0 : 24.0;
              return Stack(
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 920),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          16,
                          32,
                          16,
                          174,
                        ),
                        child: AudioNowPlayingPanel(
                          entity: current,
                          player: widget.controller.player,
                          waveformFuture: _waveformFuture,
                          scrubController: _scrubController,
                        ),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                          horizontalPadding, 0, horizontalPadding, 18),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 920),
                        child: AudioPlaybackDeck(
                          player: widget.controller.player,
                          controller: widget.controller,
                          waveformFuture: _waveformFuture,
                          scrubController: _scrubController,
                          onPrevious: widget.controller.previous,
                          onNext: widget.controller.next,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class AudioTimelineScrubController extends ChangeNotifier {
  double? _previewRatio;

  double? get previewRatio => _previewRatio;

  void update(double ratio) {
    final normalized = ratio.clamp(0.0, 1.0);
    if (_previewRatio == normalized) return;
    _previewRatio = normalized;
    notifyListeners();
  }

  void clear() {
    if (_previewRatio == null) return;
    _previewRatio = null;
    notifyListeners();
  }
}

class AudioNowPlayingPanel extends StatelessWidget {
  const AudioNowPlayingPanel({
    super.key,
    required this.entity,
    required this.player,
    required this.waveformFuture,
    required this.scrubController,
  });

  final EntityListItem entity;
  final Player player;
  final Future<Uint8List?> waveformFuture;
  final AudioTimelineScrubController scrubController;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.graphic_eq_rounded, color: scheme.primary, size: 23),
            const SizedBox(width: 10),
            Text(
              entity.format.toUpperCase(),
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(width: 8),
            Text('音频', style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          entity.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.22,
              ),
        ),
        const SizedBox(height: 24),
        _AudioWaveformSeekBar(
          player: player,
          waveformFuture: waveformFuture,
          scrubController: scrubController,
        ),
      ],
    );
  }
}

class AudioPlaybackDeck extends StatefulWidget {
  const AudioPlaybackDeck({
    super.key,
    required this.player,
    required this.waveformFuture,
    required this.scrubController,
    this.controller,
    this.onPrevious,
    this.onNext,
  });

  final Player player;
  final Future<Uint8List?> waveformFuture;
  final AudioTimelineScrubController scrubController;
  final AppAudioController? controller;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  State<AudioPlaybackDeck> createState() => _AudioPlaybackDeckState();
}

class _AudioPlaybackDeckState extends State<AudioPlaybackDeck> {
  bool _showVolume = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 9, 16, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _RibbonProgressSeekBar(
              player: widget.player,
              controller: widget.controller,
              waveformFuture: widget.waveformFuture,
              scrubController: widget.scrubController,
            ),
            const SizedBox(height: 2),
            _PlaybackTimelineLabels(
              player: widget.player,
              controller: widget.controller,
            ),
            if (_showVolume)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 4),
                child: _AudioVolumeSlider(player: widget.player),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _compactIconButton(
                  tooltip: '后退 10 秒',
                  onPressed: () => _seekPlayerBy(widget.player, -10),
                  icon: Icons.replay_10_rounded,
                ),
                _compactIconButton(
                  tooltip: '上一个实体',
                  onPressed: widget.onPrevious,
                  icon: Icons.skip_previous_rounded,
                ),
                StreamBuilder<bool>(
                  stream: widget.player.stream.playing,
                  initialData: widget.player.state.playing,
                  builder: (context, snapshot) => IconButton.filled(
                    tooltip: snapshot.data == true ? '暂停' : '播放',
                    onPressed: widget.player.playOrPause,
                    icon: Icon(snapshot.data == true
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded),
                    iconSize: 26,
                  ),
                ),
                _compactIconButton(
                  tooltip: '下一个实体',
                  onPressed: widget.onNext,
                  icon: Icons.skip_next_rounded,
                ),
                _compactIconButton(
                  tooltip: '前进 10 秒',
                  onPressed: () => _seekPlayerBy(widget.player, 10),
                  icon: Icons.forward_10_rounded,
                ),
                if (widget.controller != null)
                  _compactIconButton(
                    tooltip: '查看歌单',
                    onPressed: _showPlaylist,
                    icon: Icons.queue_music_rounded,
                  ),
                if (widget.controller != null)
                  _AudioPlaybackModeMenu(controller: widget.controller!),
                const SizedBox(width: 8),
                _compactIconButton(
                  tooltip: _showVolume ? '收起音量' : '音量',
                  onPressed: () => setState(() => _showVolume = !_showVolume),
                  icon: Icons.volume_up_rounded,
                ),
                _PlaybackSpeedMenu(player: widget.player),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showPlaylist() async {
    final controller = widget.controller;
    final session = controller?.session;
    if (controller == null || session == null || session.entries.isEmpty) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 760),
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .62,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Row(children: [
                const Icon(Icons.queue_music_rounded),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(session.name,
                        style: Theme.of(context).textTheme.titleMedium)),
                Text('${session.entries.length} 首',
                    style: Theme.of(context).textTheme.labelMedium),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
                child: ListView.builder(
              itemCount: session.entries.length,
              itemBuilder: (context, index) {
                final item = session.entries[index];
                final selected = index == session.currentIndex;
                return ListTile(
                  dense: true,
                  selected: selected,
                  leading: SizedBox(
                      width: 28,
                      child: Center(
                          child: selected
                              ? const Icon(Icons.graphic_eq_rounded)
                              : Text('${index + 1}'))),
                  title: Text(item.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: item.durationMs == null
                      ? null
                      : Text(_formatDuration(
                          Duration(milliseconds: item.durationMs!))),
                  onTap: () async {
                    Navigator.of(context).pop();
                    await controller.playSessionEntry(session, index);
                  },
                );
              },
            )),
          ]),
        ),
      ),
    );
  }
}

class _AudioPlaybackModeMenu extends StatelessWidget {
  const _AudioPlaybackModeMenu({required this.controller});
  final AppAudioController controller;

  @override
  Widget build(BuildContext context) {
    final mode = controller.mode;
    final icon = switch (mode) {
      AudioPlaybackMode.sequential => Icons.format_list_numbered_rounded,
      AudioPlaybackMode.singleRepeat => Icons.repeat_one_rounded,
      AudioPlaybackMode.nodeRepeat => Icons.repeat_rounded,
      AudioPlaybackMode.nodeShuffle => Icons.shuffle_rounded,
    };
    return PopupMenuButton<AudioPlaybackMode>(
      tooltip: '播放模式：${mode.label}',
      initialValue: mode,
      onSelected: controller.setMode,
      icon: Icon(icon, size: 20),
      itemBuilder: (context) => AudioPlaybackMode.values
          .map((item) => PopupMenuItem(
                value: item,
                child: Row(children: [
                  Icon(
                      item == mode
                          ? Icons.check_rounded
                          : Icons.circle_outlined,
                      size: 18),
                  const SizedBox(width: 10),
                  Text(item.label),
                ]),
              ))
          .toList(growable: false),
    );
  }
}

class _AudioVolumeSlider extends StatelessWidget {
  const _AudioVolumeSlider({required this.player});

  final Player player;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.volume_down_rounded, size: 18),
        Expanded(
          child: StreamBuilder<double>(
            stream: player.stream.volume,
            initialData: player.state.volume,
            builder: (context, snapshot) => Slider(
              min: 0,
              max: 100,
              value: (snapshot.data ?? 100).clamp(0, 100).toDouble(),
              onChanged: player.setVolume,
            ),
          ),
        ),
        const Icon(Icons.volume_up_rounded, size: 18),
      ],
    );
  }
}

class _AudioWaveformSeekBar extends StatefulWidget {
  const _AudioWaveformSeekBar({
    required this.player,
    required this.waveformFuture,
    required this.scrubController,
  });

  final Player player;
  final Future<Uint8List?> waveformFuture;
  final AudioTimelineScrubController scrubController;

  @override
  State<_AudioWaveformSeekBar> createState() => _AudioWaveformSeekBarState();
}

class _AudioWaveformSeekBarState extends State<_AudioWaveformSeekBar> {
  StreamSubscription<bool>? _playingSubscription;
  Timer? _pulseTimer;
  int? _pulseStartedAtUs;
  final ValueNotifier<double> _pulse = ValueNotifier(0);
  final _WaveformGeometryCache _geometryCache = _WaveformGeometryCache();
  bool _isPlaying = false;
  double? _hoverRatio;

  @override
  void initState() {
    super.initState();
    _isPlaying = widget.player.state.playing;
    _setPulseRunning(_isPlaying);
    _playingSubscription = widget.player.stream.playing.listen((playing) {
      if (!mounted) return;
      setState(() => _isPlaying = playing);
      _setPulseRunning(playing);
    });
  }

  @override
  void dispose() {
    _playingSubscription?.cancel();
    _pulseTimer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  void _setPulseRunning(bool playing) {
    _pulseTimer?.cancel();
    if (!playing) {
      _pulseStartedAtUs = null;
      _pulse.value = 0;
      return;
    }
    _pulseStartedAtUs ??= DateTime.now().microsecondsSinceEpoch;
    _pulseTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (!mounted) return;
      _pulse.value =
          (DateTime.now().microsecondsSinceEpoch - _pulseStartedAtUs!) /
              Duration.microsecondsPerSecond;
    });
  }

  Future<void> _seek(Duration duration, double ratio) async {
    widget.scrubController.update(ratio);
    await widget.player.seek(Duration(
      milliseconds: (duration.inMilliseconds * ratio).round(),
    ));
    widget.scrubController.clear();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: widget.waveformFuture,
      builder: (context, waveformSnapshot) {
        final peaks = waveformSnapshot.data;
        return StreamBuilder<Duration>(
          stream: widget.player.stream.position,
          initialData: widget.player.state.position,
          builder: (context, positionSnapshot) {
            return StreamBuilder<Duration>(
              stream: widget.player.stream.duration,
              initialData: widget.player.state.duration,
              builder: (context, durationSnapshot) {
                final duration = durationSnapshot.data ?? Duration.zero;
                final position = positionSnapshot.data ?? Duration.zero;
                final liveProgress = duration.inMilliseconds <= 0
                    ? 0.0
                    : (position.inMilliseconds / duration.inMilliseconds)
                        .clamp(0.0, 1.0);
                return ListenableBuilder(
                  listenable: widget.scrubController,
                  builder: (context, _) {
                    final progress =
                        widget.scrubController.previewRatio ?? liveProgress;
                    final hoverLabel =
                        _hoverRatio == null || duration.inMilliseconds <= 0
                            ? null
                            : _formatDuration(Duration(
                                milliseconds:
                                    (duration.inMilliseconds * _hoverRatio!)
                                        .round(),
                              ));
                    return LayoutBuilder(
                      builder: (context, constraints) => MouseRegion(
                        cursor: duration.inMilliseconds <= 0
                            ? MouseCursor.defer
                            : SystemMouseCursors.click,
                        onExit: (_) {
                          if (_hoverRatio != null) {
                            setState(() => _hoverRatio = null);
                          }
                        },
                        onHover: duration.inMilliseconds <= 0
                            ? null
                            : (event) {
                                final ratio = (event.localPosition.dx /
                                        constraints.maxWidth)
                                    .clamp(0.0, 1.0);
                                if (_hoverRatio != ratio) {
                                  setState(() => _hoverRatio = ratio);
                                }
                              },
                        child: Semantics(
                          label: '播放进度',
                          slider: true,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: duration.inMilliseconds <= 0
                                ? null
                                : (details) {
                                    final ratio = (details.localPosition.dx /
                                            constraints.maxWidth)
                                        .clamp(0.0, 1.0);
                                    _seek(duration, ratio);
                                  },
                            onHorizontalDragStart: duration.inMilliseconds <= 0
                                ? null
                                : (details) => widget.scrubController.update(
                                      (details.localPosition.dx /
                                              constraints.maxWidth)
                                          .clamp(0.0, 1.0),
                                    ),
                            onHorizontalDragUpdate: duration.inMilliseconds <= 0
                                ? null
                                : (details) => widget.scrubController.update(
                                      (details.localPosition.dx /
                                              constraints.maxWidth)
                                          .clamp(0.0, 1.0),
                                    ),
                            onHorizontalDragEnd: duration.inMilliseconds <= 0
                                ? null
                                : (_) async {
                                    final ratio =
                                        widget.scrubController.previewRatio;
                                    if (ratio != null) {
                                      await _seek(duration, ratio);
                                    }
                                  },
                            onHorizontalDragCancel: () {
                              widget.scrubController.clear();
                            },
                            child: SizedBox(
                              height: constraints.maxWidth >= 720 ? 112 : 88,
                              width: double.infinity,
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Positioned.fill(
                                    child: RepaintBoundary(
                                      child: CustomPaint(
                                        painter: _AudioWaveformPainter(
                                          peaks: peaks,
                                          progress: progress,
                                          isPlaying: _isPlaying,
                                          pulse: _pulse,
                                          geometryCache: _geometryCache,
                                          activeColor: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                          inactiveColor: Theme.of(context)
                                              .colorScheme
                                              .outlineVariant,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (hoverLabel != null)
                                    Positioned(
                                      top: -25,
                                      left: ((constraints.maxWidth *
                                                  _hoverRatio!) -
                                              24)
                                          .clamp(
                                              0.0, constraints.maxWidth - 48),
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .surface
                                              .withValues(alpha: 0.86),
                                          borderRadius:
                                              BorderRadius.circular(5),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          child: Text(
                                            hoverLabel,
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

class _AudioWaveformPainter extends CustomPainter {
  const _AudioWaveformPainter({
    required this.peaks,
    required this.progress,
    required this.isPlaying,
    required this.pulse,
    required this.geometryCache,
    required this.activeColor,
    required this.inactiveColor,
  }) : super(repaint: pulse);

  final Uint8List? peaks;
  final double progress;
  final bool isPlaying;
  final ValueListenable<double> pulse;
  final _WaveformGeometryCache geometryCache;
  final Color activeColor;
  final Color inactiveColor;

  @override
  void paint(Canvas canvas, Size size) {
    final geometry = geometryCache.resolve(size, peaks);
    final playheadX = size.width * progress;
    final localPulse =
        isPlaying ? 0.5 + 0.5 * sin(pulse.value * pi * 1.4) : 0.0;
    for (var index = 0; index < geometry.bars.length; index++) {
      final bar = geometry.bars[index];
      final distance = (bar.x - playheadX).abs();
      final proximity =
          (1 - distance / (geometry.barWidth * 11)).clamp(0.0, 1.0);
      final isActive = bar.x <= playheadX;
      if (!isActive) {
        final paint = Paint()
          ..color = inactiveColor.withValues(alpha: 0.22)
          ..strokeCap = StrokeCap.round
          ..strokeWidth = geometry.barWidth;
        canvas.drawLine(
            Offset(bar.x, bar.top), Offset(bar.x, bar.bottom), paint);
        continue;
      }

      if (proximity > 0 && isPlaying) {
        final glowPaint = Paint()
          ..color = activeColor.withValues(
            alpha: (0.04 + proximity * localPulse * 0.16),
          )
          ..strokeCap = StrokeCap.round
          ..strokeWidth = geometry.barWidth + 4 + proximity * 3;
        canvas.drawLine(
            Offset(bar.x, bar.top), Offset(bar.x, bar.bottom), glowPaint);
      }
      final height = bar.bottom - bar.top;
      final baseDivider =
          geometry.centerY + _staticDividerBias(index) * height * 0.12;
      final motion = isPlaying
          ? _organicDividerMotion(index, pulse.value) *
              height *
              (0.07 + proximity * 0.08)
          : 0.0;
      final divider = (baseDivider + motion).clamp(bar.top, bar.bottom);
      final upperPaint = Paint()
        ..color = activeColor.withValues(
          alpha: 0.46 + proximity * (0.10 + localPulse * 0.08),
        )
        ..strokeCap = StrokeCap.round
        ..strokeWidth = geometry.barWidth;
      final lowerPaint = Paint()
        ..color = activeColor.withValues(
          alpha: 0.84 + proximity * (0.08 + localPulse * 0.06),
        )
        ..strokeCap = StrokeCap.round
        ..strokeWidth = geometry.barWidth;
      canvas.drawLine(
          Offset(bar.x, bar.top), Offset(bar.x, divider), upperPaint);
      canvas.drawLine(
          Offset(bar.x, divider), Offset(bar.x, bar.bottom), lowerPaint);
    }

    if (isPlaying) {
      canvas.drawCircle(
        Offset(playheadX, geometry.centerY),
        8 + localPulse * 4,
        Paint()
          ..color = activeColor.withValues(alpha: 0.08 + localPulse * 0.08),
      );
    }
    final playheadPaint = Paint()
      ..color = activeColor
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(playheadX, 6), Offset(playheadX, size.height - 6),
        playheadPaint);
    canvas.drawCircle(
      Offset(playheadX, geometry.centerY),
      4.5,
      Paint()..color = activeColor,
    );
  }

  @override
  bool shouldRepaint(covariant _AudioWaveformPainter oldDelegate) {
    return oldDelegate.peaks != peaks ||
        oldDelegate.progress != progress ||
        oldDelegate.isPlaying != isPlaying ||
        oldDelegate.geometryCache != geometryCache ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor;
  }

  double _staticDividerBias(int index) {
    return _noiseValue(index, 13) * 2 - 1;
  }

  /// Combines each bar's own drift with a shared neighbouring drift so the
  /// separator feels organic instead of reading as synchronized sine motion.
  double _organicDividerMotion(int index, double time) {
    final shared = _smoothNoise(index ~/ 3, time * 0.48);
    final individual =
        _smoothNoise(index + 137, time * (0.7 + (index % 7) * 0.09));
    return shared * 0.42 + individual * 0.58;
  }

  double _smoothNoise(int index, double time) {
    final lower = time.floor();
    final fraction = time - lower;
    final eased = fraction * fraction * (3 - 2 * fraction);
    final from = _noiseValue(index, lower) * 2 - 1;
    final to = _noiseValue(index, lower + 1) * 2 - 1;
    return from + (to - from) * eased;
  }

  double _noiseValue(int index, int step) {
    final value = sin(index * 12.9898 + step * 78.233) * 43758.5453;
    return value - value.floor();
  }
}

class _WaveformGeometryCache {
  Size? _size;
  Uint8List? _peaks;
  _WaveformGeometry? _geometry;

  _WaveformGeometry resolve(Size size, Uint8List? peaks) {
    final cached = _geometry;
    if (cached != null && _size == size && identical(_peaks, peaks)) {
      return cached;
    }
    final bars = (size.width / 5.5).floor().clamp(72, 176).toInt();
    const gap = 3.0;
    final barWidth = max(1.2, (size.width - (bars - 1) * gap) / bars);
    final centerY = size.height / 2;
    final geometry = <_WaveformBar>[];
    for (var index = 0; index < bars; index++) {
      final from = (index * audioWaveformSampleCount / bars).floor();
      final to = ((index + 1) * audioWaveformSampleCount / bars)
          .ceil()
          .clamp(from + 1, audioWaveformSampleCount)
          .toInt();
      var peak = 0;
      if (peaks != null) {
        for (var sample = from; sample < to; sample++) {
          peak = max(peak, peaks[sample]);
        }
      } else {
        peak = (110 + 75 * sin(index * 0.73) + 45 * sin(index * 1.91))
            .round()
            .clamp(24, 220)
            .toInt();
      }
      final height = 4 + (peak / 255) * (size.height - 12);
      final x = index * (barWidth + gap) + barWidth / 2;
      geometry.add(_WaveformBar(
        x: x,
        top: centerY - height / 2,
        bottom: centerY + height / 2,
      ));
    }
    _size = size;
    _peaks = peaks;
    return _geometry = _WaveformGeometry(
      bars: geometry,
      barWidth: barWidth,
      centerY: centerY,
    );
  }
}

class _WaveformGeometry {
  const _WaveformGeometry({
    required this.bars,
    required this.barWidth,
    required this.centerY,
  });

  final List<_WaveformBar> bars;
  final double barWidth;
  final double centerY;
}

class _WaveformBar {
  const _WaveformBar({
    required this.x,
    required this.top,
    required this.bottom,
  });

  final double x;
  final double top;
  final double bottom;
}

class _VideoPlayerPreview extends StatefulWidget {
  const _VideoPlayerPreview({
    super.key,
    required this.entity,
    required this.sourceResolver,
    this.transparentStage = false,
    this.onClose,
    this.onReturnToSource,
    this.onPrevious,
    this.onNext,
    this.onDirectoryRoot,
    this.onShowDetails,
    required this.onCompleted,
    required this.onPlaybackStateChanged,
  });

  final EntityListItem entity;
  final MediaSourceResolver sourceResolver;
  final bool transparentStage;
  final VoidCallback? onClose;
  final VoidCallback? onReturnToSource;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onDirectoryRoot;
  final VoidCallback? onShowDetails;
  final MediaCompleted onCompleted;
  final PlaybackStateChanged? onPlaybackStateChanged;

  @override
  State<_VideoPlayerPreview> createState() => _VideoPlayerPreviewState();
}

class _VideoPlayerPreviewState extends State<_VideoPlayerPreview> {
  late final Player _player;
  late final VideoController _controller;
  final MediaPlayerLifecycle _lifecycle = MediaPlayerLifecycle();
  Future<void> _openChain = Future<void>.value();
  Future<void>? _closeFuture;
  int _activeGeneration = 0;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<bool>? _playingSubscription;
  Timer? _controlsTimer;
  Timer? _progressSaveTimer;
  Object? _loadError;
  bool _controlsVisible = true;
  bool _toolbarCollapsed = false;

  @override
  void initState() {
    super.initState();
    unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    _player = Player(
      configuration: const PlayerConfiguration(
        // At 150 Mbps the default 32 MB buffer is only about 1.7 seconds.
        bufferSize: 128 * 1024 * 1024,
      ),
    );
    _controller = VideoController(
      _player,
      configuration: Platform.isAndroid
          ? const VideoControllerConfiguration(
              // Avoid the conservative auto-safe/copy path for high bitrate
              // local media. MediaCodec embeds the hardware decoder surface.
              vo: 'mediacodec_embed',
              hwdec: 'mediacodec',
              enableHardwareAcceleration: true,
            )
          : const VideoControllerConfiguration(),
    );
    _completedSubscription = _player.stream.completed.listen((completed) {
      if (completed && _lifecycle.isCurrent(_activeGeneration)) {
        unawaited(widget.onCompleted(_player));
      }
    });
    _playingSubscription = _player.stream.playing.listen((playing) {
      if (!_lifecycle.isCurrent(_activeGeneration)) return;
      if (!playing) {
        _showControls(keepVisible: true);
      } else {
        _scheduleControlsHide();
      }
    });
    _open();
    _progressSaveTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _savePlaybackState());
  }

  Future<void> _open() {
    final generation = _lifecycle.beginOperation();
    final operation = _runOpenAfterPrevious(generation);
    _openChain = operation.catchError((_) {});
    return operation;
  }

  Future<void> _runOpenAfterPrevious(int generation) async {
    try {
      await _openChain;
    } catch (_) {
      // A failed/stale open must not block a later retry.
    }
    if (!_lifecycle.isCurrent(generation)) return;
    await _openSerial(generation);
  }

  Future<void> _openSerial(int generation) async {
    if (mounted) setState(() => _loadError = null);
    try {
      final source =
          await widget.sourceResolver.playerSourceAsync(widget.entity);
      if (!_lifecycle.isCurrent(generation)) return;
      await _player.open(
        Media(source),
      );
      if (!_lifecycle.isCurrent(generation)) {
        await _player.stop();
        return;
      }
      _activeGeneration = generation;
      final position = widget.entity.lastPositionMs;
      if (position != null && position > 0) {
        await _player.seek(Duration(milliseconds: position));
      }
    } catch (error) {
      if (_lifecycle.isCurrent(generation) && mounted) {
        setState(() => _loadError = error);
      }
    }
  }

  @override
  void dispose() {
    unawaited(_close());
    super.dispose();
  }

  Future<void> _close() => _closeFuture ??= _lifecycle.close(_closeImpl);

  Future<void> _closeImpl() async {
    _controlsTimer?.cancel();
    _progressSaveTimer?.cancel();
    _savePlaybackState();
    await Future.wait([
      if (_completedSubscription != null) _completedSubscription!.cancel(),
      if (_playingSubscription != null) _playingSubscription!.cancel(),
    ]);
    try {
      await _openChain;
    } catch (_) {
      // Always release the native player after an open failure.
    }
    try {
      await _player.dispose();
    } catch (error, stackTrace) {
      debugPrint('Video player dispose failed: $error\n$stackTrace');
    }
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (error, stackTrace) {
      debugPrint('System UI restore failed: $error\n$stackTrace');
    }
  }

  void _savePlaybackState() {
    widget.onPlaybackStateChanged?.call(
      _player.state.position.inMilliseconds,
      _player.state.duration.inMilliseconds,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('内置播放器打开失败：$_loadError',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _open,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重新打开'),
              ),
            ]),
          ),
        ),
      );
    }
    return _VideoKeyboardScope(
      player: _player,
      onEscape: widget.onClose ?? () => Navigator.of(context).pop(),
      enableEscape: true,
      child: MouseRegion(
        onHover: (_) => _showControls(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _showControls,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                color:
                    widget.transparentStage ? Colors.transparent : Colors.black,
                child: Center(
                  child: Video(
                    controller: _controller,
                    controls: NoVideoControls,
                  ),
                ),
              ),
              Positioned(
                left: MediaQuery.sizeOf(context).width / 6,
                width: MediaQuery.sizeOf(context).width * 2 / 3,
                bottom: 20,
                height: MediaQuery.sizeOf(context).height * .10,
                child: _VideoOverlayVisibility(
                  visible: _controlsVisible,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surface
                          .withValues(alpha: .2),
                    ),
                    child: _VideoProgressTouchZone(player: _player),
                  ),
                ),
              ),
              Positioned(
                right: 0,
                bottom: MediaQuery.sizeOf(context).width >= 900 ? 84 : 160,
                child: _VideoOverlayVisibility(
                  visible: _controlsVisible,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surface
                          .withValues(alpha: .86),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(10),
                        bottomLeft: Radius.circular(10),
                      ),
                      boxShadow: const [
                        BoxShadow(blurRadius: 10, color: Color(0x33000000)),
                      ],
                    ),
                    child: SizedBox(
                      height: 48,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _compactIconButton(
                            tooltip: _toolbarCollapsed ? '展开工具栏' : '收起工具栏',
                            onPressed: () => setState(
                              () => _toolbarCollapsed = !_toolbarCollapsed,
                            ),
                            iconWidget: const CollapseGripIcon(),
                          ),
                          if (!_toolbarCollapsed)
                            _PlaybackActionRow(
                              player: _player,
                              onBack: widget.onReturnToSource,
                              onPrevious: widget.onPrevious,
                              onNext: widget.onNext,
                              onDirectoryRoot: widget.onDirectoryRoot,
                              onShowDetails: widget.onShowDetails,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showControls({bool keepVisible = false}) {
    if (!_controlsVisible && mounted) setState(() => _controlsVisible = true);
    _controlsTimer?.cancel();
    if (!keepVisible) _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    if (!_player.state.playing) return;
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _player.state.playing) {
        setState(() => _controlsVisible = false);
      }
    });
  }
}

class _PlaybackTime extends StatelessWidget {
  const _PlaybackTime({required this.player});

  final Player player;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StreamBuilder<Duration>(
          stream: player.stream.position,
          initialData: player.state.position,
          builder: (context, snapshot) {
            return Text(_formatDuration(snapshot.data ?? Duration.zero));
          },
        ),
        const Text(' / '),
        StreamBuilder<Duration>(
          stream: player.stream.duration,
          initialData: player.state.duration,
          builder: (context, snapshot) {
            return Text(_formatDuration(snapshot.data ?? Duration.zero));
          },
        ),
      ],
    );
  }
}

class _PlaybackActionRow extends StatelessWidget {
  const _PlaybackActionRow({
    required this.player,
    this.onBack,
    this.onPrevious,
    this.onNext,
    this.onDirectoryRoot,
    this.onShowDetails,
  });

  final Player player;
  final VoidCallback? onBack;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onDirectoryRoot;
  final VoidCallback? onShowDetails;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onBack != null)
          _compactIconButton(
            tooltip: '返回所在节点',
            onPressed: onBack,
            icon: Icons.arrow_back_rounded,
          ),
        if (onDirectoryRoot != null)
          _compactIconButton(
            tooltip: '返回目录索引',
            onPressed: onDirectoryRoot,
            icon: Icons.account_tree_outlined,
          ),
        if (onShowDetails != null)
          _compactIconButton(
            tooltip: '详情',
            onPressed: onShowDetails,
            icon: Icons.info_outline_rounded,
          ),
        StreamBuilder<bool>(
          stream: player.stream.playing,
          initialData: player.state.playing,
          builder: (context, snapshot) => _compactIconButton(
            tooltip: snapshot.data == true ? '暂停' : '播放',
            onPressed: player.playOrPause,
            icon: snapshot.data == true
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
          ),
        ),
        _PlaybackSpeedMenu(player: player),
        if (onPrevious != null)
          _compactIconButton(
            tooltip: '上一个实体',
            onPressed: onPrevious,
            icon: Icons.skip_previous_rounded,
          ),
        if (onNext != null)
          _compactIconButton(
            tooltip: '下一个实体',
            onPressed: onNext,
            icon: Icons.skip_next_rounded,
          ),
      ],
    );
  }
}

Widget _compactIconButton({
  required String tooltip,
  required VoidCallback? onPressed,
  IconData? icon,
  Widget? iconWidget,
}) {
  return IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: iconWidget ?? Icon(icon!),
    iconSize: 24,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 48, height: 48),
  );
}

Future<void> _seekPlayerBy(Player player, int seconds) async {
  final target = player.state.position + Duration(seconds: seconds);
  await player.seek(target < Duration.zero ? Duration.zero : target);
}

class _PlaybackSpeedMenu extends StatelessWidget {
  const _PlaybackSpeedMenu({required this.player});

  final Player player;

  static const _rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: player.stream.rate,
      initialData: player.state.rate,
      builder: (context, snapshot) {
        final current = snapshot.data ?? 1.0;
        return PopupMenuButton<double>(
          tooltip: '播放速度',
          initialValue: _nearestRate(current),
          onSelected: player.setRate,
          itemBuilder: (context) => [
            for (final rate in _rates)
              PopupMenuItem(
                value: rate,
                child: Text('${rate.toStringAsFixed(rate == 1.0 ? 0 : 2)}x'),
              ),
          ],
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Text(
                '${current.toStringAsFixed(current == current.roundToDouble() ? 0 : 2)}x',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ),
        );
      },
    );
  }

  static double _nearestRate(double rate) {
    return _rates.reduce(
      (best, item) => (item - rate).abs() < (best - rate).abs() ? item : best,
    );
  }
}

class _VideoOverlayVisibility extends StatelessWidget {
  const _VideoOverlayVisibility({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: child,
      ),
    );
  }
}

class _ViewerChrome extends StatelessWidget {
  const _ViewerChrome({
    required this.entity,
    required this.currentIndex,
    required this.total,
    required this.isTextReader,
    required this.onBack,
    this.onDetails,
    this.onDirectoryRoot,
    this.onPrevious,
    this.onNext,
    this.onTextSettings,
    this.onBookmark,
    this.showMetadataActions = true,
  });

  final EntityListItem entity;
  final int currentIndex;
  final int total;
  final bool isTextReader;
  final VoidCallback onBack;
  final VoidCallback? onDetails;
  final VoidCallback? onDirectoryRoot;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onTextSettings;
  final VoidCallback? onBookmark;
  final bool showMetadataActions;

  @override
  Widget build(BuildContext context) {
    final surface =
        Theme.of(context).colorScheme.surface.withValues(alpha: 0.5);
    Widget tool(IconData icon, String tooltip, VoidCallback? action) =>
        IconButton(tooltip: tooltip, onPressed: action, icon: Icon(icon));
    return SafeArea(
      child: Stack(
        children: [
          if (showMetadataActions)
            Positioned(
              top: 10,
              left: 12,
              child: DecoratedBox(
                decoration:
                    BoxDecoration(color: surface, shape: BoxShape.circle),
                child: tool(Icons.arrow_back_rounded, '返回资料库', onBack),
              ),
            ),
          Positioned(
            top: 10,
            right: 12,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text('${currentIndex + 1}/$total'),
                  ),
                  if (isTextReader)
                    tool(Icons.tune_rounded, '阅读设置', onTextSettings),
                  if (isTextReader)
                    tool(
                        Icons.bookmark_add_outlined, '添加/移除当前位置书签', onBookmark),
                  if (onDirectoryRoot != null)
                    tool(
                        Icons.account_tree_outlined, '返回目录索引', onDirectoryRoot),
                  tool(Icons.info_outline_rounded, '详情', onDetails),
                ],
              ),
            ),
          ),
          if (onPrevious != null)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Center(
                child: _EntityEdgeNavigationButton(
                  direction: AxisDirection.left,
                  onPressed: onPrevious!,
                ),
              ),
            ),
          if (onNext != null)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: Center(
                child: _EntityEdgeNavigationButton(
                  direction: AxisDirection.right,
                  onPressed: onNext!,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EntityEdgeNavigationButton extends StatelessWidget {
  const _EntityEdgeNavigationButton({
    required this.direction,
    required this.onPressed,
  });

  final AxisDirection direction;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final isPrevious = direction == AxisDirection.left;
    final surface =
        Theme.of(context).colorScheme.surface.withValues(alpha: 0.5);
    return Semantics(
      button: true,
      label: isPrevious ? '上一项' : '下一项',
      child: Tooltip(
        message: isPrevious ? '上一项' : '下一项',
        child: Material(
          color: Colors.transparent,
          child: Ink(
            width: 44,
            height: 72,
            decoration: BoxDecoration(
              color: surface,
              borderRadius: isPrevious
                  ? const BorderRadius.horizontal(right: Radius.circular(12))
                  : const BorderRadius.horizontal(left: Radius.circular(12)),
            ),
            child: InkWell(
              onTap: onPressed,
              borderRadius: isPrevious
                  ? const BorderRadius.horizontal(right: Radius.circular(12))
                  : const BorderRadius.horizontal(left: Radius.circular(12)),
              child: Icon(
                isPrevious
                    ? Icons.chevron_left_rounded
                    : Icons.chevron_right_rounded,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoKeyboardScope extends StatelessWidget {
  const _VideoKeyboardScope({
    required this.player,
    required this.child,
    this.onEscape,
    this.enableEscape = false,
  });

  final Player player;
  final Widget child;
  final VoidCallback? onEscape;
  final bool enableEscape;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      child: Shortcuts(
        shortcuts: {
          const SingleActivator(LogicalKeyboardKey.space):
              const _PlayPauseIntent(),
          const SingleActivator(LogicalKeyboardKey.keyJ):
              const _SeekIntent(-10),
          const SingleActivator(LogicalKeyboardKey.keyL): const _SeekIntent(10),
          const SingleActivator(LogicalKeyboardKey.arrowDown):
              const _VolumeIntent(-5),
          const SingleActivator(LogicalKeyboardKey.arrowUp):
              const _VolumeIntent(5),
          if (enableEscape && onEscape != null)
            const SingleActivator(LogicalKeyboardKey.escape):
                const _DismissVideoIntent(),
        },
        child: Actions(
          actions: {
            _PlayPauseIntent: CallbackAction<_PlayPauseIntent>(
              onInvoke: (_) {
                player.playOrPause();
                return null;
              },
            ),
            _SeekIntent: CallbackAction<_SeekIntent>(
              onInvoke: (intent) {
                player.seek(
                  _clampDuration(
                    player.state.position + Duration(seconds: intent.seconds),
                    player.state.duration,
                  ),
                );
                return null;
              },
            ),
            _VolumeIntent: CallbackAction<_VolumeIntent>(
              onInvoke: (intent) {
                _changeVolume(player, intent.delta);
                return null;
              },
            ),
            _DismissVideoIntent: CallbackAction<_DismissVideoIntent>(
              onInvoke: (_) {
                onEscape?.call();
                return null;
              },
            ),
          },
          child: child,
        ),
      ),
    );
  }
}

class _PlayPauseIntent extends Intent {
  const _PlayPauseIntent();
}

class _SeekIntent extends Intent {
  const _SeekIntent(this.seconds);

  final int seconds;
}

class _VolumeIntent extends Intent {
  const _VolumeIntent(this.delta);

  final double delta;
}

class _DismissVideoIntent extends Intent {
  const _DismissVideoIntent();
}

class _PositionSlider extends StatefulWidget {
  const _PositionSlider({required this.player});

  final Player player;

  @override
  State<_PositionSlider> createState() => _PositionSliderState();
}

class _PositionSliderState extends State<_PositionSlider> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.player.stream.position,
      initialData: widget.player.state.position,
      builder: (context, positionSnapshot) {
        return StreamBuilder<Duration>(
          stream: widget.player.stream.duration,
          initialData: widget.player.state.duration,
          builder: (context, durationSnapshot) {
            return _buildSlider(
              positionSnapshot.data ?? Duration.zero,
              durationSnapshot.data ?? Duration.zero,
            );
          },
        );
      },
    );
  }

  Widget _buildSlider(Duration position, Duration duration) {
    final max = duration.inMilliseconds.toDouble();
    final value = _dragValue ??
        position.inMilliseconds.clamp(0, duration.inMilliseconds).toDouble();
    return Slider(
      min: 0,
      max: max <= 0 ? 1 : max,
      value: max <= 0 ? 0 : value,
      onChanged:
          max <= 0 ? null : (value) => setState(() => _dragValue = value),
      onChangeEnd: max <= 0
          ? null
          : (value) async {
              setState(() => _dragValue = null);
              await widget.player.seek(Duration(milliseconds: value.round()));
            },
    );
  }
}

/// Keeps the visible video timeline at the bottom while making the lower
/// screen area forgiving enough for touch and trackpad scrubbing.
class _VideoProgressTouchZone extends StatelessWidget {
  const _VideoProgressTouchZone({required this.player});

  final Player player;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (details) => _seekAt(
          details.localPosition.dx,
          constraints.maxWidth,
        ),
        onHorizontalDragUpdate: (details) {
          _seekAt(details.localPosition.dx, constraints.maxWidth);
        },
        child: Stack(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 6, top: 2),
                child: _PlaybackTime(player: player),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                height: 16,
                width: double.infinity,
                child: IgnorePointer(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 3,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 7,
                      ),
                    ),
                    child: _PositionSlider(player: player),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _seekAt(double dx, double width) {
    final duration = player.state.duration;
    if (duration <= Duration.zero || width <= 0) return;
    final fraction = (dx / width).clamp(0.0, 1.0);
    unawaited(player.seek(Duration(
      milliseconds: (duration.inMilliseconds * fraction).round(),
    )));
  }
}

class _RibbonProgressSeekBar extends StatefulWidget {
  const _RibbonProgressSeekBar({
    required this.player,
    required this.waveformFuture,
    required this.scrubController,
    this.controller,
  });

  final Player player;
  final AppAudioController? controller;
  final Future<Uint8List?> waveformFuture;
  final AudioTimelineScrubController scrubController;

  @override
  State<_RibbonProgressSeekBar> createState() => _RibbonProgressSeekBarState();
}

class _RibbonProgressSeekBarState extends State<_RibbonProgressSeekBar> {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: widget.waveformFuture,
      builder: (context, waveformSnapshot) {
        final controller = widget.controller;
        if (controller != null) {
          return ListenableBuilder(
            listenable: controller.progress,
            builder: (context, _) => _buildTimeline(
              controller.position,
              controller.duration,
              waveformSnapshot.data,
            ),
          );
        }
        return StreamBuilder<Duration>(
          stream: widget.player.stream.position,
          initialData: widget.player.state.position,
          builder: (context, positionSnapshot) => StreamBuilder<Duration>(
            stream: widget.player.stream.duration,
            initialData: widget.player.state.duration,
            builder: (context, durationSnapshot) => _buildTimeline(
              positionSnapshot.data ?? Duration.zero,
              durationSnapshot.data ?? Duration.zero,
              waveformSnapshot.data,
            ),
          ),
        );
      },
    );
  }

  Widget _buildTimeline(
      Duration position, Duration duration, Uint8List? peaks) {
    final durationMs = duration.inMilliseconds;
    final liveProgress = durationMs <= 0
        ? 0.0
        : (position.inMilliseconds / durationMs).clamp(0.0, 1.0);
    return ListenableBuilder(
      listenable: widget.scrubController,
      builder: (context, _) {
        final progress = widget.scrubController.previewRatio ?? liveProgress;
        return LayoutBuilder(
          builder: (context, constraints) => MouseRegion(
            cursor:
                durationMs <= 0 ? MouseCursor.defer : SystemMouseCursors.click,
            child: Semantics(
              label: '播放进度',
              slider: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: durationMs <= 0
                    ? null
                    : (details) => _seekAt(duration, details.localPosition.dx,
                        constraints.maxWidth),
                onHorizontalDragStart: durationMs <= 0
                    ? null
                    : (details) => widget.scrubController.update(
                          (details.localPosition.dx / constraints.maxWidth)
                              .clamp(0.0, 1.0),
                        ),
                onHorizontalDragUpdate: durationMs <= 0
                    ? null
                    : (details) => widget.scrubController.update(
                          (details.localPosition.dx / constraints.maxWidth)
                              .clamp(0.0, 1.0),
                        ),
                onHorizontalDragEnd: durationMs <= 0
                    ? null
                    : (_) async {
                        final ratio = widget.scrubController.previewRatio;
                        if (ratio != null) {
                          await _seek(duration, ratio);
                        }
                      },
                onHorizontalDragCancel: widget.scrubController.clear,
                child: SizedBox(
                  height: 30,
                  width: double.infinity,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _AudioRibbonPainter(
                        peaks: peaks,
                        progress: progress,
                        activeColor: Theme.of(context).colorScheme.primary,
                        inactiveColor:
                            Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _seekAt(Duration duration, double dx, double width) async {
    final ratio = (dx / width).clamp(0.0, 1.0);
    await _seek(duration, ratio);
  }

  Future<void> _seek(Duration duration, double ratio) async {
    widget.scrubController.update(ratio);
    await widget.player.seek(Duration(
      milliseconds: (duration.inMilliseconds * ratio).round(),
    ));
    widget.scrubController.clear();
  }
}

class _AudioRibbonPainter extends CustomPainter {
  const _AudioRibbonPainter({
    required this.peaks,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
  });

  final Uint8List? peaks;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  @override
  void paint(Canvas canvas, Size size) {
    const verticalInset = 4.0;
    final centerY = size.height / 2;
    final pointCount = (size.width / 9).round().clamp(48, 112).toInt();
    final amplitudes = <double>[];
    for (var index = 0; index < pointCount; index++) {
      final from = (index * audioWaveformSampleCount / pointCount).floor();
      final to = ((index + 1) * audioWaveformSampleCount / pointCount)
          .ceil()
          .clamp(from + 1, audioWaveformSampleCount)
          .toInt();
      var peak = 0;
      if (peaks != null) {
        for (var sample = from; sample < to; sample++) {
          peak = max(peak, peaks![sample]);
        }
      } else {
        peak = (118 + 65 * sin(index * 0.47) + 36 * sin(index * 1.23))
            .round()
            .clamp(30, 225)
            .toInt();
      }
      amplitudes.add(peak / 255);
    }

    final path = Path();
    for (var index = 0; index < pointCount; index++) {
      final x = index * size.width / (pointCount - 1);
      final amplitude = amplitudes[index];
      final y = centerY - 1.2 - amplitude * (centerY - verticalInset - 1.2);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        final previousX = (index - 1) * size.width / (pointCount - 1);
        final previousAmplitude = amplitudes[index - 1];
        final previousY =
            centerY - 1.2 - previousAmplitude * (centerY - verticalInset - 1.2);
        final midX = (previousX + x) / 2;
        path.quadraticBezierTo(midX, previousY, x, y);
      }
    }
    for (var index = pointCount - 1; index >= 0; index--) {
      final x = index * size.width / (pointCount - 1);
      final amplitude = amplitudes[index];
      final y =
          centerY + 1.2 + amplitude * (centerY - verticalInset - 1.2) * .62;
      if (index == pointCount - 1) {
        path.lineTo(x, y);
      } else {
        final nextX = (index + 1) * size.width / (pointCount - 1);
        final nextAmplitude = amplitudes[index + 1];
        final nextY = centerY +
            1.2 +
            nextAmplitude * (centerY - verticalInset - 1.2) * .62;
        final midX = (nextX + x) / 2;
        path.quadraticBezierTo(midX, nextY, x, y);
      }
    }
    path.close();

    canvas.save();
    canvas.clipPath(path);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, centerY),
      Paint()..color = inactiveColor.withValues(alpha: 0.16),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, centerY, size.width, size.height - centerY),
      Paint()..color = inactiveColor.withValues(alpha: 0.28),
    );
    canvas.restore();

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width * progress, size.height));
    canvas.clipPath(path);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width * progress, centerY),
      Paint()..color = activeColor.withValues(alpha: 0.46),
    );
    canvas.drawRect(
      Rect.fromLTWH(
        0,
        centerY,
        size.width * progress,
        size.height - centerY,
      ),
      Paint()..color = activeColor.withValues(alpha: 0.84),
    );
    canvas.drawLine(
      Offset(0, centerY),
      Offset(size.width * progress, centerY),
      Paint()
        ..color = activeColor.withValues(alpha: 0.88)
        ..strokeWidth = 1,
    );
    canvas.restore();

    final playheadX = size.width * progress;
    canvas.drawCircle(
      Offset(playheadX, centerY),
      5.5,
      Paint()..color = activeColor,
    );
  }

  @override
  bool shouldRepaint(covariant _AudioRibbonPainter oldDelegate) {
    return oldDelegate.peaks != peaks ||
        oldDelegate.progress != progress ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor;
  }
}

class _PlaybackTimelineLabels extends StatelessWidget {
  const _PlaybackTimelineLabels({required this.player, this.controller});

  final Player player;
  final AppAudioController? controller;

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
    if (controller != null) {
      return ListenableBuilder(
        listenable: controller.progress,
        builder: (context, _) => _buildLabels(
          context,
          controller.position,
          controller.duration,
        ),
      );
    }
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, positionSnapshot) => StreamBuilder<Duration>(
        stream: player.stream.duration,
        initialData: player.state.duration,
        builder: (context, durationSnapshot) => _buildLabels(
          context,
          positionSnapshot.data ?? Duration.zero,
          durationSnapshot.data ?? Duration.zero,
        ),
      ),
    );
  }

  Widget _buildLabels(
      BuildContext context, Duration position, Duration duration) {
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(_formatDuration(position), style: style),
        Text(_formatDuration(duration), style: style),
      ],
    );
  }
}

class _DocumentInfoPreview extends StatelessWidget {
  const _DocumentInfoPreview({
    required this.entity,
    required this.sourceResolver,
  });

  final EntityListItem entity;
  final MediaSourceResolver sourceResolver;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: FilledButton.icon(
          onPressed: () => launchUrl(sourceResolver.launchUri(entity)),
          icon: const Icon(Icons.open_in_new),
          label: const Text('系统打开'),
        ),
      ),
    );
  }
}

class _ReflowDocumentPreview extends StatefulWidget {
  const _ReflowDocumentPreview({
    super.key,
    required this.documentFuture,
    required this.initialScrollOffset,
    required this.settings,
    required this.onReaderStateChanged,
  });

  final Future<ReflowDocument?> documentFuture;
  final double? initialScrollOffset;
  final _TextReaderSettings settings;
  final ReaderStateChanged? onReaderStateChanged;

  @override
  State<_ReflowDocumentPreview> createState() => _ReflowDocumentPreviewState();
}

class _ReflowDocumentPreviewState extends State<_ReflowDocumentPreview> {
  late final ScrollController _controller;
  double? _lastPersistedOffset;
  int _chapterIndex = 0;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController(
      initialScrollOffset: widget.initialScrollOffset ?? 0,
    );
  }

  @override
  void dispose() {
    _saveState();
    unawaited(widget.documentFuture.then<void>(
      (document) => document?.archiveSession?.close(),
      onError: (_, __) {},
    ));
    _controller.dispose();
    super.dispose();
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    // SQLite writes run on the UI isolate. Saving every few hundred
    // milliseconds while the finger is moving causes visible scroll hitches.
    if (notification is ScrollEndNotification) {
      _saveState();
    }
    return false;
  }

  void _saveState() {
    if (_controller.hasClients) {
      final offset = _controller.offset;
      if (_lastPersistedOffset != null &&
          (offset - _lastPersistedOffset!).abs() < 1) {
        return;
      }
      _lastPersistedOffset = offset;
      widget.onReaderStateChanged?.call(scrollOffset: offset);
    }
  }

  void _selectChapter(int index) {
    if (index == _chapterIndex) return;
    _saveState();
    setState(() {
      _chapterIndex = index;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_controller.hasClients) _controller.jumpTo(0);
    });
  }

  void _jumpToBookmark(int offset) {
    if (_controller.hasClients) {
      _controller.animateTo(
          offset.toDouble().clamp(0, _controller.position.maxScrollExtent),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ReflowDocument?>(
      future: widget.documentFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError || snapshot.data == null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('无法读取文档：${snapshot.error ?? '内容为空'}'),
            ),
          );
        }
        final document = snapshot.data!;
        if (document.chapters.isEmpty) {
          return const Center(child: Text('文档没有可显示的内容'));
        }
        final chapterIndex =
            _chapterIndex.clamp(0, document.chapters.length - 1).toInt();
        final chapter = document.chapters[chapterIndex];
        final visibleBlocks = _spineBlocksFrom(document, chapterIndex);
        return ColoredBox(
          color: widget.settings.background,
          child: Column(
            children: [
              _ReflowReaderHeader(
                title: document.title,
                chapter: chapter.title,
                chapterIndex: chapterIndex,
                chapterCount: document.chapters.length,
                onChapterSelected: _selectChapter,
                settings: widget.settings,
                bookmarks: widget.settings.bookmarks,
                onBookmarkSelected: _jumpToBookmark,
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final blocks = visibleBlocks;
                    if (widget.settings.layoutMode ==
                            _ReaderLayoutMode.scroll ||
                        constraints.maxWidth <= constraints.maxHeight) {
                      return NotificationListener<ScrollNotification>(
                        onNotification: _handleScrollNotification,
                        child: ListView.builder(
                          controller: _controller,
                          padding: const EdgeInsets.only(top: 28, bottom: 64),
                          itemCount: blocks.length,
                          itemBuilder: (context, index) => Center(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                  maxWidth: 780 + widget.settings.padding * 2),
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                    horizontal: widget.settings.padding),
                                child: _ReflowBlockView(
                                  block: blocks[index],
                                  settings: widget.settings,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }
                    return _ReflowBookSpread(
                      blocks: blocks,
                      settings: widget.settings,
                      viewport: constraints.biggest,
                      onPageChanged: (page) => widget.onReaderStateChanged
                          ?.call(scrollOffset: page.toDouble()),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

List<ReflowBlock> _spineBlocksFrom(ReflowDocument document, int startChapter) {
  final blocks = <ReflowBlock>[];
  for (var index = startChapter; index < document.chapters.length; index++) {
    final chapter = document.chapters[index];
    final startsWithTitle = chapter.blocks.isNotEmpty &&
        chapter.blocks.first.kind == ReflowBlockKind.heading;
    // Spine documents commonly omit a visible heading. Add an anchor before
    // subsequent chapters so continuous reading still has clear boundaries.
    if (index > startChapter && !startsWithTitle && chapter.title.isNotEmpty) {
      blocks.add(ReflowBlock(
        kind: ReflowBlockKind.heading,
        level: 1,
        text: chapter.title,
      ));
    }
    blocks.addAll(chapter.blocks);
  }
  return blocks;
}

class _ReflowBookSpread extends StatefulWidget {
  const _ReflowBookSpread(
      {required this.blocks,
      required this.settings,
      required this.viewport,
      required this.onPageChanged});
  final List<ReflowBlock> blocks;
  final _TextReaderSettings settings;
  final Size viewport;
  final ValueChanged<int> onPageChanged;

  @override
  State<_ReflowBookSpread> createState() => _ReflowBookSpreadState();
}

class _ReflowBookSpreadState extends State<_ReflowBookSpread> {
  PageController? _controller;
  String? _layoutKey;
  List<List<ReflowBlock>> _pages = const [];

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pageWidth = (widget.viewport.width - 76) / 2;
    final pageHeight = widget.viewport.height - 38;
    final key =
        '${pageWidth.round()}:${pageHeight.round()}:${widget.settings.fontSize}:${widget.settings.lineHeight}:${widget.blocks.length}';
    if (_layoutKey != key) {
      _layoutKey = key;
      _pages = _paginateBookBlocks(
          widget.blocks, widget.settings, pageWidth, pageHeight);
      _controller?.dispose();
      _controller = PageController();
    }
    final pages = _pages.isEmpty ? <List<ReflowBlock>>[const []] : _pages;
    final spreadCount = (pages.length / 2).ceil();
    return PageView.builder(
      controller: _controller,
      itemCount: spreadCount,
      onPageChanged: (spread) => widget.onPageChanged(spread * 2),
      itemBuilder: (context, spread) {
        final left = pages[spread * 2];
        final rightIndex = spread * 2 + 1;
        final right = rightIndex < pages.length ? pages[rightIndex] : null;
        return Padding(
          padding: const EdgeInsets.fromLTRB(28, 16, 28, 22),
          child: Row(children: [
            Expanded(child: _BookPage(blocks: left, settings: widget.settings)),
            const SizedBox(width: 20),
            Expanded(
                child: right == null
                    ? const SizedBox.shrink()
                    : _BookPage(blocks: right, settings: widget.settings)),
          ]),
        );
      },
    );
  }
}

class _BookPage extends StatelessWidget {
  const _BookPage({required this.blocks, required this.settings});
  final List<ReflowBlock> blocks;
  final _TextReaderSettings settings;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: settings.foreground.withValues(alpha: .14)),
          color: settings.background.withValues(alpha: .62),
        ),
        child: ClipRect(
            child: Padding(
          padding: EdgeInsets.all(settings.padding),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final block in blocks)
              _ReflowBlockView(block: block, settings: settings),
          ]),
        )),
      );
}

List<List<ReflowBlock>> _paginateBookBlocks(List<ReflowBlock> source,
    _TextReaderSettings settings, double width, double height) {
  final pages = <List<ReflowBlock>>[];
  var page = <ReflowBlock>[];
  var remaining = height - settings.padding * 2;
  void finish() {
    if (page.isNotEmpty) pages.add(page);
    page = <ReflowBlock>[];
    remaining = height - settings.padding * 2;
  }

  for (final sourceBlock in source) {
    if (sourceBlock.kind == ReflowBlockKind.image) {
      if (page.isNotEmpty) finish();
      page.add(sourceBlock);
      finish();
      continue;
    }
    var text = sourceBlock.text ?? '';
    if (text.isEmpty) {
      page.add(sourceBlock);
      continue;
    }
    while (text.isNotEmpty) {
      final style = _bookTextStyle(sourceBlock, settings);
      final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: TextDirection.ltr)
        ..layout(maxWidth: width - settings.padding * 2);
      final spacing = _bookBlockSpacing(sourceBlock);
      final metrics = painter.computeLineMetrics();
      final lineHeight = style.height == null
          ? style.fontSize! * 1.2
          : style.fontSize! * style.height!;
      final allowed = ((remaining - spacing) / lineHeight).floor();
      if (allowed <= 0 && page.isNotEmpty) {
        finish();
        continue;
      }
      if (metrics.length <= allowed || allowed <= 0) {
        page.add(ReflowBlock(
            kind: sourceBlock.kind, text: text, level: sourceBlock.level));
        remaining -= painter.height + spacing;
        text = '';
      } else {
        final end = painter
            .getPositionForOffset(
                Offset(width - settings.padding * 2, lineHeight * allowed - 1))
            .offset
            .clamp(1, text.length)
            .toInt();
        page.add(ReflowBlock(
            kind: sourceBlock.kind,
            text: text.substring(0, end).trimRight(),
            level: sourceBlock.level));
        text = text.substring(end).trimLeft();
        finish();
      }
    }
  }
  if (page.isNotEmpty) pages.add(page);
  return pages;
}

TextStyle _bookTextStyle(ReflowBlock block, _TextReaderSettings settings) {
  final base = TextStyle(
      fontFamily: settings.fontFamily,
      fontSize: settings.fontSize,
      height: settings.lineHeight,
      color: settings.foreground);
  return block.kind == ReflowBlockKind.heading
      ? base.copyWith(
          fontSize: settings.fontSize + 5,
          fontWeight: FontWeight.w700,
          height: 1.25)
      : base;
}

double _bookBlockSpacing(ReflowBlock block) => switch (block.kind) {
      ReflowBlockKind.heading => 25,
      ReflowBlockKind.paragraph => 16,
      ReflowBlockKind.quote => 16,
      ReflowBlockKind.bullet => 9,
      ReflowBlockKind.code => 16,
      ReflowBlockKind.divider => 36,
      ReflowBlockKind.image => 18
    };

class _ReflowReaderHeader extends StatelessWidget {
  const _ReflowReaderHeader({
    required this.title,
    required this.chapter,
    required this.chapterIndex,
    required this.chapterCount,
    required this.onChapterSelected,
    required this.settings,
    required this.bookmarks,
    required this.onBookmarkSelected,
  });

  final String title;
  final String chapter;
  final int chapterIndex;
  final int chapterCount;
  final ValueChanged<int> onChapterSelected;
  final _TextReaderSettings settings;
  final List<int> bookmarks;
  final ValueChanged<int> onBookmarkSelected;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
            bottom:
                BorderSide(color: settings.foreground.withValues(alpha: .18))),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                chapterCount > 1 ? '$title  ·  $chapter' : title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: settings.foreground,
                    ),
              ),
            ),
            if (chapterCount > 1)
              DropdownButton<int>(
                dropdownColor: settings.background,
                value: chapterIndex,
                underline: const SizedBox.shrink(),
                items: List.generate(
                  chapterCount,
                  (index) => DropdownMenuItem(
                    value: index,
                    child: Text('第 ${index + 1} 章',
                        style: TextStyle(color: settings.foreground)),
                  ),
                ),
                onChanged: (value) {
                  if (value != null) onChapterSelected(value);
                },
              ),
            if (bookmarks.isNotEmpty)
              PopupMenuButton<int>(
                tooltip: '书签',
                icon:
                    Icon(Icons.bookmarks_outlined, color: settings.foreground),
                onSelected: onBookmarkSelected,
                itemBuilder: (context) => bookmarks
                    .map((offset) => PopupMenuItem(
                          value: offset,
                          child: Text('位置 ${offset}px',
                              style: TextStyle(color: settings.foreground)),
                        ))
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReflowBlockView extends StatelessWidget {
  const _ReflowBlockView({required this.block, required this.settings});

  final ReflowBlock block;
  final _TextReaderSettings settings;

  TextStyle get _bodyStyle => TextStyle(
        fontFamily: settings.fontFamily,
        fontSize: settings.fontSize,
        height: settings.lineHeight,
        color: settings.foreground,
      );

  @override
  Widget build(BuildContext context) {
    final text = block.text ?? '';
    switch (block.kind) {
      case ReflowBlockKind.heading:
        final size = (settings.fontSize + 12 - block.level * 1.3)
            .clamp(settings.fontSize + 2, settings.fontSize + 11)
            .toDouble();
        return Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 13),
          child: SelectableText(
            text,
            style: _bodyStyle.copyWith(
                fontSize: size, fontWeight: FontWeight.w700, height: 1.25),
          ),
        );
      case ReflowBlockKind.quote:
        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
          decoration: BoxDecoration(
            border: Border(
                left: BorderSide(
                    color: Theme.of(context).colorScheme.primary, width: 3)),
            color: Theme.of(context)
                .colorScheme
                .primaryContainer
                .withValues(alpha: 0.26),
          ),
          child: SelectableText(text,
              style: _bodyStyle.copyWith(fontStyle: FontStyle.italic)),
        );
      case ReflowBlockKind.bullet:
        return Padding(
          padding: const EdgeInsets.only(bottom: 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(top: settings.fontSize * 0.44),
                child: Icon(Icons.circle, size: 5, color: settings.foreground),
              ),
              const SizedBox(width: 11),
              Expanded(child: SelectableText(text, style: _bodyStyle)),
            ],
          ),
        );
      case ReflowBlockKind.code:
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color:
                Colors.black.withValues(alpha: settings.isDark ? 0.24 : 0.08),
            borderRadius: BorderRadius.circular(6),
          ),
          child: SelectableText(
            text,
            style: _bodyStyle.copyWith(
                fontFamily: 'Consolas', fontSize: settings.fontSize - 1),
          ),
        );
      case ReflowBlockKind.image:
        final image = block.imageBytes;
        final epubPath = block.imageEpubPath;
        final archivePath = block.imageArchivePath;
        final archiveSession = block.archiveSession;
        if (image == null && (epubPath == null || archivePath == null)) {
          return const SizedBox.shrink();
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            // A stable stage prevents an arriving lazy EPUB image from
            // changing the sliver extent beneath the reader's current offset.
            final height = (constraints.maxWidth * .75).clamp(240.0, 520.0);
            return Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: SizedBox(
                width: double.infinity,
                height: height,
                child: image != null
                    ? Image.memory(image, fit: BoxFit.contain)
                    : _DeferredEpubImage(
                        key: ValueKey('$epubPath::$archivePath'),
                        epubPath: epubPath!,
                        archivePath: archivePath!,
                        session: archiveSession,
                      ),
              ),
            );
          },
        );
      case ReflowBlockKind.divider:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Divider(color: settings.foreground.withValues(alpha: 0.25)),
        );
      case ReflowBlockKind.paragraph:
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: SelectableText(text, style: _bodyStyle),
        );
    }
  }
}

class _DeferredEpubImage extends StatefulWidget {
  const _DeferredEpubImage({
    super.key,
    required this.epubPath,
    required this.archivePath,
    this.session,
  });
  final String epubPath;
  final String archivePath;
  final ArchiveSession? session;

  @override
  State<_DeferredEpubImage> createState() => _DeferredEpubImageState();
}

class _DeferredEpubImageState extends State<_DeferredEpubImage> {
  late Future<Uint8List?> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _loadBytes();
  }

  @override
  void didUpdateWidget(covariant _DeferredEpubImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.epubPath != widget.epubPath ||
        oldWidget.archivePath != widget.archivePath ||
        oldWidget.session != widget.session) {
      _bytes = _loadBytes();
    }
  }

  Future<Uint8List?> _loadBytes() async {
    // Do not capture `widget` in the isolate closure. A StatefulWidget is
    // attached to Flutter's UI object graph and is not sendable between
    // isolates; only the two plain path strings may cross this boundary.
    final epubPath = widget.epubPath;
    final archivePath = widget.archivePath;
    final session = widget.session;
    if (session != null) {
      return Future<Uint8List?>.value(session.readBytes(archivePath));
    }
    try {
      return await Isolate.run(
        () => readEpubImageAtPath(epubPath, archivePath),
      );
    } catch (error, stackTrace) {
      debugPrint(
        'EPUB image load failed (${widget.archivePath}): $error\n$stackTrace',
      );
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
        future: _bytes,
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null) {
            if (snapshot.hasError) {
              debugPrint(
                'EPUB image unavailable (${widget.archivePath}): ${snapshot.error}',
              );
              return _EpubImageFailure(
                archivePath: widget.archivePath,
                error: snapshot.error,
              );
            }
            if (snapshot.connectionState == ConnectionState.done) {
              return _EpubImageFailure(
                archivePath: widget.archivePath,
                error: const FormatException('读取结果为空。'),
              );
            }
            return const AspectRatio(
              aspectRatio: 1.6,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, error, stackTrace) {
              debugPrint(
                'EPUB image render failed (${widget.archivePath}): $error\n$stackTrace',
              );
              return _EpubImageFailure(
                archivePath: widget.archivePath,
                error: error,
              );
            },
          );
        },
      );
}

class _EpubImageFailure extends StatelessWidget {
  const _EpubImageFailure({required this.archivePath, required this.error});

  final String archivePath;
  final Object? error;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        height: double.infinity,
        padding: const EdgeInsets.all(16),
        color:
            Theme.of(context).colorScheme.errorContainer.withValues(alpha: .55),
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          child: SelectableText(
            'EPUB 图片加载失败\n\n内部路径：$archivePath\n\n错误：$error',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onErrorContainer,
              fontFamily: 'Consolas',
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ),
      );
}

String _formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) return '$hours:$minutes:$seconds';
  return '$minutes:$seconds';
}

Duration _clampDuration(Duration value, Duration max) {
  if (value < Duration.zero) return Duration.zero;
  if (max > Duration.zero && value > max) return max;
  return value;
}

void _changeVolume(Player player, double delta) {
  final next = (player.state.volume + delta).clamp(0, 100).toDouble();
  player.setVolume(next);
}

bool _isPlayableMedia(EntityListItem entity) {
  return FileFormatRegistry.isPlayableFormat(entity.format);
}
