import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_build_repository.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'SQL reconciliation preserves other collection references and rejects incomplete scopes',
      () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final library = LibraryRepository(db);
    final builds = LibraryBuildRepository(library);
    final root = library.ensureDirectoryIndexRoot('/reconcile');
    Entity entity(String name) => library
        .upsertEntity(
            path: '/reconcile/$name.jpg',
            name: name,
            format: 'jpg',
            entityType: EntityType.image,
            hash: name,
            size: 1,
            sourceCreatedAtMs: 0,
            sourceModifiedAtMs: 0,
            directoryRootId: root.id)
        .entity;
    final shared = entity('shared');
    final orphan = entity('orphan');
    for (final item in [shared, orphan]) {
      library.linkEntityToIndexNode(entityId: item.id, indexNodeId: root.id);
    }
    library.createCollectionWithEntities(name: 'keep', entityIds: [shared.id]);
    final job = builds.create(
        sourcePath: '/reconcile', operation: LibraryBuildOperation.rootScan);
    builds.setRoots(jobId: job.id, indexRootId: root.id);
    expect(
        () => library.reconcileDirectoryScan(
            jobId: job.id, rootId: root.id, nodeId: root.id),
        throwsStateError);
    expect(library.getEntity(orphan.id), isNotNull);
    db.db.execute(
        'UPDATE library_build_jobs SET manifest_complete = 1 WHERE id = ?',
        [job.id]);
    library.reconcileDirectoryScan(
        jobId: job.id, rootId: root.id, nodeId: root.id);
    expect(library.getEntity(orphan.id), isNull);
    expect(library.getEntity(shared.id), isNotNull);
    expect(
        db.db.select(
            'SELECT 1 FROM index_node_entities WHERE index_node_id = ?',
            [root.id]),
        isEmpty);
    expect(
        () => library.reconcileDirectoryScan(
            jobId: job.id, rootId: root.id, nodeId: 'missing'),
        throwsStateError);
  });

  test('legacy archive handoff preserves media work and is idempotent', () {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final library = LibraryRepository(database);
    final builds = LibraryBuildRepository(library);
    final root = library.ensureDirectoryIndexRoot('/legacy');
    final job = builds.create(
        sourcePath: '/legacy', operation: LibraryBuildOperation.rootScan);
    for (final format in ['epub', 'docx', 'jpg']) {
      final entity = library
          .upsertEntity(
              path: '/legacy/a.$format',
              name: 'a.$format',
              format: format,
              entityType:
                  format == 'jpg' ? EntityType.image : EntityType.document,
              hash: format,
              size: 1,
              sourceCreatedAtMs: 0,
              sourceModifiedAtMs: 0)
          .entity;
      library.linkEntityToIndexNode(entityId: entity.id, indexNodeId: root.id);
      database.db.execute('''INSERT INTO library_entity_preview_work
        (job_id, entity_id, state, attempts, updated_at)
        VALUES (?, ?, 'pending', 0, 0)''', [job.id, entity.id]);
    }
    database.db.execute(
        'UPDATE library_build_jobs SET entity_preview_total = 3 WHERE id = ?',
        [job.id]);
    expect(builds.handoffLegacyArchivePreviewWork(job.id), isTrue);
    expect(builds.handoffLegacyArchivePreviewWork(job.id), isFalse);
    expect(builds.get(job.id)!.sourcePath, '/legacy');
    expect(builds.get(job.id)!.stage, LibraryBuildStage.documentPreviews);
    expect(builds.get(job.id)!.entityPreviewTotal, 1);
    expect(builds.get(job.id)!.documentPreviewTotal, 2);
    expect(builds.claimEntityPreviewWork(job.id).length, 1);
    expect(builds.claimDocumentPreviewWork(job.id).length, 2);
  });

  test(
      'document metadata uses the stored type and commits only the matching source revision',
      () {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final library = LibraryRepository(database);
    final builds = LibraryBuildRepository(library);
    final root = library.ensureDirectoryIndexRoot('/books');
    Entity book(String hash) => library
        .upsertEntity(
            path: '/books/a.epub',
            name: 'a.epub',
            format: 'epub',
            entityType: EntityType.document,
            hash: hash,
            size: 1,
            sourceCreatedAtMs: 0,
            sourceModifiedAtMs: 0)
        .entity;
    final original = book('original');
    library.linkEntityToIndexNode(entityId: original.id, indexNodeId: root.id);
    final job = builds.create(
        sourcePath: '/books', operation: LibraryBuildOperation.rootScan);
    builds.prepareDocumentPreviewWork(job.id, root.id);
    final first = builds.claimDocumentPreviewWork(job.id);
    expect(first.keys, [original.id]);
    final updated = book('updated');
    builds.completeDocumentPreviewWork(job.id,
        {original.id: (state: LibraryBuildWorkState.completed, error: null)},
        attempts: first,
        metadata: {
          original.id: DocumentPreviewMetadata(
              sourceRevision: original.sourceRevision, excerpt: 'stale')
        });
    expect(library.getEntity(original.id)!.contentExcerpt, isNull);
    expect(builds.get(job.id)!.documentPreviewFailed, 1);
    builds.retryFailedAssets(job.id);
    final retry = builds.claimDocumentPreviewWork(job.id);
    builds.completeDocumentPreviewWork(job.id,
        {original.id: (state: LibraryBuildWorkState.completed, error: null)},
        attempts: retry,
        metadata: {
          original.id: DocumentPreviewMetadata(
              sourceRevision: updated.sourceRevision,
              excerpt: 'current',
              coverRevision: updated.previewRevision)
        });
    expect(library.getEntity(original.id)!.contentExcerpt, 'current');
    final next = builds.create(
        sourcePath: '/books', operation: LibraryBuildOperation.rootScan);
    builds.prepareDocumentPreviewWork(next.id, root.id);
    expect(builds.claimDocumentPreviewWork(next.id), isEmpty);
  });

  test(
      'history retention keeps unfinished tasks while bounding completed summaries',
      () {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final builds = LibraryBuildRepository(LibraryRepository(database));
    final pending = builds.create(
        sourcePath: '/pending', operation: LibraryBuildOperation.rootScan);
    for (var index = 0; index < 103; index++) {
      final job = builds.create(
          sourcePath: '/$index', operation: LibraryBuildOperation.rootScan);
      builds.checkpointStage(jobId: job.id, stage: LibraryBuildStage.completed);
    }
    expect(builds.listHistory().length, 100);
    expect(
        database.db
            .select(
                "SELECT id FROM library_build_jobs WHERE status = 'completed'")
            .length,
        100);
    expect(builds.get(pending.id), isNotNull);
  });

  test('completed tasks retain only failed work and retry preserves counters',
      () {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final library = LibraryRepository(database);
    final builds = LibraryBuildRepository(library);
    final root = library.ensureDirectoryIndexRoot('/work');
    final job = builds.create(
        sourcePath: '/work', operation: LibraryBuildOperation.rootScan);
    for (var index = 0; index < 2; index++) {
      final entity = library
          .upsertEntity(
              path: '/work/$index.jpg',
              name: '$index.jpg',
              format: 'jpg',
              entityType: EntityType.image,
              hash: '$index',
              size: 1,
              sourceCreatedAtMs: 0,
              sourceModifiedAtMs: 0)
          .entity;
      library.linkEntityToIndexNode(entityId: entity.id, indexNodeId: root.id);
    }
    builds.setRoots(jobId: job.id, indexRootId: root.id);
    builds.prepareEntityPreviewWork(job.id, root.id);
    expect(
      () => builds.checkpointStage(
          jobId: job.id, stage: LibraryBuildStage.completed),
      throwsStateError,
    );
    final attempts = builds.claimEntityPreviewWork(job.id);
    expect(
      () => builds.checkpointStage(
          jobId: job.id, stage: LibraryBuildStage.completed),
      throwsStateError,
    );
    final ids = attempts.keys.toList();
    builds.completeEntityPreviewWork(
        job.id,
        {
          ids[0]: (state: LibraryBuildWorkState.completed, error: null),
          ids[1]: (state: LibraryBuildWorkState.failed, error: 'decode failed'),
        },
        attempts: attempts);
    final finished = builds.checkpointStage(
        jobId: job.id, stage: LibraryBuildStage.completed);
    expect(finished.status, LibraryBuildStatus.completedWithErrors);
    expect(
        database.db.select(
            'SELECT * FROM library_entity_preview_work WHERE job_id = ?',
            [job.id]).length,
        1);
    expect(builds.listRecoverable().map((job) => job.id), contains(job.id));
    builds.retryFailedAssets(job.id);
    final retry = builds.claimEntityPreviewWork(job.id);
    expect(retry.keys, [ids[1]]);
    builds.completeEntityPreviewWork(
        job.id, {ids[1]: (state: LibraryBuildWorkState.completed, error: null)},
        attempts: retry);
    final completed = builds.checkpointStage(
        jobId: job.id, stage: LibraryBuildStage.completed);
    expect(completed.entityPreviewDone, 2);
    expect(completed.entityPreviewFailed, 0);
    expect(completed.status, LibraryBuildStatus.completed);
    expect(
        database.db.select(
            'SELECT * FROM library_entity_preview_work WHERE job_id = ?',
            [job.id]),
        isEmpty);
  });

  test('node work claims dirty children before their ancestors', () {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final library = LibraryRepository(database);
    final builds = LibraryBuildRepository(library);
    final root = library.ensureCollectionIndexRoot('root');
    final child = library.createCustomNode(parentId: root.id, name: 'child');
    final sibling =
        library.createCustomNode(parentId: root.id, name: 'sibling');
    database.db.execute('DELETE FROM node_preview_dirty');
    library.markIndexNodePreviewDirty(child.id);
    final job = builds.create(
        sourcePath: 'index://${root.id}',
        operation: LibraryBuildOperation.subtreeRefresh,
        kind: LibraryBuildKind.rebuildPreviews,
        targetNodeId: root.id);
    builds.prepareNodePreviewWork(job.id,
        scopeNodeId: root.id, rootNodeId: root.id);
    final first = builds.claimNodePreviewWork(job.id);
    expect(first.keys, [child.id]);
    expect(first.keys, isNot(contains(sibling.id)));
    builds.completeNodePreviewWork(job.id,
        {child.id: (state: LibraryBuildWorkState.completed, error: null)},
        attempts: first);
    expect(builds.claimNodePreviewWork(job.id).keys, [root.id]);
  });

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
    expect(claimed.keys, [entity.id]);

    builds.markInterruptedRecoverable();

    expect(library.getEntity(entity.id), isNotNull);
    expect(builds.claimEntityPreviewWork(job.id).keys, [entity.id]);
    builds.releaseProcessingWork(job.id,
        stage: LibraryBuildStage.entityPreviews);
    final success = {
      entity.id: (state: LibraryBuildWorkState.completed, error: null)
    };
    builds.completeEntityPreviewWork(job.id, success, attempts: claimed);
    expect(builds.get(job.id)!.entityPreviewDone, 0);
    final newer = builds.claimEntityPreviewWork(job.id);
    builds.completeEntityPreviewWork(job.id, success, attempts: claimed);
    expect(builds.get(job.id)!.entityPreviewDone, 0);
    builds.completeEntityPreviewWork(job.id, success, attempts: newer);
    builds.completeEntityPreviewWork(job.id, success, attempts: newer);
    expect(builds.get(job.id)!.entityPreviewDone, 1);
    builds.restartFromManifest(job.id);
    builds.prepareEntityPreviewWork(job.id, root.id);
    final nextGeneration = builds.claimEntityPreviewWork(job.id);
    builds.completeEntityPreviewWork(job.id, success, attempts: claimed);
    expect(builds.get(job.id)!.entityPreviewDone, 0);
    builds.completeEntityPreviewWork(job.id, success, attempts: nextGeneration);
    expect(builds.get(job.id)!.entityPreviewDone, 1);
  });
}
