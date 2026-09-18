part of 'builtin_media_page.dart';

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
