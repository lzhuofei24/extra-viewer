part of 'builtin_media_page.dart';

class _ImagePreview extends StatefulWidget {
  const _ImagePreview({
    super.key,
    required this.sessions,
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
  final ViewerSessions sessions;
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
  late final ViewerSession _session;
  late final TransformationController _controller;
  late final Future<File> _sourceFile;
  late final Future<SourceFileLease> _sourceLease;
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
    _sourceLease = widget.sourceResolver.acquireFile(widget.entity);
    _sourceFile = _sourceLease.then((lease) => lease.file);
    _session = widget.sessions.register(() async {
      widget.onReaderStateChanged
          ?.call(zoomScale: _controller.value.getMaxScaleOnAxis());
      await _sourceLease.then<void>((lease) async {
        if (MediaSourceResolver.bypassSourceCache(widget.entity)) {
          await FileImage(lease.file).evict();
        }
        await lease.close();
      }, onError: (_, __) {});
    });
  }

  @override
  void dispose() {
    unawaited(_session.close().catchError((Object error, StackTrace stack) {
      debugPrint('Image close failed: $error\n$stack');
    }));
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
