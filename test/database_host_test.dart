import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:best_viewer/src/modules/infrastructure/database_host.dart';
import 'package:best_viewer/src/modules/build/build_client.dart';
import 'package:best_viewer/src/modules/library/library_client.dart';
import 'package:best_viewer/src/core/domain/models.dart';

void main() {
  test('domain receipts survive restart and prevent duplicate creation',
      () async {
    final directory = await Directory.systemTemp.createTemp('host_receipts_');
    addTearDown(() => directory.delete(recursive: true));
    final path = p.join(directory.path, 'library.db');
    final first = await DatabaseHost.start(databasePath: path);
    final commandId = DatabaseHost.newCommandId();
    await first.call('library', 'ensureCollectionIndexRoot', {'name': 'Once'},
        commandId: commandId);
    expect(await first.commandOutcome(commandId),
        DatabaseCommandOutcome.committed);
    await first.close();
    final second = await DatabaseHost.start(databasePath: path);
    addTearDown(second.close);
    await expectLater(
      second.call('library', 'ensureCollectionIndexRoot', {'name': 'Twice'},
          commandId: commandId),
      throwsA(isA<DatabaseCommandException>().having(
          (e) => e.outcome, 'outcome', DatabaseCommandOutcome.committed)),
    );
    expect(
      (await LibraryClient(second).listIndexRoots())
          .where((node) => node.systemKey == null)
          .map((node) => node.name),
      ['Once'],
    );
    final failedId = DatabaseHost.newCommandId();
    await expectLater(
      second.executeBatch(const [
        LibraryWriteStatement('CREATE TABLE should_rollback (id INTEGER)'),
        LibraryWriteStatement('INSERT INTO missing_table VALUES (1)'),
      ], commandId: failedId),
      throwsA(isA<DatabaseCommandException>().having(
          (e) => e.outcome, 'outcome', DatabaseCommandOutcome.notCommitted)),
    );
    expect(await second.commandOutcome(failedId),
        DatabaseCommandOutcome.notCommitted);
    await second.execute('CREATE TABLE should_rollback (id INTEGER)');
    final expired =
        '${DateTime.now().subtract(const Duration(days: 8)).millisecondsSinceEpoch}:old';
    await expectLater(
      second.call('library', 'ensureCollectionIndexRoot', {'name': 'Expired'},
          commandId: expired),
      throwsA(isA<DatabaseCommandException>()),
    );
    expect(
        await second.commandOutcome(expired), DatabaseCommandOutcome.unknown);
    expect(
      (await LibraryClient(second).listIndexRoots())
          .where((node) => node.systemKey == null)
          .length,
      1,
    );
  });

  test('a fresh library contains only idempotent system roots', () async {
    final directory = await Directory.systemTemp.createTemp('host_query_');
    addTearDown(() => directory.delete(recursive: true));
    final path = p.join(directory.path, 'library.db');
    final host = await DatabaseHost.start(databasePath: path);
    expect(
      (await LibraryClient(host).listIndexRoots())
          .map((node) => node.systemKey),
      containsAll(['favorites', 'rules']),
    );
    await host.close();
    final db = sqlite3.open(path);
    try {
      expect(
        db.select('SELECT * FROM index_nodes WHERE system_key IS NULL'),
        hasLength(1),
      );
      expect(db.select('SELECT * FROM database_command_receipts'), isEmpty);
    } finally {
      db.dispose();
    }
  });

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

  test('rule commands cross the database host isolate', () async {
    final directory = await Directory.systemTemp.createTemp('host_rules_');
    addTearDown(() => directory.delete(recursive: true));
    final host = await DatabaseHost.start(
        databasePath: p.join(directory.path, 'library.db'));
    addTearDown(host.close);
    final library = LibraryClient(host);

    final rule = await library.createRule(
      name: '图片规则',
      entityTypes: const [EntityType.image],
      extensions: const ['jpg'],
      defaultSort: RuleSortMode.name,
    );
    final loaded = await library.getRule(rule.node.id);
    expect(loaded?.entityTypes, const [EntityType.image]);
    expect(loaded?.extensions, const ['jpg']);
    expect(loaded?.defaultSort, RuleSortMode.name);
  });

  test('preview queue batches cross the database host isolate', () async {
    final directory =
        await Directory.systemTemp.createTemp('host_preview_batches_');
    addTearDown(() => directory.delete(recursive: true));
    final host = await DatabaseHost.start(
        databasePath: p.join(directory.path, 'library.db'));
    addTearDown(host.close);
    final library = LibraryClient(host);
    final builds = BuildClient(host);
    final root = await library.ensureDirectoryIndexRoot('/empty');
    final job = await builds.create(
      sourcePath: '/empty',
      operation: LibraryBuildOperation.rootScan,
    );
    await builds.setRoots(jobId: job.id, indexRootId: root.id);

    expect(
      await builds.prepareEntityPreviewWorkBatch(job.id, root.id, limit: 2),
      (complete: true, queued: 0),
    );
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
