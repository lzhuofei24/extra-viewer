import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/modules/viewer/viewer_sessions.dart';
import 'package:best_viewer/src/modules/infrastructure/app_runtime.dart';

void main() {
  test('runtime drains a viewer already closing before closing database',
      () async {
    final sessions = ViewerSessions();
    final gate = Completer<void>();
    final order = <String>[];
    final session = sessions.register(() async {
      await gate.future;
      order.add('viewer');
    });
    final ordinaryClose = session.close();
    expect(identical(ordinaryClose, session.close()), isTrue);
    final runtime = AppRuntime()
      ..register('stop', RuntimeClosePhase.stopWork, sessions.stop)
      ..register('viewers', RuntimeClosePhase.media, sessions.close)
      ..register('db', RuntimeClosePhase.database, () => order.add('db'));
    final closing = runtime.close();
    await Future<void>.delayed(Duration.zero);
    expect(order, isEmpty);
    expect(() => sessions.register(() async {}), throwsStateError);
    gate.complete();
    expect(await closing, isEmpty);
    expect(order, ['viewer', 'db']);
  });

  test('failed viewer cleanup does not skip other active viewers', () async {
    final sessions = ViewerSessions();
    final gate = Completer<void>();
    var released = false;
    sessions.register(() async => throw StateError('native close failed'));
    sessions.register(() async {
      await gate.future;
      released = true;
    });
    final closing = sessions.close();
    expect(identical(closing, sessions.close()), isTrue);
    var completed = false;
    final assertion =
        expectLater(closing, throwsStateError).then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    gate.complete();
    await assertion;
    expect(released, isTrue);
  });

  test('ordinary close removes resources without retaining widget callbacks',
      () async {
    final sessions = ViewerSessions();
    var closes = 0;
    final session = sessions.register(() async => closes++);
    await session.close();
    await sessions.close();
    expect(closes, 1);
  });
}
