import 'dart:async';
import 'dart:isolate';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import '../../core/database/app_database.dart';
import '../../core/database/library_repository.dart';
import '../../core/database/library_build_repository.dart';
import '../library/library_dispatch.dart';
import '../build/build_dispatch.dart';

class DatabaseHost {
  DatabaseHost._(this.databasePath);
  final String databasePath;
  String get storageDirectoryPath => p.dirname(databasePath);
  final _messages = ReceivePort();
  final _errors = ReceivePort();
  final _exits = ReceivePort();
  final _ready = Completer<void>();
  final _exited = Completer<void>();
  final _pending = <String, Completer<Object?>>{};
  late Isolate _isolate;
  SendPort? _port;
  Object? _failure;
  Future<void>? _closing;
  int _sequence = 0;
  final String _session = DateTime.now().microsecondsSinceEpoch.toString();

  static Future<DatabaseHost> start({required String databasePath}) async {
    final host = DatabaseHost._(databasePath);
    host._messages.listen((message) {
      if (message is SendPort) {
        host._port = message;
        if (!host._ready.isCompleted) host._ready.complete();
        return;
      }
      final result = message as Map<Object?, Object?>;
      if (result.containsKey('startupError')) {
        host._fail(result['startupError']!);
        return;
      }
      final pending = host._pending.remove(result['id']);
      if (pending == null) return;
      if (result['ok'] == true) {
        pending.complete(result['value']);
      } else {
        pending.completeError(StateError(result['error'] as String));
      }
    });
    host._errors.listen(
        (error) => host._fail(StateError('Database worker failed: $error')));
    host._exits.listen((_) {
      if (!host._exited.isCompleted) host._exited.complete();
      if (host._closing == null) {
        host._fail(StateError('Database worker exited'));
      }
    });
    host._isolate = await Isolate.spawn(
        _runDatabase, (path: databasePath, reply: host._messages.sendPort),
        onError: host._errors.sendPort, onExit: host._exits.sendPort);
    try {
      await host._ready.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      host._disposePorts();
      host._isolate.kill();
      rethrow;
    }
    return host;
  }

  void _fail(Object error) {
    _failure ??= error;
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
  }

  Future<Object?> call(
          String domain, String method, Map<String, Object?> args) =>
      _request({'domain': domain, 'method': method, 'args': args});

  Future<Object?> _request(Map<String, Object?> message,
      {bool closing = false}) async {
    if (_failure != null) throw StateError('Database unavailable: $_failure');
    if (_closing != null && !closing) throw StateError('Database is closing');
    final id = '$_session:${_sequence++}';
    final result = Completer<Object?>();
    _pending[id] = result;
    try {
      _port!.send({...message, 'id': id});
      return await result.future.timeout(const Duration(minutes: 2),
          onTimeout: () {
        throw TimeoutException(
            'Database request $id outcome unknown; inspect receipt before retry');
      });
    } finally {
      _pending.remove(id);
    }
  }

  Future<LibraryWriteResult> execute(String sql,
          [List<Object?> parameters = const []]) =>
      executeBatch([LibraryWriteStatement(sql, parameters)]);
  Future<LibraryWriteResult> executeBatch(
      Iterable<LibraryWriteStatement> statements) async {
    final value = await _request(
        {'domain': 'sql', 'statements': statements.toList(growable: false)});
    return LibraryWriteResult(changes: value as int);
  }

  Future<void> flush() async {
    await _request({'domain': 'barrier'});
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    try {
      if (_failure == null) await _request({'domain': 'close'}, closing: true);
      await _exited.future.timeout(const Duration(seconds: 10));
    } finally {
      _fail(StateError('Database closed'));
      _isolate.kill(priority: Isolate.beforeNextEvent);
      _disposePorts();
    }
  }

  void _disposePorts() {
    _messages.close();
    _errors.close();
    _exits.close();
  }
}

class LibraryWriteStatement {
  const LibraryWriteStatement(this.sql, [this.parameters = const []]);
  final String sql;
  final List<Object?> parameters;
}

class LibraryWriteResult {
  const LibraryWriteResult({this.changes = 0});
  final int changes;
}

Future<void> _runDatabase(({String path, SendPort reply}) config) async {
  final AppDatabase app;
  try {
    app = AppDatabase.openAtPath(config.path);
  } catch (error) {
    config.reply.send({'startupError': error});
    return;
  }
  final repository = LibraryRepository(app);
  final builds = LibraryBuildRepository(repository);
  final input = ReceivePort();
  config.reply.send(input.sendPort);
  try {
    await for (final raw in input) {
      final request = raw as Map<Object?, Object?>;
      final domain = request['domain'];
      final id = request['id']! as String;
      try {
        if (domain == 'close') {
          app.checkpointWriteAheadLog();
          app.close();
          config.reply.send({'id': id, 'ok': true, 'value': null});
          break;
        }
        final args = (request['args'] as Map<String, Object?>?) ??
            const <String, Object?>{};
        final value = switch (domain) {
          'library' => await dispatchLibrary(
              repository, request['method']! as String, args),
          'build' =>
            await dispatchBuild(builds, request['method']! as String, args),
          'sql' => _batch(app.db, id,
              (request['statements'] as List).cast<LibraryWriteStatement>()),
          'barrier' => null,
          _ => throw ArgumentError('Unknown database domain $domain'),
        };
        config.reply.send({'id': id, 'ok': true, 'value': value});
      } catch (error, stack) {
        config.reply.send({'id': id, 'ok': false, 'error': '$error\n$stack'});
      }
    }
  } finally {
    input.close();
    app.close();
  }
}

int _batch(
    Database db, String requestId, List<LibraryWriteStatement> statements) {
  final previous = db.select(
      'SELECT changes FROM database_command_receipts WHERE request_id = ?',
      [requestId]);
  if (previous.isNotEmpty) return previous.single['changes'] as int;
  final prepared = <String, PreparedStatement>{};
  db.execute('BEGIN IMMEDIATE');
  try {
    var changes = 0;
    for (final item in statements) {
      final statement =
          prepared.putIfAbsent(item.sql, () => db.prepare(item.sql));
      statement.execute(item.parameters);
      changes += db.updatedRows;
    }
    db.execute('INSERT INTO database_command_receipts VALUES (?, ?, ?)',
        [requestId, changes, DateTime.now().millisecondsSinceEpoch]);
    db.execute('COMMIT');
    return changes;
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    for (final statement in prepared.values) {
      statement.dispose();
    }
  }
}
