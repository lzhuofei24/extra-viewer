import 'dart:async';

import 'package:best_viewer/src/modules/build/periodic_checkpoint.dart';
import 'package:best_viewer/src/core/controllers/library_build_task_controller.dart';
import 'package:best_viewer/src/core/thumbnails/thumbnail_cancellation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pause and abandon propagate to active and late native listeners', () {
    final control = LibraryBuildControl();
    var notified = 0;
    control.thumbnailCancellation.addListener(() => notified++);
    control.pause();
    control.thumbnailCancellation.addListener(() => notified++);
    expect(notified, 2);
    expect(control.thumbnailCancellation.throwIfCancelled,
        throwsA(isA<ThumbnailTaskPausedException>()));
    control.abandon();
    expect(control.thumbnailCancellation.throwIfCancelled,
        throwsA(isA<ThumbnailTaskCanceledException>()));
  });

  test('timed commits are serial and close commits the trailing results',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var pending = 1;
    var active = 0;
    final committed = <int>[];
    final checkpoint = PeriodicCheckpoint(() async {
      expect(active++, 0);
      final batch = pending;
      pending = 0;
      if (!entered.isCompleted) {
        entered.complete();
        await release.future;
      }
      committed.add(batch);
      active--;
    }, interval: const Duration(milliseconds: 5));
    await entered.future;
    pending = 2;
    final closing = checkpoint.close();
    final duplicate = checkpoint.close();
    release.complete();
    await Future.wait([closing, duplicate]);
    expect(committed, [1, 2]);
  });

  test('a failed timed commit is surfaced at close, never replayed', () async {
    final entered = Completer<void>();
    var calls = 0;
    final checkpoint = PeriodicCheckpoint(() async {
      calls++;
      entered.complete();
      throw StateError('writer unavailable');
    }, interval: const Duration(milliseconds: 5));
    await entered.future;
    await expectLater(checkpoint.close(), throwsStateError);
    expect(calls, 1);
  });
}
