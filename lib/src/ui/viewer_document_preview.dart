part of 'builtin_media_page.dart';

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
    this.initialPosition,
    this.sourceRevision = 1,
    required this.settings,
    required this.onReaderStateChanged,
  });

  final Future<ReflowDocument?> documentFuture;
  final double? initialScrollOffset;
  final ReadingPosition? initialPosition;
  final int sourceRevision;
  final _TextReaderSettings settings;
  final ReaderStateChanged? onReaderStateChanged;

  @override
  State<_ReflowDocumentPreview> createState() => _ReflowDocumentPreviewState();
}

class _ReflowDocumentPreviewState extends State<_ReflowDocumentPreview> {
  late final ScrollController _controller;
  double? _lastPersistedOffset;
  int _chapterIndex = 0;
  String _chapterTitle = '';
  bool _restored = false;
  int _page = 0;
  bool _bookMode = false;
  final _blockWidgets = <int, GlobalKey>{};
  final _viewportKey = GlobalKey();
  List<String> _blockKeys = const [];
  ReflowDocument? _indexedDocument;
  int? _indexedChapter;
  List<ReflowBlock> _indexedBlocks = const [];
  int _block = 0;
  double _blockFraction = 0;
  bool _anchorRestoring = false;

  String _contentKey(ReflowBlock block) => readingBlockKey(
      '${block.kind.name}:${block.text ?? block.imageArchivePath ?? block.imageEpubPath ?? block.altText ?? ''}');

