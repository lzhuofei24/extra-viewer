import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

import '../domain/models.dart';
import '../thumbnails/thumbnail_store.dart';

/// A dedicated read-only SQLite isolate for non-interactive page warming.
/// It keeps lookahead queries from blocking scroll and navigation frames.
class LibraryReadWorker {
  LibraryReadWorker._(
    this._sendPort,
    this._isolate,
    this._errorPort,
    this._exitPort,
    this._terminalError,
  );

  final SendPort _sendPort;
  final Isolate _isolate;
  final ReceivePort _errorPort;
  final ReceivePort _exitPort;
  Future<void>? _closeFuture;
  Object? _terminalError;

  static Future<LibraryReadWorker> start({
    required String databasePath,
    required String storageDirectoryPath,
  }) async {
    final readyPort = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();
    final ready = Completer<SendPort>();
    Object? terminalError;
    LibraryReadWorker? worker;
    readyPort.listen((message) {
      if (!ready.isCompleted) ready.complete(message as SendPort);
    });
    errorPort.listen((message) {
      if (!ready.isCompleted) {
        ready.completeError(
          StateError('Read worker failed to start: $message'),
        );
      } else {
        terminalError = StateError('Read worker isolate error: $message');
        worker?._terminalError = terminalError;
      }
    });
    exitPort.listen((_) {
      if (!ready.isCompleted) {
        ready.completeError(StateError('Read worker exited during startup'));
      } else {
        terminalError ??= StateError('Read worker isolate exited');
        worker?._terminalError = terminalError;
      }
    });
    final isolate = await Isolate.spawn(
      _readWorkerMain,
      <String, Object>{
        'databasePath': databasePath,
        'storageDirectoryPath': storageDirectoryPath,
        'readyPort': readyPort.sendPort,
      },
      onError: errorPort.sendPort,
      onExit: exitPort.sendPort,
    );
    SendPort sendPort;
    try {
      sendPort = await ready.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      readyPort.close();
      errorPort.close();
      exitPort.close();
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    }
    readyPort.close();
    worker = LibraryReadWorker._(
      sendPort,
      isolate,
      errorPort,
      exitPort,
      terminalError,
    );
    return worker;
  }

  Future<LibraryReadPage> loadDirectPage({
    required String parentNodeId,
    required EntitySortMode sortMode,
    EntityPageCursor? after,
    int? limit,
  }) async {
    final message = await _request(<String, Object?>{
      'type': 'directPage',
      'parentNodeId': parentNodeId,
      'sortMode': sortMode.name,
      'cursorPrimary': after?.primary,
      'cursorSecondary': after?.secondary,
      'cursorEntityId': after?.entityId,
      'limit': limit,
    });
    return LibraryReadPage.fromMessage(message);
  }

  Future<LibraryReadPage> loadRecursivePage({
    required String nodeId,
    required EntitySortMode sortMode,
    RecursiveEntityPageCursor? after,
    int? limit,
  }) async {
    final message = await _request(<String, Object?>{
      'type': 'recursivePage',
      'nodeId': nodeId,
      'sortMode': sortMode.name,
      'hierarchyPath': after?.hierarchyPath,
      'cursorPrimary': after?.entityCursor.primary,
      'cursorSecondary': after?.entityCursor.secondary,
      'cursorEntityId': after?.entityCursor.entityId,
      'limit': limit,
    });
    return LibraryReadPage.fromMessage(message);
  }

  Future<List<IndexNode>> loadIndexRoots({
    EntitySortMode sortMode = EntitySortMode.nameAsc,
  }) async {
    final message = await _request(<String, Object?>{
      'type': 'indexRoots',
      'sortMode': sortMode.name,
    });
    return (message['nodes'] as List<Object?>)
        .cast<Map<Object?, Object?>>()
        .map(_nodeFromMap)
        .toList(growable: false);
  }

  Future<List<IndexNode>> loadNodePath({
    required String indexRootId,
    required String currentNodeId,
  }) async {
    final message = await _request(<String, Object?>{
      'type': 'nodePath',
      'indexRootId': indexRootId,
      'currentNodeId': currentNodeId,
    });
    return (message['nodes'] as List<Object?>)
        .cast<Map<Object?, Object?>>()
        .map(_nodeFromMap)
        .toList(growable: false);
  }

  Future<Map<String, IndexNodeSummary>> loadNodeSummaries(
    Iterable<String> nodeIds,
  ) async {
    final message = await _request(<String, Object?>{
      'type': 'nodeSummaries',
      'nodeIds': nodeIds.toSet().toList(growable: false),
    });
    final raw =
        (message['summaries'] as List<Object?>).cast<Map<Object?, Object?>>();
    return <String, IndexNodeSummary>{
      for (final item in raw)
        item['id']! as String: IndexNodeSummary(
          directEntityCount: item['directCount']! as int,
          descendantEntityCount: item['descendantCount']! as int,
          childNodeCount: item['childCount']! as int,
        ),
    };
  }

  Future<Map<String, int>> loadRootEntityCounts(
    Iterable<String> nodeIds,
  ) async {
    final message = await _request(<String, Object?>{
      'type': 'rootEntityCounts',
      'nodeIds': nodeIds.toSet().toList(growable: false),
    });
    final raw =
        (message['counts'] as List<Object?>).cast<Map<Object?, Object?>>();
    return <String, int>{
      for (final item in raw) item['id']! as String: item['count']! as int,
    };
  }

  /// Loads the persisted node preview description and composite asset
  /// metadata without touching the UI isolate's database or filesystem.
  Future<Map<String, IndexNodePreview>> loadNodePreviews(
    Iterable<String> nodeIds,
  ) async {
    final message = await _request(<String, Object?>{
      'type': 'nodePreviews',
      'nodeIds': nodeIds.toSet().toList(growable: false),
    });
    final raw =
        (message['previews'] as List<Object?>).cast<Map<Object?, Object?>>();
    return <String, IndexNodePreview>{
      for (final item in raw)
        item['nodeId']! as String: _previewFromMessage(item),
    };
  }

