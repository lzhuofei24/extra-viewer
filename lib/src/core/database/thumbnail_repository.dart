part of 'library_repository.dart';

/// Thumbnail status transitions, batched updates, and asset file lifecycle.
mixin ThumbnailRepositoryMixin on LibraryRepositoryBase {
  void updateEntityThumbnailPending(String entityId) {
    database.db.execute(
      '''
      UPDATE entities
      SET thumbnail_status = ?, thumbnail_error = NULL, updated_at = ?
      WHERE id = ?
      ''',
      [ThumbnailStatus.pending.value, nowMillis(), entityId],
    );
  }

  /// Applies a bounded group of thumbnail state changes in one SQLite savepoint.
  /// Scanner workers use this path so thumbnail throughput is not limited by
  /// per-file transactions.
  void applyThumbnailUpdates(Iterable<ThumbnailDatabaseUpdate> updates) {
    final batch = updates.toList(growable: false);
    if (batch.isEmpty) return;
    final now = nowMillis();
    writeTransaction(() {
      for (final update in batch) {
        switch (update.type) {
          case ThumbnailUpdateType.pending:
            database.db.execute(
              'UPDATE entities SET thumbnail_status = ?, thumbnail_error = NULL, updated_at = ? WHERE id = ?',
              [ThumbnailStatus.pending.value, now, update.entityId],
            );
          case ThumbnailUpdateType.success:
            database.db.execute(
              '''
              UPDATE entities SET thumbnail_status = ?, thumbnail_key = ?, thumbnail_format = ?,
                thumbnail_width = ?, thumbnail_height = ?, thumbnail_error = NULL,
                duration_ms = COALESCE(?, duration_ms), updated_at = ? WHERE id = ?
              ''',
              [
                ThumbnailStatus.success.value,
                update.key,
                update.format,
                update.width,
                update.height,
                update.durationMs,
                now,
                update.entityId,
              ],
            );
          case ThumbnailUpdateType.failed:
            database.db.execute(
              '''
              UPDATE entities SET thumbnail_status = ?, thumbnail_error = ?, thumbnail_key = NULL,
                thumbnail_format = NULL, thumbnail_width = NULL, thumbnail_height = NULL,
                updated_at = ? WHERE id = ?
              ''',
              [
                ThumbnailStatus.failed.value,
                update.error?.trim(),
                now,
                update.entityId,
              ],
            );
          case ThumbnailUpdateType.none:
            database.db.execute(
              '''
              UPDATE entities SET thumbnail_status = ?, thumbnail_key = NULL, thumbnail_format = NULL,
                thumbnail_width = NULL, thumbnail_height = NULL, thumbnail_error = NULL,
                updated_at = ? WHERE id = ?
              ''',
              [ThumbnailStatus.none.value, now, update.entityId],
            );
        }
      }
    });
  }


  void updateEntityThumbnailSuccess({
    required String entityId,
    required String key,
    required String format,
    required int width,
    required int height,
  }) {
    database.db.execute(
      '''
      UPDATE entities
      SET thumbnail_status = ?, thumbnail_key = ?, thumbnail_format = ?,
          thumbnail_width = ?, thumbnail_height = ?, thumbnail_error = NULL,
          updated_at = ?
      WHERE id = ?
      ''',
      [
        ThumbnailStatus.success.value,
        key,
        format,
        width,
        height,
        nowMillis(),
        entityId,
      ],
    );
  }

  void updateEntityThumbnailFailed(String entityId, String error) {
    database.db.execute(
      '''
      UPDATE entities
      SET thumbnail_status = ?, thumbnail_error = ?, thumbnail_key = NULL,
          thumbnail_format = NULL, thumbnail_width = NULL, thumbnail_height = NULL,
          updated_at = ?
      WHERE id = ?
      ''',
      [ThumbnailStatus.failed.value, error.trim(), nowMillis(), entityId],
    );
  }

  void updateEntityThumbnailNone(String entityId) {
    database.db.execute(
      '''
      UPDATE entities
      SET thumbnail_status = ?, thumbnail_key = NULL, thumbnail_format = NULL,
          thumbnail_width = NULL, thumbnail_height = NULL, thumbnail_error = NULL,
          updated_at = ?
      WHERE id = ?
      ''',
      [ThumbnailStatus.none.value, nowMillis(), entityId],
    );
  }

  void recordThumbnailAsset({
    required String key,
    required String format,
    required int byteSize,
  }) {
    _enqueueBackgroundWrite(
      'record_thumbnail_asset',
      '''
      INSERT INTO thumbnail_assets(asset_key, format, byte_size, created_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(asset_key) DO UPDATE SET
        format = excluded.format,
        byte_size = excluded.byte_size,
        created_at = excluded.created_at
      ''',
      [key, format, byteSize < 0 ? 0 : byteSize, nowMillis()],
    );
  }

  ThumbnailPreloadPage listThumbnailPreloadPageUnderNode(
    String? indexNodeId, {
    String? afterEntityId,
    bool recursive = false,
    int limit = 240,
  }) {
    if (indexNodeId == null) {
      return const ThumbnailPreloadPage(paths: []);
    }
    final safeLimit = limit.clamp(1, 500).toInt();
    final rows = recursive
        ? database.db.select('''
            WITH RECURSIVE subtree(id) AS (
              SELECT ?
              UNION ALL
              SELECT node.id FROM index_nodes node
              JOIN subtree parent ON node.parent_id = parent.id
            ), entity_ids AS (
              SELECT link.entity_id AS id
              FROM index_node_entities link
              JOIN subtree ON subtree.id = link.index_node_id
              GROUP BY link.entity_id
            )
            SELECT entity.id, entity.thumbnail_key, entity.thumbnail_format
            FROM entity_ids
            JOIN entities entity ON entity.id = entity_ids.id
            WHERE entity.archived = 0
              AND entity.thumbnail_status = 'success'
              AND entity.thumbnail_key IS NOT NULL
              AND entity.thumbnail_format IS NOT NULL
              AND (? IS NULL OR entity.id > ?)
            ORDER BY entity.id ASC
            LIMIT ?
          ''', [indexNodeId, afterEntityId, afterEntityId, safeLimit + 1])
        : database.db.select('''
            SELECT entity.id, entity.thumbnail_key, entity.thumbnail_format
            FROM index_node_entities link
            JOIN entities entity ON entity.id = link.entity_id
            WHERE link.index_node_id = ?
              AND entity.archived = 0
              AND entity.thumbnail_status = 'success'
              AND entity.thumbnail_key IS NOT NULL
              AND entity.thumbnail_format IS NOT NULL
              AND (? IS NULL OR entity.id > ?)
            ORDER BY entity.id ASC
            LIMIT ?
          ''', [indexNodeId, afterEntityId, afterEntityId, safeLimit + 1]);
    final hasMore = rows.length > safeLimit;
    final visible = hasMore ? rows.sublist(0, safeLimit) : rows;
    return ThumbnailPreloadPage(
      paths: visible
          .map((row) => thumbnailStore.pathFor(
                row['thumbnail_key'] as String,
                row['thumbnail_format'] as String,
              ))
          .toList(growable: false),
      nextEntityId: hasMore ? visible.last['id'] as String : null,
    );
  }

  Map<String, List<String>> listDirectThumbnailPathsUnderRoot(String rootId) {
    final rows = database.db.select(
      '''
      WITH RECURSIVE subtree(id) AS (
        SELECT ?
        UNION ALL
        SELECT child.id
        FROM index_nodes child
        JOIN subtree ON child.parent_id = subtree.id
      )
      SELECT link.index_node_id, entity.thumbnail_key, entity.thumbnail_format
      FROM index_node_entities link
      JOIN entities entity ON entity.id = link.entity_id
      WHERE link.index_node_id IN (SELECT id FROM subtree)
        AND entity.archived = 0
        AND entity.thumbnail_status = 'success'
        AND entity.thumbnail_key IS NOT NULL
        AND entity.thumbnail_format IS NOT NULL
      ORDER BY entity.source_modified_at_ms DESC, entity.id
      ''',
      [rootId],
    );
    final result = <String, List<String>>{};
    for (final row in rows) {
      final nodeId = row['index_node_id'] as String;
      final paths = result.putIfAbsent(nodeId, () => <String>[]);
      if (paths.length >= 4) continue;
      final path = thumbnailStore.pathFor(
        row['thumbnail_key'] as String,
        row['thumbnail_format'] as String,
      );
      if (File(path).existsSync()) paths.add(path);
    }
    return result;
  }
}
