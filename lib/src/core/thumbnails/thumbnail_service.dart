import 'dart:async';
import 'dart:io';
import 'dart:collection';

import 'package:image/image.dart' as img;

import '../database/library_repository.dart';
import '../domain/models.dart';
import '../formats/file_format_handlers.dart';
import 'image_thumbnail_worker_pool.dart';
import 'android_image_thumbnail_backend.dart';
import 'android_video_thumbnail_backend.dart';
import 'native_image_thumbnail_backend.dart';
import 'thumbnail_artifact.dart';
import 'thumbnail_cancellation.dart';
import 'thumbnail_store.dart';
import 'windows_wic_webp_thumbnail_backend.dart';

class ThumbnailService {
  ThumbnailService(
    this.repository, {
    this.imageWorkerPool,
    this.androidImageBackend,
    this.androidVideoBackend,
    this.nativeImageBackend,
    this.windowsWicBackend,
    this.updateBuffer,
  }) : store = repository.thumbnailStore;

  final LibraryRepository repository;
  final ThumbnailStore store;
  final ImageThumbnailWorkerPool? imageWorkerPool;
  final AndroidImageThumbnailBackend? androidImageBackend;
  final AndroidVideoThumbnailBackend? androidVideoBackend;
  final NativeImageThumbnailBackend? nativeImageBackend;
  final WindowsWicWebpThumbnailBackend? windowsWicBackend;
  final ThumbnailUpdateBuffer? updateBuffer;
  final timings = ThumbnailTimingCollector();
  final concurrencyAdvisor = ThumbnailConcurrencyAdvisor();

  int get recommendedImageConcurrency =>
      concurrencyAdvisor.recommendedImageConcurrency;
  int get recommendedVideoConcurrency =>
      concurrencyAdvisor.recommendedVideoConcurrency;

