import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_build_repository.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
  });
}
