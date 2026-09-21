import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/core/controllers/library_build_task_controller.dart';
import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/database/library_build_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';

void main() {
  late AppDatabase db;
  late LibraryRepository library;
  late LibraryBuildRepository builds;
  late LibraryBuildTaskController controller;
  late Directory source;
  setUp(() {
    db = AppDatabase.openInMemory();
    library = LibraryRepository(db);
    builds = LibraryBuildRepository(library);
    controller = LibraryBuildTaskController(library, builds: builds);
    source = Directory.systemTemp.createTempSync('task_queue_');
  });
  tearDown(() async {
    await controller.close();
    controller.dispose();
    db.close();
    source.deleteSync(recursive: true);
  });
  test('old paused and failed tasks never join a newly admitted queue',
      () async {
    final oldTasks = <String, LibraryBuildStatus>{};
    for (final status in [
      LibraryBuildStatus.pending,
      LibraryBuildStatus.paused,
      LibraryBuildStatus.interrupted,
      LibraryBuildStatus.failed,
      LibraryBuildStatus.completedWithErrors,
    ]) {
      final job = builds.create(
          sourcePath: '${source.path}-${status.name}',
          operation: LibraryBuildOperation.rootScan);
      builds.setTaskStatus(job.id, status);
      oldTasks[job.id] = status;
    }
    await controller.initialize();
    final fresh = await controller.createImportTask(source.path);
    await controller.drainRecoverableQueue();
    expect(builds.get(fresh.id)!.status, LibraryBuildStatus.completed);
    for (final old in oldTasks.entries) {
      expect(builds.get(old.key)!.status, old.value);
    }
  });
  test('cancelling a queued task does not cancel another source', () async {
    final old = builds.create(
        sourcePath: '${source.path}-old',
        operation: LibraryBuildOperation.rootScan);
    final fresh = await controller.createImportTask(source.path);
    await controller.cancelTask(old.id);
    await controller.drainRecoverableQueue();
    expect(builds.get(old.id)!.status, LibraryBuildStatus.abandoned);
    expect(builds.get(fresh.id)!.status, LibraryBuildStatus.completed);
  });
  test('active cancellation settles and does not resurrect after restart',
      () async {
    final job = await controller.createImportTask(source.path);
    await controller.cancelTask(job.id);
    await controller.drainRecoverableQueue();
    expect(builds.get(job.id)!.status, LibraryBuildStatus.abandoned);
    await controller.initialize();
    await controller.drainRecoverableQueue();
    expect(builds.get(job.id)!.status, LibraryBuildStatus.abandoned);
  });
  test(
      'empty directories are imported and only missing directories are removed',
      () async {
    final child = Directory('${source.path}/empty')..createSync();
    final imported = await controller.createImportTask(source.path);
    await controller.drainRecoverableQueue();
    final root = library.getIndexNode(builds.get(imported.id)!.indexRootId!)!;
    expect(
        library.listChildNodes(root.id).map((n) => n.name), contains('empty'));
    await controller.createUpdateTask(root);
    await controller.drainRecoverableQueue();
    expect(
        library.listChildNodes(root.id).map((n) => n.name), contains('empty'));
    child.deleteSync();
    await controller.createUpdateTask(root);
    await controller.drainRecoverableQueue();
    expect(library.listChildNodes(root.id), isEmpty);
  });
  test('new imports run serially while old queued tasks remain untouched',
      () async {
    final old = builds.create(
        sourcePath: '/old', operation: LibraryBuildOperation.rootScan);
    await controller.initialize();
    final a = Directory('${source.path}/a')..createSync();
    final b = Directory('${source.path}/b')..createSync();
    final jobs = await Future.wait([
      controller.createImportTask(a.path),
      controller.createImportTask(b.path)
    ]);
    await controller.drainRecoverableQueue();
    expect(jobs.map((j) => j.id).toSet(), hasLength(2));
    for (final job in jobs) {
      expect(builds.get(job.id)!.status, LibraryBuildStatus.completed);
    }
    expect(builds.get(old.id)!.status, LibraryBuildStatus.pending);
  });
  test('repeated creation shares one task, including async admission',
      () async {
    final jobs = await Future.wait([
      controller.createImportTask(source.path),
      controller.createImportTask(source.path)
    ]);
    expect(jobs[0].id, jobs[1].id);
    await controller.drainRecoverableQueue();
  });
  test('startup interrupts running jobs and does not execute them', () async {
    final job = builds.create(
        sourcePath: source.path, operation: LibraryBuildOperation.rootScan);
    builds.setRunning(job.id);
    await controller.initialize();
    await controller.drainRecoverableQueue();
    expect(builds.get(job.id)!.status, LibraryBuildStatus.interrupted);
    await controller.resumeTask(job.id);
    await controller.drainRecoverableQueue();
    expect(builds.get(job.id)!.status, LibraryBuildStatus.completed);
  });
  test('dirty maintenance waits for user and cancellation survives restart',
      () async {
    final root = library.ensureCollectionIndexRoot('covers');
    library.markIndexNodePreviewDirty(root.id);
    final job =
        await controller.createNodePreviewRetryTask(root.id, manualOnly: true);
    await controller.drainRecoverableQueue();
    expect(builds.get(job.id)!.status, LibraryBuildStatus.pending);
    await controller.cancelTask(job.id);
    await controller.initialize();
    expect(builds.get(job.id)!.status, LibraryBuildStatus.abandoned);
    expect(library.listDirtyPreviewRoots(), isEmpty);
  });
  test('cancelling a dirty snapshot preserves newer changes', () async {
    final root = library.ensureCollectionIndexRoot('covers');
    library.markIndexNodePreviewDirty(root.id);
    final job =
        await controller.createNodePreviewRetryTask(root.id, manualOnly: true);
    library.markIndexNodePreviewDirty(root.id, reason: 'new source');
    await controller.cancelTask(job.id);
    expect(library.listDirtyPreviewRoots(), contains(root.id));
  });
  test('unchanged update does not read content or create preview work',
      () async {
    final path = '${source.path}/image.jpg';
    File(path).writeAsBytesSync([1, 2, 3]);
    final root = library.ensureDirectoryIndexRoot(source.path);
    final stat = File(path).statSync();
    final entity = library
        .upsertEntity(
            path: path,
            name: 'image.jpg',
            format: 'jpg',
            entityType: EntityType.image,
            hash: 'original',
            size: 3,
            sourceCreatedAtMs: stat.modified.millisecondsSinceEpoch,
            sourceModifiedAtMs: stat.modified.millisecondsSinceEpoch,
            directoryRootId: root.id)
        .entity;
    library.linkEntityToIndexNode(entityId: entity.id, indexNodeId: root.id);
    db.db.execute('DELETE FROM node_preview_dirty');
    final job = await controller.createUpdateTask(root);
    await controller.drainRecoverableQueue();
    final result = builds.get(job.id)!;
    expect(result.status, LibraryBuildStatus.completed);
    expect(result.entityPreviewTotal, 0);
    expect(result.nodePreviewTotal, 0);
    expect(library.getEntity(entity.id)!.hash, 'original');
    expect(result.taskMetadata['skipped_count'], 1);
  });
}
