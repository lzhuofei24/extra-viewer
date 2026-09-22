import 'dart:async';

import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/core/thumbnails/thumbnail_cancellation.dart';
import 'package:best_viewer/src/core/thumbnails/thumbnail_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pause during backend decoding does not persist a failure', () async {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final repository = LibraryRepository(database);
    final entity = repository
        .upsertEntity(
            path: '${database.storageDirectoryPath}/image.jpg',
            name: 'image.jpg',
            format: 'jpg',
            entityType: EntityType.image,
            hash: 'pause',
            size: 1,
            sourceCreatedAtMs: 0,
            sourceModifiedAtMs: 0)
        .entity;
    final token = ThumbnailCancellationToken()..pause();
    await expectLater(
        ThumbnailService(repository)
            .ensureThumbnail(entity, cancellationToken: token),
        throwsA(isA<ThumbnailTaskPausedException>()));
    expect(repository.getEntity(entity.id)!.thumbnailStatus,
        isNot(ThumbnailStatus.failed));
  });

  test(
      'pause drains queued and active thumbnail work without marking it failed',
      () async {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final service = _BlockingThumbnailService(LibraryRepository(database));
    addTearDown(service.started.close);
    final queue = ThumbnailQueue(service: service, maxConcurrent: 1);
    final first = _entity('first');
    final second = _entity('second');
    final third = _entity('third');

    final firstFuture = queue.enqueue(first);
    final secondFuture = queue.enqueue(second);
    final thirdFuture = queue.enqueue(third);
    await service.firstStarted.future;

    queue.pause();
    await expectLater(
        secondFuture, throwsA(isA<ThumbnailTaskPausedException>()));
    await expectLater(
        thirdFuture, throwsA(isA<ThumbnailTaskPausedException>()));
    service.release();
    await expectLater(
        firstFuture, throwsA(isA<ThumbnailTaskPausedException>()));
    await queue.drain();
    expect(service.startedCount, 1);
  });

  test('cancel rejects queued work and active work after it reaches a boundary',
      () async {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final token = ThumbnailCancellationToken();
    final service = _BlockingThumbnailService(LibraryRepository(database));
    addTearDown(service.started.close);
    final queue = ThumbnailQueue(
      service: service,
      maxConcurrent: 1,
      cancellationToken: token,
    );
    final firstFuture = queue.enqueue(_entity('first'));
    final secondFuture = queue.enqueue(_entity('second'));
    await service.firstStarted.future;

    queue.cancel();
    await expectLater(
        secondFuture, throwsA(isA<ThumbnailTaskCanceledException>()));
    service.release();
    await expectLater(
        firstFuture, throwsA(isA<ThumbnailTaskCanceledException>()));
    await queue.drain();
    expect(token.isCancelled, isTrue);
    expect(service.startedCount, 1);
  });

  test('a canceled service request never persists a thumbnail failure',
      () async {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final repository = LibraryRepository(database);
    final entity = repository
        .upsertEntity(
          path: '/cancelled/image.jpg',
          name: 'image.jpg',
          format: 'jpg',
          entityType: EntityType.image,
          hash: 'cancelled-image',
          size: 1,
          sourceCreatedAtMs: 1,
          sourceModifiedAtMs: 1,
        )
        .entity;
    final token = ThumbnailCancellationToken()..cancel();

    await expectLater(
      ThumbnailService(repository).ensureThumbnail(
        entity,
        cancellationToken: token,
      ),
      throwsA(isA<ThumbnailTaskCanceledException>()),
    );
    expect(
        repository.getEntity(entity.id)!.thumbnailStatus, ThumbnailStatus.none);
  });
}

Entity _entity(String id) => Entity(
      id: id,
      path: '$id.txt',
      name: '$id.txt',
      format: 'txt',
      entityType: EntityType.text,
      hash: id,
      size: 1,
      sourceCreatedAtMs: 1,
      sourceModifiedAtMs: 1,
      createdAtMs: 1,
      updatedAtMs: 1,
    );

class _BlockingThumbnailService extends ThumbnailService {
  _BlockingThumbnailService(super.repository);

  final StreamController<void> started = StreamController<void>.broadcast();
  final Completer<void> _release = Completer<void>();
  final Completer<void> firstStarted = Completer<void>();
  var startedCount = 0;

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<bool> ensureThumbnail(
    Entity entity, {
    bool force = false,
    bool markNodePreviewDirty = true,
    ThumbnailCancellationToken? cancellationToken,
  }) async {
    startedCount++;
    started.add(null);
    if (!firstStarted.isCompleted) firstStarted.complete();
    await _release.future;
    cancellationToken?.throwIfCancelled();
    return true;
  }
}
