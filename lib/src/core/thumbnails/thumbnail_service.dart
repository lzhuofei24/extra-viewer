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

  Future<bool> ensureThumbnail(Entity entity, {bool force = false}) async {
    final stopwatch = Stopwatch()..start();
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
      if (handler is ImageFileHandler) {
        artifact = await androidImageBackend?.encode(entity.path);
        artifact ??= await windowsWicBackend?.encode(sourceFile);
        artifact ??= await nativeImageBackend?.encode(sourceFile);
        final workerPool = imageWorkerPool;
        if (artifact == null && workerPool != null) {
          artifact = await workerPool.encode(sourceFile);
        }
        if (artifact == null) {
          final bytes = await handler.buildThumbnailWebp(sourceFile);
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
        artifact = await androidVideoBackend?.encode(entity.path);
        if (artifact == null) {
          final result =
              await handler.backend.buildFirstFrameWebpWithMetadata(sourceFile);
          artifact = ThumbnailArtifact(
            bytes: result.bytes,
            width: result.width,
            height: result.height,
            durationMs: result.durationMs,
          );
        }
      } else {
        final bytes = await handler.buildThumbnailWebp(sourceFile);
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
      await store.writeBytes(
        key: expectedKey,
        format: 'webp',
        bytes: artifact.bytes,
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
    } catch (error) {
      _recordUpdate(ThumbnailDatabaseUpdate.failed(entity.id, '$error'));
      return true;
    } finally {
      stopwatch.stop();
      timings.record(entity.entityType, stopwatch.elapsed, artifact);
    }
  }

  Future<bool> regenerateThumbnail(Entity entity) =>
      ensureThumbnail(entity, force: true);

  /// Keeps persistent previews bounded without ever touching source files.
  Future<int> trimCacheToPlatformLimit() async {
    final evicted = await store.trimToMaxBytes(thumbnailCacheCapacityBytes());
    if (evicted.isNotEmpty) repository.invalidateThumbnailCacheKeys(evicted);
    return evicted.length;
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

class ThumbnailUpdateBuffer {
  ThumbnailUpdateBuffer(this.repository, {this.batchSize = 100});

  final LibraryRepository repository;
  final int batchSize;
  final List<ThumbnailDatabaseUpdate> _pending = <ThumbnailDatabaseUpdate>[];

  void add(ThumbnailDatabaseUpdate update) {
    _pending.add(update);
    if (_pending.length >= batchSize) flush();
  }

  void flush() {
    if (_pending.isEmpty) return;
    final batch = List<ThumbnailDatabaseUpdate>.of(_pending);
    _pending.clear();
    repository.applyThumbnailUpdates(batch);
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
  });

  final ThumbnailService service;
  final int maxConcurrent;
  final Queue<_ThumbnailJob> _pending = Queue<_ThumbnailJob>();
  final Set<String> _enqueued = <String>{};
  int _running = 0;

  Future<bool> enqueue(Entity entity) {
    if (_enqueued.contains(entity.id)) {
      return Future<bool>.value(false);
    }
    final completer = Completer<bool>();
    _pending.add(_ThumbnailJob(entity, completer));
    _enqueued.add(entity.id);
    _drain();
    return completer.future;
  }

  void _drain() {
    while (_running < maxConcurrent && _pending.isNotEmpty) {
      final job = _pending.removeFirst();
      _running++;
      service
          .ensureThumbnail(job.entity)
          .then(job.completer.complete)
          .catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        job.completer.completeError(error, stackTrace);
      }).whenComplete(() {
        _running--;
        _enqueued.remove(job.entity.id);
        _drain();
      });
    }
  }
}

class _ThumbnailJob {
  _ThumbnailJob(this.entity, this.completer);

  final Entity entity;
  final Completer<bool> completer;
}