  void _captureAnchor() {
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox) return;
    final top = viewport.localToGlobal(Offset.zero).dy;
    for (final entry in _blockWidgets.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key))) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final y = box.localToGlobal(Offset.zero).dy;
      if (y + box.size.height <= top) continue;
      if (y >= top + viewport.size.height) continue;
      _block = entry.key;
      _blockFraction =
          box.size.height > 0 ? ((top - y) / box.size.height).clamp(0, 1) : 0;
      break;
    }
    _blockWidgets.removeWhere((_, key) => key.currentContext == null);
  }

  Future<void> _restoreAnchor(int target, double fraction) async {
    _anchorRestoring = true;
    try {
      for (var attempt = 0; attempt < 40 && mounted; attempt++) {
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || !_controller.hasClients) return;
        final box = _blockWidgets[target]?.currentContext?.findRenderObject();
        final viewport = _viewportKey.currentContext?.findRenderObject();
        if (box is RenderBox && viewport is RenderBox) {
          final delta = box.localToGlobal(Offset.zero).dy -
              viewport.localToGlobal(Offset.zero).dy +
              box.size.height * fraction;
          _controller.jumpTo((_controller.offset + delta)
              .clamp(0, _controller.position.maxScrollExtent));
          return;
        }
        final visible = _blockWidgets.entries
            .where((e) => e.value.currentContext != null)
            .map((e) => e.key)
            .toList()
          ..sort();
        if (visible.isEmpty) return;
        final direction = target < visible.first ? -1 : 1;
        final next = (_controller.offset +
                direction * _controller.position.viewportDimension * 2)
            .clamp(0, _controller.position.maxScrollExtent);
        if (next == _controller.offset) return;
        _controller.jumpTo(next.toDouble());
      }
    } finally {
      _anchorRestoring = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _controller = ScrollController(
      initialScrollOffset: widget.initialPosition != null
          ? (widget.initialPosition!.sourceRevision == widget.sourceRevision
              ? widget.initialPosition!.scrollOffset
              : 0)
          : (widget.settings.layoutMode == _ReaderLayoutMode.scroll
              ? widget.initialScrollOffset ?? 0
              : 0),
    );
    _page = widget.initialPosition?.sourceRevision == widget.sourceRevision
        ? widget.initialPosition!.page
        : 0;
  }

  @override
  void dispose() {
    _saveState();
    unawaited(widget.documentFuture.then<void>(
      (document) => document?.close(),
      onError: (_, __) {},
    ));
    _controller.dispose();
    super.dispose();
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    // Save at interaction boundaries; avoid writes for every scroll event.
    if (notification is ScrollEndNotification) {
      _saveState();
    }
    return false;
  }

  void _saveState() {
    if (!_restored || _anchorRestoring) return;
    if (!_bookMode) _captureAnchor();
    final offset =
        _controller.hasClients ? _controller.offset : _lastPersistedOffset ?? 0;
    _lastPersistedOffset = offset;
    final position = ReadingPosition(
        sourceRevision: widget.sourceRevision,
        chapter: _chapterIndex,
        chapterTitle: _chapterTitle,
        scrollOffset: offset,
        page: _page,
        block: _block,
        blockKey: _block < _blockKeys.length ? _blockKeys[_block] : '',
        blockFraction: _blockFraction,
        mode: _bookMode ? 'book' : 'scroll');
    widget.onReaderStateChanged?.call(
        extraStateJson: jsonEncode({'readingPosition': position.toMap()}));
  }

  void _selectChapter(int index) {
    if (index == _chapterIndex) return;
    _saveState();
    setState(() {
      _chapterIndex = index;
      _page = 0;
      _lastPersistedOffset = 0;
      _blockWidgets.clear();
      _block = 0;
      _blockFraction = 0;
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
        final firstLayout = !_restored;
        if (!_restored) {
          _chapterIndex = widget.initialPosition?.resolveChapter(
                  document.chapters.map((chapter) => chapter.title).toList()) ??
              0;
          _restored = true;
        }
        final chapterIndex =
            _chapterIndex.clamp(0, document.chapters.length - 1).toInt();
        final chapter = document.chapters[chapterIndex];
        _chapterTitle = chapter.title;
        if (!identical(_indexedDocument, document) ||
            _indexedChapter != chapterIndex) {
          _indexedDocument = document;
          _indexedChapter = chapterIndex;
          _indexedBlocks = _spineBlocksFrom(document, chapterIndex);
          _blockKeys = _indexedBlocks.map(_contentKey).toList(growable: false);
        }
        final visibleBlocks = _indexedBlocks;
        if (firstLayout &&
            widget.initialPosition?.blockKey.isNotEmpty == true) {
          _block = widget.initialPosition!.resolveBlock(_blockKeys);
          _blockFraction = widget.initialPosition!.blockFraction;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_bookMode) {
              unawaited(_restoreAnchor(_block, _blockFraction));
            }
          });
        }
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
                    _bookMode =
                        widget.settings.layoutMode == _ReaderLayoutMode.book &&
                            constraints.maxWidth > constraints.maxHeight;
                    final blocks = visibleBlocks;
                    if (widget.settings.layoutMode ==
                            _ReaderLayoutMode.scroll ||
                        constraints.maxWidth <= constraints.maxHeight) {
                      return NotificationListener<ScrollNotification>(
                        onNotification: _handleScrollNotification,
                        child: ListView.builder(
                          key: _viewportKey,
                          controller: _controller,
                          padding: const EdgeInsets.only(top: 28, bottom: 64),
                          itemCount: blocks.length,
                          itemBuilder: (context, index) => Center(
                            key:
                                _blockWidgets.putIfAbsent(index, GlobalKey.new),
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
                      key: ValueKey(chapterIndex),
                      initialPage: _page,
                      blocks: blocks,
                      settings: widget.settings,
                      viewport: constraints.biggest,
                      onPageChanged: (page) {
                        _page = page;
                        _saveState();
                      },
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
      {super.key,
      this.initialPage = 0,
      required this.blocks,
      required this.settings,
      required this.viewport,
      required this.onPageChanged});
  final List<ReflowBlock> blocks;
  final int initialPage;
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
      final previousPage = _controller?.hasClients == true
          ? (_controller!.page ?? 0).round()
          : widget.initialPage ~/ 2;
      _controller?.dispose();
      _controller = PageController(
          initialPage:
              previousPage.clamp(0, max(0, (_pages.length / 2).ceil() - 1)));
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
