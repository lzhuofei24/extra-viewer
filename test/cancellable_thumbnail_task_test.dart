import 'dart:async';

import 'package:best_viewer/src/core/thumbnails/cancellable_thumbnail_task.dart';
import 'package:best_viewer/src/core/thumbnails/thumbnail_cancellation.dart';
import 'package:flutter_test/flutter_test.dart';

Future<int> slowComposition() async {
  await Future<void>.delayed(const Duration(minutes: 1));
  return 7;
}

void main() {
  test('composition returns results and propagates worker errors', () async {
    expect(await runCancellableThumbnailTask(() => 42), 42);
    await expectLater(runCancellableThumbnailTask<int>(() {
      throw StateError('decode failed');
    }), throwsStateError);
  });

  test('pause terminates composition without waiting for its batch', () async {
    final token = ThumbnailCancellationToken();
    final future =
        runCancellableThumbnailTask(slowComposition, cancellationToken: token);
    final assertion = expectLater(future.timeout(const Duration(seconds: 3)),
        throwsA(isA<ThumbnailTaskPausedException>()));
    Timer(const Duration(milliseconds: 30), token.pause);
    await assertion;
  });

  test('a stopped token never starts composition', () async {
    final token = ThumbnailCancellationToken()..cancel();
    await expectLater(
        runCancellableThumbnailTask(() => 1, cancellationToken: token),
        throwsA(isA<ThumbnailTaskCanceledException>()));
  });
}
