part of 'library_repository.dart';

/// Audio playback session persistence: create, list, update, delete
/// sessions that remember the play queue, position, shuffle order, and
/// history across app restarts.
mixin AudioPlaybackRepositoryMixin on LibraryRepositoryBase {
  AudioPlaybackSession createAudioPlaybackSession({
    required List<EntityListItem> entries,
    required int currentIndex,
    String? sourceNodeId,
    String? sourceNodeName,
    AudioPlaybackMode mode = AudioPlaybackMode.sequential,
  }) {
    final audioEntries = entries
        .where((entry) => entry.entityType == EntityType.audio)
        .toList(growable: false);
    if (audioEntries.isEmpty) {
      throw ArgumentError.value(
          entries, 'entries', 'Audio session needs audio entries');
    }
    final now = nowMillis();
    final id = newId();
    final safeIndex = currentIndex.clamp(0, audioEntries.length - 1);
    final name = sourceNodeName?.trim().isNotEmpty == true
        ? sourceNodeName!.trim()
        : '临时播放列表';
    writeTransaction(() {
      database.db.execute(
          'UPDATE audio_playback_sessions SET active = 0 WHERE active = 1');
      database.db.execute(
        '''INSERT INTO audio_playback_sessions
          (id, name, source_node_id, source_node_name, mode, current_index, position_ms, shuffle_remaining_json, history_json, active, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, 0, '[]', '[]', 1, ?, ?)''',
        [
          id,
          name,
          sourceNodeId,
          sourceNodeName,
          mode.name,
          safeIndex,
          now,
          now
        ],
      );
      for (var index = 0; index < audioEntries.length; index++) {
        final entry = audioEntries[index];
        database.db.execute(
          '''INSERT INTO audio_playback_session_entries
            (session_id, sort_order, entity_id, title, path, format, fingerprint, size, modified_at_ms, duration_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          [
            id,
            index,
            entry.id,
            entry.title,
            entry.path,
            entry.format,
            entry.hash,
            entry.size,
            entry.modifiedAtMs,
            entry.durationMs
          ],
        );
      }
    });
    return getAudioPlaybackSession(id)!;
  }

  List<AudioPlaybackSession> listAudioPlaybackSessions() {
    final rows = database.db.select(
      'SELECT * FROM audio_playback_sessions ORDER BY active DESC, updated_at DESC',
    );
    return rows.map(_audioSessionFromRow).toList(growable: false);
  }

  AudioPlaybackSession? getAudioPlaybackSession(String id) {
    final rows = database.db.select(
        'SELECT * FROM audio_playback_sessions WHERE id = ? LIMIT 1', [id]);
    return rows.isEmpty ? null : _audioSessionFromRow(rows.first);
  }

  void updateAudioPlaybackSession({
    required String id,
    int? currentIndex,
    int? positionMs,
    AudioPlaybackMode? mode,
    List<int>? shuffleRemaining,
    List<int>? history,
    bool? active,
  }) {
    if (active == true) {
      database.db.execute(
          'UPDATE audio_playback_sessions SET active = 0 WHERE active = 1 AND id <> ?',
          [id]);
    }
    database.db.execute(
      '''UPDATE audio_playback_sessions SET
        current_index = COALESCE(?, current_index),
        position_ms = COALESCE(?, position_ms),
        mode = COALESCE(?, mode),
        shuffle_remaining_json = COALESCE(?, shuffle_remaining_json),
        history_json = COALESCE(?, history_json),
        active = COALESCE(?, active), updated_at = ? WHERE id = ?''',
      [
        currentIndex,
        positionMs,
        mode?.name,
        shuffleRemaining == null ? null : jsonEncode(shuffleRemaining),
        history == null ? null : jsonEncode(history),
        active == null ? null : boolToInt(active),
        nowMillis(),
        id
      ],
    );
  }

  void deleteAudioPlaybackSession(String id) {
    database.db
        .execute('DELETE FROM audio_playback_sessions WHERE id = ?', [id]);
  }

  AudioPlaybackSession _audioSessionFromRow(Row row) {
    final id = row['id'] as String;
    final entryRows =
        database.db.select('''SELECT *, (SELECT source_revision FROM entities
          WHERE entities.id = audio_playback_session_entries.entity_id) AS source_revision
          FROM audio_playback_session_entries
         WHERE session_id = ? ORDER BY sort_order''', [id]);
    final entries = entryRows
        .map((entry) => EntityListItem(
              sourceRevision: entry['source_revision'] as int? ?? 1,
              id: entry['entity_id'] as String,
              title: entry['title'] as String,
              entityType: EntityType.audio,
              path: entry['path'] as String,
              format: entry['format'] as String,
              hash: entry['fingerprint'] as String,
              size: entry['size'] as int,
              modifiedAtMs: entry['modified_at_ms'] as int,
              durationMs: entry['duration_ms'] as int?,
            ))
        .toList(growable: false);
    return AudioPlaybackSession(
      id: id,
      name: row['name'] as String,
      sourceNodeId: row['source_node_id'] as String?,
      sourceNodeName: row['source_node_name'] as String?,
      mode: AudioPlaybackMode.values.firstWhere(
        (mode) => mode.name == row['mode'],
        orElse: () => AudioPlaybackMode.sequential,
      ),
      entries: entries,
      currentIndex: row['current_index'] as int,
      positionMs: row['position_ms'] as int,
      active: intToBool(row['active']),
      createdAtMs: row['created_at'] as int,
      updatedAtMs: row['updated_at'] as int,
      shuffleRemaining:
          _intListFromJson(row['shuffle_remaining_json'] as String?),
      history: _intListFromJson(row['history_json'] as String?),
    );
  }
}
