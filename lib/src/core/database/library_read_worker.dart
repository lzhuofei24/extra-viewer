import 'dart:async';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../domain/models.dart';

/// A dedicated read-only SQLite isolate for non-interactive page warming.
/// It keeps lookahead queries from blocking scroll and navigation frames.
class LibraryReadWorker {
  LibraryReadWorker._(this._sendPort, this._isolate);

  final SendPort _sendPort;
  final Isolate _isolate;
  Future<void>? _closeFuture;

  static Future<LibraryReadWorker> start({
    required String databasePath,
    required String storageDirectoryPath,
  }) async {
    final readyPort = ReceivePort();
    final isolate = await Isolate.spawn(
      _readWorkerMain,
      <String, Object>{
        'databasePath': databasePath,
        'storageDirectoryPath': storageDirectoryPath,
        'readyPort': readyPort.sendPort,
      },
    );
    final sendPort = (await readyPort.first) as SendPort;
    readyPort.close();
    return LibraryReadWorker._(sendPort, isolate);
  }

  Future<LibraryReadPage> loadDirectPage({
    required String parentNodeId,
    required EntitySortMode sortMode,
    EntityPageCursor? after,
    int? limit,
  }) async {
    _ensureOpen();
    final response = ReceivePort();
    _sendPort.send(<String, Object?>{
      'type': 'directPage',
      'replyPort': response.sendPort,
      'parentNodeId': parentNodeId,
      'sortMode': sortMode.name,
      'cursorPrimary': after?.primary,
      'cursorSecondary': after?.secondary,
      'cursorEntityId': after?.entityId,
      'limit': limit,
    });
    final message = (await response.first) as Map<Object?, Object?>;
    response.close();
    if (message['ok'] != true) {
      throw StateError(message['error'] as String? ?? 'Read worker failed');
    }
    return LibraryReadPage.fromMessage(message);
  }

  Future<LibraryReadPage> loadRecursivePage({
    required String nodeId,
    required EntitySortMode sortMode,
    RecursiveEntityPageCursor? after,
    int? limit,
  }) async {
    _ensureOpen();
    final response = ReceivePort();
    _sendPort.send(<String, Object?>{
      'type': 'recursivePage',
      'replyPort': response.sendPort,
      'nodeId': nodeId,
      'sortMode': sortMode.name,
      'hierarchyPath': after?.hierarchyPath,
      'cursorPrimary': after?.entityCursor.primary,
      'cursorSecondary': after?.entityCursor.secondary,
      'cursorEntityId': after?.entityCursor.entityId,
      'limit': limit,
    });
    final message = (await response.first) as Map<Object?, Object?>;
    response.close();
    if (message['ok'] != true) {
      throw StateError(message['error'] as String? ?? 'Read worker failed');
    }
    return LibraryReadPage.fromMessage(message);
  }

  Future<void> close() => _closeFuture ??= _closeImpl();

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
    this.recursiveHierarchyPath,
    this.cursorPrimary,
    this.cursorSecondary,
    this.cursorEntityId,
    this.cursorSortMode,
  });

  final List<Map<String, Object?>> childNodes;
  final List<Map<String, Object?>> entities;
  final bool hasMore;
  final String? recursiveHierarchyPath;
  final Object? cursorPrimary;
  final Object? cursorSecondary;
  final String? cursorEntityId;
  final String? cursorSortMode;
}

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
  final thumbnailPath =
      status == ThumbnailStatus.success.value && key != null && format != null
          ? _thumbnailPath(storageDirectoryPath, key, format)
          : null;
  return <String, Object?>{
    'id': row['id'],
    'title': row['name'],
    'entityType': row['media_type'],
    'path': row['path'],
    'localPath': row['local_path'],
    'format': row['format'],
    'size': row['size'],
    'modifiedAtMs': row['source_modified_at_ms'],
    'metadataPreview': row['metadata_preview'],
    'thumbnailStatus': status,
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

String _thumbnailPath(String storageDirectoryPath, String key, String format) {
  final prefix = key.length >= 2 ? key.substring(0, 2) : '00';
  return p.join(storageDirectoryPath, 'thumbnails', prefix, '$key.$format');
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
      metadataPreview: map['metadataPreview'] as String?,
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
      'sizeDesc' => 'COALESCE(stats.descendant_entity_count, 0) DESC, '
          'node.name COLLATE NOCASE ASC, node.id ASC',
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
