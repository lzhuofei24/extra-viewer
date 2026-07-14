import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Keeps one decoded archive available for all resources belonging to a
/// document. EPUB image requests must not reopen and decompress the whole
/// container for every image.
class ArchiveSession {
  ArchiveSession._(this.filePath, this._input, this._files);

  final String filePath;
  final InputFileStream _input;
  final Map<String, ArchiveFile> _files;
  final Map<String, Uint8List> _cache = <String, Uint8List>{};
  final List<String> _cacheOrder = <String>[];
  bool _closed = false;

  static Future<ArchiveSession> open(File file) async {
    final input = InputFileStream(file.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final files = <String, ArchiveFile>{
        for (final entry in archive.files)
          if (entry.isFile) _normalizeArchivePath(entry.name): entry,
      };
      return ArchiveSession._(file.path, input, files);
    } catch (_) {
      input.closeSync();
      rethrow;
    }
  }

  Iterable<String> get fileNames => _files.keys;

  ArchiveFile? entry(String path) {
    _ensureOpen();
    return _files[_normalizeArchivePath(path)];
  }

  Uint8List? readBytes(String path) {
    _ensureOpen();
    final normalized = _normalizeArchivePath(path);
    final cached = _cache[normalized];
    if (cached != null) {
      _touch(normalized);
      return cached;
    }
    final file = _files[normalized];
    final bytes = file?.readBytes();
    if (bytes == null || bytes.isEmpty) return bytes;
    final value = Uint8List.fromList(bytes);
    _cache[normalized] = value;
    _touch(normalized);
    _trimCache();
    return value;
  }

  String? readText(String path) {
    final bytes = readBytes(path);
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _cache.clear();
    _cacheOrder.clear();
    _input.closeSync();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Archive session is closed');
  }

  void _touch(String path) {
    _cacheOrder.remove(path);
    _cacheOrder.add(path);
  }

  void _trimCache() {
    // Keep document image reuse bounded; the archive itself is already held
    // once, while large embedded images should not accumulate indefinitely.
    const maxEntries = 8;
    while (_cacheOrder.length > maxEntries) {
      _cache.remove(_cacheOrder.removeAt(0));
    }
  }
}

String _normalizeArchivePath(String value) => value
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'^\./'), '')
        .split('/')
        .fold<List<String>>(<String>[], (parts, segment) {
      if (segment.isEmpty || segment == '.') return parts;
      if (segment == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(segment);
      }
      return parts;
    }).join('/');
