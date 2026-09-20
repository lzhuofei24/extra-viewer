import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

class SourceEntry {
  const SourceEntry(
      {required this.locator,
      required this.name,
      required this.isDirectory,
      this.size = 0,
      this.modifiedAtMs = 0,
      this.authority,
      this.rootDocumentId,
      this.documentId});
  final String locator;
  final String name;
  final bool isDirectory;
  final int size;
  final int modifiedAtMs;
  final String? authority, rootDocumentId, documentId;
}

abstract interface class SourceAdapter {
  Future<String> resolveRoot(String locator, {String? relativeScope});
  Stream<List<SourceEntry>> listDirectory(String locator);
}

class LocalSourceAdapter implements SourceAdapter {
  @override
  Future<String> resolveRoot(String locator, {String? relativeScope}) async =>
      p.normalize(locator);

  @override
  Stream<List<SourceEntry>> listDirectory(String locator) async* {
    var page = <SourceEntry>[];
    await for (final entry in Directory(locator).list(followLinks: false)) {
      if (entry is! File && entry is! Directory) continue;
      page.add(SourceEntry(
          locator: p.normalize(entry.path),
          name: p.basename(entry.path),
          isDirectory: entry is Directory));
      if (page.length == 200) {
        yield page;
        page = [];
      }
    }
    if (page.isNotEmpty) yield page;
  }
}

class SafSourceAdapter implements SourceAdapter {
  static const _channel = MethodChannel('best_viewer/directory_picker');
  @override
  Future<String> resolveRoot(String locator, {String? relativeScope}) async {
    final root = await _channel.invokeMethod<String>('resolveSourceDirectory',
        {'source': locator, 'relativeScope': relativeScope ?? ''});
    if (root == null) throw StateError('来源目录不可用');
    return root;
  }

  @override
  Stream<List<SourceEntry>> listDirectory(String locator) async* {
    final token = await _channel
        .invokeMethod<String>('openSourceDirectory', {'source': locator});
    if (token == null) throw StateError('目录提供方未返回读取会话');
    try {
      while (true) {
        final page = await _channel.invokeMapMethod<String, Object?>(
            'readSourceDirectory', {'token': token});
        if (page == null) throw StateError('目录提供方未返回读取结果');
        final entries = (page['entries'] as List<Object?>).map((raw) {
          final row = raw! as Map<Object?, Object?>;
          return SourceEntry(
              locator: row['locator']! as String,
              authority: row['authority'] as String?,
              rootDocumentId: row['rootDocumentId'] as String?,
              documentId: row['documentId'] as String?,
              name: row['name']! as String,
              isDirectory: row['directory'] == true,
              size: (row['size'] as num?)?.toInt() ?? 0,
              modifiedAtMs: (row['modified'] as num?)?.toInt() ?? 0);
        }).toList(growable: false);
        if (entries.isNotEmpty) yield entries;
        if (page['complete'] == true) return;
      }
    } finally {
      await _channel
          .invokeMethod<void>('closeSourceDirectory', {'token': token});
    }
  }
}
