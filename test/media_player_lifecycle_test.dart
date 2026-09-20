import 'package:best_viewer/src/core/media/media_player_lifecycle.dart';
import 'package:best_viewer/src/core/media/app_audio_controller.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:best_viewer/src/ui/widgets/app_widgets.dart';

void main() {
  test('audio session failure is observable without constructing a player',
      () async {
    final controller = AppAudioController(
      onProgressSaved: (_, __, ___) {},
      onSessionCreated: (
          {required entries,
          required currentIndex,
          sourceNodeId,
          sourceNodeName,
          required mode}) async {
        throw StateError('session write failed');
      },
      onSessionUpdated: (
          {required id,
          currentIndex,
          positionMs,
          mode,
          shuffleRemaining,
          history,
          active}) {},
    );
    await controller.open(const EntityListItem(
        id: 'audio',
        title: 'song',
        entityType: EntityType.audio,
        path: 'song.mp3',
        format: 'mp3',
        size: 1,
        modifiedAtMs: 0));
    expect(controller.error, isA<StateError>());
    expect(controller.opening, isFalse);
    expect(controller.initializedPlayer, isNull);
    await controller.close();
    controller.dispose();
  });

  testWidgets(
      'native initialization failure retains a usable mini player and retries',
      (tester) async {
    var attempts = 0;
    final controller = AppAudioController(
      playerFactory: () {
        attempts++;
        throw StateError('native init failed');
      },
      onProgressSaved: (_, __, ___) {},
      onSessionCreated: (
              {required entries,
              required currentIndex,
              sourceNodeId,
              sourceNodeName,
              required mode}) =>
          AudioPlaybackSession(
              id: 'session',
              name: 'test',
              entries: entries,
              currentIndex: currentIndex,
              mode: mode,
              positionMs: 0,
              createdAtMs: 0,
              updatedAtMs: 0),
      onSessionUpdated: (
          {required id,
          currentIndex,
          positionMs,
          mode,
          shuffleRemaining,
          history,
          active}) {},
    );
    const audio = EntityListItem(
        id: 'audio',
        title: 'song',
        entityType: EntityType.audio,
        path: 'song.mp3',
        format: 'mp3',
        size: 1,
        modifiedAtMs: 0);
    await controller.open(audio);
    expect(controller.current?.id, 'audio');
    expect(controller.error, isA<StateError>());
    expect(controller.opening, isFalse);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MiniAudioPlayer(
                controller: controller,
                onOpen: () {},
                collapsed: false,
                onToggleCollapsed: () {}))));
    expect(find.byTooltip('播放失败，查看详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await controller.open(audio);
    expect(attempts, 2);
    await tester.pumpWidget(const SizedBox());
    await controller.close();
    controller.dispose();
  });

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