  Future<bool> ensureThumbnail(
    Entity entity, {
    bool force = false,
    ThumbnailCancellationToken? cancellationToken,
  }) async {
    final stopwatch = Stopwatch()..start();
    cancellationToken?.throwIfCancelled();
    final handler = FileFormatRegistry.resolveFormat(entity.format);
    if (handler == null || !handler.supportsGeneratedThumbnail) return false;
    final expectedKey = thumbnailCacheKeyFor(
      fingerprint: entity.hash,
    );
    if (!force &&
        entity.thumbnailStatus == ThumbnailStatus.success &&
        entity.thumbnailKey == expectedKey &&
        entity.thumbnailFormat != null &&
        store.exists(expectedKey, entity.thumbnailFormat!)) {
      return false;
    }

    _recordUpdate(ThumbnailDatabaseUpdate.pending(entity.id));
    ThumbnailArtifact? artifact;
    try {
      final sourceFile = File(entity.localPath ?? entity.path);
      final nativeOutputPath = await store.prepareNativeOutputPath(
        expectedKey,
        'webp',
      );
      if (handler is ImageFileHandler) {
        artifact = await androidImageBackend?.encode(
          entity.path,
          outputPath: nativeOutputPath,
          cancellationToken: cancellationToken,
        );
        cancellationToken?.throwIfCancelled();
        artifact ??= await windowsWicBackend?.encode(
          sourceFile,
          cancellationToken: cancellationToken,
        );
        cancellationToken?.throwIfCancelled();
        artifact ??= await nativeImageBackend?.encode(
          sourceFile,
          cancellationToken: cancellationToken,
        );
        cancellationToken?.throwIfCancelled();
        final workerPool = imageWorkerPool;
        if (artifact == null && workerPool != null) {
          artifact = await workerPool.encode(
            sourceFile,
            cancellationToken: cancellationToken,
          );
        }
        cancellationToken?.throwIfCancelled();
        if (artifact == null) {
          final bytes = await handler.buildThumbnailWebp(sourceFile);
          cancellationToken?.throwIfCancelled();
          final decoded = img.decodeImage(bytes);
          if (decoded == null) {
            throw FileSystemException(
              'Image thumbnail encoding failed',
              entity.path,
            );
          }
          artifact = ThumbnailArtifact(
            bytes: bytes,
            width: decoded.width,
            height: decoded.height,
          );
        }
      } else if (handler is VideoFileHandler) {
        artifact = await androidVideoBackend?.encode(
          entity.path,
          outputPath: nativeOutputPath,
          cancellationToken: cancellationToken,
        );
        cancellationToken?.throwIfCancelled();
        if (artifact == null) {
          final result = await handler.backend.buildFirstFrameWebpWithMetadata(
            sourceFile,
            cancellationToken: cancellationToken,
          );
          cancellationToken?.throwIfCancelled();
          artifact = ThumbnailArtifact(
            bytes: result.bytes,
            width: result.width,
            height: result.height,
            durationMs: result.durationMs,
          );
        }
      } else {
        final bytes = await handler.buildThumbnailWebp(sourceFile);
        cancellationToken?.throwIfCancelled();
        if (bytes != null) {
          final decoded = img.decodeImage(bytes);
          if (decoded == null) {
            throw FileSystemException(
              'Thumbnail WebP encoding decode failed',
              entity.path,
            );
          }
          artifact = ThumbnailArtifact(
            bytes: bytes,
            width: decoded.width,
            height: decoded.height,
          );
        }
      }
      if (artifact == null) {
        _recordUpdate(ThumbnailDatabaseUpdate.none(entity.id));
        return true;
      }
      cancellationToken?.throwIfCancelled();
      if (artifact.persistedPath == null) {
        await store.writeBytes(
          key: expectedKey,
          format: 'webp',
          bytes: artifact.bytes,
        );
      } else if (!await File(artifact.persistedPath!).exists()) {
        throw FileSystemException('Native thumbnail output was missing',
            artifact.persistedPath);
      }
      repository.recordThumbnailAsset(
        key: expectedKey,
        format: 'webp',
        byteSize: artifact.persistedPath == null
            ? artifact.bytes.length
            : await File(artifact.persistedPath!).length(),
      );
      _recordUpdate(ThumbnailDatabaseUpdate.success(
        entityId: entity.id,
        key: expectedKey,
        format: 'webp',
        width: artifact.width,
        height: artifact.height,
        durationMs: artifact.durationMs,
      ));
      return true;
    } on ThumbnailTaskCanceledException {
      rethrow;
    } catch (error) {
      _recordUpdate(ThumbnailDatabaseUpdate.failed(entity.id, '$error'));
      return true;
    } finally {
      stopwatch.stop();
      timings.record(entity.entityType, stopwatch.elapsed, artifact);
      concurrencyAdvisor.record(entity.entityType, stopwatch.elapsed, artifact);
    }
  }

  Future<bool> regenerateThumbnail(Entity entity) async {
    return ensureThumbnail(entity, force: true);
  }

  void _recordUpdate(ThumbnailDatabaseUpdate update) {
    final buffer = updateBuffer;
    if (buffer != null) {
      buffer.add(update);
    } else {
      repository.applyThumbnailUpdates([update]);
    }
  }
}

class ThumbnailConcurrencyAdvisor {
  int _imageAverageMs = 0;
  int _videoAverageMs = 0;

  int get recommendedImageConcurrency {
    if (!Platform.isAndroid) return 8;
    if (_imageAverageMs == 0) return 4;
    return _imageAverageMs < 280 ? 6 : _imageAverageMs < 700 ? 5 : 4;
  }

  int get recommendedVideoConcurrency {
    if (!Platform.isAndroid) return 4;
    if (_videoAverageMs == 0) return 1;
    return _videoAverageMs < 900 ? 2 : 1;
  }

