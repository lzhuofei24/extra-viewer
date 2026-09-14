import 'dart:async';
import 'dart:io';

import '../domain/models.dart';
import '../sources/platform_directory_picker.dart';
import '../sources/source_handle.dart';
import '../../modules/sources/source_file_cache.dart';
export '../../modules/sources/source_file_cache.dart' show SourceFileLease;

class MediaSourceResolver {
  const MediaSourceResolver();

  static final _sessionCache = _AndroidSourceSessionCache();

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
    return _sessionCache.acquire(entity);
  }

  Uri launchUri(EntityListItem entity) {
    final source = SourceHandle.parse(entity.path);
    return source.isLocalFile ? Uri.file(source.raw) : Uri.parse(source.raw);
  }

  String playerSource(EntityListItem entity) => launchUri(entity).toString();

  String displayLocation(EntityListItem entity) => entity.path;
}

class _AndroidSourceSessionCache {
  final _cache = SourceFileCache(budgetBytes: 2 * 1024 * 1024 * 1024);
  Future<void>? _initialized;

  Future<SourceFileLease> acquire(EntityListItem entity) async {
    await (_initialized ??= PlatformDirectoryPicker.clearSessionDocuments());
    final key = '${entity.id}:${entity.sourceRevision}:${entity.path}';
    return _cache.acquire(key, entity.size, (maxBytes) async {
      final path = await PlatformDirectoryPicker.materializeDocument(
          entity.path,
          name: entity.title,
          maxBytes: maxBytes);
      return File(path);
    });
  }
}
