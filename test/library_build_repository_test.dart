import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_build_repository.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('interrupted asset work is resumable without deleting committed rows', () {
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
