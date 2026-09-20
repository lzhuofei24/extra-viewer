import 'dart:io';
import 'package:path/path.dart' as p;

/// The lock belongs to the runtime, not either reader isolate.
class BrowseCacheFiles {
  static final _active = <String>{};
  BrowseCacheFiles._(this.path, this._lock);
  final String path;
  final RandomAccessFile _lock;
  bool _closed = false;

  static Future<BrowseCacheFiles> create(String directory) async {
    var visited = 0;
    await for (final entry in Directory(directory).list()) {
      if (entry is! File ||
          !RegExp(r'^browse-\d+\.cache\.db\.lock$')
              .hasMatch(p.basename(entry.path))) {
        continue;
      }
      if (++visited > 32) break;
      final candidate = entry.path.substring(0, entry.path.length - 5);
      if (_active.contains(candidate)) continue;
      RandomAccessFile? lock;
      try {
        lock = await entry.open(mode: FileMode.append);
        await lock.lock(FileLock.exclusive);
        await _removeDatabase(candidate);
        await lock.close();
        lock = null;
        await entry.delete();
      } on FileSystemException {
        // Locked caches belong to another live runtime and must be retained.
      } finally {
        await lock?.close();
      }
    }
    final path = p.join(
        directory, 'browse-${DateTime.now().microsecondsSinceEpoch}.cache.db');
    final lock = await File('$path.lock').open(mode: FileMode.append);
    await lock.lock(FileLock.exclusive);
    _active.add(path);
    return BrowseCacheFiles._(path, lock);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    var removed = false;
    try {
      await _removeDatabase(path);
      removed = true;
    } on FileSystemException {
      // Retain the marker so next startup can reclaim interrupted native work.
    } finally {
      await _lock.close();
      _active.remove(path);
    }
    if (removed) {
      final marker = File('$path.lock');
      if (await marker.exists()) await marker.delete();
    }
  }

  static Future<void> _removeDatabase(String path) async {
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('$path$suffix');
      if (await file.exists()) await file.delete();
    }
  }
}
