part of 'builtin_media_page.dart';

class _VideoPlayerPreview extends StatefulWidget {
  const _VideoPlayerPreview({
    super.key,
    required this.sessions,
    required this.entity,
    required this.sourceResolver,
    this.transparentStage = false,
    this.onClose,
    this.onReturnToSource,
    this.onPrevious,
    this.onNext,
    this.onShowDetails,
    this.onDirectoryRoot,
    required this.onCompleted,
    required this.onPlaybackStateChanged,
  });

  final EntityListItem entity;
  final ViewerSessions sessions;
  final MediaSourceResolver sourceResolver;
  final bool transparentStage;
  final VoidCallback? onClose;
  final VoidCallback? onReturnToSource;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onShowDetails;
  final VoidCallback? onDirectoryRoot;
  final MediaCompleted onCompleted;
  final PlaybackStateChanged? onPlaybackStateChanged;

  @override
  State<_VideoPlayerPreview> createState() => _VideoPlayerPreviewState();
}

class _VideoPlayerPreviewState extends State<_VideoPlayerPreview> {
  late final ViewerSession _session;
  late final Player _player;
  late final VideoController _controller;
  final MediaPlayerLifecycle _lifecycle = MediaPlayerLifecycle();
  Future<void> _openChain = Future<void>.value();
  Future<void>? _closeFuture;
  int _activeGeneration = 0;
  SourceFileLease? _sourceLease;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<String>? _errorSubscription;
  Timer? _controlsTimer;
  Timer? _progressSaveTimer;
  Object? _loadError;
  bool _controlsVisible = true;

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
    _errorSubscription = _player.stream.error.listen((message) {
      if (!mounted || !_lifecycle.isCurrent(_activeGeneration)) return;
      AppDiagnosticLog.instance.error(
          'video_player_async_failed', StateError(message), StackTrace.current,
          fields: {'entityId': widget.entity.id, 'path': widget.entity.path});
      setState(() => _loadError = message);
    });
    _open();
    _progressSaveTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _savePlaybackState());
    _session = widget.sessions.register(_close);
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
      await _player.stop();
      await _sourceLease?.close();
      _sourceLease = null;
      final lease = await widget.sourceResolver.acquireFile(widget.entity);
      if (!_lifecycle.isCurrent(generation)) {
        await lease.close();
        return;
      }
      _sourceLease = lease;
      final source = MediaSourceResolver.playbackSourceForFile(lease.file);
      _activeGeneration = generation;
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
        AppDiagnosticLog.instance.error(
            'video_player_open_failed', error, StackTrace.current,
            fields: {
              'entityId': widget.entity.id,
              'size': widget.entity.size,
              'sourceMode': MediaSourceResolver.bypassSourceCache(widget.entity)
                  ? 'direct'
                  : 'temporary'
            });
        setState(() => _loadError = error);
      }
    }
  }

  @override
  void dispose() {
    unawaited(_session.close().catchError((Object error, StackTrace stack) {
      debugPrint('Video close failed: $error\n$stack');
    }));
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
      if (_errorSubscription != null) _errorSubscription!.cancel(),
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
    } finally {
      await _sourceLease?.close();
      _sourceLease = null;
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
                left: 12,
                right: 12,
                bottom: 12,
                child: _VideoOverlayVisibility(
                  visible: _controlsVisible,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 900),
                      child: _VideoControlBar(
                        player: _player,
                        onBack: widget.onReturnToSource,
                        onPrevious: widget.onPrevious,
                        onNext: widget.onNext,
                        onShowDetails: widget.onShowDetails,
                        onDirectoryRoot: widget.onDirectoryRoot,
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

class _VideoControlBar extends StatelessWidget {
  const _VideoControlBar({
    required this.player,
    this.onBack,
    this.onPrevious,
    this.onNext,
    this.onShowDetails,
    this.onDirectoryRoot,
  });

  final Player player;
  final VoidCallback? onBack;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onShowDetails;
  final VoidCallback? onDirectoryRoot;

  @override
  Widget build(BuildContext context) {
    return FloatingGlassSurface(
      borderRadius: 24,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 38,
            child: _VideoProgressTouchZone(player: player),
          ),
          SizedBox(
            height: 48,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: _PlaybackActionRow(
                player: player,
                onBack: onBack,
                onPrevious: onPrevious,
                onNext: onNext,
                onShowDetails: onShowDetails,
                onDirectoryRoot: onDirectoryRoot,
              ),
            ),
          ),
        ],
      ),
    );
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
    this.onShowDetails,
    this.onDirectoryRoot,
  });

  final Player player;
  final VoidCallback? onBack;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onShowDetails;
  final VoidCallback? onDirectoryRoot;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onBack != null)
          _compactIconButton(
            tooltip: '返回所在位置',
            onPressed: onBack,
            icon: Icons.arrow_back_rounded,
          ),
        if (onDirectoryRoot != null)
          _compactIconButton(
            tooltip: '返回目录',
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
            tooltip: '上一个文件',
            onPressed: onPrevious,
            icon: Icons.skip_previous_rounded,
          ),
        if (onNext != null)
          _compactIconButton(
            tooltip: '下一个文件',
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
                    tool(Icons.account_tree_outlined, '返回目录', onDirectoryRoot),
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
            return StreamBuilder<Duration>(
              stream: widget.player.stream.buffer,
              initialData: widget.player.state.buffer,
              builder: (context, bufferSnapshot) => _buildSlider(
                positionSnapshot.data ?? Duration.zero,
                durationSnapshot.data ?? Duration.zero,
                bufferSnapshot.data ?? Duration.zero,
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSlider(Duration position, Duration duration, Duration buffer) {
    final max = duration.inMilliseconds.toDouble();
    final value = _dragValue ??
        position.inMilliseconds.clamp(0, duration.inMilliseconds).toDouble();
    return Slider(
      min: 0,
      max: max <= 0 ? 1 : max,
      value: max <= 0 ? 0 : value,
      secondaryTrackValue:
          max <= 0 ? 0 : buffer.inMilliseconds.toDouble().clamp(0, max),
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
