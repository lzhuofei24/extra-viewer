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
    if (file.existsSync()) {
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

  Future<void> delete(String key, String format) async {
    final file = fileFor(key, format);
    if (file.existsSync()) {
      await file.delete();
    }
  }

  /// Evicts least-recently-used thumbnail files until [maxBytes] is met.
  /// Returns cache keys whose database metadata must be invalidated by the
  /// caller. The storage layer deliberately does not know about SQLite.
  Future<List<String>> trimToMaxBytes(int maxBytes) async {
    final root = Directory(rootPath);
    if (!await root.exists()) return const <String>[];
    final entries = <_StoredThumbnail>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.webp')) {
        continue;
      }
      final stat = await entity.stat();
      entries.add(_StoredThumbnail(
        file: entity,
        bytes: stat.size,
        accessed: stat.accessed,
      ));
    }
    var totalBytes = entries.fold<int>(0, (sum, entry) => sum + entry.bytes);
    if (totalBytes <= maxBytes) return const <String>[];
    entries.sort((left, right) => left.accessed.compareTo(right.accessed));
    final evicted = <String>[];
    for (final entry in entries) {
      if (totalBytes <= maxBytes) break;
      try {
        await entry.file.delete();
        totalBytes -= entry.bytes;
        evicted.add(p.basenameWithoutExtension(entry.file.path));
      } on FileSystemException {
        // A card may be opening the file while cleanup runs. Keep its metadata
        // intact and revisit it on the next cleanup pass.
      }
    }
    return evicted;
  }
}

class _StoredThumbnail {
  const _StoredThumbnail({
    required this.file,
    required this.bytes,
    required this.accessed,
  });

  final File file;
  final int bytes;
  final DateTime accessed;
}

int thumbnailCacheCapacityBytes() {
  if (Platform.isAndroid) return 1024 * 1024 * 1024;
  return 5 * 1024 * 1024 * 1024;
}

String thumbnailCacheKeyFor({
  required String fingerprint,
  int version = 3,
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
  return high.toRadixString(16).padLeft(8, '0') +
      low.toRadixString(16).padLeft(8, '0');
}
