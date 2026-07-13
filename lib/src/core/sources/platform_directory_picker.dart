import 'dart:io';
import 'package:flutter/services.dart';

class DirectorySelection {
  const DirectorySelection({
    required this.source,
    required this.displayName,
  });

  final String source;
  final String displayName;
}

class SourceDocument {
  const SourceDocument({
    required this.source,
    required this.relativePath,
    required this.name,
    required this.size,
    required this.modifiedAtMs,
    this.mimeType,
  });

  final String source;
  final String relativePath;
  final String name;
  final int size;
  final int modifiedAtMs;
  final String? mimeType;
}

class PlatformDirectoryPicker {
  PlatformDirectoryPicker._();

  static const _channel = MethodChannel('best_viewer/directory_picker');
  static const _progressChannel =
      EventChannel('best_viewer/directory_picker_progress');

  static bool get isSupported => Platform.isAndroid;

  static Future<DirectorySelection?> pickDirectory() async {
    if (!isSupported) return null;
    final raw =
        await _channel.invokeMapMethod<String, dynamic>('pickDirectory');
    if (raw == null) return null;
    final source = raw['uri'] as String?;
    if (source == null || source.isEmpty) return null;
    return DirectorySelection(
      source: source,
      displayName: raw['displayName'] as String? ?? '已选目录',
    );
  }

  static Future<List<SourceDocument>> listDirectoryTree(String source) async {
    if (!isSupported) return const [];
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'listDirectoryTree',
      {'source': source},
    );
    return (raw ?? const <Map<Object?, Object?>>[]).map((item) {
      final uri = item['uri'] as String?;
      final relativePath = item['relativePath'] as String?;
      final name = item['name'] as String?;
      if (uri == null || relativePath == null || name == null) {
        throw const FormatException('Invalid Android source document');
      }
      return SourceDocument(
        source: uri,
        relativePath: relativePath,
        name: name,
        size: (item['size'] as num?)?.toInt() ?? 0,
        modifiedAtMs: (item['modifiedAtMs'] as num?)?.toInt() ?? 0,
        mimeType: item['mimeType'] as String?,
      );
    }).toList(growable: false);
  }

  /// Counts the source tree without retaining document metadata, then starts
  /// a pull-based scan session for the caller.
  static Future<int> beginDirectoryTreeScan(
    String source, {
    String? relativeScope,
  }) async {
    if (!isSupported) return 0;
    final payload = await _channel.invokeMapMethod<String, dynamic>(
      'startDirectoryTreeScan',
      {
        'source': source,
        if (relativeScope?.isNotEmpty ?? false) 'relativeScope': relativeScope
      },
    );
    final total = payload?['total'];
    if (total is! num) {
      throw StateError('Android did not return a directory scan total');
    }
    return total.toInt();
  }

  /// Pulls records in batches after [beginDirectoryTreeScan].
  static Stream<List<SourceDocument>> readDirectoryTreeBatches() async* {
    if (!isSupported) return;
    while (true) {
      final payload = await _channel.invokeMapMethod<String, dynamic>(
        'nextDirectoryTreeBatch',
      );
      if (payload == null) {
        throw StateError('Android did not return a directory scan batch');
      }
      final rawDocuments =
          payload['documents'] as List<Object?>? ?? const <Object?>[];
      final batch = rawDocuments.map(_sourceDocumentFromMap).toList();
      if (batch.isNotEmpty) yield batch;
      if (payload['completed'] == true) return;
    }
  }

  static Future<void> cancelDirectoryTreeScan() async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('cancelDirectoryTreeScan');
  }

  static Future<String> materializeDocument(
    String source, {
    String? name,
    String cacheScope = 'session',
  }) async {
    if (!isSupported) {
      throw UnsupportedError('Android SAF is only available on Android');
    }
    final path = await _channel.invokeMethod<String>(
      'materializeDocument',
      {
        'source': source,
        'cacheScope': cacheScope,
        if (name != null) 'name': name,
      },
    );
    if (path == null || path.isEmpty) {
      throw StateError('Android did not return a materialized document path');
    }
    return path;
  }

  static Future<Uint8List> readDocumentPrefix(
    String source, {
    int maxBytes = 64 * 1024,
  }) async {
    if (!isSupported) {
      throw UnsupportedError('Android SAF is only available on Android');
    }
    final bytes = await _channel.invokeMethod<Uint8List>(
      'readDocumentPrefix',
      {'source': source, 'maxBytes': maxBytes},
    );
    if (bytes == null) {
      throw StateError('Android did not return a document prefix');
    }
    return bytes;
  }

  static Future<void> clearTransientDocuments() async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('clearTransientDocuments');
  }

  static Future<void> clearSessionDocuments() async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('clearSessionDocuments');
  }

  static Stream<int> get directoryDiscoveryProgress => _progressChannel
      .receiveBroadcastStream()
      .map((event) => (event as Map<Object?, Object?>)['discovered'])
      .where((value) => value is num)
      .cast<num>()
      .map((value) => value.toInt());

  static SourceDocument _sourceDocumentFromMap(Object? raw) {
    final item = raw as Map<Object?, Object?>;
    final uri = item['uri'] as String?;
    final relativePath = item['relativePath'] as String?;
    final name = item['name'] as String?;
    if (uri == null || relativePath == null || name == null) {
      throw const FormatException('Invalid Android source document');
    }
    return SourceDocument(
      source: uri,
      relativePath: relativePath,
      name: name,
      size: (item['size'] as num?)?.toInt() ?? 0,
      modifiedAtMs: (item['modifiedAtMs'] as num?)?.toInt() ?? 0,
      mimeType: item['mimeType'] as String?,
    );
  }
}