  Future<Entity?> loadEntity(String entityId) async {
    final message = await _request(<String, Object?>{
      'type': 'entity',
      'entityId': entityId,
    });
    final raw = message['entity'];
    return raw == null
        ? null
        : _fullEntityFromMap(raw as Map<Object?, Object?>);
  }

  Future<ThumbnailPreloadPage> loadThumbnailPreloadPage({
    required String nodeId,
    String? afterEntityId,
    bool recursive = false,
    int limit = 240,
  }) async {
    final message = await _request(<String, Object?>{
      'type': 'thumbnailPreload',
      'nodeId': nodeId,
      'afterEntityId': afterEntityId,
      'recursive': recursive,
      'limit': limit,
    });
    return ThumbnailPreloadPage(
      paths: (message['paths'] as List<Object?>).cast<String>(),
      nextEntityId: message['nextEntityId'] as String?,
    );
  }

  Future<void> close() => _closeFuture ??= _closeImpl();

  Future<Map<Object?, Object?>> _request(Map<String, Object?> request) async {
    _ensureOpen();
    final terminalError = _terminalError;
    if (terminalError != null) throw terminalError;
    final response = ReceivePort();
    _sendPort.send(<String, Object?>{
      ...request,
      'replyPort': response.sendPort,
    });
    late final Map<Object?, Object?> message;
    try {
      message = (await response.first.timeout(const Duration(seconds: 30)))
          as Map<Object?, Object?>;
    } on TimeoutException {
      throw StateError('Read worker request timed out');
    } finally {
      response.close();
    }
    if (message['ok'] != true) {
      throw StateError(message['error'] as String? ?? 'Read worker failed');
    }
    return message;
  }

  void _ensureOpen() {
    if (_closeFuture != null) {
      throw StateError('Library read worker is closed');
    }
  }

  Future<void> _closeImpl() async {
    final response = ReceivePort();
    _sendPort.send(<String, Object?>{
      'type': 'close',
      'replyPort': response.sendPort,
    });
    try {
      await response.first.timeout(const Duration(seconds: 2));
    } finally {
      response.close();
      _isolate.kill(priority: Isolate.beforeNextEvent);
      _errorPort.close();
      _exitPort.close();
    }
  }
}

class LibraryReadPage {
  const LibraryReadPage({
    required this.childNodes,
    required this.entities,
    required this.hasMore,
    this.recursiveCursor,
  });

  final List<IndexNode> childNodes;
  final List<EntityListItem> entities;
  final bool hasMore;
  final RecursiveEntityPageCursor? recursiveCursor;

  factory LibraryReadPage.fromMessage(Map<Object?, Object?> message) {
    final childNodes = (message['childNodes'] as List<Object?>)
        .cast<Map<Object?, Object?>>()
        .map(_nodeFromMap)
        .toList(growable: false);
    final entities = (message['entities'] as List<Object?>)
        .cast<Map<Object?, Object?>>()
        .map(_entityFromMap)
        .toList(growable: false);
    final hierarchyPath = message['recursiveHierarchyPath'] as String?;
    final cursorPrimary = message['cursorPrimary'];
    final cursorEntityId = message['cursorEntityId'] as String?;
    final cursorSortMode = message['cursorSortMode'] as String?;
    return LibraryReadPage(
      childNodes: childNodes,
      entities: entities,
      hasMore: message['hasMore'] == true,
      recursiveCursor: hierarchyPath == null ||
              cursorPrimary == null ||
              cursorEntityId == null ||
              cursorSortMode == null
          ? null
          : RecursiveEntityPageCursor(
              hierarchyPath: hierarchyPath,
              entityCursor: EntityPageCursor(
                sortMode: EntitySortMode.values.byName(cursorSortMode),
                primary: cursorPrimary,
                secondary: message['cursorSecondary'],
                entityId: cursorEntityId,
              ),
            ),
    );
  }
}

void _readWorkerMain(Map<String, Object> config) {
  final databasePath = config['databasePath']! as String;
  final storageDirectoryPath = config['storageDirectoryPath']! as String;
  final readyPort = config['readyPort']! as SendPort;
  final database = sqlite3.open(databasePath, mode: OpenMode.readOnly);
  final requestPort = ReceivePort();
  readyPort.send(requestPort.sendPort);
  requestPort.listen((message) {
    final request = message as Map<Object?, Object?>;
    if (request['type'] == 'close') {
      database.dispose();
      requestPort.close();
      final replyPort = request['replyPort'] as SendPort?;
      replyPort?.send(true);
      return;
    }
    final replyPort = request['replyPort'] as SendPort;
    try {
      final page = switch (request['type']) {
        'directPage' =>
          _loadDirectPage(database, storageDirectoryPath, request),
        'recursivePage' =>
          _loadRecursivePage(database, storageDirectoryPath, request),
        'indexRoots' => _loadIndexRoots(database, request),
        'nodePath' => _loadNodePath(database, request),
        'nodeSummaries' => _loadNodeSummaries(database, request),
        'rootEntityCounts' => _loadRootEntityCounts(database, request),
        'nodePreviews' =>
          _loadNodePreviews(database, storageDirectoryPath, request),
        'entity' => _loadEntity(database, storageDirectoryPath, request),
        'thumbnailPreload' =>
          _loadThumbnailPreload(database, storageDirectoryPath, request),
        _ => throw ArgumentError.value(
            request['type'], 'type', 'Unknown read request'),
      };
      replyPort.send(<String, Object?>{
        'ok': true,
        'childNodes': page.childNodes,
        'entities': page.entities,
        'hasMore': page.hasMore,
        'recursiveHierarchyPath': page.recursiveHierarchyPath,
        'cursorPrimary': page.cursorPrimary,
        'cursorSecondary': page.cursorSecondary,
        'cursorEntityId': page.cursorEntityId,
        'cursorSortMode': page.cursorSortMode,
        'nodes': page.nodes ?? page.childNodes,
        'summaries': page.summaries,
        'counts': page.counts,
        'previews': page.previews,
        'entity': page.entity,
        'paths': page.paths,
        'nextEntityId': page.nextEntityId,
      });
    } catch (error) {
      replyPort.send(<String, Object?>{'ok': false, 'error': '$error'});
    }
  });
}

