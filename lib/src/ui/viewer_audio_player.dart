part of 'builtin_media_page.dart';

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
        if (widget.controller.initializedPlayer == null) {
          return const Center(child: CircularProgressIndicator());
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
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _compactIconButton(
                  tooltip: '上一首',
                  onPressed: widget.onPrevious,
                  icon: Icons.skip_previous_rounded,
                ),
                StreamBuilder<bool>(
                  stream: widget.player.stream.playing,
                  initialData: widget.player.state.playing,
                  builder: (context, snapshot) => IconButton.filled(
                    tooltip: snapshot.data == true ? '暂停' : '播放',
                    onPressed: widget.controller?.playOrPause ??
                        widget.player.playOrPause,
                    icon: Icon(snapshot.data == true
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded),
                    iconSize: 26,
                  ),
                ),
                _compactIconButton(
                  tooltip: '下一首',
                  onPressed: widget.onNext,
                  icon: Icons.skip_next_rounded,
                ),
                if (widget.controller != null)
                  _compactIconButton(
                    tooltip: '查看歌单',
                    onPressed: _showPlaylist,
                    icon: Icons.queue_music_rounded,
                  ),
                if (widget.controller != null)
                  _AudioPlaybackModeMenu(controller: widget.controller!),
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
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _buildButton(context),
    );
  }

  Widget _buildButton(BuildContext context) {
    final mode = controller.mode;
    final icon = switch (mode) {
      AudioPlaybackMode.sequential => Icons.format_list_numbered_rounded,
      AudioPlaybackMode.singleRepeat => Icons.repeat_one_rounded,
      AudioPlaybackMode.nodeRepeat => Icons.repeat_rounded,
      AudioPlaybackMode.nodeShuffle => Icons.shuffle_rounded,
    };
    return IconButton(
      tooltip: '播放模式：${mode.label}',
      onPressed: controller.cycleMode,
      icon: Icon(icon, size: 20),
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
