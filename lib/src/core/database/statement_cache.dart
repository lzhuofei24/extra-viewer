import 'package:sqlite3/sqlite3.dart';

/// Owned by one connection on the single writer isolate.
class StatementCache {
  StatementCache(this.database, {this.capacity = 64}) : assert(capacity > 0);
  final Database database;
  final int capacity;
  final _statements = <String, PreparedStatement>{};

  int execute(String sql, List<Object?> parameters) {
    var statement = _statements.remove(sql);
    if (statement == null) {
      if (_statements.length >= capacity) {
        _statements.remove(_statements.keys.first)!.dispose();
      }
      statement = database.prepare(sql);
    }
    _statements[sql] = statement;
    try {
      statement.execute(parameters);
      return database.updatedRows;
    } catch (_) {
      _statements.remove(sql)?.dispose();
      rethrow;
    }
  }

  void dispose() {
    for (final statement in _statements.values) {
      statement.dispose();
    }
    _statements.clear();
  }
}
