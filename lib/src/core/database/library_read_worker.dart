import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../domain/models.dart';

/// A dedicated read-only SQLite isolate for non-interactive page warming.
/// It keeps lookahead queries from blocking scroll and navigation frames.
class LibraryReadWorker {
  LibraryReadWorker._(this._sendPort, this._isolate);

  final SendPort _sendPort;
  final Isolate _isolate;

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

  void close() {
    _sendPort.send(const <String, Object?>{'type': 'close'});
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

class LibraryReadPage {
  const LibraryReadPage({
    required this.childNodes,
    required this.entities,
    required this.hasMore,
  });

  final List<IndexNode> childNodes;
  final List<EntityListItem> entities;
  final bool hasMore;

  factory LibraryReadPage.fromMessage(Map<Object?, Object?> message) {
    final childNodes = (message['childNodes'] as List<Object?>)
        .cast<Map<Object?, Object?>>()
        .map(_nodeFromMap)
        .toList(growable: false);
    final entities = (message['entities'] as List<Object?>)
        .cast<Map<Object?, Object?>>()
        .map(_entityFromMap)
        .toList(growable: false);
    return LibraryReadPage(
      childNodes: childNodes,
      entities: entities,
      hasMore: message['hasMore'] == true,
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
      return;
    }
    final replyPort = request['replyPort'] as SendPort;
    try {
      final page = _loadDirectPage(database, storageDirectoryPath, request);
      replyPort.send(<String, Object?>{
        'ok': true,
        'childNodes': page.childNodes,
        'entities': page.entities,
        'hasMore': page.hasMore,
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

class _RawReadPage {
  const _RawReadPage({
    required this.childNodes,
    required this.entities,
    required this.hasMore,
  });

  final List<Map<String, Object?>> childNodes;
  final List<Map<String, Object?>> entities;
  final bool hasMore;
}

Map<String, Object?> _nodeToMap(Row row) => <String, Object?>{
      'id': row['id'],
      'parentId': row['parent_id'],
      'name': row['name'],
      'nodeType': row['node_type'],
      'viewType': row['view_type'],
      'sourcePath': row['source_path'],
      'thumbnailPng': row['thumbnail_png'],
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
      thumbnailPng: map['thumbnailPng'] as Uint8List?,
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
