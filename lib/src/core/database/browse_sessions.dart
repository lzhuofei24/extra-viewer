import 'package:sqlite3/sqlite3.dart';

/// Disposable ordered IDs, never a second copy of library metadata.
class BrowseSessions {
  BrowseSessions(this.database, {String? cachePath})
      : namespace = cachePath == null ? 'temp' : 'browse_cache' {
    if (cachePath != null) {
      database.execute('ATTACH DATABASE ? AS browse_cache', [cachePath]);
      database.execute('PRAGMA browse_cache.journal_mode=WAL');
    } else {
      database.execute('PRAGMA temp_store=FILE');
    }
    database.execute('''PRAGMA $namespace.cache_size=-2048;
      PRAGMA $namespace.max_page_count=32768;
      CREATE TABLE IF NOT EXISTS $namespace.browse_sessions(id TEXT PRIMARY KEY, scope TEXT NOT NULL, touched INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS $namespace.browse_items(session_id TEXT NOT NULL, ordinal INTEGER NOT NULL, entity_id TEXT NOT NULL,
        PRIMARY KEY(session_id,ordinal));''');
  }
  final Database database;
  final String namespace;
  int _sequence = 0;

  String create(String scope, String selectSql, List<Object?> arguments) {
    final id = '${DateTime.now().microsecondsSinceEpoch}:${_sequence++}';
    database.execute('SAVEPOINT create_session');
    try {
      final expired = database.select(
          'SELECT id FROM $namespace.browse_sessions ORDER BY touched DESC,id DESC LIMIT -1 OFFSET 5');
      for (final row in expired) {
        database.execute(
            'DELETE FROM $namespace.browse_items WHERE session_id=?',
            [row['id']]);
        database.execute(
            'DELETE FROM $namespace.browse_sessions WHERE id=?', [row['id']]);
      }
      database.execute('INSERT INTO $namespace.browse_sessions VALUES(?,?,?)',
          [id, scope, DateTime.now().microsecondsSinceEpoch]);
      database.execute('''INSERT INTO $namespace.browse_items
        SELECT ?,ROW_NUMBER() OVER (),id FROM ($selectSql)''',
          [id, ...arguments]);
      database.execute('RELEASE create_session');
      return id;
    } catch (_) {
      database.execute('ROLLBACK TO create_session');
      database.execute('RELEASE create_session');
      rethrow;
    }
  }

  void validate(String id, String scope) {
    if (database.select(
        'SELECT 1 FROM $namespace.browse_sessions WHERE id=? AND scope=?',
        [id, scope]).isEmpty) {
      throw StateError('浏览会话已失效，请刷新');
    }
    database.execute(
        'UPDATE $namespace.browse_sessions SET touched=? WHERE id=?',
        [DateTime.now().microsecondsSinceEpoch, id]);
  }

  ResultSet page(String id, int after, int limit) => database.select('''
    SELECT e.*,s.ordinal AS session_ordinal FROM $namespace.browse_items s
    JOIN entity_details e ON e.id=s.entity_id
    WHERE s.session_id=? AND s.ordinal>? AND e.archived=0
    ORDER BY s.ordinal LIMIT ?''', [id, after, limit + 1]);
}
