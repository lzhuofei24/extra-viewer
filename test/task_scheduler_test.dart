import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:best_viewer/src/core/tasks/task_scheduler.dart';

void main() {
  test('scheduler prioritizes interactive work and cancels queued tags',
      () async {
    final scheduler = TaskScheduler(maxConcurrent: 1);
    addTearDown(scheduler.close);
    final gate = Completer<void>();
    final order = <String>[];
    unawaited(scheduler.schedule<void>(
      key: 'running',
      tag: 'keep',
      priority: TaskPriority.maintenance,
      action: () async {
        await gate.future;
        order.add('running');
      },
    ));
    final canceled = scheduler.schedule<void>(
      key: 'prefetch',
      tag: 'discard',
      priority: TaskPriority.prefetch,
      action: () async => order.add('prefetch'),
    );
    final interactive = scheduler.schedule<void>(
      key: 'interactive',
      tag: 'keep',
      priority: TaskPriority.interactive,
      action: () async => order.add('interactive'),
    );

    final canceledExpectation =
        expectLater(canceled, throwsA(isA<StateError>()));
    scheduler.cancelTag('discard');
    gate.complete();
    await interactive;
    await canceledExpectation;
    expect(order, ['running', 'interactive']);
  });
}
