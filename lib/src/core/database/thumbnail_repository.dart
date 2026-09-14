part of 'library_repository.dart';

/// Thumbnail status transitions, batched updates, and asset file lifecycle.
mixin ThumbnailRepositoryMixin on LibraryRepositoryBase {
  EntityPreviewTicket beginEntityPreview(Entity entity) => writeTransaction(() {
        final rows = database.db.select(
            'SELECT source_revision, preview_revision, hash, size FROM entities WHERE id = ?',
            [entity.id]);
        if (rows.isEmpty ||
            rows.single['source_revision'] != entity.sourceRevision ||
            rows.single['hash'] != entity.hash ||
            rows.single['size'] != entity.size) {
          throw StateError('Entity changed before preview generation');
        }
        final revision = (rows.single['preview_revision'] as int) + 1;
        final digest = sha256.convert(utf8.encode(
            '${entity.id}|${entity.sourceRevision}|$revision|webp80-area360000-v7'));
        final ticket = EntityPreviewTicket(
            entityId: entity.id,
            sourceRevision: entity.sourceRevision,
            previewRevision: revision,
            assetKey: 'v7_$digest');
        database.db.execute(
            "UPDATE entities SET preview_revision = ?, thumbnail_status = 'pending', thumbnail_error = NULL WHERE id = ?",
            [revision, entity.id]);
        // Register before writing, so a crash leaves a reclaimable, unreferenced file.
        _retirePreviewAsset('entity', ticket.assetKey, 'webp');
        return ticket;
      });

  bool commitEntityPreview(
          EntityPreviewTicket ticket, ThumbnailDatabaseUpdate update,
          {int byteSize = 0}) =>
      writeTransaction(() {
        if (update.entityId != ticket.entityId ||
            update.type == ThumbnailUpdateType.pending) {
          throw ArgumentError('Invalid preview result');
        }
        final rows = database.db.select(
            'SELECT thumbnail_key, thumbnail_format FROM entities WHERE id = ? AND source_revision = ? AND preview_revision = ?',
            [ticket.entityId, ticket.sourceRevision, ticket.previewRevision]);
        if (rows.isEmpty) return false;
        final oldKey = rows.single['thumbnail_key'] as String?;
        final oldFormat = rows.single['thumbnail_format'] as String?;
        switch (update.type) {
          case ThumbnailUpdateType.success:
            if (update.key != ticket.assetKey ||
                update.format != 'webp' ||
                (update.width ?? 0) <= 0 ||
                (update.height ?? 0) <= 0 ||
                byteSize <= 0 ||
                thumbnailStore.fileFor(ticket.assetKey, 'webp').lengthSync() !=
                    byteSize) {
              throw StateError('Preview file is not ready to publish');
            }
            database.db.execute('''
          INSERT OR IGNORE INTO thumbnail_assets(asset_key, format, byte_size, created_at)
          VALUES (?, 'webp', ?, ?)
        ''', [ticket.assetKey, byteSize, nowMillis()]);
            database.db.execute('''
          UPDATE entities SET thumbnail_status = 'success', thumbnail_key = ?, thumbnail_format = 'webp',
            thumbnail_width = ?, thumbnail_height = ?, thumbnail_error = NULL,
            duration_ms = COALESCE(?, duration_ms), updated_at = ? WHERE id = ?
        ''', [
              ticket.assetKey,
              update.width,
              update.height,
              update.durationMs,
              nowMillis(),
              ticket.entityId
            ]);
            database.db.execute(
                "DELETE FROM retired_preview_assets WHERE kind = 'entity' AND asset_key = ?",
                [ticket.assetKey]);
          case ThumbnailUpdateType.failed:
            database.db.execute(
                "UPDATE entities SET thumbnail_status = 'failed', thumbnail_error = ?, updated_at = ? WHERE id = ?",
                [update.error, nowMillis(), ticket.entityId]);
            return true;
          case ThumbnailUpdateType.none:
            database.db.execute('''
          UPDATE entities SET thumbnail_status = 'none', thumbnail_key = NULL, thumbnail_format = NULL,
            thumbnail_width = NULL, thumbnail_height = NULL, thumbnail_error = NULL, updated_at = ? WHERE id = ?
        ''', [nowMillis(), ticket.entityId]);
          case ThumbnailUpdateType.pending:
            throw StateError('Use beginEntityPreview');
        }
        if (oldKey != null && oldFormat != null && oldKey != ticket.assetKey) {
          _retirePreviewAsset('entity', oldKey, oldFormat);
        }
        for (final row in database.db.select(
            'SELECT index_node_id FROM index_node_entities WHERE entity_id = ?',
            [ticket.entityId])) {
          markIndexNodePreviewDirty(row['index_node_id'] as String,
              reason: 'entity_preview_published');
        }
        return true;
      });

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
