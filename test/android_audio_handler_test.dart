import 'package:audio_service/audio_service.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/core/media/android_audio_handler.dart';
import 'package:best_viewer/src/core/media/app_audio_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAudioController extends AppAudioController {
  FakeAudioController()
      : super(
          onProgressSaved: (_, __, ___) {},
          onSessionCreated: (
                  {required entries,
                  required currentIndex,
                  sourceNodeId,
                  sourceNodeName,
                  required mode}) =>
              throw UnimplementedError(),
          onSessionUpdated: (
              {required id,
              currentIndex,
              positionMs,
              mode,
              shuffleRemaining,
              history,
              active}) {},
        );
  bool playing = false;
  bool stopped = false;
  int track = 0;
  AudioPlaybackMode playbackMode = AudioPlaybackMode.nodeRepeat;
  @override
  AudioPlaybackMode get mode => playbackMode;
  @override
  void setMode(AudioPlaybackMode value) {
    playbackMode = value;
    notifyListeners();
  }

  @override
  EntityListItem? get current => stopped
      ? null
      : EntityListItem(
          id: '$track',
          title: 'Song $track',
          path: '/$track.mp3',
          format: 'mp3',
          entityType: EntityType.audio,
          size: 1,
          modifiedAtMs: 0);
  @override
  bool get isPlaying => playing;
  @override
  Duration get duration => const Duration(minutes: 3);
  @override
  Future<void> play() async {
    playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    playing = false;
    notifyListeners();
  }

  @override
  Future<void> next({bool fromCompletion = false}) async {
    track++;
    notifyListeners();
  }

  @override
  Future<void> previous() async {
    track--;
    notifyListeners();
  }

  @override
  Future<void> stopAndClear() async {
    stopped = true;
    playing = false;
    notifyListeners();
  }
}

void main() {
  test(
      'system media controls and metadata mirror the existing audio controller',
      () async {
    final controller = FakeAudioController();
    final handler = AndroidAudioHandler()..attach(controller);
    expect(handler.mediaItem.value?.title, 'Song 0');
    expect(handler.mediaItem.value?.duration, const Duration(minutes: 3));
    expect(handler.playbackState.value.controls, contains(MediaControl.play));
    expect(handler.playbackState.value.controls, hasLength(3));
    expect(handler.playbackState.value.controls,
        isNot(contains(MediaControl.stop)));
    expect(handler.playbackState.value.systemActions,
        isNot(contains(MediaAction.stop)));
    await handler.play();
    expect(controller.isPlaying, isTrue);
    expect(handler.playbackState.value.controls, contains(MediaControl.pause));
    await handler.setRepeatMode(AudioServiceRepeatMode.one);
    expect(controller.mode, AudioPlaybackMode.singleRepeat);
    expect(handler.playbackState.value.repeatMode, AudioServiceRepeatMode.one);
    await handler.setShuffleMode(AudioServiceShuffleMode.all);
    expect(controller.mode, AudioPlaybackMode.nodeShuffle);
    expect(
        handler.playbackState.value.shuffleMode, AudioServiceShuffleMode.all);
    await handler.setRepeatMode(AudioServiceRepeatMode.none);
    expect(handler.playbackState.value.repeatMode, AudioServiceRepeatMode.none);
    await handler.skipToNext();
    expect(handler.mediaItem.value?.id, '1');
    await handler.skipToPrevious();
    expect(handler.mediaItem.value?.id, '0');
    await handler.pause();
    expect(handler.playbackState.value.playing, isFalse);
    await handler.stop();
    expect(controller.stopped, isTrue);
    expect(handler.mediaItem.value, isNull);
    expect(
        handler.playbackState.value.processingState, AudioProcessingState.idle);
    handler.detach();
    await controller.close();
  });

  test('detaching and reattaching isolates old playback events', () async {
    final old = FakeAudioController();
    final current = FakeAudioController()..track = 5;
    final handler = AndroidAudioHandler()..attach(old);
    handler.attach(current);
    await old.next();
    expect(handler.mediaItem.value?.id, '5');
    await handler.play();
    expect(current.isPlaying, isTrue);
    await handler.onTaskRemoved();
    expect(current.stopped, isTrue);
    expect(
        handler.playbackState.value.processingState, AudioProcessingState.idle);
    handler.detach();
    await old.close();
    await current.close();
  });
}
