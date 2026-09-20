import 'dart:async';
import 'dart:isolate';
import 'dart:convert';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import '../../core/database/app_database.dart';
import '../../core/database/schema_v10.dart';
import '../../core/database/local_statistics.dart';
import '../../core/database/statement_cache.dart';
import '../../core/database/library_repository.dart';
import '../../core/database/library_build_repository.dart';
import '../library/library_dispatch.dart';
import '../build/build_dispatch.dart';
import 'database_operations.dart';

enum DatabaseCommandOutcome { committed, notCommitted, unknown }

class DatabaseCommandException extends StateError {
  DatabaseCommandException(this.commandId, this.outcome, String message)
      : super('$message (command=$commandId, outcome=${outcome.name})');
  final String commandId;
  final DatabaseCommandOutcome outcome;
}

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
        pending.completeError(result['committedCommand'] is String
            ? DatabaseCommandException(
                result['committedCommand'] as String,
                DatabaseCommandOutcome.committed,
                'Command already committed; refresh state')
            : StateError(result['error'] as String));
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

  static String newCommandId() {
    final random = Random.secure();
    final nonce =
        base64Url.encode(List.generate(16, (_) => random.nextInt(256)));
    return '${DateTime.now().millisecondsSinceEpoch}:$nonce';
  }

  Future<DatabaseCommandOutcome> commandOutcome(String commandId) async {
    final committed =
        await _request({'domain': 'receipt', 'commandId': commandId});
    return switch (committed) {
      true => DatabaseCommandOutcome.committed,
      false => DatabaseCommandOutcome.notCommitted,
      _ => DatabaseCommandOutcome.unknown,
    };
  }

  Future<Object?> call(String domain, String method, Map<String, Object?> args,
      {String? commandId}) async {
    final command = !isDatabaseQuery(domain, method) &&
        !isDatabaseMaintenance(domain, method);
    final ticket = command ? commandId ?? newCommandId() : null;
    return _requestWithOutcome({
      'domain': domain,
      'method': method,
      'args': args,
      if (ticket != null) 'commandId': ticket,
    }, ticket);
  }

  Future<Object?> _requestWithOutcome(
      Map<String, Object?> message, String? commandId) async {
    try {
      return await _request(message);
    } on DatabaseCommandException {
      rethrow;
    } catch (error) {
      if (commandId == null) rethrow;
      var outcome = DatabaseCommandOutcome.unknown;
      try {
        // The worker is serial: this query runs after the original command.
        // A missing receipt therefore means that transaction did not commit.
        outcome = await commandOutcome(commandId);
      } catch (_) {
        // Keep an explicit unknown outcome when the worker is unavailable.
      }
      throw DatabaseCommandException(commandId, outcome, '$error');
    }
  }

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
      Iterable<LibraryWriteStatement> statements,
      {String? commandId}) async {
    final ticket = commandId ?? newCommandId();
    final value = await _requestWithOutcome({
      'domain': 'sql',
      'commandId': ticket,
      'statements': statements.toList(growable: false)
    }, ticket);
    return LibraryWriteResult(changes: value as int);
  }

  Future<void> flush() async {
    await _request({'domain': 'barrier'});
  }

  Future<void> enableBackgroundStatistics() async {
    await _request({'domain': 'statisticsEnable'});
  }

  Future<void> publishStatisticsBatch(List<Map<String, Object?>> rows) async {
    await _request({'domain': 'statisticsPublish', 'rows': rows});
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
  final statements = StatementCache(app.db);
  final builds = LibraryBuildRepository(repository);
  final input = ReceivePort();
  config.reply.send(input.sendPort);
  try {
    await for (final raw in input) {
      final request = raw as Map<Object?, Object?>;
      final domain = request['domain'];
      final id = request['id']! as String;
      try {
        if (domain == 'statisticsEnable') {
          installStatisticsGeneration(app.db);
          repository.deferStatistics = true;
          config.reply.send({'id': id, 'ok': true, 'value': null});
          continue;
        }
        if (domain == 'statisticsPublish') {
          final rows = (request['rows'] as List).cast<Map<String, Object?>>();
          if (rows.length > 32) {
            throw ArgumentError('Statistics batch exceeds 32');
          }
          repository.writeTransaction(() => publishStatistics(app.db, rows));
          config.reply.send({'id': id, 'ok': true, 'value': null});
          continue;
        }
        if (domain == 'close') {
          statements.dispose();
          app.checkpointWriteAheadLog();
          app.close();
          config.reply.send({'id': id, 'ok': true, 'value': null});
          break;
        }
        final args = (request['args'] as Map<String, Object?>?) ??
            const <String, Object?>{};
        final method = request['method'] as String? ?? '';
        Future<Object?> dispatch() async => switch (domain) {
              'library' => await dispatchLibrary(repository, method, args),
              'build' => await dispatchBuild(builds, method, args),
              'sql' => _batch(
                  statements,
                  (request['statements'] as List)
                      .cast<LibraryWriteStatement>()),
              'receipt' => _receipt(app.db, request['commandId']! as String),
              'barrier' => null,
              _ => throw ArgumentError('Unknown database domain $domain'),
            };
        final transactional = domain == 'sql' ||
            ((domain == 'library' || domain == 'build') &&
                !isDatabaseQuery(domain as String, method) &&
                !isDatabaseMaintenance(domain, method));
        final value = transactional
            ? await _command(app.db, request['commandId']! as String, dispatch)
            : await dispatch();
        config.reply.send({'id': id, 'ok': true, 'value': value});
      } catch (error, stack) {
        config.reply.send({
          'id': id,
          'ok': false,
          'error': '$error\n$stack',
          if (error is DatabaseCommandException &&
              error.outcome == DatabaseCommandOutcome.committed)
            'committedCommand': error.commandId,
        });
      }
    }
  } finally {
    statements.dispose();
    input.close();
    app.close();
  }
}

