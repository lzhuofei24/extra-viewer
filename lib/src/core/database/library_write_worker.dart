import 'dart:async';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

/// Owns the application's write connection.
///
/// SQLite allows many readers in WAL mode, but writes still execute on the
/// calling isolate. Keeping one connection in a dedicated isolate gives the
/// application a single write order and prevents progress, playback, and
/// cache bookkeeping from competing with Flutter frames.
class LibraryWriteWorker {
  LibraryWriteWorker._(this._sendPort, this._isolate);

  final SendPort _sendPort;
  final Isolate _isolate;
  Future<void>? _closeFuture;
  int _requestId = 0;

  static Future<LibraryWriteWorker> start(
      {required String databasePath}) async {
    final readyPort = ReceivePort();
    final isolate = await Isolate.spawn(
      _writeWorkerMain,
      <String, Object>{
        'databasePath': databasePath,
        'readyPort': readyPort.sendPort,
      },
    );
    final sendPort = (await readyPort.first) as SendPort;
    readyPort.close();
    return LibraryWriteWorker._(sendPort, isolate);
  }

  /// Executes one write statement and waits for its commit.
  Future<LibraryWriteResult> execute(
    String sql, [
    List<Object?> parameters = const <Object?>[],
  ]) {
    return _request(<String, Object?>{
      'type': 'execute',
      'sql': sql,
      'parameters': parameters,
    });
  }

  /// Executes a bounded group atomically. The worker never accepts an
  /// arbitrary callback because closures cannot cross isolate boundaries.
  Future<LibraryWriteResult> executeBatch(
    Iterable<LibraryWriteStatement> statements,
  ) {
    final batch = statements.toList(growable: false);
    if (batch.isEmpty) {
      return Future<LibraryWriteResult>.value(const LibraryWriteResult());
    }
    return _request(<String, Object?>{
      'type': 'batch',
      'statements': batch.map((statement) => statement.toMessage()).toList(),
    });
  }

  /// Completes after every request sent before this barrier has committed.
  Future<void> flush() async {
    await _request(<String, Object?>{'type': 'barrier'});
  }

  Future<LibraryWriteResult> _request(Map<String, Object?> request) async {
    _ensureOpen();
    final response = ReceivePort();
    final requestWithReply = <String, Object?>{
      ...request,
      'requestId': _requestId++,
      'replyPort': response.sendPort,
    };
    _sendPort.send(requestWithReply);
    try {
      final message = (await response.first) as Map<Object?, Object?>;
      if (message['ok'] != true) {
        throw StateError(message['error'] as String? ?? 'SQLite write failed');
      }
      return LibraryWriteResult(
        changes: (message['changes'] as int?) ?? 0,
      );
    } finally {
      response.close();
    }
  }

  Future<void> close() => _closeFuture ??= _closeImpl();

  Future<void> _closeImpl() async {
    final response = ReceivePort();
    _sendPort.send(<String, Object?>{
      'type': 'close',
      'replyPort': response.sendPort,
    });
    try {
      await response.first.timeout(const Duration(seconds: 5));
    } finally {
      response.close();
      _isolate.kill(priority: Isolate.beforeNextEvent);
    }
  }

  void _ensureOpen() {
    if (_closeFuture != null) {
      throw StateError('Library write worker is closed');
    }
  }
}

class LibraryWriteStatement {
  const LibraryWriteStatement(this.sql, [this.parameters = const <Object?>[]]);

  final String sql;
  final List<Object?> parameters;

  Map<String, Object?> toMessage() => <String, Object?>{
        'sql': sql,
        'parameters': parameters,
      };
}

class LibraryWriteResult {
  const LibraryWriteResult({this.changes = 0});

  final int changes;
}

void _writeWorkerMain(Map<String, Object> config) {
  final databasePath = config['databasePath']! as String;
  final readyPort = config['readyPort']! as SendPort;
  final database = sqlite3.open(databasePath);
  database.execute('PRAGMA foreign_keys = ON;');
  database.execute('PRAGMA journal_mode = WAL;');
  database.execute('PRAGMA busy_timeout = 5000;');
  database.execute('PRAGMA synchronous = NORMAL;');

  final requestPort = ReceivePort();
  readyPort.send(requestPort.sendPort);
  requestPort.listen((message) {
    final request = message as Map<Object?, Object?>;
    final replyPort = request['replyPort'] as SendPort?;
    if (request['type'] == 'close') {
      try {
        database.select('PRAGMA wal_checkpoint(PASSIVE)');
      } finally {
        database.dispose();
        requestPort.close();
        replyPort?.send(true);
      }
      return;
    }
    if (replyPort == null) return;
    try {
      final changes = switch (request['type']) {
        'execute' => _executeStatement(
            database,
            request['sql']! as String,
            (request['parameters'] as List<Object?>?) ?? const <Object?>[],
          ),
        'batch' => _executeBatch(
            database,
            (request['statements'] as List<Object?>?) ?? const <Object?>[],
          ),
        'barrier' => 0,
        _ => throw ArgumentError.value(
            request['type'], 'type', 'Unknown write request'),
      };
      replyPort.send(<String, Object?>{'ok': true, 'changes': changes});
    } catch (error, stackTrace) {
      replyPort.send(<String, Object?>{
        'ok': false,
        'error': '$error\n$stackTrace',
      });
    }
  });
}

int _executeStatement(
  Database database,
  String sql,
  List<Object?> parameters,
) {
  database.execute(sql, parameters);
  return _changes(database);
}

int _executeBatch(
  Database database,
  List<Object?> rawStatements,
) {
  database.execute('BEGIN IMMEDIATE;');
  try {
    var changes = 0;
    for (final raw in rawStatements) {
      final statement = (raw as Map<Object?, Object?>);
      changes += _executeStatement(
        database,
        statement['sql']! as String,
        (statement['parameters'] as List<Object?>?) ?? const <Object?>[],
      );
    }
    database.execute('COMMIT;');
    return changes;
  } catch (_) {
    database.execute('ROLLBACK;');
    rethrow;
  }
}

int _changes(Database database) {
  final rows = database.select('SELECT changes() AS changes');
  return rows.isEmpty ? 0 : rows.first['changes'] as int;
}