_RawReadPage _loadDirectPage(
  Database database,
  String storageDirectoryPath,
  Map<Object?, Object?> request,
) {
  final parentId = request['parentNodeId']! as String;
  final sortName = request['sortMode']! as String;
  final limit = request['limit'] as int?;
  final nodeRows = database.select(
    '''
    SELECT node.* FROM index_nodes node
    LEFT JOIN index_node_stats stats ON stats.node_id = node.id
    WHERE node.parent_id = ?
    ORDER BY ${_nodeOrderBy(sortName)}
    ''',
    [parentId],
  );
  final orderBy = sortName == EntitySortMode.nameAsc.name
      ? 'link.sort_name COLLATE NOCASE ASC, entity.id ASC'
      : _orderBy(sortName);
  final cursor = _workerCursorCondition(request, sortName);
  final parameters = <Object>[
    parentId,
    if (cursor != null) ...cursor.parameters,
  ];
  final limitSql = limit == null ? '' : 'LIMIT ?';
  if (limit != null) parameters.add(limit + 1);
  final entityRows = database.select(
    '''
    SELECT entity.* FROM index_node_entities link
    JOIN entities entity ON entity.id = link.entity_id
    WHERE link.index_node_id = ?
    AND entity.archived = 0
    ${cursor == null ? '' : 'AND (${cursor.sql})'}
    ORDER BY $orderBy
    $limitSql
    ''',
    parameters,
  );
  final hasMore = limit != null && entityRows.length > limit;
  final visibleRows = hasMore ? entityRows.sublist(0, limit) : entityRows;
  return _RawReadPage(
    childNodes: nodeRows.map(_nodeToMap).toList(growable: false),
    entities: visibleRows
        .map((row) => _entityToMap(row, storageDirectoryPath))
        .toList(growable: false),
    hasMore: hasMore,
  );
}

_RawReadPage _loadIndexRoots(
  Database database,
  Map<Object?, Object?> request,
) {
  final sortName = request['sortMode']! as String;
  final rows = database.select(
    '''
    SELECT node.* FROM index_nodes node
    LEFT JOIN index_node_stats stats ON stats.node_id = node.id
    WHERE node.parent_id = (
      SELECT root.id FROM index_nodes root WHERE root.node_type = ? LIMIT 1
    )
      AND node.is_staging = 0
    ORDER BY ${_nodeOrderBy(sortName)}
    ''',
    ['root'],
  );
  return _RawReadPage(
    childNodes: rows.map(_nodeToMap).toList(growable: false),
    entities: const [],
    hasMore: false,
    nodes: rows.map(_nodeToMap).toList(growable: false),
  );
}

_RawReadPage _loadNodePath(
  Database database,
  Map<Object?, Object?> request,
) {
  final currentNodeId = request['currentNodeId']! as String;
  final rootId = request['indexRootId']! as String;
  final rows = database.select(
    '''
    WITH RECURSIVE ancestors(id, parent_id, depth) AS (
      SELECT id, parent_id, 0
      FROM index_nodes
      WHERE id = ?
      UNION ALL
      SELECT parent.id, parent.parent_id, ancestors.depth + 1
      FROM index_nodes parent
      JOIN ancestors ON ancestors.parent_id = parent.id
    )
    SELECT node.*
    FROM ancestors
    JOIN index_nodes node ON node.id = ancestors.id
    WHERE node.node_type <> ?
    ORDER BY ancestors.depth DESC
    ''',
    [currentNodeId, 'root'],
  );
  final path = rows.map(_nodeToMap).toList(growable: false);
  if (path.isEmpty || path.first['id'] != rootId) {
    return const _RawReadPage(
      childNodes: [],
      entities: [],
      hasMore: false,
    );
  }
  return _RawReadPage(
    childNodes: path,
    entities: const [],
    hasMore: false,
    nodes: path,
  );
}

_RawReadPage _loadNodeSummaries(
  Database database,
  Map<Object?, Object?> request,
) {
  final ids = (request['nodeIds'] as List<Object?>).cast<String>();
  if (ids.isEmpty) {
    return const _RawReadPage(childNodes: [], entities: [], hasMore: false);
  }
  final placeholders = List<String>.filled(ids.length, '?').join(', ');
  final rows = database.select(
    '''
    SELECT node.id,
           COALESCE(stats.direct_entity_count, 0) AS direct_count,
           COALESCE(stats.descendant_entity_count, 0) AS descendant_count,
           COALESCE(stats.child_node_count, 0) AS child_count
    FROM index_nodes node
    LEFT JOIN index_node_stats stats ON stats.node_id = node.id
    WHERE node.id IN ($placeholders)
    ''',
    ids,
  );
  return _RawReadPage(
    childNodes: const [],
    entities: const [],
    hasMore: false,
    summaries: rows
        .map((row) => <String, Object?>{
              'id': row['id'],
              'directCount': row['direct_count'],
              'descendantCount': row['descendant_count'],
              'childCount': row['child_count'],
            })
        .toList(growable: false),
  );
}

