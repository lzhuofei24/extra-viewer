import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';

import '../domain/models.dart';
import 'app_audio_controller.dart';

/// Mirrors the app player into Android's media session; owns no second player.
class AndroidAudioHandler extends BaseAudioHandler {
  static AndroidAudioHandler? instance;
  AppAudioController? _controller;
  AudioSession? _audioSession;

  static Future<void> initialize() async {
    if (!Platform.isAndroid || instance != null) return;
    final handler = await AudioService.init(
      builder: AndroidAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.lzhuofei.extraviewer.music',
        androidNotificationChannelName: '音乐播放',
        androidNotificationIcon: 'drawable/ic_music_notification',
        androidStopForegroundOnPause: false,
      ),
    );
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    handler._audioSession = session;
    session.interruptionEventStream.listen((event) {
      // Resume only on an explicit user action after an interruption.
      if (event.begin) unawaited(handler.pause());
    });
    session.becomingNoisyEventStream.listen((_) => unawaited(handler.pause()));
    instance = handler;
  }

  Future<bool> requestFocus() async =>
      await _audioSession?.setActive(true) ?? true;

  void attach(AppAudioController controller) {
    detach();
    _controller = controller;
    controller.addListener(_publish);
    controller.progress.addListener(_publish);
    _publish();
  }

  void detach() {
    _controller?.removeListener(_publish);
    _controller?.progress.removeListener(_publish);
    _controller = null;
    _publish();
  }

  void _publish() {
    final controller = _controller;
    final current = controller?.current;
    if (controller == null || current == null) {
      mediaItem.add(null);
      playbackState
          .add(PlaybackState(processingState: AudioProcessingState.idle));
      return;
    }
    final duration = controller.duration > Duration.zero
        ? controller.duration
        : Duration(milliseconds: current.durationMs ?? 0);
    if (mediaItem.value?.id != current.id ||
        mediaItem.value?.duration != duration) {
      mediaItem.add(MediaItem(
          id: current.id,
          title: current.title,
          album: controller.session?.name,
          duration: duration));
    }
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        controller.isPlaying ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop
      ],
      androidCompactActionIndices: const [0, 1, 2],
      systemActions: const {MediaAction.seek},
      processingState: controller.error != null
          ? AudioProcessingState.error
          : controller.opening
              ? AudioProcessingState.loading
              : AudioProcessingState.ready,
      playing: controller.isPlaying,
      updatePosition: controller.position,
      errorCode: controller.error == null ? null : 1,
      errorMessage: controller.error == null ? null : '音频播放失败',
      repeatMode: controller.mode == AudioPlaybackMode.singleRepeat
          ? AudioServiceRepeatMode.one
          : AudioServiceRepeatMode.all,
      shuffleMode: controller.mode == AudioPlaybackMode.nodeShuffle
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
    ));
  }

  @override
  Future<void> play() async => _controller?.play();
  @override
  Future<void> pause() async => _controller?.pause();
  @override
  Future<void> skipToNext() async => _controller?.next();
  @override
  Future<void> skipToPrevious() async => _controller?.previous();
  @override
  Future<void> seek(Duration position) async {
    final controller = _controller;
    if (controller == null) return;
    await controller.initializedPlayer?.seek(position);
  }

  @override
  Future<void> stop() async {
    await _controller?.stopAndClear();
    await _audioSession?.setActive(false);
    await super.stop();
  }
}