bool? _receipt(Database db, String commandId) {
  if (db.select('SELECT 1 FROM database_command_receipts WHERE request_id = ?',
      [commandId]).isNotEmpty) {
    return true;
  }
  final issuedAt = int.tryParse(commandId.split(':').first);
  if (issuedAt == null ||
      issuedAt <
          DateTime.now().millisecondsSinceEpoch -
              const Duration(days: 7).inMilliseconds) {
    return null;
  }
  return false;
}

Future<Object?> _command(
    Database db, String commandId, Future<Object?> Function() action) async {
  final previous = db.select(
      'SELECT 1 FROM database_command_receipts WHERE request_id = ?',
      [commandId]);
  if (previous.isNotEmpty) {
    throw DatabaseCommandException(commandId, DatabaseCommandOutcome.committed,
        'Command already committed');
  }
  final issuedAt = int.tryParse(commandId.split(':').first);
  final now = DateTime.now().millisecondsSinceEpoch;
  final oldest = now - const Duration(days: 7).inMilliseconds;
  if (issuedAt == null || issuedAt < oldest || issuedAt > now + 60000) {
    throw ArgumentError('Expired or invalid command ID; do not replay');
  }
  db.execute('BEGIN IMMEDIATE');
  try {
    final result = await action();
    flushQueryRevisions(db);
    db.execute('INSERT INTO database_command_receipts VALUES (?, ?, ?)',
        [commandId, 0, now]);
    if (now - _lastReceiptCleanup >= const Duration(hours: 1).inMilliseconds) {
      db.execute('''DELETE FROM database_command_receipts WHERE request_id IN (
        SELECT request_id FROM database_command_receipts WHERE committed_at < ?
        ORDER BY committed_at LIMIT 1000)''', [oldest]);
      _lastReceiptCleanup = now;
    }
    db.execute('COMMIT');
    return result;
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

int _lastReceiptCleanup = 0;

int _batch(StatementCache cache, List<LibraryWriteStatement> statements) {
  var changes = 0;
  for (final item in statements) {
    changes += cache.execute(item.sql, item.parameters);
  }
  return changes;
}
