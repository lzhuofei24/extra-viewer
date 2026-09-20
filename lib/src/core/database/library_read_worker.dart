import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:sqlite3/sqlite3.dart';

import '../domain/models.dart';
import '../thumbnails/thumbnail_store.dart';
import '../../modules/library/library_queries.dart';
import 'node_search_query.dart';
import 'browse_sessions.dart';
import 'browse_cache_files.dart';
import 'local_statistics.dart';
import 'query_cache.dart';

enum RecursiveReadScope { node, directoryHome, collectionHome }

/// A dedicated read-only SQLite isolate for non-interactive page warming.
/// It keeps lookahead queries from blocking scroll and navigation frames.
class LibraryReadWorker implements LibraryQueries {
  LibraryReadWorker._(
    this._sendPort,
    this._isolate,
    this._errorPort,
    this._exitPort,
    this._terminalError,
    this._databasePath,
    this._storageDirectoryPath,
    this._cachePath,
    this._cacheFiles,
  );

  final SendPort _sendPort;
  final Isolate _isolate;
  final ReceivePort _errorPort;
  final ReceivePort _exitPort;
  Future<void>? _closeFuture;
  Object? _terminalError;
  final Set<Completer<Map<Object?, Object?>>> _pending = {};
  LibraryReadWorker? _background;
  Timer? _statisticsTimer;
  bool _statisticsRunning = false;

  void stopStatisticsMaintenance() => _statisticsTimer?.cancel();

