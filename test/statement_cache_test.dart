import 'package:best_viewer/src/core/database/statement_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('cached statements recover after rollback and eviction', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    db.execute('CREATE TABLE records(id INTEGER PRIMARY KEY, value TEXT)');
    final cache = StatementCache(db, capacity: 2);
    addTearDown(cache.dispose);
    const insert = 'INSERT INTO records VALUES(?,?)';
    expect(cache.execute(insert, [1, 'one']), 1);
    db.execute('BEGIN');
    expect(() => cache.execute(insert, [1, 'duplicate']),
        throwsA(isA<SqliteException>()));
    db.execute('ROLLBACK');
    cache.execute(insert, [2, 'two']);
    cache.execute('UPDATE records SET value=? WHERE id=?', ['updated', 2]);
    cache.execute('DELETE FROM records WHERE id=?', [1]);
    cache.execute(insert, [3, 'three']);
    expect(
        db
            .select('SELECT value FROM records ORDER BY id')
            .map((row) => row['value']),
        ['updated', 'three']);
    cache.dispose();
  });
}
