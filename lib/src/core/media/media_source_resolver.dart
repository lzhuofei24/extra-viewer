import 'dart:async';
import 'dart:io';

import '../domain/models.dart';
import '../sources/platform_directory_picker.dart';
import '../sources/source_handle.dart';

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
  Future<File> localFileAsync(EntityListItem entity) {
    final source = SourceHandle.parse(entity.path);
    if (source.isLocalFile) return Future<File>.value(localFile(entity));
    return _sessionCache.fileFor(entity);
  }

  Uri launchUri(EntityListItem entity) {
    final source = SourceHandle.parse(entity.path);
    return source.isLocalFile ? Uri.file(source.raw) : Uri.parse(source.raw);
  }

  String playerSource(EntityListItem entity) => launchUri(entity).toString();

  Future<String> playerSourceAsync(EntityListItem entity) async {
    final source = SourceHandle.parse(entity.path);
    if (source.isLocalFile) return launchUri(entity).toString();
    return (await localFileAsync(entity)).path;
  }

  String displayLocation(EntityListItem entity) => entity.path;
}

class _AndroidSourceSessionCache {
  static const _androidBudgetBytes = 2 * 1024 * 1024 * 1024;

  final _entries = <String, _CachedSource>{};
  final _inFlight = <String, Future<File>>{};
  Future<void>? _initialized;

  Future<File> fileFor(EntityListItem entity) {
    return _initialize().then((_) => _fileForInitialized(entity));
  }

  Future<void> _initialize() {
    return _initialized ??= PlatformDirectoryPicker.clearSessionDocuments();
  }

  Future<File> _fileForInitialized(EntityListItem entity) {
    final existing = _entries[entity.path];
    if (existing != null && existing.file.existsSync()) {
      existing.lastAccessMs = DateTime.now().millisecondsSinceEpoch;
      return Future<File>.value(existing.file);
    }
    final pending = _inFlight[entity.path];
    if (pending != null) return pending;
    final future = _materialize(entity);
    _inFlight[entity.path] = future;
    return future.whenComplete(() => _inFlight.remove(entity.path));
  }

  Future<File> _materialize(EntityListItem entity) async {
    if (!PlatformDirectoryPicker.isSupported) {
      throw UnsupportedError('Android content URI must be materialized first.');
    }
    final path = await PlatformDirectoryPicker.materializeDocument(
      entity.path,
      name: entity.title,
    );
    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('无法暂存 Android 源文件', entity.path);
    }
    final entry = _CachedSource(
      file: file,
      bytes: await file.length(),
      lastAccessMs: DateTime.now().millisecondsSinceEpoch,
    );
    _entries[entity.path] = entry;
    _evictOverflow(except: entity.path);
    return file;
  }

  void _evictOverflow({required String except}) {
    var usedBytes =
        _entries.values.fold<int>(0, (sum, entry) => sum + entry.bytes);
    if (usedBytes <= _androidBudgetBytes) return;
    final candidates = _entries.entries
        .where((entry) => entry.key != except)
        .toList(growable: false)
      ..sort((a, b) => a.value.lastAccessMs.compareTo(b.value.lastAccessMs));
    for (final candidate in candidates) {
      if (usedBytes <= _androidBudgetBytes) break;
      _entries.remove(candidate.key);
      usedBytes -= candidate.value.bytes;
      if (candidate.value.file.existsSync()) candidate.value.file.deleteSync();
    }
  }
}

class _CachedSource {
  _CachedSource({
    required this.file,
    required this.bytes,
    required this.lastAccessMs,
  });

  final File file;
  final int bytes;
  int lastAccessMs;
}