  void startStatisticsMaintenance(
      Future<void> Function(List<Map<String, Object?>>) publish,
      {void Function(Object, StackTrace)? onError}) {
    _statisticsTimer?.cancel();
    _statisticsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_statisticsRunning || _closeFuture != null) return;
      _statisticsRunning = true;
      try {
        final rows = await loadDirtyStatistics();
        if (_closeFuture == null && rows.isNotEmpty) await publish(rows);
      } catch (error, stack) {
        if (_closeFuture == null) onError?.call(error, stack);
      } finally {
        _statisticsRunning = false;
      }
    });
  }

  Future<List<Map<String, Object?>>> loadDirtyStatistics() async {
    final result = await _request({'type': 'dirtyStatistics'});
    return (result['rows'] as List).cast<Map<String, Object?>>();
  }

  final String _databasePath;
  final String _storageDirectoryPath;
  final String _cachePath;
  final BrowseCacheFiles? _cacheFiles;
  LibraryReadWorker? _replacement;
  Future<LibraryReadWorker>? _restarting;

  Future<LibraryReadWorker> _recover() async {
    final previous = _replacement;
    if (previous != null && previous._terminalError == null) return previous;
    return _restarting ??= _startReplacement();
  }

  Future<LibraryReadWorker> _startReplacement() async {
    try {
      await _replacement?.close();
      _isolate.kill(priority: Isolate.immediate);
      _errorPort.close();
      _exitPort.close();
      final next = await start(
        databasePath: _databasePath,
        storageDirectoryPath: _storageDirectoryPath,
        createBackground: false,
        sessionCachePath: _cachePath,
      );
      if (_closeFuture != null) {
        await next.close();
        throw StateError('Library read worker is closed');
      }
      _replacement = next;
      return next;
    } finally {
      _restarting = null;
    }
  }

  @visibleForTesting
  Future<void> exitForTesting({bool background = false}) async {
    final target = background ? _background! : (_replacement ?? this);
    final response = ReceivePort();
    target._sendPort.send({'type': 'close', 'replyPort': response.sendPort});
    try {
      await response.first;
    } finally {
      response.close();
      target._fail(StateError('Read worker exited'));
    }
  }

  void _fail(Object error) {
    _terminalError ??= error;
    for (final pending in _pending.toList()) {
      if (!pending.isCompleted) pending.completeError(error);
    }
  }

  static Future<LibraryReadWorker> start({
    required String databasePath,
    required String storageDirectoryPath,
    bool createBackground = true,
    String? sessionCachePath,
  }) async {
    final cacheFiles = sessionCachePath == null
        ? await BrowseCacheFiles.create(storageDirectoryPath)
        : null;
    final cachePath = sessionCachePath ?? cacheFiles!.path;
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
        worker?._fail(terminalError!);
      }
    });
    exitPort.listen((_) {
      if (!ready.isCompleted) {
        ready.completeError(StateError('Read worker exited during startup'));
      } else {
        terminalError ??= StateError('Read worker isolate exited');
        worker?._fail(terminalError!);
      }
    });
    final isolate = await Isolate.spawn(
      _readWorkerMain,
      <String, Object>{
        'databasePath': databasePath,
        'storageDirectoryPath': storageDirectoryPath,
        'readyPort': readyPort.sendPort,
        'cachePath': cachePath,
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
      await cacheFiles?.close();
      rethrow;
    }
    readyPort.close();
    worker = LibraryReadWorker._(
      sendPort,
      isolate,
      errorPort,
      exitPort,
      terminalError,
      databasePath,
      storageDirectoryPath,
      cachePath,
      cacheFiles,
    );
    if (createBackground) {
      try {
        worker._background = await start(
            databasePath: databasePath,
            storageDirectoryPath: storageDirectoryPath,
            sessionCachePath: cachePath,
            createBackground: false);
      } catch (_) {
        await worker.close();
        rethrow;
      }
    }
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

  @override
  Future<NodeSearchPage> searchNodes(NodeSearchQuery query) async {
    final response = await _request({
      'type': 'nodeSearch',
      'text': query.text,
      'scope': query.scope.name,
      'offset': query.offset,
      'after': query.after == null
          ? null
          : [query.after!.rank, query.after!.name, query.after!.id],
      'limit': query.limit,
    });
    return NodeSearchPage.fromMessage(
        response['page'] as Map<Object?, Object?>);
  }

  @override
  Future<List<RuleDefinition>> listRules() async {
    final response = await _request({'type': 'listRules'});
    return (response['rules'] as List<Object?>)
        .cast<Map<Object?, Object?>>()
        .map(_ruleFromMessage)
        .toList(growable: false);
  }

  @override
  Future<Map<String, RuleSummary>> loadRuleSummaries(
      List<String> ruleIds) async {
    if (ruleIds.length > 8) {
      throw ArgumentError('Rule summary batch exceeds eight');
    }
    final response =
        await _request({'type': 'ruleSummaries', 'ruleIds': ruleIds});
    final counts = (response['counts'] as Map).cast<String, int>();
    final covers = await loadRuleCovers(ruleIds);
    return {
      for (final entry in counts.entries)
        entry.key: RuleSummary(count: entry.value, cover: covers[entry.key])
    };
  }

  @override
  Future<Map<String, EntityListItem>> loadRuleCovers(
      List<String> ruleIds) async {
    final response = await _request({'type': 'ruleCovers', 'ruleIds': ruleIds});
    return (response['covers'] as Map<Object?, Object?>).map((key, value) =>
        MapEntry(
            key as String, _entityFromMap(value as Map<Object?, Object?>)));
  }

  @override
  Future<RuleResultPage> loadRulePage({
    required String ruleNodeId,
    RuleSortMode? sortMode,
    RulePageCursor? after,
    int limit = 60,
  }) async {
    final response = await _request({
      'type': 'rulePage',
      'ruleNodeId': ruleNodeId,
      'sortMode': sortMode?.name,
      'cursorPrimary': after?.primary,
      'cursorSecondary': after?.secondary,
      'cursorEntityId': after?.entityId,
      'consumed': after?.consumed ?? 0,
      'sessionId': after?.sessionId,
      'limit': limit,
    });
    final cursor = response['ruleCursor'] as Map<Object?, Object?>?;
    return RuleResultPage(
      items: (response['entities'] as List<Object?>)
          .cast<Map<Object?, Object?>>()
          .map(_entityFromMap)
          .toList(growable: false),
      hasMore: response['hasMore'] == true,
      cursor: cursor == null
          ? null
          : RulePageCursor(
              primary: cursor['primary']!,
              secondary: cursor['secondary'],
              entityId: cursor['entityId']! as String,
              consumed: cursor['consumed']! as int,
              sessionId: cursor['sessionId'] as String?,
            ),
    );
  }

  @override
  Future<RuleFilterOptions> listRuleFilterOptions({
    List<EntityType> entityTypes = const [],
  }) async {
    final response = await _request({
      'type': 'ruleFilterOptions',
      'entityTypes': entityTypes.map((type) => type.value).toList(),
    });
    final raw = response['extensionsByType'] as Map<Object?, Object?>;
    return RuleFilterOptions(
      extensionsByType: {
        for (final entry in raw.entries)
          EntityType.fromValue(entry.key! as String):
              (entry.value as List<Object?>).cast<String>(),
      },
      scopeNodes: (response['scopeNodes'] as List<Object?>)
          .cast<Map<Object?, Object?>>()
          .map(_nodeFromMap)
          .toList(growable: false),
    );
  }

  Future<LibraryReadPage> loadRecursivePage({
    String? nodeId,
    RecursiveReadScope scope = RecursiveReadScope.node,
    required EntitySortMode sortMode,
    RecursiveEntityPageCursor? after,
    int? limit,
  }) async {
    final message = await _request(<String, Object?>{
      'type': 'recursivePage',
      'scope': scope.name,
      'nodeId': nodeId,
      'sortMode': sortMode.name,
      'hierarchyPath': after?.hierarchyPath,
      'sessionId': after?.sessionId,
      'ordinal': after?.ordinal ?? 0,
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

  Future<void> close() => _closeFuture ??= _closeImpl();

  Future<Map<Object?, Object?>> _request(Map<String, Object?> request) async {
    _ensureOpen();
    final createsSnapshot = request['sessionId'] == null &&
        const {'rulePage', 'recursivePage'}.contains(request['type']);
    if (_background != null &&
        (createsSnapshot ||
            const {
              'ruleSummaries',
              'ruleCovers',
              'ruleFilterOptions',
              'dirtyStatistics'
            }.contains(request['type']))) {
      return _background!._request(request);
    }
    if (_terminalError != null) {
      final next = await _recover();
      return next._requestOnce(request);
    }
    return _requestOnce(request);
  }

  Future<Map<Object?, Object?>> _requestOnce(
      Map<String, Object?> request) async {
    _ensureOpen();
    if (_terminalError != null) throw _terminalError!;
    final response = ReceivePort();
    final pending = Completer<Map<Object?, Object?>>();
    _pending.add(pending);
    final subscription = response.listen((message) {
      if (!pending.isCompleted) {
        pending.complete(message as Map<Object?, Object?>);
      }
    });
    _sendPort.send(<String, Object?>{
      ...request,
      'replyPort': response.sendPort,
    });
    late final Map<Object?, Object?> message;
    try {
      message = await pending.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      _isolate.kill(priority: Isolate.immediate);
      _fail(StateError('Read worker timed out; retry the request'));
      throw StateError('Read worker request timed out');
    } finally {
      _pending.remove(pending);
      await subscription.cancel();
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
    _statisticsTimer?.cancel();
    final wasHealthy = _terminalError == null;
    _fail(StateError('Read worker closed'));
    await _background?.close();
    final restarting = _restarting;
    if (restarting != null) {
      try {
        await restarting;
      } catch (_) {
        // A concurrent restart closes its new worker before rejecting.
      }
    }
    await _replacement?.close();
    if (wasHealthy) {
      final response = ReceivePort();
      _sendPort.send({'type': 'close', 'replyPort': response.sendPort});
      try {
        await response.first.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // A stuck reader must not hold application shutdown open.
      } finally {
        response.close();
      }
    }
    _isolate.kill(priority: Isolate.immediate);
    _errorPort.close();
    _exitPort.close();
    await _cacheFiles?.close();
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
              sessionId: message['sessionId'] as String?,
              ordinal: message['ordinal'] as int? ?? 0,
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
  // The empty main database permits writable cache attachments. The business
  // database is explicitly read-only, including native SQLite enforcement.
  final database = sqlite3.open(':memory:', uri: true);
  late final BrowseSessions sessions;
  try {
    final uri = Uri.file(databasePath).replace(queryParameters: {'mode': 'ro'});
    database.execute('ATTACH DATABASE ? AS library', [uri.toString()]);
    database.execute('PRAGMA library.cache_size = -8192');
    database.execute('PRAGMA busy_timeout = 1000');
    sessions =
        BrowseSessions(database, cachePath: config['cachePath'] as String);
  } catch (_) {
    database.dispose();
    rethrow;
  }
  final cache = QueryCache();
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
      if (request['type'] == 'dirtyStatistics') {
        database.execute('BEGIN');
        try {
          final rows = computeDirtyStatistics(database);
          database.execute('COMMIT');
          replyPort.send({'ok': true, 'rows': rows});
        } catch (_) {
          database.execute('ROLLBACK');
          rethrow;
        }
        return;
      }
      if (request['type'] == 'nodeSearch') {
        final after = request['after'] as List<Object?>?;
        final query = NodeSearchQuery(
          text: request['text'] as String,
          scope: NodeSearchScope.values
              .firstWhere((value) => value.name == request['scope']),
          offset: request['offset'] as int,
          after: after == null
              ? null
              : NodeSearchCursor(
                  after[0] as int, after[1] as String, after[2] as String),
          limit: request['limit'] as int,
        );
        replyPort.send(
            {'ok': true, 'page': queryNodes(database, query).toMessage()});
        return;
      }
      if (request['type'] == 'listRules') {
        replyPort.send({'ok': true, 'rules': _loadRules(database)});
        return;
      }
      if (request['type'] == 'ruleSummaries') {
        cache.synchronize(database);
        final ids = (request['ruleIds'] as List).cast<String>().toSet();
        final rules =
            _loadRules(database, includeCounts: true, ids: ids, cache: cache);
        replyPort.send({
          'ok': true,
          'counts': {
            for (final r in rules) (r['node'] as Map)['id']: r['resultCount']
          }
        });
        return;
      }
      if (request['type'] == 'rulePage') {
        replyPort.send({
          'ok': true,
          ..._loadRulePage(database, storageDirectoryPath, request, sessions),
        });
        return;
      }
      if (request['type'] == 'ruleCovers') {
        cache.synchronize(database);
        final covers = <String, Object?>{};
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final id in (request['ruleIds'] as List).cast<String>().toSet()) {
          final cached = cache.get('cover:$id', now) as Map<String, Object?>?;
          if (cached != null) {
            if (cached['entity'] != null) covers[id] = cached['entity'];
            continue;
          }
          final rules = database
              .select('SELECT * FROM index_rules WHERE node_id = ?', [id]);
          if (rules.isEmpty) continue;
          final rule = rules.single;
          final query = _ruleQuery(rule, now);
          final sort =
              RuleSortMode.values.byName(rule['default_sort'] as String);
          final rows = database.select('''
            SELECT * FROM (
              SELECT e.* FROM entity_details e WHERE ${query.whereSql}
              ORDER BY ${_ruleOrderBy(sort)} LIMIT ?
            ) WHERE media_type IN ('image', 'video')
            ORDER BY source_modified_at_ms DESC, id ASC LIMIT 1
          ''', [...query.parameters, rule['max_results']]);
          if (rows.isNotEmpty) {
            covers[id] = _entityToMap(rows.single, storageDirectoryPath);
          }
          cache.put('cover:$id', {'entity': covers[id]},
              expiresAt: _ruleExpiry(database, rule, query));
        }
        replyPort.send({'ok': true, 'covers': covers});
        return;
      }
      if (request['type'] == 'ruleFilterOptions') {
        replyPort.send({
          'ok': true,
          ..._loadRuleFilterOptions(database, request),
        });
        return;
      }
      final page = switch (request['type']) {
        'directPage' =>
          _loadDirectPage(database, storageDirectoryPath, request),
        'recursivePage' =>
          _loadRecursivePage(database, storageDirectoryPath, request, sessions),
        'indexRoots' => _loadIndexRoots(database, request),
        'nodePath' => _loadNodePath(database, request),
        'nodeSummaries' => _loadNodeSummaries(database, request),
        'rootEntityCounts' => _loadRootEntityCounts(database, request),
        'nodePreviews' =>
          _loadNodePreviews(database, storageDirectoryPath, request),
        'entity' => _loadEntity(database, storageDirectoryPath, request),
        _ => throw ArgumentError.value(
            request['type'], 'type', 'Unknown read request'),
      };
      replyPort.send(<String, Object?>{
        'ok': true,
        'childNodes': page.childNodes,
        'entities': page.entities,
        'hasMore': page.hasMore,
        'recursiveHierarchyPath': page.recursiveHierarchyPath,
        'sessionId': page.sessionId,
        'ordinal': page.ordinal,
        'cursorPrimary': page.cursorPrimary,
        'cursorSecondary': page.cursorSecondary,
        'cursorEntityId': page.cursorEntityId,
        'cursorSortMode': page.cursorSortMode,
        'nodes': page.nodes ?? page.childNodes,
        'summaries': page.summaries,
        'counts': page.counts,
        'previews': page.previews,
        'entity': page.entity,
      });
    } catch (error) {
      replyPort.send(<String, Object?>{'ok': false, 'error': '$error'});
    }
  });
}

List<Map<String, Object?>> _loadRules(Database database,
    {bool includeCounts = false, Set<String>? ids, QueryCache? cache}) {
  final rows = database.select('''
    SELECT node.*, rule.entity_types_json, rule.extensions_json,
           rule.scope_node_id, rule.scope_state, rule.min_size, rule.max_size,
           rule.modified_within_days, rule.opened_within_days,
           rule.default_sort, rule.max_results, rule.built_in_kind,
           rule.updated_at AS rule_updated_at
    FROM index_rules rule
    JOIN index_nodes node ON node.id = rule.node_id
    WHERE node.node_type = 'rule'
    ORDER BY CASE WHEN rule.built_in_kind IS NULL THEN 1 ELSE 0 END,
             node.sort_order, node.name COLLATE NOCASE, node.id
  ''');
  return rows.where((row) => ids == null || ids.contains(row['id'])).map((row) {
    if (!includeCounts) return _ruleToMessage(row, null);
    final key = 'count:${row['id']}';
    final cached =
        cache?.get(key, DateTime.now().millisecondsSinceEpoch) as int?;
    if (cached != null) return _ruleToMessage(row, cached);
    final query = _ruleQuery(row, DateTime.now().millisecondsSinceEpoch);
    final count = database.select(
      'SELECT COUNT(*) AS count FROM (SELECT 1 FROM entities e WHERE ${query.whereSql} LIMIT ?)',
      [...query.parameters, row['max_results']],
    ).single['count'] as int;
    cache?.put(key, count, expiresAt: _ruleExpiry(database, row, query));
    return _ruleToMessage(row, count.clamp(0, row['max_results'] as int));
  }).toList(growable: false);
}

int? _ruleExpiry(Database database, Row rule, _RuleQueryParts query) {
  final terms = <String>[];
  final modifiedDays = rule['modified_within_days'] as int?;
  final openedDays = rule['opened_within_days'] as int?;
  if (modifiedDays != null) {
    terms.add(
        'MIN(e.source_modified_at_ms) + ${modifiedDays * Duration.millisecondsPerDay + 1}');
  }
  if (openedDays != null) {
    terms.add(
        'MIN(e.last_opened_at) + ${openedDays * Duration.millisecondsPerDay + 1}');
  }
  if (terms.isEmpty) return null;
  final expression =
      terms.length == 1 ? terms.single : 'MIN(${terms.join(',')})';
  return database
      .select(
          'SELECT $expression AS expiry FROM entities e WHERE ${query.whereSql}',
          query.parameters)
      .single['expiry'] as int?;
}

Map<String, Object?> _loadRulePage(
  Database database,
  String storageDirectoryPath,
  Map<Object?, Object?> request,
  BrowseSessions sessions,
) {
  final rows = database.select('''
    SELECT node.*, rule.entity_types_json, rule.extensions_json,
           rule.scope_node_id, rule.scope_state, rule.min_size, rule.max_size,
           rule.modified_within_days, rule.opened_within_days,
           rule.default_sort, rule.max_results, rule.built_in_kind,
           rule.updated_at AS rule_updated_at
    FROM index_rules rule
    JOIN index_nodes node ON node.id = rule.node_id
    WHERE node.id = ? AND node.node_type = 'rule'
    LIMIT 1
  ''', [request['ruleNodeId']]);
  if (rows.isEmpty) {
    throw ArgumentError.value(request['ruleNodeId'], 'ruleNodeId');
  }
  final rule = rows.single;
  final builtIn = rule['built_in_kind'] as String?;
  final requestedSort = request['sortMode'] as String?;
  final sort = builtIn == null && requestedSort != null
      ? RuleSortMode.values.byName(requestedSort)
      : RuleSortMode.values.byName(rule['default_sort'] as String);
  final consumed = request['consumed'] as int? ?? 0;
  final maxResults = rule['max_results'] as int;
  final limit = (request['limit'] as int? ?? 60).clamp(1, 60);
  if (rule['scope_state'] == 'missing') {
    return const {
      'entities': <Object?>[],
      'hasMore': false,
      'ruleCursor': null
    };
  }
  final scope = 'rule:${request['ruleNodeId']}:${sort.name}';
  var sessionId = request['sessionId'] as String?;
  if (sessionId == null) {
    if (consumed != 0) throw StateError('浏览会话已失效，请刷新');
    final query = _ruleQuery(rule, DateTime.now().millisecondsSinceEpoch);
    sessionId = sessions.create(scope, '''SELECT e.id FROM entities e
      WHERE ${query.whereSql} ORDER BY ${_ruleOrderBy(sort)} LIMIT ?''',
        [...query.parameters, maxResults]);
  }
  sessions.validate(sessionId, scope);
  final entityRows = sessions.page(sessionId, consumed, limit);
  final hasMore = entityRows.length > limit;
  final visible = entityRows.take(limit).toList(growable: false);
  final last = visible.isEmpty ? null : visible.last;
  return {
    'entities': visible
        .map((row) => _entityToMap(row, storageDirectoryPath))
        .toList(growable: false),
    'hasMore': hasMore,
    'ruleCursor': last == null
        ? null
        : {
            ..._ruleCursorValues(last, sort),
            'entityId': last['id'],
            'consumed': last['session_ordinal'],
            'sessionId': sessionId,
          },
  };
}

Map<String, Object?> _loadRuleFilterOptions(
  Database database,
  Map<Object?, Object?> request,
) {
  final selected = (request['entityTypes'] as List<Object?>).cast<String>();
  final parameters = <Object?>[];
  final typeFilter = selected.isEmpty
      ? ''
      : 'AND media_type IN (${List.filled(selected.length, '?').join(',')})';
  parameters.addAll(selected);
  final rows = database.select('''
    SELECT media_type, lower(format) AS extension
    FROM entity_details
    WHERE archived = 0 AND format <> '' $typeFilter
    GROUP BY media_type, lower(format)
    ORDER BY media_type, extension
  ''', parameters);
  final extensions = <String, List<String>>{};
  for (final row in rows) {
    extensions
        .putIfAbsent(row['media_type'] as String, () => <String>[])
        .add(row['extension'] as String);
  }
  final scopes = database.select('''
    SELECT * FROM index_nodes
    WHERE is_staging = 0
      AND node_type IN ('directory_index_root', 'folder',
                        'category_index_root', 'category')
    ORDER BY CASE system_key WHEN 'favorites' THEN 0 ELSE 1 END,
             name COLLATE NOCASE, id
  ''');
  return {
    'extensionsByType': extensions,
    'scopeNodes': scopes.map(_nodeToMap).toList(growable: false),
  };
}

class _RuleQueryParts {
  const _RuleQueryParts(this.whereSql, this.parameters);
  final String whereSql;
  final List<Object?> parameters;
}

_RuleQueryParts _ruleQuery(Row rule, int nowMs) {
  final clauses = <String>['e.archived = 0'];
  if (rule['scope_state'] == 'missing') clauses.add('0');
  final parameters = <Object?>[];
  final builtIn = rule['built_in_kind'] as String?;
  if (builtIn == BuiltInRuleKind.frequent.name) {
    clauses.add('e.open_count > 0');
  } else if (builtIn != null) {
    clauses.add('e.last_opened_at IS NOT NULL');
  }
  final types =
      (jsonDecode(rule['entity_types_json'] as String) as List).cast<String>();
  if (types.isNotEmpty) {
    clauses
        .add('e.media_type IN (${List.filled(types.length, '?').join(',')})');
    parameters.addAll(types);
  }
  final extensions =
      (jsonDecode(rule['extensions_json'] as String) as List).cast<String>();
  if (extensions.isNotEmpty) {
    clauses.add(
        'lower(e.format) IN (${List.filled(extensions.length, '?').join(',')})');
    parameters.addAll(extensions);
  }
  final scopeNodeId = rule['scope_node_id'] as String?;
  if (scopeNodeId != null) {
    clauses.add('''e.id IN (
      WITH RECURSIVE subtree(id) AS (
        SELECT ? UNION ALL
        SELECT node.id FROM index_nodes node JOIN subtree parent
          ON node.parent_id = parent.id
      )
      SELECT link.entity_id FROM index_node_entities link
      WHERE link.index_node_id IN (SELECT id FROM subtree)
    )''');
    parameters.add(scopeNodeId);
  }
  final minSize = rule['min_size'] as int?;
  final maxSize = rule['max_size'] as int?;
  if (minSize != null) {
    clauses.add('e.size >= ?');
    parameters.add(minSize);
  }
  if (maxSize != null) {
    clauses.add('e.size <= ?');
    parameters.add(maxSize);
  }
  final modifiedDays = rule['modified_within_days'] as int?;
  if (modifiedDays != null) {
    clauses.add('e.source_modified_at_ms >= ?');
    parameters.add(nowMs - modifiedDays * Duration.millisecondsPerDay);
  }
  final openedDays = rule['opened_within_days'] as int?;
  if (openedDays != null) {
    clauses.add('e.last_opened_at IS NOT NULL AND e.last_opened_at >= ?');
    parameters.add(nowMs - openedDays * Duration.millisecondsPerDay);
  }
  return _RuleQueryParts(clauses.join(' AND '), parameters);
}

String _ruleOrderBy(RuleSortMode sort) => switch (sort) {
      RuleSortMode.lastOpened => 'COALESCE(e.last_opened_at, 0) DESC, e.id ASC',
      RuleSortMode.openCount =>
        'e.open_count DESC, COALESCE(e.last_opened_at, 0) DESC, e.id ASC',
      RuleSortMode.modified => 'e.source_modified_at_ms DESC, e.id ASC',
      RuleSortMode.name => 'e.name COLLATE NOCASE ASC, e.id ASC',
      RuleSortMode.size => 'e.size DESC, e.id ASC',
    };

Map<String, Object?> _ruleCursorValues(Row row, RuleSortMode sort) =>
    switch (sort) {
      RuleSortMode.lastOpened => {
          'primary': row['last_opened_at'] as int? ?? 0,
          'secondary': null,
        },
      RuleSortMode.openCount => {
          'primary': row['open_count'] as int,
          'secondary': row['last_opened_at'] as int? ?? 0,
        },
      RuleSortMode.modified => {
          'primary': row['source_modified_at_ms'] as int,
          'secondary': null,
        },
      RuleSortMode.name => {
          'primary': row['name'] as String,
          'secondary': null,
        },
      RuleSortMode.size => {
          'primary': row['size'] as int,
          'secondary': null,
        },
    };

Map<String, Object?> _ruleToMessage(Row row, int? resultCount) => {
      'node': _nodeToMap(row),
      'entityTypes': (jsonDecode(row['entity_types_json'] as String) as List),
      'extensions': (jsonDecode(row['extensions_json'] as String) as List),
      'scopeNodeId': row['scope_node_id'],
      'scopeMissing': row['scope_state'] == 'missing',
      'minSize': row['min_size'],
      'maxSize': row['max_size'],
      'modifiedWithinDays': row['modified_within_days'],
      'openedWithinDays': row['opened_within_days'],
      'defaultSort': row['default_sort'],
      'maxResults': row['max_results'],
      'builtInKind': row['built_in_kind'],
      'updatedAtMs': row['rule_updated_at'],
      'resultCount': resultCount,
    };

RuleDefinition _ruleFromMessage(Map<Object?, Object?> map) {
  final builtIn = map['builtInKind'] as String?;
  return RuleDefinition(
    node: _nodeFromMap(map['node'] as Map<Object?, Object?>),
    entityTypes: (map['entityTypes'] as List<Object?>)
        .cast<String>()
        .map(EntityType.fromValue)
        .toList(growable: false),
    extensions: (map['extensions'] as List<Object?>).cast<String>(),
    scopeNodeId: map['scopeNodeId'] as String?,
    scopeMissing: map['scopeMissing'] == true,
    minSize: map['minSize'] as int?,
    maxSize: map['maxSize'] as int?,
    modifiedWithinDays: map['modifiedWithinDays'] as int?,
    openedWithinDays: map['openedWithinDays'] as int?,
    defaultSort: RuleSortMode.values.byName(map['defaultSort'] as String),
    maxResults: map['maxResults'] as int,
    builtInKind:
        builtIn == null ? null : BuiltInRuleKind.values.byName(builtIn),
    resultCount: map['resultCount'] as int?,
    updatedAtMs: map['updatedAtMs'] as int,
  );
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
    ORDER BY CASE node.system_key WHEN 'favorites' THEN 0 ELSE 1 END,
             ${_nodeOrderBy(sortName)}
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
    JOIN entity_details entity ON entity.id = link.entity_id
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
    ORDER BY CASE node.system_key WHEN 'favorites' THEN 0 ELSE 1 END,
             ${_nodeOrderBy(sortName)}
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
    'SELECT * FROM entity_details WHERE id = ? LIMIT 1',
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

_RawReadPage _loadRecursivePage(
  Database database,
  String storageDirectoryPath,
  Map<Object?, Object?> request,
  BrowseSessions sessions,
) {
  final scope = request['scope'] as String? ?? 'node';
  final nodeId = request['nodeId'] as String?;
  if (scope == 'node' && nodeId == null) {
    throw ArgumentError('Node scope requires nodeId');
  }
  final seed = switch (scope) {
    'node' => 'id = ?',
    'directoryHome' => "node_type = 'directory_index_root'",
    'collectionHome' => "node_type = 'category_index_root'",
    _ => throw ArgumentError('Invalid recursive scope'),
  };
  final sortName = request['sortMode']! as String;
  final limit = (request['limit'] as int? ?? 60).clamp(1, 60);
  final parameters = <Object>[
    if (scope == 'node') nodeId!,
  ];
  if (scope == 'node' &&
      database
          .select('SELECT 1 FROM index_nodes WHERE id=?', [nodeId]).isEmpty) {
    throw StateError('浏览目录已删除');
  }
  final sessionScope = 'recursive:$scope:$nodeId:$sortName';
  var sessionId = request['sessionId'] as String?;
  sessionId ??= sessions.create(
    sessionScope,
    '''
    WITH RECURSIVE subtree(id, hierarchy_path) AS (
      SELECT id,
             printf('%010d', sort_order) || char(31) ||
             lower(name) || char(31) || id
      FROM index_nodes
      WHERE ($seed) AND is_staging = 0
      UNION ALL
      SELECT node.id,
             parent.hierarchy_path || char(30) ||
             printf('%010d', node.sort_order) || char(31) ||
             lower(node.name) || char(31) || node.id
      FROM index_nodes node
      JOIN subtree parent ON node.parent_id = parent.id
      WHERE node.is_staging = 0
    ), entity_nodes AS (
      SELECT link.entity_id, MIN(subtree.hierarchy_path) AS hierarchy_path
      FROM index_node_entities link
      JOIN subtree ON subtree.id = link.index_node_id
      GROUP BY link.entity_id
    )
    SELECT entity.id
    FROM entity_nodes
    JOIN entities entity ON entity.id = entity_nodes.entity_id
    WHERE entity.archived = 0
    ORDER BY entity_nodes.hierarchy_path ASC, ${_orderBy(sortName)}
    ''',
    parameters,
  );
  sessions.validate(sessionId, sessionScope);
  final rows = sessions.page(sessionId, request['ordinal'] as int? ?? 0, limit);
  final hasMore = rows.length > limit;
  final visibleRows = hasMore ? rows.sublist(0, limit) : rows;
  final last = visibleRows.isEmpty ? null : visibleRows.last;
  final cursorValues = last == null ? null : _cursorValues(last, sortName);
  return _RawReadPage(
    childNodes: const [],
    entities: visibleRows
        .map((row) => _entityToMap(row, storageDirectoryPath))
        .toList(growable: false),
    hasMore: hasMore,
    recursiveHierarchyPath: last == null ? null : '',
    sessionId: sessionId,
    ordinal: last?['session_ordinal'] as int? ?? 0,
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
    this.sessionId,
    this.ordinal = 0,
    this.cursorPrimary,
    this.cursorSecondary,
    this.cursorEntityId,
    this.cursorSortMode,
    this.summaries = const [],
    this.counts = const [],
    this.entity,
    this.previews = const [],
  });

  final List<Map<String, Object?>> childNodes;
  final List<Map<String, Object?>> entities;
  final bool hasMore;
  final List<Map<String, Object?>>? nodes;
  final String? recursiveHierarchyPath;
  final String? sessionId;
  final int ordinal;
  final Object? cursorPrimary;
  final Object? cursorSecondary;
  final String? cursorEntityId;
  final String? cursorSortMode;
  final List<Map<String, Object?>> summaries;
  final List<Map<String, Object?>> counts;
  final Map<String, Object?>? entity;
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
      'viewType': 'tree',
      'sourcePath': row['source_path'],
      'sortOrder': row['sort_order'],
      'createdAtMs': row['created_at'],
      'updatedAtMs': row['updated_at'],
      'lastBuiltAtMs': row['last_built_at_ms'],
      'systemKey': row['system_key'],
      'isProtected': row['is_protected'],
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
    'openCount': row['open_count'],
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
      systemKey: map['systemKey'] as String?,
      isProtected: map['isProtected'] == 1 || map['isProtected'] == true,
    );

EntityListItem _entityFromMap(Map<Object?, Object?> map) => EntityListItem(
      sourceRevision: map['sourceRevision'] as int? ?? 1,
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
      openCount: map['openCount'] as int? ?? 0,
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
      openCount: map['openCount'] as int? ?? 0,
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
