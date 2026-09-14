part of 'builtin_media_page.dart';

class _PdfPreview extends StatefulWidget {
  const _PdfPreview({
    super.key,
    required this.sessions,
    required this.entity,
    required this.sourceResolver,
    required this.onReaderStateChanged,
  });

  final EntityListItem entity;
  final ViewerSessions sessions;
  final MediaSourceResolver sourceResolver;
  final ReaderStateChanged onReaderStateChanged;

  @override
  State<_PdfPreview> createState() => _PdfPreviewState();
}

class _PdfPreviewState extends State<_PdfPreview> {
  PdfViewerController? _controller;
  late final LeasedDocumentSession<PdfDocument> _documentSession;
  late final ViewerSession _session;
  PdfDocumentRefDirect? _documentRef;
  PdfDocumentListenable? _documentListenable;
  bool _closed = false;
  late int _currentPage;
  int? _pageCount;
  late final Set<int> _bookmarks;

  @override
  void initState() {
    super.initState();
    _currentPage = _restoredPdfPage(widget.entity);
    _bookmarks = _restoredPdfBookmarks(widget.entity);
    _documentSession = LeasedDocumentSession(
      source: widget.sourceResolver.acquireFile(widget.entity),
      open: (lease) async {
        await pdfrxFlutterInitialize();
        return PdfDocument.openFile(lease.file.path,
            useProgressiveLoading: true);
      },
      disposeDocument: (document) => document.dispose(),
    );
    _session = widget.sessions.register(() async {
      _persistReaderState();
      _closed = true;
      // Finish reference publication before detaching, including a late load.
      final listenable = _documentListenable;
      if (listenable != null) {
        await listenable.load();
        listenable.setError(StateError('Viewer closed'));
      }
      _controller = null;
      await _documentSession.close();
    });
  }

  @override
  void dispose() {
    unawaited(_session.close().catchError((Object error, StackTrace stack) {
      debugPrint('PDF close failed: $error\n$stack');
    }));
    super.dispose();
  }

  void _persistReaderState() {
    if (_closed) return;
    widget.onReaderStateChanged(
      zoomScale: _controller?.isReady == true ? _controller!.currentZoom : null,
      extraStateJson: jsonEncode({
        'readingPosition': {
          'version': 1,
          'kind': 'pdf',
          'sourceRevision': widget.entity.sourceRevision,
          'page': _currentPage,
        },
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
    if (_closed || !mounted || pageNumber == null || pageNumber < 1) return;
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
    if (_closed) return const SizedBox.shrink();
    return FutureBuilder<PdfDocument>(
      future: _documentSession.document,
      builder: (context, snapshot) {
        if (_closed) return const SizedBox.shrink();
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return _MissingSourceNotice(
            path:
                '${snapshot.error ?? widget.sourceResolver.displayLocation(widget.entity)}',
          );
        }
        _documentRef ??= PdfDocumentRefDirect(snapshot.data!,
            autoDispose: false,
            key: PdfDocumentRefKey(widget.entity.path, [Object()]));
        _documentListenable ??= _documentRef!.resolveListenable();
        return _buildLoaded(context);
      },
    );
  }

  Widget _buildLoaded(BuildContext context) {
    final pageLabel = _pageCount == null
        ? '第 $_currentPage 页'
        : '第 $_currentPage / $_pageCount 页';
    return ColoredBox(
        color: const Color(0xff102c28),
        child: Stack(
          children: [
            PdfViewer(
              _documentRef!,
              initialPageNumber: _currentPage,
              params: PdfViewerParams(
                onPageChanged: _onPageChanged,
                onViewerReady: (document, controller) {
                  if (!mounted || _closed) return;
                  _controller = controller;
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
        final position = decoded['readingPosition'];
        final stored = position is Map && position['kind'] == 'pdf'
            ? position['page']
            : decoded['pdfPage'];
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
