import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/modules/infrastructure/app_runtime.dart';

void main() {
  test('shutdown preserves phase order and continues after failure', () async {
    final order = <String>[];
    final runtime = AppRuntime()
      ..register('logs', RuntimeClosePhase.diagnostics, () => order.add('logs'))
      ..register('db', RuntimeClosePhase.database, () => order.add('db'))
      ..register('build', RuntimeClosePhase.stopWork, () {
        order.add('build');
        throw StateError('failed');
      })
      ..register('player', RuntimeClosePhase.media, () => order.add('player'));
    final failures = await runtime.close();
    expect(order, ['build', 'player', 'db', 'logs']);
    expect(failures.single.name, 'build');
  });
  test('concurrent close calls share completion and reject new services',
      () async {
    final gate = Completer<void>();
    final runtime = AppRuntime()
      ..register('build', RuntimeClosePhase.stopWork, () => gate.future);
    final first = runtime.close();
    expect(identical(first, runtime.close()), isTrue);
    expect(() => runtime.register('late', RuntimeClosePhase.media, () {}),
        throwsStateError);
    gate.complete();
    expect(await first, isEmpty);
  });
}
