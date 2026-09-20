import 'dart:io';
import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('interrupted reset resumes before creating a fresh library', () {
    final dir = Directory.systemTemp.createTempSync('interrupted_reset_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/library.db';
    File('$path.reset-pending').writeAsStringSync('14');
    Directory('${dir.path}/thumbnails').createSync();
    File('${dir.path}/thumbnails/old.webp').writeAsStringSync('stale');
    final db = AppDatabase.openAtPath(path);
    addTearDown(db.close);
    expect(File('$path.reset-pending').existsSync(), isFalse);
    expect(Directory('${dir.path}/thumbnails').existsSync(), isFalse);
    expect(db.db.select('SELECT * FROM entities'), isEmpty);
  });

  test('fresh database directly creates constrained current tables', () {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    expect(db.db.userVersion, AppDatabase.currentSchemaVersion);
    expect(db.db.select('PRAGMA foreign_key_check'), isEmpty);
    expect(db.db.select('PRAGMA integrity_check').single.values.single, 'ok');
    expect(
        db.db
            .select('PRAGMA table_info(index_nodes)')
            .any((r) => r['name'] == 'view_type'),
        isFalse);
    expect(
        db.db
            .select('PRAGMA table_info(entity_progress)')
            .any((r) => r['name'] == 'document_revision'),
        isTrue);
    expect(
        db.db.select(
            "SELECT name FROM sqlite_master WHERE name IN ('index_node_edges','graph_node_positions')"),
        isEmpty);
    expect(db.db.select('SELECT * FROM index_rules'), hasLength(5));
    final root = LibraryRepository(db).ensureCollectionIndexRoot('Books');
    expect(
        () => db.db.execute(
            'UPDATE index_nodes SET is_staging=2 WHERE id=?', [root.id]),
        throwsA(isA<SqliteException>()));
    expect(
        () => db.db.execute(
            "UPDATE index_nodes SET parent_id='system-rules' WHERE id=?",
            [root.id]),
        throwsA(isA<SqliteException>()));
    expect(() => db.db.execute('UPDATE index_rules SET max_results=0'),
        throwsA(isA<SqliteException>()));
  });

  test('old library reset removes generated data only', () {
    final dir = Directory.systemTemp.createTempSync('library_reset_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/library.db';
    final old = sqlite3.open(path);
    old.execute(
        "CREATE TABLE entities(id TEXT); CREATE TABLE index_nodes(id TEXT); INSERT INTO entities VALUES('old')");
    old.userVersion = 13;
    old.dispose();
    final backup = File('$path.schema13.123.backup')
      ..writeAsStringSync('backup');
    final original = File('${dir.path}/photo.jpg')
      ..writeAsStringSync('original');
    final key = File('${dir.path}/release.jks')..writeAsStringSync('signing');
    Directory('${dir.path}/node_previews').createSync();
    File('${dir.path}/node_previews/old.webp').writeAsStringSync('preview');
    final db = AppDatabase.openAtPath(path);
    addTearDown(db.close);
    expect(db.db.select('SELECT * FROM entities'), isEmpty);
    expect(backup.existsSync(), isFalse);
    expect(Directory('${dir.path}/node_previews').existsSync(), isFalse);
    expect(original.readAsStringSync(), 'original');
    expect(key.readAsStringSync(), 'signing');
  });

  test('current library is retained on repeated open', () {
    final dir = Directory.systemTemp.createTempSync('library_reopen_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/library.db';
    final first = AppDatabase.openAtPath(path);
    final root = LibraryRepository(first).ensureCollectionIndexRoot('Keep');
    first.close();
    final next = AppDatabase.openAtPath(path);
    addTearDown(next.close);
    expect(LibraryRepository(next).getIndexNode(root.id)?.name, 'Keep');
    expect(
        next.db
            .select("SELECT * FROM index_nodes WHERE system_key='favorites'"),
        hasLength(1));
  });

  test('unrecognized databases are rejected without deletion', () {
    final dir = Directory.systemTemp.createTempSync('unknown_library_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/unrelated.db';
    final raw = sqlite3.open(path);
    raw.execute(
        "CREATE TABLE notes(body TEXT); INSERT INTO notes VALUES('keep')");
    raw.userVersion = 1;
    raw.dispose();
    expect(() => AppDatabase.openAtPath(path),
        throwsA(isA<AppDatabaseResetRequired>()));
    final check = sqlite3.open(path);
    addTearDown(check.dispose);
    expect(check.select('SELECT body FROM notes').single['body'], 'keep');
  });
}
