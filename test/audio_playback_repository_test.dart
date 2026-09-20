import 'dart:io';

import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('audio queue restores ordered snapshots and live source revisions',
      () async {
    final temp = await Directory.systemTemp.createTemp('audio_queue_');
    addTearDown(() => temp.delete(recursive: true));
    final path = '${temp.path}/library.db';
    var db = AppDatabase.openAtPathForTesting(path);
    addTearDown(() => db.close());
    var repo = LibraryRepository(db);
    final entries = <EntityListItem>[];
    for (var index = 0; index < 2; index++) {
      final entity = repo
          .upsertEntity(
            path: '/track$index.mp3',
            name: 'Track $index',
            format: 'mp3',
            entityType: EntityType.audio,
            hash: 'hash$index',
            size: 100,
            sourceCreatedAtMs: 0,
            sourceModifiedAtMs: 10,
          )
          .entity;
      db.db.execute('UPDATE entities SET source_revision=? WHERE id=?',
          [index + 3, entity.id]);
      entries.add(EntityListItem(
        id: entity.id,
        title: 'Snapshot $index',
        entityType: EntityType.audio,
        path: entity.path,
        format: 'mp3',
        hash: 'hash$index',
        size: 100,
        modifiedAtMs: 10,
        durationMs: 5000,
      ));
    }
    final session = repo.createAudioPlaybackSession(
        entries: entries, currentIndex: 1, sourceNodeName: 'Queue');
    expect(session.entries.map((entry) => entry.sourceRevision), [3, 4]);
    expect(session.entries.map((entry) => entry.title),
        ['Snapshot 0', 'Snapshot 1']);
    repo.updateAudioPlaybackSession(
      id: session.id,
      positionMs: 1234,
      mode: AudioPlaybackMode.nodeShuffle,
      shuffleRemaining: [0],
      history: [1],
    );
    db.close();
    db = AppDatabase.openAtPathForTesting(path);
    repo = LibraryRepository(db);
    final restored = repo.listAudioPlaybackSessions().single;
    expect(restored.currentIndex, 1);
    expect(restored.positionMs, 1234);
    expect(restored.mode, AudioPlaybackMode.nodeShuffle);
    expect(restored.shuffleRemaining, [0]);
    expect(restored.history, [1]);
    expect(restored.entries.map((entry) => entry.id),
        entries.map((entry) => entry.id));
    expect(restored.entries.first.durationMs, 5000);

    // Queue snapshots survive removal of their library entity records.
    db.db.execute('DELETE FROM entities WHERE id=?', [entries.first.id]);
    final orphaned = repo.getAudioPlaybackSession(session.id)!;
    expect(orphaned.entries, hasLength(2));
    expect(orphaned.entries.map((entry) => entry.sourceRevision), [1, 4]);
    expect(orphaned.entries.first.path, entries.first.path);
    repo.deleteAudioPlaybackSession(session.id);
    expect(repo.listAudioPlaybackSessions(), isEmpty);
    expect(
        db.db.select('SELECT * FROM audio_playback_session_entries'), isEmpty);
  });
}
