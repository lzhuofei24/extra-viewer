import 'package:best_viewer/src/core/database/query_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('cache evicts least recently read DTO and expires at exact boundary',
      () {
    final cache = QueryCache(maxEntries: 2, maxBytes: 300);
    cache.put('a', 1);
    cache.put('b', 2, expiresAt: 100);
    expect(cache.get('a', 0), 1);
    cache.put('c', 3);
    expect(cache.get('b', 0), isNull);
    cache.put('d', 4, expiresAt: 100);
    expect(cache.get('d', 99), 4);
    expect(cache.get('d', 100), isNull);
    cache.put('huge', 'x' * 301);
    expect(cache.get('huge', 0), isNull);
  });

  test('query revision invalidation leaves unrelated progress updates cached',
      () {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    db.execute(
        '''CREATE TABLE query_revisions(domain TEXT,scope_id TEXT,revision INTEGER);
      CREATE TABLE query_revision_dirty(domain TEXT);
      CREATE TABLE progress(value INTEGER);
      INSERT INTO query_revisions VALUES('metadata','',1);''');
    final cache = QueryCache();
    cache.synchronize(db);
    cache.put('count', 2);
    db.execute('INSERT INTO progress VALUES(10)');
    cache.synchronize(db);
    expect(cache.get('count', 0), 2);
    db.execute('UPDATE query_revisions SET revision=2');
    cache.synchronize(db);
    expect(cache.get('count', 0), isNull);
    cache.put('count', 3);
    db.execute("INSERT INTO query_revision_dirty VALUES('metadata')");
    cache.synchronize(db);
    expect(cache.get('count', 0), isNull);
  });
}
