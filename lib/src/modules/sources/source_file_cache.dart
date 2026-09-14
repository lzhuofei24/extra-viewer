import 'dart:async';
import 'dart:io';

/// Owns only application-created temporary files, never original sources.
class SourceFileLease {
  SourceFileLease(this.file, [this._release]);
  final File file;
  final Future<void> Function()? _release;
  Future<void>? _released;
  Future<void> close() => _released ??= _release?.call() ?? Future.value();
}

class SourceFileCache {
  SourceFileCache({required this.budgetBytes});
  final int budgetBytes;
  final _entries = <String, _Entry>{};
  Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  /// Copy operations are serialized, reserving capacity before native I/O.
  /// The producer must enforce maxBytes and remove failed partial copies.
  Future<SourceFileLease> acquire(String key, int expectedBytes,
          Future<File> Function(int maxBytes) produce) =>
      _serial(() async {
        var entry = _entries.remove(key);
        if (entry != null && !await entry.file.exists()) entry = null;
        if (entry == null) {
          final reservation = expectedBytes > 0 ? expectedBytes : budgetBytes;
          // Preserve large-video playback: one known oversized source may own
          // the cache exclusively, and is removed immediately after use.
          final capacity =
              reservation > budgetBytes ? reservation : budgetBytes;
          var used = _entries.values.fold<int>(0, (sum, e) => sum + e.bytes);
          for (final candidate in _entries.entries.toList()) {
            if (used + reservation <= capacity) break;
            if (candidate.value.users != 0) continue;
            if (await candidate.value.file.exists()) {
              await candidate.value.file.delete();
            }
            _entries.remove(candidate.key);
            used -= candidate.value.bytes;
          }
          if (used + reservation > capacity) {
            throw const FileSystemException('暂存空间正在使用，请关闭其它查看器后重试');
          }
          final file = await produce(capacity - used);
          final bytes = await file.length();
          if (bytes > capacity - used) {
            await file.delete();
            throw const FileSystemException('源文件实际大小超过暂存容量');
          }
          entry = _Entry(file, bytes);
        }
        final leased = entry;
        _entries[key] = leased;
        leased.users++;
        return SourceFileLease(
            leased.file,
            () => _serial(() async {
                  leased.users--;
                  if (leased.users == 0 && leased.bytes > budgetBytes) {
                    if (await leased.file.exists()) await leased.file.delete();
                    _entries.remove(key);
                  }
                }));
      });
}

class _Entry {
  _Entry(this.file, this.bytes);
  final File file;
  final int bytes;
  int users = 0;
}
