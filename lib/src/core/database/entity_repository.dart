part of 'library_repository.dart';

/// Entity CRUD, lookup, playback/reader state, and listing queries.
mixin EntityRepositoryMixin on LibraryRepositoryBase {
  EntityUpsertResult upsertEntity({
    required String path,
    required String name,
    required String format,
    required EntityType entityType,
    required String hash,
    required int size,
    required int sourceCreatedAtMs,
    required int sourceModifiedAtMs,
    String? contentExcerpt,
    int? durationMs,
    String? directoryRootId,
    String? localPath,
    Entity? knownExisting,
    bool existingLookupCompleted = false,
  }) {
    final normalizedPath = _normalizeEntityPath(path);
    final normalizedName = _normalizeEntityText(name, 'name');
    final normalizedFormat =
        _normalizeEntityText(format, 'format').toLowerCase();
    final normalizedHash = _normalizeEntityText(hash, 'hash');
    var normalizedPreview = _normalizeOptionalText(contentExcerpt);
    final normalizedLocalPath = localPath == null || localPath.trim().isEmpty
        ? null
        : p.normalize(localPath.trim());
    if (directoryRootId != null) {
      final root = _nodeById(directoryRootId);
      if (root?.nodeType != NodeType.directoryIndexRoot) {
        throw ArgumentError.value(
          directoryRootId,
          'directoryRootId',
          'must identify a directory index root',
        );
      }
    }
    _validateNonNegativeInt(size, 'size');
    _validateNonNegativeInt(sourceCreatedAtMs, 'sourceCreatedAtMs');
    _validateNonNegativeInt(sourceModifiedAtMs, 'sourceModifiedAtMs');
    if (durationMs != null) _validateNonNegativeInt(durationMs, 'durationMs');
    final existingRows = existingLookupCompleted || knownExisting != null
        ? const <Row>[]
        : database.db.select(
            'SELECT * FROM entities WHERE path = ? LIMIT 1',
            [normalizedPath],
          );
    final nextThumbnailStatus = _defaultThumbnailStatusFor(entityType);
    final existing = knownExisting ??
        (existingRows.isEmpty
            ? null
            : _entityFromRow(existingRows.first, thumbnailStore));
    if (existing != null) {
      normalizedPreview ??= existing.contentExcerpt;
      durationMs ??= existing.durationMs;
      final requiresRuntimePreview = !_hasGeneratedThumbnail(entityType);
      if (existing.hash == normalizedHash &&
          existing.name == normalizedName &&
          existing.contentExcerpt == normalizedPreview &&
          existing.entityType == entityType &&
          existing.format == normalizedFormat &&
          existing.size == size &&
          existing.durationMs == durationMs &&
          existing.directoryRootId == directoryRootId &&
          existing.localPath == normalizedLocalPath &&
          (!requiresRuntimePreview ||
              existing.thumbnailStatus == ThumbnailStatus.none)) {
        return EntityUpsertResult(
          entity: existing,
          status: EntityUpsertStatus.skipped,
        );
      }
      final now = nowMillis();
      final thumbnailReset = !requiresRuntimePreview &&
              existing.hash == normalizedHash &&
              existing.entityType == entityType
          ? existing.thumbnailStatus
          : nextThumbnailStatus;
      if (requiresRuntimePreview &&
          existing.thumbnailKey != null &&
          existing.thumbnailFormat != null) {
        final staleThumbnail = thumbnailStore.fileFor(
          existing.thumbnailKey!,
          existing.thumbnailFormat!,
        );
        if (staleThumbnail.existsSync()) staleThumbnail.deleteSync();
      }
      database.db.execute(
        '''
        UPDATE entities
        SET name = ?, format = ?, media_type = ?, hash = ?, metadata_preview = ?,
            thumbnail_status = ?, thumbnail_key = CASE WHEN ? = 'success' THEN thumbnail_key ELSE NULL END,
            thumbnail_format = CASE WHEN ? = 'success' THEN thumbnail_format ELSE NULL END,
            thumbnail_width = CASE WHEN ? = 'success' THEN thumbnail_width ELSE NULL END,
            thumbnail_height = CASE WHEN ? = 'success' THEN thumbnail_height ELSE NULL END,
            thumbnail_error = CASE WHEN ? = 'failed' THEN thumbnail_error ELSE NULL END,
            size = ?, source_created_at_ms = ?, source_modified_at_ms = ?, duration_ms = ?,
            directory_root_id = ?, local_path = ?, updated_at = ?
        WHERE id = ?
        ''',
        [
          normalizedName,
          normalizedFormat,
          entityType.value,
          normalizedHash,
          normalizedPreview,
          thumbnailReset.value,
          thumbnailReset.value,
          thumbnailReset.value,
          thumbnailReset.value,
          thumbnailReset.value,
          thumbnailReset.value,
          size,
          sourceCreatedAtMs,
          sourceModifiedAtMs,
          durationMs,
          directoryRootId,
          normalizedLocalPath,
          now,
          existing.id,
        ],
      );
      final thumbnailKey = thumbnailReset == ThumbnailStatus.success
          ? existing.thumbnailKey
          : null;
      final thumbnailFormat = thumbnailReset == ThumbnailStatus.success
          ? existing.thumbnailFormat
          : null;
      return EntityUpsertResult(
        entity: Entity(
          id: existing.id,
          path: normalizedPath,
          name: normalizedName,
          format: normalizedFormat,
          entityType: entityType,
          hash: normalizedHash,
          size: size,
          sourceCreatedAtMs: sourceCreatedAtMs,
          sourceModifiedAtMs: sourceModifiedAtMs,
          createdAtMs: existing.createdAtMs,
          updatedAtMs: now,
          contentExcerpt: normalizedPreview,
          thumbnailStatus: thumbnailReset,
          thumbnailKey: thumbnailKey,
          thumbnailFormat: thumbnailFormat,
          thumbnailWidth: thumbnailReset == ThumbnailStatus.success
              ? existing.thumbnailWidth
              : null,
          thumbnailHeight: thumbnailReset == ThumbnailStatus.success
              ? existing.thumbnailHeight
              : null,
          thumbnailError: thumbnailReset == ThumbnailStatus.failed
              ? existing.thumbnailError
              : null,
          thumbnailPath: thumbnailKey != null && thumbnailFormat != null
              ? thumbnailStore.pathFor(thumbnailKey, thumbnailFormat)
              : null,
          archived: existing.archived,
          lastOpenedAtMs: existing.lastOpenedAtMs,
          lastPositionMs: existing.lastPositionMs,
          durationMs: durationMs,
          readerScrollOffset: existing.readerScrollOffset,
          zoomScale: existing.zoomScale,
          extraStateJson: existing.extraStateJson,
          directoryRootId: directoryRootId,
          localPath: normalizedLocalPath,
        ),
        status: EntityUpsertStatus.updated,
      );
    }

    final now = nowMillis();
    final id = newId();
    database.db.execute(
      '''
      INSERT INTO entities
      (id, path, local_path, name, format, media_type, hash, metadata_preview,
       thumbnail_status, thumbnail_key, thumbnail_format, thumbnail_width, thumbnail_height, thumbnail_error, size,
       source_created_at_ms, source_modified_at_ms, duration_ms, directory_root_id, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        id,
        normalizedPath,
        normalizedLocalPath,
        normalizedName,
        normalizedFormat,
        entityType.value,
        normalizedHash,
        normalizedPreview,
        nextThumbnailStatus.value,
        null,
        null,
        null,
        null,
        null,
        size,
        sourceCreatedAtMs,
        sourceModifiedAtMs,
        durationMs,
        directoryRootId,
        now,
        now,
      ],
    );
    return EntityUpsertResult(
      entity: Entity(
        id: id,
        path: normalizedPath,
        name: normalizedName,
        format: normalizedFormat,
        entityType: entityType,
        hash: normalizedHash,
        size: size,
        sourceCreatedAtMs: sourceCreatedAtMs,
        sourceModifiedAtMs: sourceModifiedAtMs,
        createdAtMs: now,
        updatedAtMs: now,
        contentExcerpt: normalizedPreview,
        thumbnailStatus: nextThumbnailStatus,
        durationMs: durationMs,
        directoryRootId: directoryRootId,
        localPath: normalizedLocalPath,
      ),
      status: EntityUpsertStatus.inserted,
    );
  }

  void updateEntityMetadataPreview(
    String entityId,
    String? contentExcerpt,
    int? durationMs,
  ) {
    database.db.execute(
      '''
      UPDATE entities
      SET metadata_preview = ?, duration_ms = ?, updated_at = ?
      WHERE id = ?
      ''',
      [
        _normalizeOptionalText(contentExcerpt),
        durationMs,
        nowMillis(),
        entityId,
      ],
    );
  }

  /// Returns only EPUB records whose old build did not persist a text
  /// excerpt. This is intentionally independent from directory scanning so a
  /// renderer upgrade can repair previews without touching index membership.
  List<Entity> listEpubsMissingMetadataPreview({int limit = 200}) {
    final rows = database.db.select(
      '''
      SELECT * FROM entities
      WHERE archived = 0
        AND format = 'epub'
        AND (metadata_preview IS NULL OR trim(metadata_preview) = '')
      ORDER BY updated_at ASC, id ASC
      LIMIT ?
      ''',
      [limit],
    );
    return rows.map((row) => _entityFromRow(row, thumbnailStore)).toList();
  }

  /// SAF scans use a temporary local file only while extracting metadata and
  /// rendering previews. It must never become persistent entity state.
  void clearEntityLocalPath(String id) {
    database.db.execute(
      'UPDATE entities SET local_path = NULL WHERE id = ?',
      [id],
    );
  }


  Entity? getEntityByPath(String path) {
    final rows = database.db.select(
      'SELECT * FROM entities WHERE path = ? LIMIT 1',
      [_normalizeEntityPath(path)],
    );
    if (rows.isEmpty) return null;
    return _entityFromRow(rows.first, thumbnailStore);
  }

  /// Loads source entities in bounded batches so large scans avoid one lookup
  /// per file without exceeding SQLite's host-parameter limit.
  Map<String, Entity> getEntitiesByPaths(Iterable<String> paths) {
    final normalizedPaths =
        paths.map(_normalizeEntityPath).toSet().toList(growable: false);
    if (normalizedPaths.isEmpty) return const <String, Entity>{};
    final result = <String, Entity>{};
    const batchSize = 400;
    for (var offset = 0; offset < normalizedPaths.length; offset += batchSize) {
      final end = (offset + batchSize).clamp(0, normalizedPaths.length);
      final batch = normalizedPaths.sublist(offset, end);
      final placeholders = List<String>.filled(batch.length, '?').join(',');
      final rows = database.db.select(
        'SELECT * FROM entities WHERE path IN ($placeholders)',
        batch,
      );
      for (final row in rows) {
        final entity = _entityFromRow(row, thumbnailStore);
        result[entity.path] = entity;
      }
    }
    return Map<String, Entity>.unmodifiable(result);
  }

  Map<String, Entity> getEntitiesByIds(Iterable<String> entityIds) {
    final ids = entityIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const <String, Entity>{};
    final result = <String, Entity>{};
    const batchSize = 400;
    for (var offset = 0; offset < ids.length; offset += batchSize) {
      final end = (offset + batchSize).clamp(0, ids.length);
      final batch = ids.sublist(offset, end);
      final placeholders = List<String>.filled(batch.length, '?').join(',');
      final rows = database.db.select(
        'SELECT * FROM entities WHERE id IN ($placeholders)',
        batch,
      );
      for (final row in rows) {
        final entity = _entityFromRow(row, thumbnailStore);
        result[entity.id] = entity;
      }
    }
    return Map<String, Entity>.unmodifiable(result);
  }

  void updateEntityDuration(String entityId, int durationMs) {
    _validateNonNegativeInt(durationMs, 'durationMs');
    database.db.execute(
      '''
      UPDATE entities
      SET duration_ms = ?, updated_at = ?
      WHERE id = ?
      ''',
      [durationMs, nowMillis(), entityId],
    );
  }

  bool hasEntityForPath(String path) {
    final rows = database.db.select(
      'SELECT 1 FROM entities WHERE path = ? LIMIT 1',
      [_normalizeEntityPath(path)],
    );
    return rows.isNotEmpty;
  }

  void markOpened(String entityId) {
    _requireEntityExists(entityId);
    final now = nowMillis();
    _enqueueBackgroundWrite(
      'mark_opened',
      'UPDATE entities SET last_opened_at = ?, updated_at = ? WHERE id = ?',
      [now, now, entityId],
    );
  }

  void savePlaybackState({
    required String entityId,
    required int positionMs,
    required int durationMs,
  }) {
    _requireEntityExists(entityId);
    final safeDurationMs = durationMs < 0 ? 0 : durationMs;
    final safePositionMs = (positionMs < 0 ? 0 : positionMs)
        .clamp(
          0,
          safeDurationMs > 0 ? safeDurationMs : 0x7fffffffffffffff,
        )
        .toInt();
    _enqueueBackgroundWrite(
      'save_playback_state',
      '''
      UPDATE entities
      SET last_position_ms = ?, duration_ms = ?, updated_at = ?
      WHERE id = ?
      ''',
      [safePositionMs, safeDurationMs, nowMillis(), entityId],
    );
  }

  void saveReaderState({
    required String entityId,
    double? scrollOffset,
    double? zoomScale,
    String? extraStateJson,
  }) {
    _requireEntityExists(entityId);
    final safeScrollOffset =
        scrollOffset == null ? null : (scrollOffset < 0 ? 0.0 : scrollOffset);
    final safeZoomScale =
        zoomScale == null || zoomScale <= 0 ? null : zoomScale;
    _enqueueBackgroundWrite(
      'save_reader_state',
      '''
      UPDATE entities
      SET reader_scroll_offset = COALESCE(?, reader_scroll_offset),
          zoom_scale = COALESCE(?, zoom_scale),
          extra_state_json = COALESCE(?, extra_state_json),
          updated_at = ?
      WHERE id = ?
      ''',
      [safeScrollOffset, safeZoomScale, extraStateJson, nowMillis(), entityId],
    );
  }

  void removeEntityFromLibrary(String entityId) {
    writeTransaction(() {
      _markEntityPreviewDirty(entityId, reason: 'entity_deleted');
      database.db.execute('DELETE FROM entities WHERE id = ?', [entityId]);
    });
    rebuildIndexNodeStats();
  }

  void removeEntitiesFromLibrary(Iterable<String> entityIds) {
    final ids = entityIds.toList(growable: false);
    if (ids.isEmpty) return;
    writeTransaction(() {
      for (final entityId in ids) {
        _markEntityPreviewDirty(entityId, reason: 'entities_deleted');
        database.db.execute('DELETE FROM entities WHERE id = ?', [entityId]);
      }
    });
    rebuildIndexNodeStats();
  }

  List<EntityListItem> listRecentOpenedEntities({
    int limit = 12,
    Iterable<EntityType>? entityTypes,
  }) {
    final types = entityTypes?.map((type) => type.value).toSet().toList() ??
        const <String>[];
    final typePlaceholders = types.isEmpty
        ? ''
        : 'AND media_type IN (${List<String>.filled(types.length, '?').join(', ')})';
    final rows = database.db.select(
      '''
      SELECT * FROM entities
      WHERE archived = 0 AND last_opened_at IS NOT NULL
      $typePlaceholders
      ORDER BY last_opened_at DESC
      LIMIT ?
      ''',
      [...types, limit],
    );
    return rows.map((row) => _listItemFromRow(row, thumbnailStore)).toList();
  }

  List<EntityListItem> listRecentlyModifiedEntities({int limit = 12}) {
    final rows = database.db.select(
      '''
      SELECT * FROM entities
      WHERE archived = 0
      ORDER BY source_modified_at_ms DESC
      LIMIT ?
      ''',
      [limit],
    );
    return rows.map((row) => _listItemFromRow(row, thumbnailStore)).toList();
  }

  Set<String> entityIdsUnderDirectorySource(String sourcePath) {
    final rows = database.db.select(
      '''
      SELECT id FROM index_nodes
      WHERE node_type = ? AND source_path = ?
      LIMIT 1
      ''',
      [NodeType.directoryIndexRoot.value, _normalizeSourcePath(sourcePath)],
    );
    if (rows.isEmpty) return <String>{};
    return _entityIdsUnderNode(rows.first['id'] as String).toSet();
  }
}
