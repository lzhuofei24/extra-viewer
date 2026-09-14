import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/core/controllers/library_build_task_controller.dart';
import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/database/library_build_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/modules/build/build_access.dart';

void main() {
  test('ownership covers async task creation and notifies when released', () async {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final library = LibraryRepository(database);
    final persisted = LibraryBuildRepository(library);
    final job = persisted.create(sourcePath: '/source', operation: LibraryBuildOperation.rootScan);
    final completed = persisted.checkpointStage(jobId: job.id, stage: LibraryBuildStage.completed);
    final builds = _DelayedBuildAccess(completed);
    final controller = LibraryBuildTaskController(library, builds: builds);
    addTearDown(controller.dispose);
    final states = <bool>[];
    controller.addListener(() => states.add(controller.isRunning));
    final first = controller.startRoot('/source');
    expect(controller.isRunning, isTrue);
    expect(await controller.startRoot('/second'), isNull);
    expect(builds.creates, 1);
    builds.creation.complete(completed);
    await first;
    expect(controller.isRunning, isFalse);
    expect(states.first, isTrue);
    expect(states.last, isFalse);
    await controller.close();
  });
}

class _DelayedBuildAccess implements BuildAccess {
  _DelayedBuildAccess(this.job);
  final LibraryBuildJob job;
  final creation = Completer<LibraryBuildJob>();
  int creates = 0;

  @override
  Future<LibraryBuildJob> create({required String sourcePath,
    required LibraryBuildOperation operation, String? targetNodeId,
    LibraryBuildKind kind = LibraryBuildKind.scanScope}) {
    creates++;
    return creation.future;
  }
  @override
  LibraryBuildJob setRunning(String jobId) => job;
  @override
  List<LibraryBuildJob> listRecoverable() => [];
  @override
  List<LibraryBuildJob> listHistory({int limit = 100}) => [job];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
