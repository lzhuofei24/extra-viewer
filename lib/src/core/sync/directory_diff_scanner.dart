import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;

import '../../modules/library/library_access.dart';
import '../../modules/sources/source_adapter.dart';
import '../domain/models.dart';
import '../formats/file_format_handlers.dart';
import '../sources/source_handle.dart';

class DirectorySyncRoot {
  const DirectorySyncRoot({
    required this.rootId,
    required this.name,
    required this.sourcePath,
  });

  final String rootId;
  final String name;
  final String sourcePath;
}

class DirectoryDiffRecord {
  const DirectoryDiffRecord({
    required this.sourcePath,
    required this.relativePath,
    required this.name,
    required this.format,
    required this.entityType,
    required this.size,
    required this.modifiedAtMs,
  });

  final String sourcePath;
  final String relativePath;
  final String name;
  final String format;
  final EntityType entityType;
  final int size;
  final int modifiedAtMs;
}

class DirectoryDiffRootResult {
  const DirectoryDiffRootResult({
    required this.root,
    required this.added,
    required this.updated,
    required this.missing,
    required this.unavailable,
  });

  final DirectorySyncRoot root;
  final int added;
  final int updated;
  final int missing;
  final bool unavailable;

  int get changed => added + updated + missing;

  Map<String, Object?> toJson() => {
        'rootId': root.rootId,
        'name': root.name,
        'sourcePath': root.sourcePath,
        'added': added,
        'updated': updated,
        'missing': missing,
        'unavailable': unavailable,
      };

  static DirectoryDiffRootResult? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final rootId = raw['rootId'];
    final sourcePath = raw['sourcePath'];
    if (rootId is! String || sourcePath is! String) return null;
    int value(String key) => (raw[key] as num?)?.toInt() ?? 0;
    return DirectoryDiffRootResult(
      root: DirectorySyncRoot(
        rootId: rootId,
        name: raw['name'] as String? ?? sourcePath,
        sourcePath: sourcePath,
      ),
      added: value('added'),
      updated: value('updated'),
      missing: value('missing'),
      unavailable: raw['unavailable'] == true,
    );
  }
}

class DirectoryDiffScanResult {
  const DirectoryDiffScanResult({
    required this.scanStartedAt,
    required this.scanCompletedAt,
    required this.roots,
  });

  final DateTime scanStartedAt;
  final DateTime scanCompletedAt;
  final List<DirectoryDiffRootResult> roots;

  int get addedCount => roots.fold(0, (sum, root) => sum + root.added);
  int get updatedCount => roots.fold(0, (sum, root) => sum + root.updated);
  int get missingCount => roots.fold(0, (sum, root) => sum + root.missing);
  int get unavailableCount => roots.where((root) => root.unavailable).length;
  bool get hasChanges => addedCount + updatedCount + missingCount > 0;

  Map<String, Object?> toJson({bool awaitingConfirmation = false}) => {
        'scanStartedAt': scanStartedAt.toIso8601String(),
        'scanCompletedAt': scanCompletedAt.toIso8601String(),
        'rootResults': roots.map((root) => root.toJson()).toList(),
        'addedCount': addedCount,
        'updatedCount': updatedCount,
        'missingCount': missingCount,
        'unavailableCount': unavailableCount,
        'awaitingConfirmation': awaitingConfirmation,
      };

  static DirectoryDiffScanResult? fromJson(String? encoded) {
    if (encoded == null || encoded.isEmpty) return null;
    try {
      final raw = jsonDecode(encoded);
      if (raw is! Map) return null;
      final started = DateTime.tryParse(raw['scanStartedAt'] as String? ?? '');
      final completed =
          DateTime.tryParse(raw['scanCompletedAt'] as String? ?? '');
      if (started == null || completed == null) return null;
      final roots =
          (raw['rootResults'] is List ? raw['rootResults'] as List : const [])
              .map(DirectoryDiffRootResult.fromJson)
              .whereType<DirectoryDiffRootResult>()
              .toList(growable: false);
      return DirectoryDiffScanResult(
        scanStartedAt: started,
        scanCompletedAt: completed,
        roots: roots,
      );
    } catch (_) {
      return null;
    }
  }
}

class DirectoryDiffScanner {
  DirectoryDiffScanner(this.library, {SourceAdapter? local, SourceAdapter? saf})
      : _local = local ?? LocalSourceAdapter(),
        _saf = saf ?? SafSourceAdapter();

  final LibraryAccess library;
  final SourceAdapter _local;
  final SourceAdapter _saf;

  Future<DirectoryDiffScanResult> scan(
    Iterable<DirectorySyncRoot> roots, {
    void Function(DirectoryDiffRootResult result)? onRootComplete,
  }) async {
    final started = DateTime.now();
    final results = <DirectoryDiffRootResult>[];
    for (final root in roots) {
      final result = await _scanRoot(root);
      results.add(result);
      onRootComplete?.call(result);
    }
    return DirectoryDiffScanResult(
      scanStartedAt: started,
      scanCompletedAt: DateTime.now(),
      roots: List.unmodifiable(results),
    );
  }

  Future<DirectoryDiffRootResult> _scanRoot(DirectorySyncRoot root) async {
    try {
      final source = SourceHandle.parse(root.sourcePath);
      final adapter = source.isAndroidContentUri ? _saf : _local;
      final existing = await library.listEntitiesUnderNode(root.rootId);
      final oldByPath = <String, EntityListItem>{
        for (final entity in existing) _key(entity.path): entity,
      };
      final seen = <String>{};
      final pending = <({String locator, String relativePath})>[
        (
          locator: await adapter.resolveRoot(root.sourcePath),
          relativePath: '',
        )
      ];
      var added = 0;
      var updated = 0;
      while (pending.isNotEmpty) {
        final directory = pending.removeLast();
        await for (final entries in adapter.listDirectory(directory.locator)) {
          for (final entry in entries) {
            final relative = directory.relativePath.isEmpty
                ? entry.name
                : '${directory.relativePath}/${entry.name}';
            if (entry.isDirectory) {
              pending.add((locator: entry.locator, relativePath: relative));
              continue;
            }
            final handler = FileFormatRegistry.resolvePath(entry.name);
            if (handler == null) continue;
            final key = _key(entry.locator);
            seen.add(key);
            final old = oldByPath[key];
            if (old == null) {
              added++;
              continue;
            }
            if (old.title != entry.name ||
                old.format != handler.formatFor(entry.name) ||
                old.entityType != handler.entityType ||
                old.size != entry.size ||
                old.modifiedAtMs != entry.modifiedAtMs) {
              updated++;
            }
          }
        }
      }
      final missing = oldByPath.keys.where((key) => !seen.contains(key)).length;
      return DirectoryDiffRootResult(
        root: root,
        added: added,
        updated: updated,
        missing: missing,
        unavailable: false,
      );
    } catch (_) {
      return DirectoryDiffRootResult(
        root: root,
        added: 0,
        updated: 0,
        missing: 0,
        unavailable: true,
      );
    }
  }

  String _key(String value) {
    final source = SourceHandle.parse(value);
    return source.isAndroidContentUri ? value : p.normalize(value);
  }
}