_RawReadPage _loadRootEntityCounts(
  Database database,
  Map<Object?, Object?> request,
) {
  final ids = (request['nodeIds'] as List<Object?>).cast<String>();
  if (ids.isEmpty) {
    return const _RawReadPage(childNodes: [], entities: [], hasMore: false);
  }
  final placeholders = List<String>.filled(ids.length, '?').join(', ');
  final rows = database.select(
    '''
    SELECT node.id, COALESCE(stats.descendant_entity_count, 0) AS count
    FROM index_nodes node
    LEFT JOIN index_node_stats stats ON stats.node_id = node.id
    WHERE node.id IN ($placeholders)
    ''',
    ids,
  );
  return _RawReadPage(
    childNodes: const [],
    entities: const [],
    hasMore: false,
    counts: rows
        .map((row) => <String, Object?>{
              'id': row['id'],
              'count': row['count'],
            })
        .toList(growable: false),
  );
}

_RawReadPage _loadNodePreviews(
  Database database,
  String storageDirectoryPath,
  Map<Object?, Object?> request,
) {
  final ids = (request['nodeIds'] as List<Object?>? ?? const <Object?>[])
      .whereType<String>()
      .toSet()
      .toList(growable: false);
  if (ids.isEmpty) {
    return const _RawReadPage(
      childNodes: [],
      entities: [],
      hasMore: false,
    );
  }
  final placeholders = List<String>.filled(ids.length, '?').join(', ');
  final nodeRows = database.select(
    'SELECT id, name, preview_json FROM index_nodes WHERE id IN ($placeholders)',
    ids,
  );
  final names = <String, String>{};
  final previewJson = <String, String?>{};
  for (final row in nodeRows) {
    final id = row['id'] as String;
    names[id] = row['name'] as String;
    previewJson[id] = row['preview_json'] as String?;
  }

  final assetRows = database.select(
    '''
    SELECT node_id, asset_key, format, width, height
    FROM node_preview_assets
    WHERE node_id IN ($placeholders)
    ''',
    ids,
  );
  final assets = <String, ({String path, double aspectRatio})>{};
  for (final row in assetRows) {
    final width = row['width'] as int? ?? 0;
    final height = row['height'] as int? ?? 0;
    if (width <= 0 || height <= 0) continue;
    final assetKey = row['asset_key'] as String;
    final format = row['format'] as String;
    assets[row['node_id'] as String] = (
      path: nodePreviewAssetPathFor(storageDirectoryPath, assetKey, format),
      aspectRatio: width / height,
    );
  }

  final overrideRows = database.select(
    '''
    SELECT node_id, items_json
    FROM node_preview_overrides
    WHERE node_id IN ($placeholders)
    ''',
    ids,
  );
  final overrides = <String, String>{};
  for (final row in overrideRows) {
    overrides[row['node_id'] as String] = row['items_json'] as String;
  }

  final previews = <Map<String, Object?>>[];
  for (final nodeId in ids) {
    final nodeName = names[nodeId] ?? '';
    final override = overrides[nodeId];
    final raw = override == null || _decodeList(override).isEmpty
        ? _storedNodePreview(
            previewJson[nodeId], nodeName, storageDirectoryPath)
        : _storedOverridePreview(override, nodeName, storageDirectoryPath);
    final asset = assets[nodeId];
    if (asset != null && _isVisualPreviewKind(raw['kind'])) {
      raw['visualAssetPath'] = asset.path;
      raw['visualAssetAspectRatio'] = asset.aspectRatio;
    }
    previews.add(<String, Object?>{'nodeId': nodeId, ...raw});
  }
  return _RawReadPage(
    childNodes: const [],
    entities: const [],
    hasMore: false,
    previews: previews,
  );
}

Map<String, Object?> _storedNodePreview(
  String? json,
  String nodeName,
  String storageDirectoryPath,
) {
  final value = _decodeObject(json);
  if (value == null) return <String, Object?>{'kind': 'empty'};
  final tile = _storedTileMessage(value, nodeName, storageDirectoryPath);
  final tileKind = tile['kind'] as String?;
  return switch (tileKind) {
    'visual' => <String, Object?>{
        'kind': 'singleVisual',
        'tiles': [tile],
      },
    'audio' => <String, Object?>{
        'kind': 'audioList',
        'audioNames': tile['audioNames'] ?? const <String>[],
      },
    'document' => <String, Object?>{
        'kind': 'documentList',
        'documentNames': tile['documentNames'] ?? const <String>[],
      },
    'mixedData' => <String, Object?>{
        'kind': 'splitLists',
        'audioNames': tile['audioNames'] ?? const <String>[],
        'documentNames': tile['documentNames'] ?? const <String>[],
      },
    _ => <String, Object?>{'kind': 'empty'},
  };
}

Map<String, Object?> _storedOverridePreview(
  String json,
  String nodeName,
  String storageDirectoryPath,
) {
  final decoded = _decodeList(json);
  final tiles = [
    for (final value in decoded)
      _storedTileMessage(value, nodeName, storageDirectoryPath),
  ];
  final audioNames = <String>[];
  final documentNames = <String>[];
  for (final tile in tiles) {
    for (final value
        in (tile['audioNames'] as List<Object?>? ?? const <Object?>[])) {
      if (value is String) audioNames.add(value);
    }
    for (final value
        in (tile['documentNames'] as List<Object?>? ?? const <Object?>[])) {
      if (value is String) documentNames.add(value);
    }
  }
  final hasVisual = tiles.any((tile) => tile['kind'] == 'visual');
  if (hasVisual) {
    return <String, Object?>{
      'kind': 'visualGrid',
      'tiles': tiles,
      'audioNames': _distinctStrings(audioNames),
      'documentNames': _distinctStrings(documentNames),
      'customOrderTopToBottom': true,
    };
  }
  if (audioNames.isNotEmpty && documentNames.isNotEmpty) {
    return <String, Object?>{
      'kind': 'splitLists',
      'audioNames': _distinctStrings(audioNames),
      'documentNames': _distinctStrings(documentNames),
      'customOrderTopToBottom': true,
    };
  }
  return <String, Object?>{
    'kind': audioNames.isNotEmpty ? 'audioList' : 'documentList',
    'audioNames': _distinctStrings(audioNames),
    'documentNames': _distinctStrings(documentNames),
    'customOrderTopToBottom': true,
  };
}

