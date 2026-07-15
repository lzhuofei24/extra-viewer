import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

class ThumbnailStore {
  ThumbnailStore(this.baseDirectoryPath);

  final String baseDirectoryPath;
  final Map<String, Future<void>> _preparedDirectories =
      <String, Future<void>>{};

  String get rootPath => p.join(baseDirectoryPath, 'thumbnails');

  String pathFor(String key, String format) {
    final safeKey = key.trim().toLowerCase();
    final safeFormat = format.trim().toLowerCase();
    final prefix = safeKey.length >= 2 ? safeKey.substring(0, 2) : '00';
    return p.join(rootPath, prefix, '$safeKey.$safeFormat');
  }

  File fileFor(String key, String format) => File(pathFor(key, format));

  /// Prepares an app-owned destination for a native backend. The backend
  /// writes `<path>.tmp` and atomically replaces this final path itself.
  Future<String> prepareNativeOutputPath(String key, String format) async {
    final file = fileFor(key, format);
    await _ensureDirectory(file.parent.path);
    return file.path;
  }

  Future<String> writeBytes({
    required String key,
    required String format,
    required Uint8List bytes,
  }) async {
    final file = fileFor(key, format);
    await _ensureDirectory(file.parent.path);
    final tempFile = File('${file.path}.tmp');
    // Atomic rename protects readers from partial files; forcing every small
    // thumbnail through a physical flush makes large imports unnecessarily IO-bound.
    await tempFile.writeAsBytes(bytes, flush: false);
    if (await file.exists()) {
      await file.delete();
    }
    await tempFile.rename(file.path);
    return file.path;
  }

  Future<void> _ensureDirectory(String path) {
    return _preparedDirectories.putIfAbsent(
      path,
      () => Directory(path).create(recursive: true),
    );
  }

  bool exists(String key, String format) => fileFor(key, format).existsSync();

  Future<bool> deleteIfExists(String key, String format) async {
    final file = fileFor(key, format);
    try {
      if (await file.exists()) await file.delete();
      return true;
    } on FileSystemException {
      // A card may be decoding this file. Retain metadata so a later trim can
      // retry instead of leaving the database and filesystem out of sync.
      return false;
    }
  }
}

String thumbnailCacheKeyFor({
  required String fingerprint,
  int version = 6,
}) {
  final input = '$fingerprint|$version';
  var hash = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  for (final unit in input.codeUnits) {
    hash ^= unit;
    hash = (hash * prime).toUnsigned(64);
  }
  final high = (hash >>> 32) & 0xffffffff;
  final low = hash & 0xffffffff;
  // The prefix makes cache-spec changes queryable from SQLite so an index
  // update can rebuild old low-resolution assets without scanning files again.
  return 'v${version}_${high.toRadixString(16).padLeft(8, '0')}'
      '${low.toRadixString(16).padLeft(8, '0')}';
}
