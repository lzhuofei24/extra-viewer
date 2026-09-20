import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:media_kit/media_kit.dart';

import '../domain/models.dart';
import '../diagnostics/app_diagnostic_log.dart';
import 'app_audio_controller.dart';

/// Mirrors the app player into Android's media session; owns no second player.
class AndroidAudioHandler extends BaseAudioHandler {
  static AndroidAudioHandler? instance;
  AppAudioController? _controller;
  AudioSession? _audioSession;
  Player? _player;
  final List<StreamSubscription<dynamic>> _playerSubscriptions = [];
  List<EntityListItem>? _publishedEntries;
  Duration? _publishedPosition;

  static Future<void>? _initializing;
  static StreamSubscription<Object>? _serviceErrors;

  static Future<void> initialize() async {
    if (!Platform.isAndroid || instance != null) return;
    await (_initializing ??=
        _initialize().whenComplete(() => _initializing = null));
  }

  static Future<void> _initialize() async {
    _serviceErrors ??= AudioService.asyncError.listen((error) {
      AppDiagnosticLog.instance
          .error('audio_service_platform_error', error, StackTrace.current);
    });
    final handler = await AudioService.init(
      builder: AndroidAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.lzhuofei.extraviewer.music',
        androidNotificationChannelName: '音乐播放',
        androidNotificationChannelDescription: '当前歌曲、播放进度和音乐控制',
        androidNotificationIcon: 'drawable/ic_music_notification',
        androidNotificationClickStartsActivity: true,
        androidStopForegroundOnPause: false,
      ),
    );
    // Media-session registration remains usable if audio-focus setup fails.
    instance = handler;
    AppDiagnosticLog.instance.info('audio_service_initialized');
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      handler._audioSession = session;
      session.interruptionEventStream.listen((event) {
        // Resume only on an explicit user action after an interruption.
        if (event.begin) unawaited(handler.pause());
      });
      session.becomingNoisyEventStream
          .listen((_) => unawaited(handler.pause()));
    } catch (error, stack) {
      AppDiagnosticLog.instance
          .error('audio_session_configuration_failed', error, stack);
    }
  }

  Future<bool> requestFocus() async =>
      await _audioSession?.setActive(true) ?? true;

  void attach(AppAudioController controller) {
    detach();
    _controller = controller;
    controller.addListener(_onControllerChanged);
    controller.progress.addListener(_onProgress);
    _bindPlayer();
    _publish();
  }

  void detach() {
    _controller?.removeListener(_onControllerChanged);
    _controller?.progress.removeListener(_onProgress);
    for (final subscription in _playerSubscriptions) {
      unawaited(subscription.cancel());
    }
    _playerSubscriptions.clear();
    _player = null;
    _publishedEntries = null;
    _publishedPosition = null;
    _controller = null;
    _publish();
  }

  void _onControllerChanged() {
    _bindPlayer();
    _publish();
  }

  void _onProgress() {
    final position = _controller?.position ?? Duration.zero;
    if (_publishedPosition == null ||
        (position - _publishedPosition!).abs() >= const Duration(seconds: 1) ||
        mediaItem.value?.duration != _controller?.duration) {
      _publish();
    }
  }

  void _bindPlayer() {
    final player = _controller?.initializedPlayer;
    if (identical(player, _player)) return;
    for (final subscription in _playerSubscriptions) {
      unawaited(subscription.cancel());
    }
    _playerSubscriptions.clear();
    _player = player;
    if (player == null) return;
    // Observe the engine itself, not only UI/controller notifications.
    void changed(dynamic _) {
      if (identical(player, _player)) _publish();
    }

    _playerSubscriptions.addAll([
      player.stream.playing.listen(changed),
      player.stream.buffering.listen(changed),
      player.stream.completed.listen(changed),
      player.stream.duration.listen(changed),
      player.stream.rate.listen(changed),
    ]);
  }

  void _publish() {
    final controller = _controller;
    final current = controller?.current;
    if (controller == null || current == null) {
      queue.add(const []);
      mediaItem.add(null);
      playbackState
          .add(PlaybackState(processingState: AudioProcessingState.idle));
      return;
    }
    final entries = controller.session?.entries;
    if (!identical(entries, _publishedEntries)) {
      _publishedEntries = entries;
      queue.add((entries ?? [current])
          .map((entry) => MediaItem(
                id: entry.id,
                title: entry.title,
                album: controller.session?.name,
                duration: entry.durationMs == null
                    ? null
                    : Duration(milliseconds: entry.durationMs!),
              ))
          .toList(growable: false));
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
    _publishedPosition = controller.position;
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        controller.isPlaying ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop
      ],
      androidCompactActionIndices: const [0, 1, 2],
      systemActions: const {
        MediaAction.seek,
        MediaAction.play,
        MediaAction.pause,
        MediaAction.stop,
        MediaAction.skipToPrevious,
        MediaAction.skipToNext,
        MediaAction.setRepeatMode,
        MediaAction.setShuffleMode,
        MediaAction.setSpeed
      },
      processingState: controller.error != null
          ? AudioProcessingState.error
          : controller.opening
              ? AudioProcessingState.loading
              : _player?.state.buffering == true
                  ? AudioProcessingState.buffering
                  : _player?.state.completed == true
                      ? AudioProcessingState.completed
                      : AudioProcessingState.ready,
      playing: controller.isPlaying,
      updatePosition: controller.position,
      bufferedPosition: _player?.state.buffer ?? Duration.zero,
      speed: _player?.state.rate ?? 1,
      queueIndex: controller.session?.currentIndex,
      errorCode: controller.error == null ? null : 1,
      errorMessage: controller.error == null ? null : '音频播放失败',
      repeatMode: switch (controller.mode) {
        AudioPlaybackMode.singleRepeat => AudioServiceRepeatMode.one,
        AudioPlaybackMode.sequential => AudioServiceRepeatMode.none,
        _ => AudioServiceRepeatMode.all,
      },
      shuffleMode: controller.mode == AudioPlaybackMode.nodeShuffle
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
    ));
  }

  @override
  Future<void> play() async {
    await _controller?.play();
    _publish();
  }

  @override
  Future<void> pause() async {
    await _controller?.pause();
    _publish();
  }

  @override
  Future<void> skipToNext() async {
    await _controller?.next();
    _publish();
  }

  @override
  Future<void> skipToPrevious() async {
    await _controller?.previous();
    _publish();
  }

  @override
  Future<void> seek(Duration position) async {
    final controller = _controller;
    if (controller == null) return;
    await controller.initializedPlayer?.seek(position);
    _publish();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    final controller = _controller;
    final session = controller?.session;
    if (controller == null || session == null) return;
    await controller.playSessionEntry(session, index);
    _publish();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    _controller?.setMode(switch (repeatMode) {
      AudioServiceRepeatMode.one => AudioPlaybackMode.singleRepeat,
      AudioServiceRepeatMode.none => AudioPlaybackMode.sequential,
      _ => AudioPlaybackMode.nodeRepeat,
    });
    _publish();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    _controller?.setMode(shuffleMode == AudioServiceShuffleMode.none
        ? AudioPlaybackMode.nodeRepeat
        : AudioPlaybackMode.nodeShuffle);
    _publish();
  }

  @override
  Future<void> setSpeed(double speed) async {
    if (!speed.isFinite || speed <= 0) return;
    await _controller?.initializedPlayer?.setRate(speed);
    _publish();
  }

  @override
  Future<void> onTaskRemoved() => stop();

  @override
  Future<void> stop() async {
    await _controller?.stopAndClear();
    await _audioSession?.setActive(false);
    await super.stop();
  }
}