Map<String, Object?> _storedTileMessage(
  Map<String, Object?> value,
  String nodeName,
  String storageDirectoryPath,
) {
  final key = value['thumbnailKey'] as String?;
  final format = value['thumbnailFormat'] as String?;
  final thumbnailPath =
      key != null && format != null && key.isNotEmpty && format.isNotEmpty
          ? _thumbnailPath(storageDirectoryPath, key, format)
          : null;
  return <String, Object?>{
    'kind': value['kind'] as String? ?? 'node',
    'title': value['title'] as String? ?? nodeName,
    'thumbnailPath': thumbnailPath,
    'thumbnailKey': key,
    'thumbnailFormat': format,
    'entityId': value['entityId'] as String?,
    'nodeId': value['nodeId'] as String?,
    'aspectRatio': (value['aspectRatio'] as num?)?.toDouble() ?? 1.0,
    'audioNames': _stringList(value['audioNames']),
    'documentNames': _stringList(value['documentNames']),
  };
}

Map<String, Object?>? _decodeObject(String? json) {
  if (json == null || json.isEmpty) return null;
  try {
    final value = jsonDecode(json);
    return value is Map ? Map<String, Object?>.from(value) : null;
  } catch (_) {
    return null;
  }
}

List<Map<String, Object?>> _decodeList(String json) {
  try {
    final value = jsonDecode(json);
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((item) => Map<String, Object?>.from(item))
        .toList(growable: false);
  } catch (_) {
    return const [];
  }
}

List<String> _stringList(Object? value) => value is List
    ? value.whereType<String>().toList(growable: false)
    : const <String>[];

List<String> _distinctStrings(Iterable<String> values) {
  final seen = <String>{};
  return [
    for (final value in values)
      if (value.trim().isNotEmpty && seen.add(value)) value,
  ];
}

bool _isVisualPreviewKind(Object? value) =>
    value == 'singleVisual' || value == 'visualGrid';

_RawReadPage _loadEntity(
  Database database,
  String storageDirectoryPath,
  Map<Object?, Object?> request,
) {
  final rows = database.select(
    'SELECT * FROM entities WHERE id = ? LIMIT 1',
    [request['entityId']! as String],
  );
  return _RawReadPage(
    childNodes: const [],
    entities: const [],
    hasMore: false,
    entity: rows.isEmpty
        ? null
        : _fullEntityToMap(rows.first, storageDirectoryPath),
  );
}

_RawReadPage _loadThumbnailPreload(
  Database database,
  String storageDirectoryPath,
  Map<Object?, Object?> request,
) {
  final nodeId = request['nodeId']! as String;
  final afterEntityId = request['afterEntityId'] as String?;
  final recursive = request['recursive'] == true;
  final requestedLimit = (request['limit'] as num?)?.toInt() ?? 240;
  final limit = requestedLimit.clamp(1, 500).toInt();
  final rows = recursive
      ? database.select('''
          WITH RECURSIVE subtree(id) AS (
            SELECT ?
            UNION ALL
            SELECT node.id FROM index_nodes node
            JOIN subtree parent ON node.parent_id = parent.id
          ), entity_ids AS (
            SELECT link.entity_id AS id
            FROM index_node_entities link
            JOIN subtree ON subtree.id = link.index_node_id
            GROUP BY link.entity_id
          )
          SELECT entity.id, entity.thumbnail_key, entity.thumbnail_format
          FROM entity_ids
          JOIN entities entity ON entity.id = entity_ids.id
          WHERE entity.archived = 0
            AND entity.thumbnail_status = 'success'
            AND entity.thumbnail_key IS NOT NULL
            AND entity.thumbnail_format IS NOT NULL
            AND (? IS NULL OR entity.id > ?)
          ORDER BY entity.id ASC
          LIMIT ?
        ''', [nodeId, afterEntityId, afterEntityId, limit + 1])
      : database.select('''
          SELECT entity.id, entity.thumbnail_key, entity.thumbnail_format
          FROM index_node_entities link
          JOIN entities entity ON entity.id = link.entity_id
          WHERE link.index_node_id = ?
            AND entity.archived = 0
            AND entity.thumbnail_status = 'success'
            AND entity.thumbnail_key IS NOT NULL
            AND entity.thumbnail_format IS NOT NULL
            AND (? IS NULL OR entity.id > ?)
          ORDER BY entity.id ASC
          LIMIT ?
        ''', [nodeId, afterEntityId, afterEntityId, limit + 1]);
  final hasMore = rows.length > limit;
  final visible = hasMore ? rows.sublist(0, limit) : rows;
  final paths = visible
      .map((row) => _thumbnailPath(
            storageDirectoryPath,
            row['thumbnail_key'] as String,
            row['thumbnail_format'] as String,
          ))
      .toList(growable: false);
  return _RawReadPage(
    childNodes: const [],
    entities: const [],
    hasMore: hasMore,
    paths: paths,
    nextEntityId: hasMore ? visible.last['id'] as String : null,
  );
}

