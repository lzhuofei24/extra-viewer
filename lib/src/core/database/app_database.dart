import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'schema_current.dart';

/// App-owned storage. This release starts a new library without migration.
class AppDatabase {
  AppDatabase._(this.db, this.storageDirectoryPath, this.databasePath);
  static const currentSchemaVersion = 14;
  final Database db;
  final String storageDirectoryPath;
  final String? databasePath;
  bool _closed = false;

  static Future<AppDatabase> open() async {
    final dir = await getApplicationSupportDirectory();
    return openAtPath(p.join(dir.path, 'best_viewer.db'));
  }

  static AppDatabase openInMemory() => openForTesting(sqlite3.openInMemory());
  static AppDatabase openForTesting(Database database) => _initialize(database,
      Directory.systemTemp.createTempSync('best_viewer_test_').path, null);
  static AppDatabase openAtPathForTesting(String path) => openAtPath(path);

  static AppDatabase openAtPath(String path) {
    final file = File(p.normalize(p.absolute(path)));
    file.parent.createSync(recursive: true);
    final pendingReset = File('${file.path}.reset-pending');
    if (pendingReset.existsSync()) {
      _clearOwnedStorage(file.path);
      pendingReset.deleteSync();
    }
    var database = sqlite3.open(file.path);
    final old = database.userVersion > 0 &&
        database.userVersion < currentSchemaVersion &&
        database
            .select(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='entities'")
            .isNotEmpty &&
        database
            .select(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='index_nodes'")
            .isNotEmpty;
    if (old) {
      database.dispose();
      pendingReset.writeAsStringSync('14', flush: true);
      _clearOwnedStorage(file.path);
      pendingReset.deleteSync();
      database = sqlite3.open(file.path);
    }
    return _initialize(database, file.parent.path, file.path);
  }

  static AppDatabase _initialize(Database database, String root, String? path) {
    final app = AppDatabase._(database, root, path);
    try {
      database.execute('''PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL;
        PRAGMA busy_timeout=3000; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-16384;''');
      if (database.userVersion == currentSchemaVersion) return app;
      final populated = database
          .select(
              "SELECT 1 FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' LIMIT 1")
          .isNotEmpty;
      if (database.userVersion != 0 || populated) {
        throw AppDatabaseResetRequired(database.userVersion);
      }
      database.execute('BEGIN IMMEDIATE');
      try {
        database.execute(currentSchemaSql);
        _seedSystemNodes(database);
        database.execute('DELETE FROM query_revision_dirty');
        if (database.select('PRAGMA foreign_key_check').isNotEmpty) {
          throw StateError('Invalid fresh database foreign keys');
        }
        database.execute(
            "INSERT INTO index_node_search(index_node_search,rank) VALUES('integrity-check',1)");
        database.userVersion = currentSchemaVersion;
        database.execute('COMMIT');
      } catch (_) {
        database.execute('ROLLBACK');
        rethrow;
      }
      return app;
    } catch (_) {
      app.close();
      rethrow;
    }
  }

  static void _seedSystemNodes(Database db) {
    final now = DateTime.now().millisecondsSinceEpoch;
    void node(String id, String? parent, String name, String type, String? key,
        int order) {
      db.execute(
          '''INSERT INTO index_nodes(id,parent_id,name,node_type,system_key,
        is_protected,sort_order,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)''',
          [id, parent, name, type, key, key == null ? 0 : 1, order, now, now]);
    }

    node('system-root', null, 'Root', 'root', null, 0);
    node('system-favorites', 'system-root', '收藏', 'category_index_root',
        'favorites', -1000);
    node('system-rules', 'system-root', '规则', 'rule_index_root', 'rules', -900);
    final rules = [
      ('frequent', '常用', '[]'),
      ('recentImages', '最近图片', '["image"]'),
      ('recentVideos', '最近视频', '["video"]'),
      ('recentText', '最近文本', '["text","external_link"]'),
      ('recentMusic', '最近音乐', '["audio"]')
    ];
    for (var i = 0; i < rules.length; i++) {
      final (key, name, types) = rules[i];
      final id = 'system-rule-$key';
      node(id, 'system-rules', name, 'rule', 'rule.$key', i);
      db.execute(
          '''INSERT INTO index_rules(node_id,entity_types_json,extensions_json,
        default_sort,max_results,built_in_kind,updated_at) VALUES(?,?,'[]',?,1000,?,?)''',
          [
            id,
            types,
            key == 'frequent' ? 'openCount' : 'lastOpened',
            key,
            now
          ]);
    }
  }

  static Future<void> resetLocalIndexStorage() async {
    final dir = await getApplicationSupportDirectory();
    _clearOwnedStorage(p.join(dir.path, 'best_viewer.db'));
  }

  static void _clearOwnedStorage(String databasePath) {
    final root = p.dirname(databasePath);
    final name = p.basename(databasePath);
    // Only exact generated names in the database's own directory are removed.
    for (final entry in Directory(root).listSync(followLinks: false)) {
      if (entry is! File) continue;
      final leaf = p.basename(entry.path);
      final backup =
          RegExp('^${RegExp.escape(name)}' r'\.schema[0-9]+\.[0-9]+\.backup$')
              .hasMatch(leaf);
      if ([name, '$name-wal', '$name-shm', '$name-journal'].contains(leaf) ||
          backup ||
          RegExp(r'^browse-\d+\.cache\.db(?:-wal|-shm|\.lock)?$')
              .hasMatch(leaf)) {
        entry.deleteSync();
      }
    }
    for (final leaf in [
      'thumbnails',
      'node_previews',
      'audio_waveforms',
      'reader_cache'
    ]) {
      final target = p.normalize(p.join(root, leaf));
      if (!p.isWithin(root, target)) {
        throw StateError('Invalid cache cleanup path');
      }
      if (FileSystemEntity.typeSync(target, followLinks: false) ==
          FileSystemEntityType.directory) {
        Directory(target).deleteSync(recursive: true);
      }
    }
  }

  void checkpointWriteAheadLog() {
    db.select('PRAGMA wal_checkpoint(PASSIVE)');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    db.dispose();
  }
}

class AppDatabaseResetRequired implements Exception {
  const AppDatabaseResetRequired(this.foundVersion);
  final int foundVersion;
  @override
  String toString() => 'AppDatabaseResetRequired(foundVersion: $foundVersion)';
}