  void record(EntityType type, Duration elapsed, ThumbnailArtifact? artifact) {
    final value = elapsed.inMilliseconds;
    if (value <= 0 || artifact == null) return;
    if (type == EntityType.image) {
      _imageAverageMs = _smoothed(_imageAverageMs, value);
    } else if (type == EntityType.video) {
      _videoAverageMs = _smoothed(_videoAverageMs, value);
    }
  }

  int _smoothed(int previous, int next) =>
      previous == 0 ? next : ((previous * 7) + next) ~/ 8;
}

class ThumbnailUpdateBuffer {
  ThumbnailUpdateBuffer(
    this.repository, {
    this.batchSize = 100,
    this.useWriteWorker = false,
  });

  final LibraryRepository repository;
  final int batchSize;
  final bool useWriteWorker;
  final List<ThumbnailDatabaseUpdate> _pending = <ThumbnailDatabaseUpdate>[];

  void add(ThumbnailDatabaseUpdate update) {
    _pending.add(update);
    if (_pending.length >= batchSize) {
      if (useWriteWorker) {
        unawaited(flushAsync());
      } else {
        flush();
      }
    }
  }

  void flush() {
    if (_pending.isEmpty) return;
    final batch = List<ThumbnailDatabaseUpdate>.of(_pending);
    _pending.clear();
    repository.applyThumbnailUpdates(batch);
  }

  Future<void> flushAsync() async {
    if (_pending.isEmpty) return;
    final batch = List<ThumbnailDatabaseUpdate>.of(_pending);
    _pending.clear();
    await repository.applyThumbnailUpdatesAsync(batch);
  }
}

class ThumbnailTimingCollector {
  int imageMs = 0;
  int videoMs = 0;
  int documentMs = 0;
  int otherMs = 0;
  int imageCount = 0;
  int videoCount = 0;
  int documentCount = 0;
  int otherCount = 0;
  int imageReadMs = 0;
  int imageDecodeMs = 0;
  int imageResizeMs = 0;
  int imageEncodeMs = 0;
  int imageSourcePixels = 0;
  final List<int> _imageDurationsMs = <int>[];

  void record(EntityType type, Duration elapsed, ThumbnailArtifact? artifact) {
    final milliseconds = elapsed.inMilliseconds;
    switch (type) {
      case EntityType.image:
        imageMs += milliseconds;
        imageCount++;
        imageReadMs += artifact?.readMs ?? 0;
        imageDecodeMs += artifact?.decodeMs ?? 0;
        imageResizeMs += artifact?.resizeMs ?? 0;
        imageEncodeMs += artifact?.encodeMs ?? 0;
        imageSourcePixels += artifact?.sourcePixelCount ?? 0;
        _imageDurationsMs.add(milliseconds);
      case EntityType.video:
        videoMs += milliseconds;
        videoCount++;
      case EntityType.externalLink:
        documentMs += milliseconds;
        documentCount++;
      default:
        otherMs += milliseconds;
        otherCount++;
    }
  }

  ThumbnailTimingSummary snapshot() => ThumbnailTimingSummary(
        imageMs: imageMs,
        videoMs: videoMs,
        documentMs: documentMs,
        otherMs: otherMs,
        imageCount: imageCount,
        videoCount: videoCount,
        documentCount: documentCount,
        otherCount: otherCount,
        imageReadMs: imageReadMs,
        imageDecodeMs: imageDecodeMs,
        imageResizeMs: imageResizeMs,
        imageEncodeMs: imageEncodeMs,
        imageSourcePixels: imageSourcePixels,
        imageP95Ms: _percentile95(_imageDurationsMs),
      );
}

int _percentile95(List<int> values) {
  if (values.isEmpty) return 0;
  final sorted = List<int>.of(values)..sort();
  return sorted[((sorted.length - 1) * 0.95).ceil()];
}

class ThumbnailTimingSummary {
  const ThumbnailTimingSummary({
    required this.imageMs,
    required this.videoMs,
    required this.documentMs,
    required this.otherMs,
    required this.imageCount,
    required this.videoCount,
    required this.documentCount,
    required this.otherCount,
    required this.imageReadMs,
    required this.imageDecodeMs,
    required this.imageResizeMs,
    required this.imageEncodeMs,
    required this.imageSourcePixels,
    required this.imageP95Ms,
  });

