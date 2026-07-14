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
class AppDiagnosticLog extends ChangeNotifier {
  AppDiagnosticLog._();

  static final AppDiagnosticLog instance = AppDiagnosticLog._();
  static const _maxLogBytes = 5 * 1024 * 1024;
  static const _maxLogFiles = 7;
  static const _recentReadBytes = 384 * 1024;

  IOSink? _sink;
  Directory? _directory;
  File? _sessionMarker;
  String? _sessionId;
  Future<void> _pending = Future<void>.value();
  bool _initialized = false;

  bool get isInitialized => _initialized;
  String? get directoryPath => _directory?.path;

  /// Reads the newest structured records from the persisted JSONL files.
  /// Reading is intentionally separate from writing so the UI can refresh on
  /// demand without adding database work to the application hot path.
  Future<List<AppDiagnosticRecord>> readRecent({int limit = 160}) async {
    await _pending;
    final directory = _directory;
    if (directory == null || !await directory.exists()) return const [];
    final files = await directory
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.jsonl'))
        .cast<File>()
        .toList();
    files.sort((left, right) => right.path.compareTo(left.path));
    final records = <AppDiagnosticRecord>[];
    for (final file in files) {
      try {
        // Diagnostics can be written for hours during an index build. Reading
        // every rotated file and decoding thousands of records on the UI
        // isolate made merely opening the page enough to trigger ANR.
        final bytes = await _readTail(file, _recentReadBytes);
        final lines = const Utf8Decoder(allowMalformed: true)
            .convert(bytes)
            .split('\n');
        for (final line in lines.reversed) {
          if (line.trim().isEmpty) continue;
          try {
            final decoded = jsonDecode(line);
            if (decoded is Map<String, dynamic>) {
              records.add(AppDiagnosticRecord.fromJson(decoded));
              if (records.length >= limit) {
                return List.unmodifiable(records);
              }
            }
          } catch (_) {
            // A partially written final line must not hide older diagnostics.
          }
        }
      } catch (_) {
        // A rotated log can disappear while the page is reading it.
      }
    }
    return List.unmodifiable(records);
  }

  static Future<List<int>> _readTail(File file, int maxBytes) async {
    final length = await file.length();
    final start = length > maxBytes ? length - maxBytes : 0;
    final handle = await file.open();
    try {
      await handle.setPosition(start);
      final bytes = await handle.read(length - start);
      // The first line is incomplete when the read starts mid-file.
      if (start > 0) {
        final newline = bytes.indexOf(10);
        return newline < 0 ? const [] : bytes.sublist(newline + 1);
      }
      return bytes;
    } finally {
      await handle.close();
    }
  }

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
        notifyListeners();
      } catch (error, stackTrace) {
        debugPrint(
            'Best Viewer diagnostic log write failed: $error\n$stackTrace');
      }
    });
    return _pending;
  }
}

class AppDiagnosticRecord {
  const AppDiagnosticRecord({
    required this.timestamp,
    required this.level,
    required this.event,
    required this.fields,
  });

  factory AppDiagnosticRecord.fromJson(Map<String, dynamic> json) {
    final fields = <String, Object?>{};
    for (final entry in json.entries) {
      if (entry.key != 'timestamp' &&
          entry.key != 'level' &&
          entry.key != 'event' &&
          entry.key != 'sessionId') {
        fields[entry.key] = entry.value;
      }
    }
    return AppDiagnosticRecord(
      timestamp: DateTime.tryParse('${json['timestamp']}') ?? DateTime.now(),
      level: '${json['level'] ?? 'info'}',
      event: '${json['event'] ?? 'unknown'}',
      fields: fields,
    );
  }

  final DateTime timestamp;
  final String level;
  final String event;
  final Map<String, Object?> fields;

  String? get error => fields['error']?.toString();
  String? get stackTrace => fields['stackTrace']?.toString();
  String? get category => fields['category']?.toString() ?? _categoryFor(event);
  String get message => fields['message']?.toString() ?? _humanize(event);
  String get errorSignature {
    final detail = error ?? message;
    final firstLine = detail.split(RegExp(r'\r?\n')).first.trim();
    return '$event · $firstLine';
  }

  static String _humanize(String value) => value
      .replaceAll('_', ' ')
      .split(' ')
      .map((part) => part.isEmpty
          ? part
          : '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');

  static String _categoryFor(String event) {
    if (event.startsWith('database') || event.contains('query')) return '数据库';
    if (event.startsWith('audio') || event.startsWith('player')) return '播放器';
    if (event.contains('thumbnail') || event.contains('preview')) return '缩略图';
    if (event.contains('job') || event.contains('scan') || event.contains('build')) {
      return '索引任务';
    }
    if (event.startsWith('android') || event.contains('materialize')) return 'Android';
    if (event.contains('uncaught') || event.contains('error')) return '界面';
    return '应用';
  }
}
