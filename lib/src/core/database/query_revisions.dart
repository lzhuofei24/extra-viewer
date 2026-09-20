import 'package:sqlite3/sqlite3.dart';

void flushQueryRevisions(Database db) {
  db.execute('''INSERT INTO query_revisions(domain, scope_id, revision)
    SELECT domain, scope_id, 1 FROM query_revision_dirty WHERE true
    ON CONFLICT(domain, scope_id) DO UPDATE SET revision = revision + 1''');
  db.execute('DELETE FROM query_revision_dirty');
}
