part of 'builtin_media_page.dart';

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
  late final Future<SourceFileLease> _sourceLease;
  late int _currentPage;
  int? _pageCount;
  late final Set<int> _bookmarks;

  @override
  void initState() {
    super.initState();
    _currentPage = _restoredPdfPage(widget.entity);
    _bookmarks = _restoredPdfBookmarks(widget.entity);
    _sourceLease = widget.sourceResolver.acquireFile(widget.entity);
    _sourceFile = _sourceLease.then((lease) => lease.file);
  }

  @override
  void dispose() {
    _persistReaderState();
    unawaited(
        _sourceLease.then<void>((lease) => lease.close(), onError: (_, __) {}));
    super.dispose();
  }

  void _persistReaderState() {
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
