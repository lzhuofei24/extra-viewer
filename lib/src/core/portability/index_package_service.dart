import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../database/library_repository.dart';
import '../domain/models.dart';
import '../media/audio_waveform_service.dart';
import '../thumbnails/thumbnail_store.dart';

class IndexPackageReport {
  const IndexPackageReport({
    required this.rootCount,
    required this.nodeCount,
    required this.entityCount,
    required this.linkCount,
  });

  final int rootCount;
  final int nodeCount;
  final int entityCount;
  final int linkCount;
}

class IndexPackageService {
  IndexPackageService(this.repository)
      : waveformStore =
            AudioWaveformStore(repository.database.storageDirectoryPath);

  final LibraryRepository repository;
  final AudioWaveformStore waveformStore;

  Future<IndexPackageReport> exportPackage(
    String outputPath, {
    Iterable<String>? rootIds,
    void Function(int processed, int total, String phase)? onProgress,
  }) async {
    final selectedIds = rootIds?.toSet();
    final roots = repository
        .listIndexRoots()
        .where((root) => selectedIds == null || selectedIds.contains(root.id))
        .toList(growable: false);
    final nodes = <IndexNode>[];
    final rootByNodeId = <String, IndexNode>{};
    for (final root in roots) {
      _collectNodes(root, root, nodes, rootByNodeId);
    }
    final nodeIds = nodes.map((node) => node.id).toSet();
    final linkRows = repository.database.db.select(
      'SELECT * FROM index_node_entities ORDER BY index_node_id, entity_id',
    );
    final links = linkRows
        .where((row) => nodeIds.contains(row['index_node_id']))
        .map((row) => <String, Object?>{
              'nodeId': row['index_node_id'],
              'entityId': row['entity_id'],
              'createdAt': row['created_at'],
            })
        .toList(growable: false);
    final entityIds = links.map((link) => link['entityId']! as String).toSet();
    final entitiesById = repository.getEntitiesByIds(entityIds);
    final entities = entityIds
        .map((id) => entitiesById[id])
        .whereType<Entity>()
        .toList(growable: false);
    final entityById = <String, Entity>{
      for (final entity in entities) entity.id: entity,
    };
    final locationsByEntity = <String, List<Map<String, Object?>>>{};
    for (final link in links) {
      final entityId = link['entityId']! as String;
      final root = rootByNodeId[link['nodeId']! as String];
      if (root?.nodeType != NodeType.directoryIndexRoot ||
          root?.sourcePath == null) {
        continue;
      }
      final entity = entityById[entityId];
      if (entity == null) continue;
      (locationsByEntity[entityId] ??= []).add({
        'rootId': root!.id,
        'sourcePath': root.sourcePath,
        'relativePath': p.relative(entity.path, from: root.sourcePath!),
      });
    }
    final edgeRows = repository.database.db.select(
      'SELECT * FROM index_node_edges ORDER BY sort_order, id',
    );
    final edges = edgeRows
        .where((row) =>
            nodeIds.contains(row['from_node_id']) &&
            nodeIds.contains(row['to_node_id']))
        .map((row) => <String, Object?>{
              'id': row['id'],
              'fromNodeId': row['from_node_id'],
              'toNodeId': row['to_node_id'],
              'edgeType': row['edge_type'],
              'label': row['label'],
              'sortOrder': row['sort_order'],
            })
        .toList(growable: false);

    final manifest = <String, Object?>{
      'format': 'best-viewer-index-package',
      'version': 1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'roots': roots.map(_nodeToJson).toList(growable: false),
      'nodes': nodes.map(_nodeToJson).toList(growable: false),
      'entities': entities
          .map((entity) => _entityToJson(
                entity,
                locationsByEntity[entity.id] ?? const [],
              ))
          .toList(growable: false),
      'links': links,
      'edges': edges,
    };
    final manifestBytes = utf8.encode(jsonEncode(manifest));
    final files = <Map<String, String>>[];
    var collected = 0;
    for (final entity in entities) {
      final thumbnailPath = entity.thumbnailPath;
      if (thumbnailPath != null) {
        final file = File(thumbnailPath);
        if (await file.exists()) {
          files.add({
            'source': file.path,
            'archive': 'thumbnails/${entity.id}.webp',
          });
        }
      }
      final waveformKey = thumbnailCacheKeyFor(
        fingerprint: entity.hash,
        version: 1,
      );
      final waveformFile = File(waveformStore.pathFor(waveformKey));
      if (await waveformFile.exists()) {
        files.add({
          'source': waveformFile.path,
          'archive': 'waveforms/${entity.id}.wave',
        });
      }
      collected++;
      if (collected % 100 == 0 || collected == entities.length) {
        onProgress?.call(collected, entities.length, '正在整理导出文件');
        await Future<void>.delayed(Duration.zero);
      }
    }
    final output = File(_normalizePackagePath(outputPath));
    await output.parent.create(recursive: true);
    final temporary = File('${output.path}.tmp');
    onProgress?.call(0, files.length + 1, '正在写入索引包');
    await _runPackageArchiveWriter(
      temporary.path,
      Uint8List.fromList(manifestBytes),
      files,
    );
    onProgress?.call(files.length + 1, files.length + 1, '正在完成导出');
    if (await output.exists()) await output.delete();
    await temporary.rename(output.path);
    return IndexPackageReport(
      rootCount: roots.length,
      nodeCount: nodes.length,
      entityCount: entities.length,
      linkCount: links.length,
    );
  }