  final int imageMs;
  final int videoMs;
  final int documentMs;
  final int otherMs;
  final int imageCount;
  final int videoCount;
  final int documentCount;
  final int otherCount;
  final int imageReadMs;
  final int imageDecodeMs;
  final int imageResizeMs;
  final int imageEncodeMs;
  final int imageSourcePixels;
  final int imageP95Ms;
}

class ThumbnailQueue {
  ThumbnailQueue({
    required this.service,
    this.maxConcurrent = 2,
    this.cancellationToken,
  });

  final ThumbnailService service;
  final int maxConcurrent;
  final ThumbnailCancellationToken? cancellationToken;
  final Queue<_ThumbnailJob> _pending = Queue<_ThumbnailJob>();
  final Set<String> _enqueued = <String>{};
  Completer<void>? _idleCompleter;
  int _running = 0;
  bool _paused = false;
  bool _canceled = false;

  Future<bool> enqueue(Entity entity) {
    if (_canceled) {
      return Future<bool>.error(const ThumbnailTaskCanceledException());
    }
    if (_paused) {
      return Future<bool>.error(const ThumbnailTaskPausedException());
    }
    if (_enqueued.contains(entity.id)) {
      return Future<bool>.value(false);
    }
    final completer = Completer<bool>();
    _pending.add(_ThumbnailJob(entity, completer));
    _enqueued.add(entity.id);
    _idleCompleter ??= Completer<void>();
    _drain();
    return completer.future;
  }

  /// Stops dequeueing while keeping the durable candidate state resumable.
  void pause() {
    if (_paused || _canceled) return;
    _paused = true;
    cancellationToken?.pause();
    _completePending(const ThumbnailTaskPausedException());
    _completeIdleIfReady();
  }

  /// Rejects queued work and asks the service/worker to stop active work.
  void cancel() {
    if (_canceled) return;
    _canceled = true;
    cancellationToken?.cancel();
    _completePending(const ThumbnailTaskCanceledException());
    _completeIdleIfReady();
  }

  Future<void> drain() {
    if (_running == 0 && _pending.isEmpty) {
      return Future<void>.value();
    }
    return (_idleCompleter ??= Completer<void>()).future;
  }

  void _completePending(Object error) {
    while (_pending.isNotEmpty) {
      final job = _pending.removeFirst();
      _enqueued.remove(job.entity.id);
      if (!job.completer.isCompleted) job.completer.completeError(error);
    }
  }

  void _drain() {
    while (!_paused &&
        !_canceled &&
        _running < maxConcurrent &&
        _pending.isNotEmpty) {
      final job = _pending.removeFirst();
      _running++;
      unawaited(_run(job));
    }
  }

  Future<void> _run(_ThumbnailJob job) async {
    try {
      final generated = await service.ensureThumbnail(
        job.entity,
        cancellationToken: cancellationToken,
      );
      if (_canceled) throw const ThumbnailTaskCanceledException();
      if (_paused) throw const ThumbnailTaskPausedException();
      if (!job.completer.isCompleted) job.completer.complete(generated);
    } catch (error, stackTrace) {
      if (!job.completer.isCompleted) {
        job.completer.completeError(error, stackTrace);
      }
    } finally {
      _running--;
      _enqueued.remove(job.entity.id);
      _drain();
      _completeIdleIfReady();
    }
  }

  void _completeIdleIfReady() {
    if (_running != 0 || _pending.isNotEmpty) return;
    final idle = _idleCompleter;
    _idleCompleter = null;
    if (idle != null && !idle.isCompleted) idle.complete();
  }
}

class _ThumbnailJob {
  _ThumbnailJob(this.entity, this.completer);

  final Entity entity;
  final Completer<bool> completer;
}
