import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_build_repository.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'partial page commits successes, blocks reconciliation and retries only failures',
      () {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final library = LibraryRepository(database);
    final builds = LibraryBuildRepository(library);
    final root = library.ensureDirectoryIndexRoot('/partial', staging: true);
    final job = builds.create(
        sourcePath: '/partial', operation: LibraryBuildOperation.rootScan);
    builds.setRoots(jobId: job.id, indexRootId: root.id);
    final page = List.generate(
        2,
        (i) => LibraryBuildManifestItem(
              jobId: job.id,
              sourcePath: '/partial/$i.md',
              relativePath: '$i.md',
              sequence: i,
              name: '$i.md',
              format: 'md',
              entityType: EntityType.document,
              size: 1,
              sourceCreatedAtMs: 0,
              sourceModifiedAtMs: 0,
            ));
    builds.upsertManifest(page);
    builds.completeManifest(job.id, 2);
    final count = library.commitInspectedPage(
      job: builds.get(job.id)!,
      page: page,
      rootId: root.id,
      existing: {},
      detailsBySequence: {0: ('hash', 1, 0, 0, 'saved excerpt', null)},
      nodesBySequence: {0: root, 1: root},
      indexedBefore: 0,
      inspectionErrors: {1: 'source offline'},
    );
    expect(count, 1);
    expect(builds.get(job.id)!.indexFailed, 1);
    expect(library.listIndexRoots().map((node) => node.id), contains(root.id));
    builds.finalizeIndex(builds.get(job.id)!);
    expect(builds.get(job.id)!.status, LibraryBuildStatus.blocked);
    builds.retryFailedAssets(job.id);
    final retry =
        builds.listManifestPage(job.id, afterSequence: -1, pendingOnly: true);
    expect(retry.map((item) => item.sequence), [1]);
    expect(builds.get(job.id)!.indexedTotal, 1);
    expect(library.getEntityByPath('/partial/0.md')!.contentExcerpt,
        'saved excerpt');
    final before = library.getEntityByPath('/partial/0.md')!;
    library.commitInspectedPage(
      job: builds.get(job.id)!,
      page: [page.first],
      rootId: root.id,
      existing: {page.first.sourcePath: before},
      detailsBySequence: {0: ('new-hash', 2, 0, 0, null, null)},
      nodesBySequence: {0: root},
      indexedBefore: 0,
    );
    expect(library.getEntityByPath('/partial/0.md')!.contentExcerpt,
        'saved excerpt');
    builds.abandon(job.id);
    expect(library.getEntityByPath('/partial/0.md'), isNotNull);
  });

  test(
      'unfinished directory replaces partial pages without rescanning completed siblings',
      () {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final builds = LibraryBuildRepository(LibraryRepository(database));
    final job = builds.create(
        sourcePath: '/root', operation: LibraryBuildOperation.rootScan);
    LibraryBuildManifestItem item(String name, int sequence) =>
        LibraryBuildManifestItem(
            jobId: job.id,
            sourcePath: '/root/$name',
            relativePath: name,
            sequence: sequence,
            name: name,
            format: 'jpg',
            entityType: EntityType.image,
            size: 1,
            sourceCreatedAtMs: 0,
            sourceModifiedAtMs: 0);
    builds.seedDirectory(job.id, '/root');
    builds.commitDirectoryPage(job.id, '/root', [
      item('root.jpg', 0)
    ], [
      (locator: '/root/a', relativePath: 'a'),
      (locator: '/root/b', relativePath: 'b')
    ]);
    builds.completeDirectory(job.id, '/root');
    builds.beginDirectory(job.id, '/root/a', 'a');
    builds.commitDirectoryPage(job.id, '/root/a', [item('a/old.jpg', 1)],
        [(locator: '/root/a/removed', relativePath: 'a/removed')]);
    final sequence = builds.beginDirectory(job.id, '/root/a', 'a');
    builds.commitDirectoryPage(
        job.id, '/root/a', [item('a/new.jpg', sequence)], []);
    builds.completeDirectory(job.id, '/root/a');
    expect(builds.nextDirectory(job.id)!.locator, '/root/b');
    expect(
        builds.listManifestPage(job.id, afterSequence: -1).map((e) => e.name),
        ['root.jpg', 'a/new.jpg']);
  });
  test('deleted task target never becomes a root scope', () {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final library = LibraryRepository(database);
    final builds = LibraryBuildRepository(library);
    final root =
        library.createCollectionWithEntities(name: 'collection', entityIds: []);
    final job = builds.create(
        sourcePath: 'index://${root.id}',
        operation: LibraryBuildOperation.subtreeRefresh,
        kind: LibraryBuildKind.rebuildPreviews,
        targetNodeId: root.id);
    library.deleteIndexNode(root.id);
    final restored = builds.get(job.id)!;
    expect(restored.targetNodeId, isNull);
    expect(restored.scopeNodeId, root.id);
    expect(() => builds.validateScope(restored), throwsStateError);
  });

  test('preview tasks cannot restart as directory scans', () {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final builds = LibraryBuildRepository(LibraryRepository(database));
    final job = builds.create(
        sourcePath: 'index://example',
        operation: LibraryBuildOperation.subtreeRefresh,
        kind: LibraryBuildKind.rebuildPreviews);
    expect(() => builds.restartFromManifest(job.id), throwsStateError);
    expect(builds.get(job.id)!.kind, LibraryBuildKind.rebuildPreviews);
  });
  test('interrupted asset work is resumable without deleting committed rows',
      () {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final library = LibraryRepository(database);
    final builds = LibraryBuildRepository(library);
    final job = builds.create(
      sourcePath: '/library',
      operation: LibraryBuildOperation.rootScan,
    );
    final entity = library
        .upsertEntity(
          path: '/library/image.jpg',
          name: 'image.jpg',
          format: 'jpg',
          entityType: EntityType.image,
          hash: 'fingerprint',
          size: 1,
          sourceCreatedAtMs: 1,
          sourceModifiedAtMs: 1,
        )
        .entity;
    final root = library.ensureDirectoryIndexRoot('/library');
    library.linkEntitiesToIndexNodes(
      [(entityId: entity.id, indexNodeId: root.id)],
      markPreviewDirty: false,
    );
    builds.setRoots(jobId: job.id, indexRootId: root.id);
    builds.prepareEntityPreviewWork(job.id, root.id);
    final claimed = builds.claimEntityPreviewWork(job.id, limit: 100);
    expect(claimed, [entity.id]);

    builds.markInterruptedRecoverable();

    expect(library.getEntity(entity.id), isNotNull);
    expect(builds.claimEntityPreviewWork(job.id), [entity.id]);
    builds.releaseProcessingWork(job.id,
        stage: LibraryBuildStage.entityPreviews);
    final success = {
      entity.id: (state: LibraryBuildWorkState.completed, error: null)
    };
    builds.completeEntityPreviewWork(job.id, success);
    expect(builds.get(job.id)!.entityPreviewDone, 0);
    builds.claimEntityPreviewWork(job.id);
    builds.completeEntityPreviewWork(job.id, success);
    builds.completeEntityPreviewWork(job.id, success);
    expect(builds.get(job.id)!.entityPreviewDone, 1);
  });
}