  Future<IndexPackageReport> importPackage(
    String packagePath, {
    Map<String, String> sourcePathMappings = const {},
  }) async {
    final bytes = await File(packagePath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final manifestFile = archive.findFile('manifest.json');
    if (manifestFile == null) {
      throw const FormatException('Index package has no manifest.json');
    }
    final manifest = jsonDecode(utf8.decode(manifestFile.content as List<int>));
    if (manifest is! Map<String, dynamic> ||
        manifest['format'] != 'best-viewer-index-package' ||
        manifest['version'] != 1) {
      throw const FormatException('Unsupported index package');
    }
    final rootRows = (manifest['roots'] as List).cast<Map<String, dynamic>>();
    final nodeRows = (manifest['nodes'] as List).cast<Map<String, dynamic>>();
    final entityRows =
        (manifest['entities'] as List).cast<Map<String, dynamic>>();
    final linkRows = (manifest['links'] as List).cast<Map<String, dynamic>>();
    final edgeRows = (manifest['edges'] as List).cast<Map<String, dynamic>>();
    final importedNodeByOldId = <String, IndexNode>{};
    final rootOldIds = rootRows.map((row) => row['id'] as String).toSet();

    repository.writeTransaction(() {
      for (final row in rootRows) {
        final type = NodeType.fromValue(row['nodeType'] as String);
        final source = row['sourcePath'] as String?;
        final mappedSource = source == null
            ? null
            : p.normalize(sourcePathMappings[source] ?? source);
        final root = switch (type) {
          NodeType.directoryIndexRoot =>
            repository.ensureDirectoryIndexRoot(mappedSource!),
          NodeType.categoryIndexRoot =>
            repository.ensureCollectionIndexRoot(row['name'] as String),
          NodeType.graphIndexRoot =>
            repository.ensureGraphIndexRoot(row['name'] as String),
          _ => throw FormatException('Invalid exported root type: $type'),
        };
        importedNodeByOldId[row['id'] as String] = root;
      }
      final pending =
          nodeRows.where((row) => !rootOldIds.contains(row['id'])).toList();
      while (pending.isNotEmpty) {
        final before = pending.length;
        pending.removeWhere((row) {
          final parent = importedNodeByOldId[row['parentId'] as String?];
          if (parent == null) return false;
          final node = repository.ensureIndexNode(
            parentId: parent.id,
            name: row['name'] as String,
            nodeType: NodeType.fromValue(row['nodeType'] as String),
            viewType: ViewType.fromValue(row['viewType'] as String),
            sortOrder: row['sortOrder'] as int? ?? 0,
          );
          importedNodeByOldId[row['id'] as String] = node;
          return true;
        });
        if (pending.length == before) {
          throw const FormatException('Index package contains orphan nodes');
        }
      }
    });

    final importedEntityByOldId = <String, Entity>{};
    for (final row in entityRows) {
      final oldPath = row['path'] as String;
      var importedPath = oldPath;
      final locations =
          (row['locations'] as List? ?? const []).cast<Map<String, dynamic>>();
      if (locations.isNotEmpty) {
        final location = locations.first;
        final source = location['sourcePath'] as String;
        final mappedRoot = sourcePathMappings[source] ?? source;
        importedPath =
            p.normalize(p.join(mappedRoot, location['relativePath'] as String));
      }
      final result = repository.upsertEntity(
        path: importedPath,
        name: row['name'] as String,
        format: row['format'] as String,
        entityType: EntityType.fromValue(row['entityType'] as String),
        hash: row['hash'] as String,
        size: row['size'] as int,
        sourceCreatedAtMs: row['sourceCreatedAtMs'] as int,
        sourceModifiedAtMs: row['sourceModifiedAtMs'] as int,
        metadataPreview: row['metadataPreview'] as String?,
        durationMs: row['durationMs'] as int?,
      );
      importedEntityByOldId[row['id'] as String] = result.entity;
      repository.restoreEntityUserState(
        entityId: result.entity.id,
        archived: row['archived'] == true,
        lastOpenedAtMs: row['lastOpenedAtMs'] as int?,
        lastPositionMs: row['lastPositionMs'] as int?,
        readerScrollOffset: (row['readerScrollOffset'] as num?)?.toDouble(),
        zoomScale: (row['zoomScale'] as num?)?.toDouble(),
        extraStateJson: row['extraStateJson'] as String?,
      );
      await _restoreEntityCaches(
        archive: archive,
        oldEntityId: row['id'] as String,
        entity: result.entity,
        thumbnailWidth: row['thumbnailWidth'] as int?,
        thumbnailHeight: row['thumbnailHeight'] as int?,
      );
    }
    final links = <({String entityId, String indexNodeId})>[];
    for (final row in linkRows) {
      final node = importedNodeByOldId[row['nodeId'] as String];
      final entity = importedEntityByOldId[row['entityId'] as String];
      if (node != null && entity != null) {
        links.add((entityId: entity.id, indexNodeId: node.id));
      }
    }
    repository.writeTransaction(() {
      repository.linkEntitiesToIndexNodes(links, rebuildStats: false);
      for (final row in edgeRows) {
        final from = importedNodeByOldId[row['fromNodeId'] as String];
        final to = importedNodeByOldId[row['toNodeId'] as String];
        if (from == null || to == null) continue;
        repository.linkIndexNodes(
          fromNodeId: from.id,
          toNodeId: to.id,
          edgeType: row['edgeType'] as String,
          label: row['label'] as String?,
          sortOrder: row['sortOrder'] as int? ?? 0,
        );
      }
    });
    repository.rebuildIndexNodeStats();
    return IndexPackageReport(
      rootCount: rootRows.length,
      nodeCount: nodeRows.length,
      entityCount: entityRows.length,
      linkCount: links.length,
    );
  }

  void _collectNodes(
    IndexNode node,
    IndexNode root,
    List<IndexNode> output,
    Map<String, IndexNode> rootByNodeId,
  ) {
    output.add(node);
    rootByNodeId[node.id] = root;
    for (final child in repository.listChildNodes(root.id, parentId: node.id)) {
      _collectNodes(child, root, output, rootByNodeId);
    }
  }

  Map<String, Object?> _nodeToJson(IndexNode node) => {
        'id': node.id,
        'parentId': node.parentId,
        'name': node.name,
        'nodeType': node.nodeType.value,
        'viewType': node.viewType.value,
        'sourcePath': node.sourcePath,
        'sortOrder': node.sortOrder,
      };

  Map<String, Object?> _entityToJson(
    Entity entity,
    List<Map<String, Object?>> locations,
  ) =>
      {
        'id': entity.id,
        'path': entity.path,
        'name': entity.name,
        'format': entity.format,
        'entityType': entity.entityType.value,
        'hash': entity.hash,
        'size': entity.size,
        'sourceCreatedAtMs': entity.sourceCreatedAtMs,
        'sourceModifiedAtMs': entity.sourceModifiedAtMs,
        'metadataPreview': entity.metadataPreview,
        'durationMs': entity.durationMs,
        'archived': entity.archived,
        'lastOpenedAtMs': entity.lastOpenedAtMs,
        'lastPositionMs': entity.lastPositionMs,
        'readerScrollOffset': entity.readerScrollOffset,
        'zoomScale': entity.zoomScale,
        'extraStateJson': entity.extraStateJson,
        'thumbnailWidth': entity.thumbnailWidth,
        'thumbnailHeight': entity.thumbnailHeight,
        'locations': locations,
      };

  Future<void> _restoreEntityCaches({
    required Archive archive,
    required String oldEntityId,
    required Entity entity,
    required int? thumbnailWidth,
    required int? thumbnailHeight,
  }) async {
    final thumbnail = archive.findFile('thumbnails/$oldEntityId.webp');
    if (thumbnail != null &&
        thumbnailWidth != null &&
        thumbnailHeight != null) {
      final key = thumbnailCacheKeyFor(
        fingerprint: entity.hash,
      );
      await repository.thumbnailStore.writeBytes(
        key: key,
        format: 'webp',
        bytes: Uint8List.fromList(thumbnail.content as List<int>),
      );
      repository.updateEntityThumbnailSuccess(
        entityId: entity.id,
        key: key,
        format: 'webp',
        width: thumbnailWidth,
        height: thumbnailHeight,
      );
    }
    final waveform = archive.findFile('waveforms/$oldEntityId.wave');
    if (waveform != null) {
      final key = thumbnailCacheKeyFor(
        fingerprint: entity.hash,
        version: 1,
      );
      await waveformStore.write(
        key,
        Uint8List.fromList(waveform.content as List<int>),
      );
    }
  }

  String _normalizePackagePath(String path) {
    final normalized = p.normalize(path.trim());
    if (normalized.isEmpty || normalized == '.') {
      throw ArgumentError.value(path, 'outputPath', 'Path cannot be empty');
    }
    return p.extension(normalized).toLowerCase() == '.bvi'
        ? normalized
        : '$normalized.bvi';
  }
}

Future<void> _writePackageArchive(
  String temporaryPath,
  Uint8List manifestBytes,
  List<Map<String, String>> files,
) async {
  final temporary = File(temporaryPath);
  if (await temporary.exists()) await temporary.delete();
  final encoder = ZipFileEncoder();
  var opened = false;
  try {
    encoder.create(temporaryPath, level: ZipFileEncoder.store);
    opened = true;
    encoder.addArchiveFile(
      ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
    );
    for (final entry in files) {
      final source = File(entry['source']!);
      if (!source.existsSync()) continue;
      await encoder.addFile(
        source,
        entry['archive'],
        ZipFileEncoder.store,
      );
    }
    await encoder.close();
    opened = false;
  } catch (_) {
    if (opened) {
      try {
        await encoder.close();
      } catch (_) {
        // Preserve the original export failure.
      }
    }
    if (await temporary.exists()) await temporary.delete();
    rethrow;
  }
}

Future<void> _runPackageArchiveWriter(
  String temporaryPath,
  Uint8List manifestBytes,
  List<Map<String, String>> files,
) {
  return Isolate.run(
    () => _writePackageArchive(temporaryPath, manifestBytes, files),
  );
}
