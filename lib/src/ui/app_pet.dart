import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/pet/pet_controller.dart';

/// A lightweight in-app pet. Each action asset is a horizontal strip of
/// 192x208 frames, so its frame count is inferred from decoded dimensions.
class AppPet extends StatefulWidget {
  const AppPet({
    super.key,
    required this.controller,
  });

  final PetController controller;

  @override
  State<AppPet> createState() => _AppPetState();
}

class _AppPetState extends State<AppPet> {
  static const _displaySize = Size(126, 137);
  Offset? _position;
  Timer? _frameTimer;
  int _frame = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
    _startAnimation();
  }

  @override
  void didUpdateWidget(covariant AppPet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
      _frame = 0;
      _startAnimation();
    }
  }

  @override
  void dispose() {
    _frameTimer?.cancel();
    widget.controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    setState(() => _frame = 0);
    _startAnimation();
  }

  void _startAnimation() {
    _frameTimer?.cancel();
    final interval = widget.controller.reducedMotion
        ? const Duration(seconds: 2)
        : widget.controller.presentation.action.frameDuration;
    _frameTimer = Timer.periodic(interval, (_) {
      if (mounted) setState(() => _frame++);
    });
  }

  void _move(
    DragUpdateDetails details,
    BoxConstraints constraints,
    Size displaySize,
  ) {
    final current = _position ?? _initialPosition(constraints, displaySize);
    final maxX = (constraints.maxWidth - displaySize.width)
        .clamp(0.0, double.infinity)
        .toDouble();
    final maxY = (constraints.maxHeight - displaySize.height)
        .clamp(0.0, double.infinity)
        .toDouble();
    final next = Offset(
      (current.dx + details.delta.dx).clamp(0.0, maxX).toDouble(),
      (current.dy + details.delta.dy).clamp(0.0, maxY).toDouble(),
    );
    setState(() {
      _position = next;
    });
    widget.controller.setPositionRatio(
      x: maxX == 0 ? 0 : next.dx / maxX,
      y: maxY == 0 ? 0 : next.dy / maxY,
    );
  }

  Offset _initialPosition(BoxConstraints constraints, Size displaySize) {
    final ratio = widget.controller.positionRatio;
    final maxX = (constraints.maxWidth - displaySize.width)
        .clamp(0.0, double.infinity)
        .toDouble();
    final maxY = (constraints.maxHeight - displaySize.height)
        .clamp(0.0, double.infinity)
        .toDouble();
    if (ratio != null) return Offset(maxX * ratio.x, maxY * ratio.y);
    return Offset(
      (constraints.maxWidth - displaySize.width - 18)
          .clamp(12.0, double.infinity)
          .toDouble(),
      (constraints.maxHeight - displaySize.height - 116)
          .clamp(12.0, double.infinity)
          .toDouble(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final presentation = widget.controller.presentation;
    final scale = widget.controller.scale;
    final displaySize = Size(
      _displaySize.width * scale,
      _displaySize.height * scale,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final position =
            _position ?? _initialPosition(constraints, displaySize);
        return Stack(
          children: [
            Positioned(
              left: position.dx,
              top: position.dy,
              width: displaySize.width,
              height: displaySize.height,
              child: Semantics(
                button: true,
                label: '银狼桌宠',
                child: IgnorePointer(
                  ignoring: widget.controller.ignorePointer,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onPanUpdate: (details) =>
                        _move(details, constraints, displaySize),
                    onTap: () =>
                        widget.controller.trigger(PetTrigger.petTapped),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        if (presentation.bubbleText case final text?)
                          Positioned(
                            right: 0,
                            bottom: displaySize.height,
                            child: _PetSpeechBubble(
                              text: text,
                              onTap: widget.controller.clearBubble,
                            ),
                          ),
                        _PetSpriteStrip(
                          key: ValueKey(presentation.action.asset),
                          asset: presentation.action.asset,
                          frame: widget.controller.reducedMotion ? 0 : _frame,
                        ),
                      ],
                    ),
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

class _PetSpeechBubble extends StatelessWidget {
  const _PetSpeechBubble({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 190),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color:
                theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Text(text, style: theme.textTheme.labelMedium),
          ),
        ),
      ),
    );
  }
}

class _PetSpriteStrip extends StatefulWidget {
  const _PetSpriteStrip({
    super.key,
    required this.asset,
    required this.frame,
  });

  final String asset;
  final int frame;

  @override
  State<_PetSpriteStrip> createState() => _PetSpriteStripState();
}

class _PetSpriteStripState extends State<_PetSpriteStrip> {
  static const _frameAspect = 192 / 208;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    super.dispose();
  }

  void _load() {
    final stream = AssetImage(widget.asset).resolve(const ImageConfiguration());
    // The widget key is the asset path, so each action receives a fresh state.
    _stream = stream;
    _listener = ImageStreamListener((info, _) {
      if (mounted) setState(() => _image = info.image);
    });
    stream.addListener(_listener!);
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return const SizedBox.expand();
    final frameWidth = (image.height * _frameAspect).round();
    final frameCount = (image.width ~/ frameWidth).clamp(1, 999);
    return CustomPaint(
      painter: _PetFramePainter(
        image: image,
        frame: widget.frame % frameCount,
        frameWidth: frameWidth,
      ),
      size: Size.infinite,
    );
  }
}

class _PetFramePainter extends CustomPainter {
  const _PetFramePainter({
    required this.image,
    required this.frame,
    required this.frameWidth,
  });

  final ui.Image image;
  final int frame;
  final int frameWidth;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH((frame * frameWidth).toDouble(), 0, frameWidth.toDouble(),
          image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(covariant _PetFramePainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.frame != frame;
}
