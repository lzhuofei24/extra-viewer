part of 'library_repository.dart';

/// Thumbnail status transitions, batched updates, and asset file lifecycle.
mixin ThumbnailRepositoryMixin on LibraryRepositoryBase {
  EntityPreviewTicket beginEntityPreview(Entity entity) => writeTransaction(() {
        final rows = database.db.select(
            'SELECT source_revision, preview_revision, hash, size FROM entity_details WHERE id = ?',
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
            "UPDATE entity_previews SET preview_revision = ?, thumbnail_status = 'pending', thumbnail_error = NULL WHERE entity_id = ?",
            [revision, entity.id]);
        // Register before writing, so a crash leaves a reclaimable, unreferenced file.
        _retirePreviewAsset('entity', ticket.assetKey, 'webp');
        return ticket;
      });

  bool commitEntityPreview(
          EntityPreviewTicket ticket, ThumbnailDatabaseUpdate update,
          {int byteSize = 0, bool markNodePreviewDirty = true}) =>
      writeTransaction(() => _commitEntityPreviewInTransaction(ticket, update,
          byteSize: byteSize, markNodePreviewDirty: markNodePreviewDirty));

  Map<String, bool> commitEntityPreviewBatch(
      Iterable<PreparedEntityPreview> previews,
      {bool markNodePreviewDirty = false}) {
    final values = previews.toList(growable: false);
    if (values.isEmpty) return const {};
    return writeTransaction(() => {
          for (final preview in values)
            preview.ticket.entityId: _commitEntityPreviewInTransaction(
                preview.ticket, preview.update,
                byteSize: preview.byteSize,
                markNodePreviewDirty: markNodePreviewDirty),
        });
  }

  bool _commitEntityPreviewInTransaction(
      EntityPreviewTicket ticket, ThumbnailDatabaseUpdate update,
      {int byteSize = 0, bool markNodePreviewDirty = true}) {
    if (update.entityId != ticket.entityId ||
        update.type == ThumbnailUpdateType.pending) {
      throw ArgumentError('Invalid preview result');
    }
    final rows = database.db.select(
        'SELECT thumbnail_key, thumbnail_format FROM entity_details WHERE id = ? AND source_revision = ? AND preview_revision = ?',
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
        registerPreviewAsset(
            database.db, ticket.assetKey, 'entity', 'webp80-area360000-v7', {
          'thumbnail': (
            path: thumbnailStore.pathFor(ticket.assetKey, 'webp'),
            width: update.width,
            height: update.height
          )
        });
        database.db.execute('''
          UPDATE entity_previews SET thumbnail_status = 'success', thumbnail_key = ?, thumbnail_format = 'webp',
            thumbnail_width = ?, thumbnail_height = ?, thumbnail_error = NULL,
            updated_at = ? WHERE entity_id = ?
        ''', [
          ticket.assetKey,
          update.width,
          update.height,
          nowMillis(),
          ticket.entityId
        ]);
        if (update.durationMs != null) {
          database.db.execute('UPDATE entities SET duration_ms=? WHERE id=?',
              [update.durationMs, ticket.entityId]);
        }
        database.db.execute(
            "DELETE FROM retired_preview_assets WHERE kind = 'entity' AND asset_key = ?",
            [ticket.assetKey]);
      case ThumbnailUpdateType.failed:
        database.db.execute(
            "UPDATE entity_previews SET thumbnail_status = 'failed', thumbnail_error = ?, updated_at = ? WHERE entity_id = ?",
            [update.error, nowMillis(), ticket.entityId]);
        return true;
      case ThumbnailUpdateType.none:
        database.db.execute('''
          UPDATE entity_previews SET thumbnail_status = 'none', thumbnail_key = NULL, thumbnail_format = NULL,
            thumbnail_width = NULL, thumbnail_height = NULL, thumbnail_error = NULL, updated_at = ? WHERE entity_id = ?
        ''', [nowMillis(), ticket.entityId]);
      case ThumbnailUpdateType.pending:
        throw StateError('Use beginEntityPreview');
    }
    if (oldKey != null && oldFormat != null && oldKey != ticket.assetKey) {
      _retirePreviewAsset('entity', oldKey, oldFormat);
    }
    if (markNodePreviewDirty) {
      for (final row in database.db.select(
          '''SELECT index_node_id FROM index_node_entities WHERE entity_id = ?
              UNION SELECT node_id FROM node_preview_override_items WHERE entity_id = ?''',
          [ticket.entityId, ticket.entityId])) {
        markIndexNodePreviewDirty(row['index_node_id'] as String,
            reason: 'entity_preview_published');
      }
    }
    return true;
  }
}
