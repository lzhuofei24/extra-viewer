import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/media/app_audio_controller.dart';
import '../core/media/audio_waveform_service.dart';
import 'builtin_media_page.dart';

/// A global audio surface. It deliberately has no entity-navigation context.
class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({
    super.key,
    required this.controller,
    required this.waveformService,
  });

  final AppAudioController controller;
  final AudioWaveformService waveformService;

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  Future<Uint8List?>? _waveform;
  final AudioTimelineScrubController _scrubController =
      AudioTimelineScrubController();
  String? _waveformEntityId;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncWaveform);
    _syncWaveform();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncWaveform);
    _scrubController.dispose();
    super.dispose();
  }

  void _syncWaveform() {
    final entity = widget.controller.current;
    if (entity == null || entity.id == _waveformEntityId) return;
    _waveformEntityId = entity.id;
    _scrubController.clear();
    if (mounted) {
      setState(() {
        _waveform = widget.waveformService.ensure(
          path: entity.path,
          fingerprint: entity.hash,
          durationMs: entity.durationMs,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final current = widget.controller.current;
          if (current == null) {
            return Center(
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back_rounded),
                label: const Text('没有正在播放的音乐'),
              ),
            );
          }
          final waveform = _waveform;
          return SafeArea(
            child: Stack(children: [
              Positioned(
                top: 8,
                left: 12,
                child: IconButton(
                  tooltip: '返回',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 64, 16, 172),
                    child: AudioNowPlayingPanel(
                      entity: current,
                      player: widget.controller.player,
                      waveformFuture: waveform ?? Future.value(null),
                      scrubController: _scrubController,
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 920),
                    child: AudioPlaybackDeck(
                      player: widget.controller.player,
                      controller: widget.controller,
                      waveformFuture: waveform ?? Future.value(null),
                      scrubController: _scrubController,
                      onPrevious: widget.controller.previous,
                      onNext: widget.controller.next,
                    ),
                  ),
                ),
              ),
            ]),
          );
        },
      ),
    );
  }
}