_RawReadPage _loadRecursivePage(
  Database database,
  String storageDirectoryPath,
  Map<Object?, Object?> request,
) {
  final nodeId = request['nodeId']! as String;
  final sortName = request['sortMode']! as String;
  final hierarchyPath = request['hierarchyPath'] as String?;
  final cursor = _workerCursorCondition(request, sortName);
  final limit = request['limit'] as int?;
  final parameters = <Object>[
    nodeId,
    if (hierarchyPath != null && cursor != null) ...[
      hierarchyPath,
      hierarchyPath,
      ...cursor.parameters,
    ],
  ];
  final limitSql = limit == null ? '' : 'LIMIT ?';
  if (limit != null) parameters.add(limit + 1);
  final rows = database.select(
    '''
    WITH RECURSIVE subtree(id, hierarchy_path) AS (
      SELECT id,
             printf('%010d', sort_order) || char(31) ||
             lower(name) || char(31) || id
      FROM index_nodes
      WHERE id = ?
      UNION ALL
      SELECT node.id,
             parent.hierarchy_path || char(30) ||
             printf('%010d', node.sort_order) || char(31) ||
             lower(node.name) || char(31) || node.id
      FROM index_nodes node
      JOIN subtree parent ON node.parent_id = parent.id
    ), entity_nodes AS (
      SELECT link.entity_id, MIN(subtree.hierarchy_path) AS hierarchy_path
      FROM index_node_entities link
      JOIN subtree ON subtree.id = link.index_node_id
      GROUP BY link.entity_id
    )
    SELECT entity.*, entity_nodes.hierarchy_path AS recursive_hierarchy_path
    FROM entity_nodes
    JOIN entities entity ON entity.id = entity_nodes.entity_id
    WHERE entity.archived = 0
    ${hierarchyPath == null || cursor == null ? '' : 'AND (entity_nodes.hierarchy_path > ? OR (entity_nodes.hierarchy_path = ? AND (${cursor.sql})))'}
    ORDER BY entity_nodes.hierarchy_path ASC, ${_orderBy(sortName)}
    $limitSql
    ''',
    parameters,
  );
  final hasMore = limit != null && rows.length > limit;
  final visibleRows = hasMore ? rows.sublist(0, limit) : rows;
  final last = visibleRows.isEmpty ? null : visibleRows.last;
  final cursorValues = last == null ? null : _cursorValues(last, sortName);
  return _RawReadPage(
    childNodes: const [],
    entities: visibleRows
        .map((row) => _entityToMap(row, storageDirectoryPath))
        .toList(growable: false),
    hasMore: hasMore,
    recursiveHierarchyPath: last?['recursive_hierarchy_path'] as String?,
    cursorPrimary: cursorValues?.primary,
    cursorSecondary: cursorValues?.secondary,
    cursorEntityId: last?['id'] as String?,
    cursorSortMode: last == null ? null : sortName,
  );
}

class _RawReadPage {
  const _RawReadPage({
    required this.childNodes,
    required this.entities,
    required this.hasMore,
    this.nodes,
    this.recursiveHierarchyPath,
    this.cursorPrimary,
    this.cursorSecondary,
    this.cursorEntityId,
    this.cursorSortMode,
    this.summaries = const [],
    this.counts = const [],
    this.entity,
    this.paths = const [],
    this.nextEntityId,
    this.previews = const [],
  });

  final List<Map<String, Object?>> childNodes;
  final List<Map<String, Object?>> entities;
  final bool hasMore;
  final List<Map<String, Object?>>? nodes;
  final String? recursiveHierarchyPath;
  final Object? cursorPrimary;
  final Object? cursorSecondary;
  final String? cursorEntityId;
  final String? cursorSortMode;
  final List<Map<String, Object?>> summaries;
  final List<Map<String, Object?>> counts;
  final Map<String, Object?>? entity;
  final List<String> paths;
  final String? nextEntityId;
  final List<Map<String, Object?>> previews;
}

IndexNodePreview _previewFromMessage(Map<Object?, Object?> raw) {
  final kind = _previewKindFromName(raw['kind'] as String?);
  final rawTiles = raw['tiles'];
  final tiles = rawTiles is List
      ? rawTiles
          .whereType<Map>()
          .map(
            (item) => _previewTileFromMessage(
              Map<Object?, Object?>.from(item),
            ),
          )
          .toList(growable: false)
      : const <IndexNodePreviewTile>[];
  final rawAspect = raw['visualAssetAspectRatio'];
  return IndexNodePreview(
    nodeId: raw['nodeId']! as String,
    kind: kind,
    tiles: tiles,
    audioNames: _stringList(raw['audioNames']),
    documentNames: _stringList(raw['documentNames']),
    customOrderTopToBottom: raw['customOrderTopToBottom'] == true,
    visualAssetPath: raw['visualAssetPath'] as String?,
    visualAssetAspectRatio: (rawAspect as num?)?.toDouble(),
  );
}

IndexNodePreviewTile _previewTileFromMessage(Map<Object?, Object?> raw) {
  return IndexNodePreviewTile(
    kind: _previewTileKindFromName(raw['kind'] as String?),
    title: raw['title'] as String? ?? '',
    thumbnailPath: raw['thumbnailPath'] as String?,
    thumbnailKey: raw['thumbnailKey'] as String?,
    thumbnailFormat: raw['thumbnailFormat'] as String?,
    entityId: raw['entityId'] as String?,
    nodeId: raw['nodeId'] as String?,
    aspectRatio: (raw['aspectRatio'] as num?)?.toDouble() ?? 1.0,
    audioNames: _stringList(raw['audioNames']),
    documentNames: _stringList(raw['documentNames']),
  );
}

IndexNodePreviewKind _previewKindFromName(String? name) =>
    IndexNodePreviewKind.values.firstWhere(
      (value) => value.name == name,
      orElse: () => IndexNodePreviewKind.empty,
    );

