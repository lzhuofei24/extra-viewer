import 'package:best_viewer/src/core/media/media_player_lifecycle.dart';
import 'package:best_viewer/src/core/media/app_audio_controller.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a newer operation invalidates stale generations', () {
    final lifecycle = MediaPlayerLifecycle();
    final first = lifecycle.beginOperation();
    final second = lifecycle.beginOperation();

    expect(lifecycle.isCurrent(first), isFalse);
    expect(lifecycle.isCurrent(second), isTrue);
  });

  test('close is idempotent and invalidates callbacks before release',
      () async {
    final lifecycle = MediaPlayerLifecycle();
    final generation = lifecycle.beginOperation();
    var releaseCount = 0;
    final firstClose = lifecycle.close(() async {
      releaseCount++;
    });
    final secondClose = lifecycle.close(() async {
      releaseCount++;
    });

    await Future.wait([firstClose, secondClose]);
    expect(releaseCount, 1);
    expect(lifecycle.isCurrent(generation), isFalse);
    expect(() => lifecycle.beginOperation(), throwsStateError);
  });

  test('audio controller can be closed asynchronously without a player',
      () async {
    final controller = AppAudioController(
      onProgressSaved: (_, __, ___) {},
      onSessionCreated: ({
        required entries,
        required currentIndex,
        sourceNodeId,
        sourceNodeName,
        required mode,
      }) =>
          AudioPlaybackSession(
        id: 'test-session',
        name: 'test',
        entries: entries,
        currentIndex: currentIndex,
        mode: mode,
        positionMs: 0,
        createdAtMs: 0,
        updatedAtMs: 0,
        sourceNodeId: sourceNodeId,
        sourceNodeName: sourceNodeName,
      ),
      onSessionUpdated: ({
        required id,
        currentIndex,
        positionMs,
        mode,
        shuffleRemaining,
        history,
        active,
      }) {},
    );

    await controller.close();
    await controller.close();
    controller.dispose();
  });
}
