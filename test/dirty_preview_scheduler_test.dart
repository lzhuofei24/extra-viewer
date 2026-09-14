import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/modules/previews/dirty_preview_scheduler.dart';
import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/database/library_build_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';

void main() {
  test(
      'node override dependencies mark other collections without recursive cycles',
      () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final library = LibraryRepository(db);
    final first =
        library.createCollectionWithEntities(name: 'first', entityIds: []);
    final second =
        library.createCollectionWithEntities(name: 'second', entityIds: []);
    db.db.execute(
        'INSERT INTO node_preview_overrides(node_id, items_json, updated_at) VALUES (?, ?, 0)',
        [second.id, '[{"kind":"image","nodeId":"${first.id}"}]']);
    db.db.execute(
        'INSERT INTO node_preview_overrides(node_id, items_json, updated_at) VALUES (?, ?, 0)',
        [first.id, '[{"kind":"image","nodeId":"${second.id}"}]']);
    db.db.execute('DELETE FROM node_preview_dirty');
    library.markIndexNodePreviewDirty(first.id, reason: 'changed');
    expect(library.listDirtyPreviewRoots().keys,
        containsAll([first.id, second.id]));
    expect(db.db.select('SELECT * FROM node_preview_dirty').length, 3);
  });

  test('coalesces signatures and retries only changed dirtiness', () async {
    var signature = 'a:1';
    var calls = 0;
    final scheduler = DirtyPreviewScheduler(
        isBusy: () => false,
        load: () async => {'root': signature},
        rebuild: (_) async {
          calls++;
        },
        onError: (e, s) => fail('$e'));
    await scheduler.tick();
    await scheduler.tick();
    expect(calls, 1);
    signature = 'a:2';
    await scheduler.tick();
    expect(calls, 2);
    await scheduler.close();
    await scheduler.tick();
    expect(calls, 2);
  });
  test('close drains active rebuild and prevents remaining roots', () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final visited = <String>[];
    final scheduler = DirtyPreviewScheduler(
        isBusy: () => false,
        load: () async => {'a': '1', 'b': '1'},
        rebuild: (id) async {
          visited.add(id);
          started.complete();
          await gate.future;
        },
        onError: (e, s) => fail('$e'));
    final run = scheduler.tick();
    await started.future;
    final close = scheduler.close();
    gate.complete();
    await Future.wait([run, close]);
    expect(visited, ['a']);
  });
  test('dirty roots survive restart and exclude paused task scopes', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final library = LibraryRepository(db);
    final root =
        library.createCollectionWithEntities(name: 'collection', entityIds: []);
    library.markIndexNodePreviewDirty(root.id, reason: 'test');
    expect(library.listDirtyPreviewRoots(), contains(root.id));
    final builds = LibraryBuildRepository(library);
    final job = builds.create(
        sourcePath: 'index://${root.id}',
        operation: LibraryBuildOperation.subtreeRefresh,
        targetNodeId: root.id,
        kind: LibraryBuildKind.rebuildPreviews);
    builds.setRoots(jobId: job.id, indexRootId: root.id);
    builds.pause(job.id);
    expect(library.listDirtyPreviewRoots(), isNot(contains(root.id)));
    builds.abandon(job.id);
    expect(library.listDirtyPreviewRoots(), contains(root.id));
  });
}