IndexNodePreviewTileKind _previewTileKindFromName(String? name) =>
    IndexNodePreviewTileKind.values.firstWhere(
      (value) => value.name == name,
      orElse: () => IndexNodePreviewTileKind.node,
    );

({Object primary, Object? secondary}) _cursorValues(Row row, String sortMode) {
  return switch (sortMode) {
    'nameAsc' || 'nameDesc' => (
        primary: row['name'] as String,
        secondary: null
      ),
    'modifiedDesc' || 'modifiedAsc' => (
        primary: row['source_modified_at_ms'] as int,
        secondary: null
      ),
    'sizeDesc' || 'sizeAsc' => (primary: row['size'] as int, secondary: null),
    'typeAsc' => (
        primary: row['format'] as String,
        secondary: row['name'] as String,
      ),
    _ => (primary: row['name'] as String, secondary: null),
  };
}

Map<String, Object?> _nodeToMap(Row row) => <String, Object?>{
      'id': row['id'],
      'parentId': row['parent_id'],
      'name': row['name'],
      'nodeType': row['node_type'],
      'viewType': row['view_type'],
      'sourcePath': row['source_path'],
      'sortOrder': row['sort_order'],
      'createdAtMs': row['created_at'],
      'updatedAtMs': row['updated_at'],
      'lastBuiltAtMs': row['last_built_at_ms'],
    };

Map<String, Object?> _entityToMap(Row row, String storageDirectoryPath) {
  final status = row['thumbnail_status'] as String? ?? 'none';
  final key = row['thumbnail_key'] as String?;
  final format = row['thumbnail_format'] as String?;
  final thumbnailPath = key != null && format != null
      ? _thumbnailPath(storageDirectoryPath, key, format)
      : null;
  return <String, Object?>{
    'id': row['id'],
    'hash': row['hash'],
    'title': row['name'],
    'entityType': row['media_type'],
    'path': row['path'],
    'localPath': row['local_path'],
    'format': row['format'],
    'size': row['size'],
    'modifiedAtMs': row['source_modified_at_ms'],
    'contentExcerpt': row['metadata_preview'],
    'thumbnailStatus': status,
    'sourceRevision': row['source_revision'],
    'previewRevision': row['preview_revision'],
    'thumbnailPath': thumbnailPath,
    'thumbnailKey': key,
    'thumbnailFormat': format,
    'thumbnailWidth': row['thumbnail_width'],
    'thumbnailHeight': row['thumbnail_height'],
    'archived': row['archived'],
    'lastOpenedAtMs': row['last_opened_at'],
    'lastPositionMs': row['last_position_ms'],
    'durationMs': row['duration_ms'],
    'readerScrollOffset': row['reader_scroll_offset'],
    'zoomScale': row['zoom_scale'],
    'extraStateJson': row['extra_state_json'],
  };
}

Map<String, Object?> _fullEntityToMap(
  Row row,
  String storageDirectoryPath,
) {
  final values = _entityToMap(row, storageDirectoryPath);
  return <String, Object?>{
    ...values,
    'name': row['name'],
    'format': row['format'],
    'sourceCreatedAtMs': row['source_created_at_ms'],
    'sourceModifiedAtMs': row['source_modified_at_ms'],
    'createdAtMs': row['created_at'],
    'updatedAtMs': row['updated_at'],
    'thumbnailError': row['thumbnail_error'],
    'directoryRootId': row['directory_root_id'],
  };
}

String _thumbnailPath(String storageDirectoryPath, String key, String format) {
  return ThumbnailStore(storageDirectoryPath).pathFor(key, format);
}

IndexNode _nodeFromMap(Map<Object?, Object?> map) => IndexNode(
      id: map['id']! as String,
      parentId: map['parentId'] as String?,
      name: map['name']! as String,
      nodeType: NodeType.fromValue(map['nodeType']! as String),
      viewType: ViewType.fromValue(map['viewType']! as String),
      sourcePath: map['sourcePath'] as String?,
      sortOrder: map['sortOrder']! as int,
      createdAtMs: map['createdAtMs']! as int,
      updatedAtMs: map['updatedAtMs']! as int,
      lastBuiltAtMs: map['lastBuiltAtMs'] as int?,
    );

EntityListItem _entityFromMap(Map<Object?, Object?> map) => EntityListItem(
      id: map['id']! as String,
      title: map['title']! as String,
      entityType: EntityType.fromValue(map['entityType']! as String),
      path: map['path']! as String,
      localPath: map['localPath'] as String?,
      format: map['format']! as String,
      size: map['size']! as int,
      modifiedAtMs: map['modifiedAtMs']! as int,
      contentExcerpt: map['contentExcerpt'] as String?,
      thumbnailStatus:
          ThumbnailStatus.fromValue(map['thumbnailStatus']! as String),
      thumbnailPath: map['thumbnailPath'] as String?,
      thumbnailKey: map['thumbnailKey'] as String?,
      thumbnailFormat: map['thumbnailFormat'] as String?,
      thumbnailWidth: map['thumbnailWidth'] as int?,
      thumbnailHeight: map['thumbnailHeight'] as int?,
      archived: map['archived'] == 1,
      lastOpenedAtMs: map['lastOpenedAtMs'] as int?,
      lastPositionMs: map['lastPositionMs'] as int?,
      durationMs: map['durationMs'] as int?,
      readerScrollOffset: (map['readerScrollOffset'] as num?)?.toDouble(),
      zoomScale: (map['zoomScale'] as num?)?.toDouble(),
      extraStateJson: map['extraStateJson'] as String?,
    );

