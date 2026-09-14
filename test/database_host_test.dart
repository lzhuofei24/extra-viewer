import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:best_viewer/src/modules/infrastructure/database_host.dart';
import 'package:best_viewer/src/modules/library/library_client.dart';

void main() {
  test('host serializes commands, rolls back batches and drains before close',
      () async {
    final directory = await Directory.systemTemp.createTemp('database_host_');
    addTearDown(() => directory.delete(recursive: true));
    final host = await DatabaseHost.start(
        databasePath: p.join(directory.path, 'library.db'));
    addTearDown(host.close);
    final library = LibraryClient(host);
    final root = await library
        .ensureDirectoryIndexRoot(p.join(directory.path, 'source'));
    expect((await library.getIndexNode(root.id))?.id, root.id);
    expect(await library.getEntitiesByIds(<String>{}.map((id) => id)), isEmpty);

    await host.execute('CREATE TABLE host_probe (id INTEGER PRIMARY KEY)');
    await expectLater(
        host.executeBatch(const [
          LibraryWriteStatement('INSERT INTO host_probe VALUES (?)', [1]),
          LibraryWriteStatement('INSERT INTO host_probe VALUES (?)', [1]),
        ]),
        throwsStateError);
    // This insert can only succeed if the first insert above was rolled back.
    final write = host.execute('INSERT INTO host_probe VALUES (?)', [1]);
    final close = host.close();
    expect((await write).changes, 1);
    await close;
    await expectLater(library.getIndexNode(root.id), throwsStateError);
  });

  test('startup failure completes instead of waiting indefinitely', () async {
    final directory =
        await Directory.systemTemp.createTemp('database_host_bad_');
    addTearDown(() => directory.delete(recursive: true));
    await expectLater(
      DatabaseHost.start(databasePath: directory.path)
          .timeout(const Duration(seconds: 15)),
      throwsA(isA<SqliteException>()),
    );
  });
}
