import 'dart:io';

import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_read_worker.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final entityCount in [1000, 10000, 130000]) {
    test('$entityCount entity rule query scale probe', () async {
      final directory =
          await Directory.systemTemp.createTemp('extra_rule_scale_');
      final database = AppDatabase.openAtPathForTesting(
          p.join(directory.path, 'library.db'));
      try {
        final now = DateTime.now().millisecondsSinceEpoch;
        final statement = database.db.prepare('''
      INSERT INTO entities
      (id, path, name, format, media_type, hash, size,
       source_created_at_ms, source_modified_at_ms, archived,
       last_opened_at, open_count, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?)
    ''');
        database.db.execute('BEGIN IMMEDIATE');
        try {
          for (var index = 0; index < entityCount; index++) {
            final type = EntityType.values[index % EntityType.values.length];
            final opened = index % 3 == 0;
            statement.execute([
              'entity-$index',
              '/scale/entity-$index.dat',
              'entity-$index.dat',
              'dat',
              type.value,
              'hash-$index',
              index + 1,
              now,
              now - index * 1000,
              opened ? now - index * 10 : null,
              opened ? (index % 25) + 1 : 0,
              now,
              now,
            ]);
          }
          database.db.execute('COMMIT');
        } catch (_) {
          database.db.execute('ROLLBACK');
          rethrow;
        } finally {
          statement.dispose();
        }

        final plan = database.db.select('''
      EXPLAIN QUERY PLAN
      SELECT * FROM entities
      WHERE archived = 0 AND open_count > 0
      ORDER BY open_count DESC, COALESCE(last_opened_at, 0) DESC, id ASC
      LIMIT 61
    ''');
        final worker = await LibraryReadWorker.start(
          databasePath: database.databasePath!,
          storageDirectoryPath: database.storageDirectoryPath,
        );
        try {
          final rulesWatch = Stopwatch()..start();
          final rules = await worker.listRules();
          rulesWatch.stop();
          final frequent = rules.firstWhere(
            (rule) => rule.builtInKind == BuiltInRuleKind.frequent,
          );
          final firstWatch = Stopwatch()..start();
          var page = await worker.loadRulePage(ruleNodeId: frequent.node.id);
          firstWatch.stop();
          final allWatch = Stopwatch()..start();
          var loaded = page.items.length;
          while (page.hasMore) {
            page = await worker.loadRulePage(
              ruleNodeId: frequent.node.id,
              after: page.cursor,
            );
            loaded += page.items.length;
          }
          allWatch.stop();
          stdout.writeln('entities=$entityCount');
          stdout.writeln('listRulesMs=${rulesWatch.elapsedMilliseconds}');
          stdout.writeln('firstPageMs=${firstWatch.elapsedMilliseconds}');
          stdout.writeln('cappedResults=$loaded');
          stdout.writeln('allPagesMs=${allWatch.elapsedMilliseconds}');
          final samples = <int>[];
          for (var run = 0; run < 30; run++) {
            final watch = Stopwatch()..start();
            final result =
                await worker.loadRulePage(ruleNodeId: frequent.node.id);
            samples.add(watch.elapsedMicroseconds);
            expect(result.items.map((item) => item.id).toSet().length,
                result.items.length);
          }
          samples.sort();
          stdout.writeln('warmFirstPageP50Us=${samples[14]}');
          stdout.writeln('warmFirstPageP95Us=${samples[28]}');
          stdout.writeln('processRssBytes=${ProcessInfo.currentRss}');
          stdout.writeln(
              'databaseBytes=${File(database.databasePath!).lengthSync()}');
          final wal = File('${database.databasePath!}-wal');
          stdout.writeln('walBytes=${wal.existsSync() ? wal.lengthSync() : 0}');
          for (final row in plan) {
            stdout.writeln('queryPlan=${row['detail']}');
          }
        } finally {
          await worker.close();
        }
      } finally {
        database.close();
        await directory.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}
