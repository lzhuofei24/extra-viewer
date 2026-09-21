import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import '../sources/platform_directory_picker.dart';
import '../sources/source_handle.dart';
import '../../modules/viewer/media_directory_location.dart';
import '../thumbnails/thumbnail_cancellation.dart';
import '../../modules/sources/source_file_cache.dart';
export '../../modules/sources/source_file_cache.dart' show SourceFileLease;

class MediaSourceResolver {
  const MediaSourceResolver();

  static final _sessionCache = _AndroidSourceSessionCache();
  static const _channel = MethodChannel('best_viewer/directory_picker');

  /// mpv must consume the existing descriptor rather than reopen its proc path.
  static String playbackSourceForFile(File file) {
    final match = RegExp(r'^/proc/self/fd/(\d+)$').firstMatch(file.path);
    return match == null ? file.path : 'fd://${match.group(1)}';
  }

  static bool bypassSourceCache(EntityListItem entity) =>
      (entity.entityType == EntityType.image ||
          entity.entityType == EntityType.video) &&
      entity.size > 50 * 1024 * 1024;

  Future<SourceFileLease> _acquireDescriptor(EntityListItem entity) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
        'openSourceDescriptor', {'source': entity.path});
    final token = result!['token'] as String;
    return SourceFileLease(File(result['path'] as String), () async {
      await _channel
          .invokeMethod<void>('closeSourceDescriptor', {'token': token});
    });
  }

  static void stopSessionReads() => _sessionCache.stop();
  static Future<void> closeSessionCache() => _sessionCache.close();

  File localFile(EntityListItem entity) {
    final materializedPath = entity.localPath;
    if (materializedPath != null && materializedPath.isNotEmpty) {
      return File(materializedPath);
    }
    final source = SourceHandle.parse(entity.path);
    if (!source.isLocalFile) {
      throw UnsupportedError('Android content URI must be materialized first.');
    }
    return File(source.raw);
  }

  /// Resolves SAF files only when a reader or image viewer actually needs a
  /// local path. Scans never retain this materialization in the database.
  Future<SourceFileLease> acquireFile(EntityListItem entity) {
    final source = SourceHandle.parse(entity.path);
    if (source.isLocalFile) {
      return Future.value(SourceFileLease(localFile(entity)));
    }
    if (bypassSourceCache(entity)) return _acquireDescriptor(entity);
    return _sessionCache.acquire(entity);
  }

  Uri launchUri(EntityListItem entity) {
    final source = SourceHandle.parse(entity.path);
    return source.isLocalFile ? Uri.file(source.raw) : Uri.parse(source.raw);
  }

  String playerSource(EntityListItem entity) => launchUri(entity).toString();

  String displayLocation(EntityListItem entity) {
    final source = SourceHandle.parse(entity.path);
    if (source.isLocalFile) return source.raw;
    return formatSafDisplayPath(entity.path, fallback: entity.path);
  }
}

class _AndroidSourceSessionCache {
  final _cache = SourceFileCache(budgetBytes: 2 * 1024 * 1024 * 1024);
  Future<void>? _initialized;
  final _cancellation = ThumbnailCancellationToken();

  void stop() {
    _cache.stop();
    _cancellation.cancel();
  }

  Future<void> close() {
    stop();
    return _cache.close();
  }

  Future<SourceFileLease> acquire(EntityListItem entity) async {
    _cancellation.throwIfCancelled();
    await (_initialized ??= PlatformDirectoryPicker.clearSessionDocuments());
    final key = '${entity.id}:${entity.sourceRevision}:${entity.path}';
    return _cache.acquire(key, entity.size, (maxBytes) async {
      final path = await PlatformDirectoryPicker.materializeDocument(
          entity.path,
          name: entity.title,
          cancellationToken: _cancellation,
          maxBytes: maxBytes);
      return File(path);
    });
  }
}
