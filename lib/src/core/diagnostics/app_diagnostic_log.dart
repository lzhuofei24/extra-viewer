import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persistent diagnostic breadcrumbs for failures that happen outside Dart.
///
/// Native crashes cannot be caught by Flutter, so the latest media lifecycle
/// events are flushed to disk as they happen and the next launch detects a
/// session marker left behind by an unclean exit.
class AppDiagnosticLog {
  AppDiagnosticLog._();

  static final AppDiagnosticLog instance = AppDiagnosticLog._();
  static const _maxLogBytes = 5 * 1024 * 1024;
  static const _maxLogFiles = 7;

  IOSink? _sink;
  Directory? _directory;
  File? _sessionMarker;
  String? _sessionId;
  Future<void> _pending = Future<void>.value();
  bool _initialized = false;

  bool get isInitialized => _initialized;
  String? get directoryPath => _directory?.path;

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      final support = await getApplicationSupportDirectory();
      await initializeAtPath(support.path);
    } catch (error, stackTrace) {
      debugPrint('Best Viewer diagnostic log unavailable: $error\n$stackTrace');
    }
  }

  @visibleForTesting
  Future<void> initializeAtPath(String storageDirectoryPath) async {
    if (_initialized) return;
    _directory = Directory(p.join(storageDirectoryPath, 'logs'));
    await _directory!.create(recursive: true);
    _sessionMarker = File(p.join(_directory!.path, 'active_session.json'));
    final previousSession = await _readPreviousSession();
    _sessionId = '${DateTime.now().microsecondsSinceEpoch}-$pid';
    await _openSink();
    _initialized = true;
    await _write(
      level: 'info',
      event: 'session_started',
      fields: {'sessionId': _sessionId, 'pid': pid},
      flush: true,
    );
    if (previousSession != null) {
      await _write(
        level: 'warning',
        event: 'previous_session_unclean',
        fields: previousSession,
        flush: true,
      );
    }
    await _writeSessionMarker();
    await _deleteExpiredLogs();
  }

  void info(String event, {Map<String, Object?> fields = const {}}) {
    unawaited(_write(level: 'info', event: event, fields: fields));
  }

  void warning(String event, {Map<String, Object?> fields = const {}}) {
    unawaited(
        _write(level: 'warning', event: event, fields: fields, flush: true));
  }

  void error(
    String event,
    Object error,
    StackTrace stackTrace, {
    Map<String, Object?> fields = const {},
  }) {
    unawaited(_write(
      level: 'error',
      event: event,
      fields: {
        ...fields,
        'error': error.toString(),
        'stackTrace': stackTrace.toString(),
      },
      flush: true,
    ));
  }

  Future<void> close({String reason = 'application_disposed'}) async {
    if (!_initialized) return;
    await _write(
      level: 'info',
      event: 'session_ended',
      fields: {'reason': reason},
      flush: true,
    );
    await _pending;
    await _sink?.close();
    _sink = null;
    try {
      if (await _sessionMarker?.exists() ?? false) {
        await _sessionMarker!.delete();
      }
    } catch (_) {
      // The next launch can safely treat an undeletable marker as unclean.
    }
    _initialized = false;
  }

  Future<Map<String, Object?>?> _readPreviousSession() async {
    final marker = _sessionMarker;
    if (marker == null || !await marker.exists()) return null;
    try {
      final decoded = jsonDecode(await marker.readAsString());
      if (decoded is Map<String, dynamic>) {
        return decoded.map((key, value) => MapEntry(key, value));
      }
    } catch (_) {
      return const {'marker': 'unreadable'};
    }
    return const {'marker': 'invalid'};
  }

  Future<void> _openSink() async {
    final directory = _directory!;
    final now = DateTime.now();
    final day = '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    var file = File(p.join(directory.path, 'best_viewer_$day.jsonl'));
    if (await file.exists() && await file.length() >= _maxLogBytes) {
      file = File(p.join(
        directory.path,
        'best_viewer_${day}_${now.millisecondsSinceEpoch}.jsonl',
      ));
    }
    _sink = file.openWrite(mode: FileMode.append);
  }

  Future<void> _writeSessionMarker() async {
    final marker = _sessionMarker;
    if (marker == null) return;
    await marker.writeAsString(
        jsonEncode({
          'sessionId': _sessionId,
          'startedAt': DateTime.now().toUtc().toIso8601String(),
          'pid': pid,
        }),
        flush: true);
  }

  Future<void> _deleteExpiredLogs() async {
    final directory = _directory;
    if (directory == null) return;
    final files = await directory
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.jsonl'))
        .cast<File>()
        .toList();
    files.sort((left, right) =>
        right.lastModifiedSync().compareTo(left.lastModifiedSync()));
    for (final file in files.skip(_maxLogFiles)) {
      try {
        await file.delete();
      } catch (_) {
        // Retention must not interfere with normal startup.
      }
    }
  }

  Future<void> _write({
    required String level,
    required String event,
    required Map<String, Object?> fields,
    bool flush = false,
  }) {
    if (!_initialized && _sink == null) return Future<void>.value();
    final record = <String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'level': level,
      'event': event,
      'sessionId': _sessionId,
      ...fields,
    };
    _pending = _pending.then((_) async {
      try {
        _sink?.writeln(jsonEncode(record));
        if (flush) await _sink?.flush();
      } catch (error, stackTrace) {
        debugPrint(
            'Best Viewer diagnostic log write failed: $error\n$stackTrace');
      }
    });
    return _pending;
  }
}