Entity _fullEntityFromMap(Map<Object?, Object?> map) => Entity(
      id: map['id']! as String,
      sourceRevision: map['sourceRevision'] as int? ?? 1,
      previewRevision: map['previewRevision'] as int? ?? 1,
      path: map['path']! as String,
      localPath: map['localPath'] as String?,
      name: (map['name'] ?? map['title'])! as String,
      format: map['format']! as String,
      entityType: EntityType.fromValue(map['entityType']! as String),
      hash: map['hash'] as String? ?? '',
      size: map['size']! as int,
      sourceCreatedAtMs: map['sourceCreatedAtMs'] as int? ?? 0,
      sourceModifiedAtMs:
          map['sourceModifiedAtMs'] as int? ?? map['modifiedAtMs'] as int? ?? 0,
      createdAtMs: map['createdAtMs'] as int? ?? 0,
      updatedAtMs: map['updatedAtMs'] as int? ?? 0,
      contentExcerpt: map['contentExcerpt'] as String?,
      thumbnailStatus:
          ThumbnailStatus.fromValue(map['thumbnailStatus']! as String),
      thumbnailKey: map['thumbnailKey'] as String?,
      thumbnailFormat: map['thumbnailFormat'] as String?,
      thumbnailWidth: map['thumbnailWidth'] as int?,
      thumbnailHeight: map['thumbnailHeight'] as int?,
      thumbnailError: map['thumbnailError'] as String?,
      thumbnailPath: map['thumbnailPath'] as String?,
      archived: map['archived'] == 1 || map['archived'] == true,
      lastOpenedAtMs: map['lastOpenedAtMs'] as int?,
      lastPositionMs: map['lastPositionMs'] as int?,
      durationMs: map['durationMs'] as int?,
      readerScrollOffset: (map['readerScrollOffset'] as num?)?.toDouble(),
      zoomScale: (map['zoomScale'] as num?)?.toDouble(),
      extraStateJson: map['extraStateJson'] as String?,
      directoryRootId: map['directoryRootId'] as String?,
    );

String _orderBy(String sortMode) => switch (sortMode) {
      'nameAsc' => 'entity.name COLLATE NOCASE ASC, entity.id ASC',
      'nameDesc' => 'entity.name COLLATE NOCASE DESC, entity.id ASC',
      'modifiedDesc' => 'entity.source_modified_at_ms DESC, entity.id ASC',
      'modifiedAsc' => 'entity.source_modified_at_ms ASC, entity.id ASC',
      'sizeDesc' => 'entity.size DESC, entity.id ASC',
      'sizeAsc' => 'entity.size ASC, entity.id ASC',
      'typeAsc' =>
        'entity.format COLLATE NOCASE ASC, entity.name COLLATE NOCASE ASC, entity.id ASC',
      _ => 'entity.name COLLATE NOCASE ASC, entity.id ASC',
    };

String _nodeOrderBy(String sortMode) => switch (sortMode) {
      'modifiedDesc' =>
        'node.updated_at DESC, node.name COLLATE NOCASE ASC, node.id ASC',
      'nameAsc' => 'node.name COLLATE NOCASE ASC, node.id ASC',
      'nameDesc' => 'node.name COLLATE NOCASE DESC, node.id ASC',
      'sizeDesc' => 'COALESCE(stats.descendant_entity_count, 0) DESC, '
          'node.name COLLATE NOCASE ASC, node.id ASC',
      'sizeAsc' => 'COALESCE(stats.descendant_entity_count, 0) ASC, '
          'node.name COLLATE NOCASE ASC, node.id ASC',
      'modifiedAsc' =>
        'node.updated_at ASC, node.name COLLATE NOCASE ASC, node.id ASC',
      'typeAsc' =>
        'node.node_type ASC, node.name COLLATE NOCASE ASC, node.id ASC',
      _ => 'node.name COLLATE NOCASE ASC, node.id ASC',
    };

({String sql, List<Object> parameters})? _workerCursorCondition(
  Map<Object?, Object?> request,
  String sortMode,
) {
  final primary = request['cursorPrimary'];
  final entityId = request['cursorEntityId'] as String?;
  if (primary == null || entityId == null) return null;
  final secondary = request['cursorSecondary'];
  return switch (sortMode) {
    'nameAsc' => (
        sql:
            'entity.name COLLATE NOCASE > ? OR (entity.name COLLATE NOCASE = ? AND entity.id > ?)',
        parameters: [primary, primary, entityId],
      ),
    'nameDesc' => (
        sql:
            'entity.name COLLATE NOCASE < ? OR (entity.name COLLATE NOCASE = ? AND entity.id > ?)',
        parameters: [primary, primary, entityId],
      ),
    'modifiedDesc' => (
        sql:
            'entity.source_modified_at_ms < ? OR (entity.source_modified_at_ms = ? AND entity.id > ?)',
        parameters: [primary, primary, entityId],
      ),
    'modifiedAsc' => (
        sql:
            'entity.source_modified_at_ms > ? OR (entity.source_modified_at_ms = ? AND entity.id > ?)',
        parameters: [primary, primary, entityId],
      ),
    'sizeDesc' => (
        sql: 'entity.size < ? OR (entity.size = ? AND entity.id > ?)',
        parameters: [primary, primary, entityId],
      ),
    'sizeAsc' => (
        sql: 'entity.size > ? OR (entity.size = ? AND entity.id > ?)',
        parameters: [primary, primary, entityId],
      ),
    'typeAsc' when secondary != null => (
        sql: '''
entity.format COLLATE NOCASE > ? OR
(entity.format COLLATE NOCASE = ? AND (
  entity.name COLLATE NOCASE > ? OR
  (entity.name COLLATE NOCASE = ? AND entity.id > ?)
))
''',
        parameters: [primary, primary, secondary, secondary, entityId],
      ),
    _ => null,
  };
}
