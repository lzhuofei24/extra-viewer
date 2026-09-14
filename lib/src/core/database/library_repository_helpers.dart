part of 'library_repository.dart';

String _indexNodeOrderBy(EntitySortMode sortMode) => switch (sortMode) {
      EntitySortMode.modifiedDesc =>
        'node.updated_at DESC, node.name COLLATE NOCASE ASC, node.id ASC',
      EntitySortMode.nameAsc => 'node.name COLLATE NOCASE ASC, node.id ASC',
      EntitySortMode.nameDesc => 'node.name COLLATE NOCASE DESC, node.id ASC',
      EntitySortMode.sizeDesc =>
        'COALESCE(stats.descendant_entity_count, 0) DESC, '
            'node.name COLLATE NOCASE ASC, node.id ASC',
      EntitySortMode.sizeAsc =>
        'COALESCE(stats.descendant_entity_count, 0) ASC, '
            'node.name COLLATE NOCASE ASC, node.id ASC',
      EntitySortMode.modifiedAsc =>
        'node.updated_at ASC, node.name COLLATE NOCASE ASC, node.id ASC',
      EntitySortMode.typeAsc =>
        'node.node_type ASC, node.name COLLATE NOCASE ASC, node.id ASC',
    };

List<int> _intListFromJson(String? value) {
  try {
    final decoded = jsonDecode(value ?? '[]');
    return decoded is List
        ? decoded.whereType<num>().map((item) => item.toInt()).toList()
        : const [];
  } catch (_) {
    return const [];
  }
}

Entity _entityFromRow(Row row, [ThumbnailStore? thumbnailStore]) {
  final thumbnailStatus =
      ThumbnailStatus.fromValue(row['thumbnail_status'] as String? ?? 'none');
  final thumbnailKey = row['thumbnail_key'] as String?;
  final thumbnailFormat = row['thumbnail_format'] as String?;
  return Entity(
    id: row['id'] as String,
    path: row['path'] as String,
    localPath: row['local_path'] as String?,
    name: row['name'] as String,
    format: row['format'] as String,
    entityType: EntityType.fromValue(row['media_type'] as String),
    hash: row['hash'] as String,
    size: row['size'] as int,
    sourceCreatedAtMs: row['source_created_at_ms'] as int,
    sourceModifiedAtMs: row['source_modified_at_ms'] as int,
    createdAtMs: row['created_at'] as int,
    updatedAtMs: row['updated_at'] as int,
    contentExcerpt: row['metadata_preview'] as String?,
    thumbnailStatus: thumbnailStatus,
    sourceRevision: row['source_revision'] as int? ?? 1,
    previewRevision: row['preview_revision'] as int? ?? 1,
    thumbnailKey: thumbnailKey,
    thumbnailFormat: thumbnailFormat,
    thumbnailWidth: row['thumbnail_width'] as int?,
    thumbnailHeight: row['thumbnail_height'] as int?,
    thumbnailError: row['thumbnail_error'] as String?,
    thumbnailPath: thumbnailKey != null &&
            thumbnailFormat != null &&
            thumbnailKey.isNotEmpty &&
            thumbnailFormat.isNotEmpty
        ? thumbnailStore?.pathFor(thumbnailKey, thumbnailFormat)
        : null,
    archived: intToBool(row['archived']),
    lastOpenedAtMs: row['last_opened_at'] as int?,
    lastPositionMs: row['last_position_ms'] as int?,
    durationMs: row['duration_ms'] as int?,
    readerScrollOffset: row['reader_scroll_offset'] as double?,
    zoomScale: row['zoom_scale'] as double?,
    extraStateJson: row['extra_state_json'] as String?,
    directoryRootId: row['directory_root_id'] as String?,
  );
}

IndexNode _nodeFromRow(Row row) {
  return IndexNode(
    id: row['id'] as String,
    parentId: row['parent_id'] as String?,
    name: row['name'] as String,
    nodeType: NodeType.fromValue(row['node_type'] as String),
    viewType: ViewType.fromValue(row['view_type'] as String),
    sourcePath: row['source_path'] as String?,
    previewJson: row['preview_json'] as String?,
    sortOrder: row['sort_order'] as int,
    createdAtMs: row['created_at'] as int,
    updatedAtMs: row['updated_at'] as int,
    lastBuiltAtMs: row['last_built_at_ms'] as int?,
    isStaging: (row['is_staging'] as int? ?? 0) != 0,
  );
}

IndexNodePreviewTile _representativePreviewTile(
  IndexNode node,
  List<EntityListItem> entities,
) {
  final visuals = entities
      .where((entity) =>
          entity.entityType == EntityType.image ||
          entity.entityType == EntityType.video)
      .toList(growable: false);
  if (visuals.isNotEmpty) return _visualPreviewTile(visuals.first);
  final audioNames = entities
      .where((entity) => entity.entityType == EntityType.audio)
      .map(_nodePreviewAudioTitle)
      .toList(growable: false);
  final documentNames = entities
      .where(_isTextDataPreviewEntity)
      .map((entity) => entity.title)
      .toList(growable: false);
  if (audioNames.isNotEmpty && documentNames.isNotEmpty) {
    return IndexNodePreviewTile(
      kind: IndexNodePreviewTileKind.mixedData,
      title: node.name,
      audioNames: audioNames,
      documentNames: documentNames,
    );
  }
  if (audioNames.isNotEmpty) {
    return IndexNodePreviewTile(
      kind: IndexNodePreviewTileKind.audio,
      title: node.name,
      audioNames: audioNames,
    );
  }
  if (documentNames.isNotEmpty) {
    return IndexNodePreviewTile(
      kind: IndexNodePreviewTileKind.document,
      title: node.name,
      documentNames: documentNames,
    );
  }
  return IndexNodePreviewTile(
      kind: IndexNodePreviewTileKind.node, title: node.name);
}

IndexNodePreviewTile? _representativePreviewTileFromCache(
  IndexNode node, [
  ThumbnailStore? thumbnailStore,
]) {
  final json = node.previewJson;
  if (json == null || json.isEmpty) return null;
  try {
    final value = jsonDecode(json);
    if (value is! Map<String, dynamic>) return null;
    final kind =
        IndexNodePreviewTileKind.values.byName(value['kind'] as String);
    final key = value['thumbnailKey'] as String?;
    final format = value['thumbnailFormat'] as String?;
    final path = key != null && format != null && thumbnailStore != null
        ? thumbnailStore.pathFor(key, format)
        : null;
    return IndexNodePreviewTile(
      kind: kind,
      title: value['title'] as String? ?? node.name,
      thumbnailPath: path,
      thumbnailKey: key,
      thumbnailFormat: format,
      entityId: value['entityId'] as String?,
      nodeId: value['nodeId'] as String?,
      aspectRatio: (value['aspectRatio'] as num?)?.toDouble() ?? 1,
      audioNames:
          (value['audioNames'] as List?)?.whereType<String>().toList() ??
              const [],
      documentNames:
          (value['documentNames'] as List?)?.whereType<String>().toList() ??
              const [],
    );
  } catch (_) {
    return null;
  }
}

List<IndexNodePreviewTile> _previewOverrideTiles(String value) {
  try {
    final decoded = jsonDecode(value);
    if (decoded is! List) return const [];
    return decoded.take(4).whereType<Map>().map((raw) {
      final item = Map<String, dynamic>.from(raw);
      return IndexNodePreviewTile(
        kind: IndexNodePreviewTileKind.values.byName(item['kind'] as String),
        title: item['title'] as String? ?? '',
        thumbnailKey: item['thumbnailKey'] as String?,
        thumbnailFormat: item['thumbnailFormat'] as String?,
        entityId: item['entityId'] as String?,
        nodeId: item['nodeId'] as String?,
        aspectRatio: (item['aspectRatio'] as num?)?.toDouble() ?? 1,
        audioNames:
            (item['audioNames'] as List?)?.whereType<String>().toList() ??
                const [],
        documentNames:
            (item['documentNames'] as List?)?.whereType<String>().toList() ??
                const [],
      );
    }).toList(growable: false);
  } catch (_) {
    return const [];
  }
}

String? _previewTileToJson(IndexNodePreviewTile? tile) {
  if (tile == null) return null;
  return jsonEncode({
    'kind': tile.kind.name,
    'title': tile.title,
    'thumbnailKey': tile.thumbnailKey,
    'thumbnailFormat': tile.thumbnailFormat,
    'entityId': tile.entityId,
    'nodeId': tile.nodeId,
    'aspectRatio': tile.aspectRatio,
    'audioNames': tile.audioNames,
    'documentNames': tile.documentNames,
  });
}

IndexNodePreviewTile? _selectRepresentativePreviewTile(
  IndexNode node,
  List<EntityListItem> entities,
  List<IndexNodePreviewTile> childRepresentatives,
) {
  final visuals = entities
      .where((entity) =>
          entity.entityType == EntityType.image ||
          entity.entityType == EntityType.video)
      .toList(growable: false);
  if (visuals.isNotEmpty) return _visualPreviewTile(visuals.first);
  for (final child in childRepresentatives) {
    if (child.kind == IndexNodePreviewTileKind.visual) return child;
  }
  final direct = _representativePreviewTile(node, entities);
  if (direct.kind != IndexNodePreviewTileKind.node) return direct;
  return childRepresentatives.isEmpty ? direct : childRepresentatives.first;
}

IndexNodePreview _buildIndexNodePreview({
  required String nodeId,
  required List<IndexNodePreviewTile> childTiles,
  required List<EntityListItem> entities,
}) {
  final visuals = entities
      .where((entity) =>
          entity.entityType == EntityType.image ||
          entity.entityType == EntityType.video)
      .map(_visualPreviewTile)
      .toList(growable: false);
  final audioNames = entities
      .where((entity) => entity.entityType == EntityType.audio)
      .map(_nodePreviewAudioTitle)
      .toList(growable: true);
  final documentNames = entities
      .where(_isTextDataPreviewEntity)
      .map((entity) => entity.title)
      .toList(growable: true);
  for (final tile in childTiles) {
    switch (tile.kind) {
      case IndexNodePreviewTileKind.audio:
        audioNames.addAll(tile.audioNames);
      case IndexNodePreviewTileKind.document:
        documentNames.addAll(tile.documentNames);
      case IndexNodePreviewTileKind.mixedData:
        audioNames.addAll(tile.audioNames);
        documentNames.addAll(tile.documentNames);
      case IndexNodePreviewTileKind.visual || IndexNodePreviewTileKind.node:
        break;
    }
  }
  final distinctAudioNames = _distinctPreviewNames(audioNames);
  final distinctDocumentNames = _distinctPreviewNames(documentNames);
  final hasSemanticData =
      distinctAudioNames.isNotEmpty || distinctDocumentNames.isNotEmpty;
  final visualCandidates = <IndexNodePreviewTile>[
    ...childTiles.where((tile) => tile.kind == IndexNodePreviewTileKind.visual),
    ...visuals,
  ]..sort(
      childTiles.isEmpty
          ? (left, right) => left.title.compareTo(right.title)
          : _compareNodePreviewVisualTiles,
    );

  if (visualCandidates.isEmpty) {
    if (distinctAudioNames.isEmpty && distinctDocumentNames.isEmpty) {
      return IndexNodePreview(nodeId: nodeId, kind: IndexNodePreviewKind.empty);
    }
    if (distinctAudioNames.isNotEmpty && distinctDocumentNames.isNotEmpty) {
      return IndexNodePreview(
        nodeId: nodeId,
        kind: IndexNodePreviewKind.splitLists,
        audioNames: distinctAudioNames,
        documentNames: distinctDocumentNames,
      );
    }
    return IndexNodePreview(
      nodeId: nodeId,
      kind: distinctAudioNames.isNotEmpty
          ? IndexNodePreviewKind.audioList
          : IndexNodePreviewKind.documentList,
      audioNames: distinctAudioNames,
      documentNames: distinctDocumentNames,
    );
  }

  if (childTiles.isEmpty && !hasSemanticData) {
    return IndexNodePreview(
      nodeId: nodeId,
      kind: IndexNodePreviewKind.singleVisual,
      tiles: [visualCandidates.first],
    );
  }
  final tiles = <IndexNodePreviewTile>[];
  if (hasSemanticData) {
    tiles.add(IndexNodePreviewTile(
      kind: distinctAudioNames.isNotEmpty && distinctDocumentNames.isNotEmpty
          ? IndexNodePreviewTileKind.mixedData
          : distinctAudioNames.isNotEmpty
              ? IndexNodePreviewTileKind.audio
              : IndexNodePreviewTileKind.document,
      title: '资料',
      audioNames: distinctAudioNames,
      documentNames: distinctDocumentNames,
    ));
  }
  final selectedVisuals =
      visualCandidates.take(hasSemanticData ? 3 : 4).toList(growable: false);
  tiles.addAll(selectedVisuals);
  return IndexNodePreview(
    nodeId: nodeId,
    kind: IndexNodePreviewKind.visualGrid,
    tiles: tiles,
  );
}

List<String> _distinctPreviewNames(Iterable<String> values) {
  final seen = <String>{};
  return [
    for (final value in values)
      if (value.trim().isNotEmpty && seen.add(value)) value,
  ];
}

IndexNodePreview _withNodePreviewAsset(
  IndexNodePreview preview,
  ({String path, double aspectRatio})? asset,
) {
  if (preview.kind != IndexNodePreviewKind.singleVisual &&
      preview.kind != IndexNodePreviewKind.visualGrid) {
    return preview;
  }
  return IndexNodePreview(
    nodeId: preview.nodeId,
    kind: preview.kind,
    tiles: preview.tiles,
    audioNames: preview.audioNames,
    documentNames: preview.documentNames,
    customOrderTopToBottom: preview.customOrderTopToBottom,
    visualAssetPath: asset?.path,
    visualAssetAspectRatio: asset?.aspectRatio,
  );
}

int _compareNodePreviewVisualTiles(
  IndexNodePreviewTile left,
  IndexNodePreviewTile right,
) {
  final leftRank = _nodePreviewVisualAspectRank(left.aspectRatio);
  final rightRank = _nodePreviewVisualAspectRank(right.aspectRatio);
  if (leftRank != rightRank) return leftRank.compareTo(rightRank);
  return left.title.compareTo(right.title);
}

int _nodePreviewVisualAspectRank(double aspectRatio) {
  if (aspectRatio < .95) return 0;
  if (aspectRatio <= 1.05) return 1;
  return 2;
}

IndexNodePreviewTile _visualPreviewTile(EntityListItem entity) =>
    IndexNodePreviewTile(
      kind: IndexNodePreviewTileKind.visual,
      title: entity.title,
      thumbnailPath: entity.thumbnailPath,
      thumbnailKey: entity.thumbnailKey,
      thumbnailFormat: entity.thumbnailFormat,
      entityId: entity.id,
      aspectRatio: _nodePreviewAspectRatio(entity),
    );

IndexNodePreviewTile _resolvePreviewOverrideTile(
  IndexNodePreviewTile tile,
  Map<String, EntityListItem> entities,
  Map<String, IndexNode> nodes,
  ThumbnailStore thumbnailStore,
) {
  final entityId = tile.entityId;
  if (entityId != null) {
    final entity = entities[entityId];
    if (entity != null) {
      return switch (entity.entityType) {
        EntityType.image || EntityType.video => _visualPreviewTile(entity),
        EntityType.audio => IndexNodePreviewTile(
            kind: IndexNodePreviewTileKind.audio,
            title: entity.title,
            entityId: entity.id,
            audioNames: [_nodePreviewAudioTitle(entity)],
          ),
        EntityType.text || EntityType.document => IndexNodePreviewTile(
            kind: IndexNodePreviewTileKind.document,
            title: entity.title,
            entityId: entity.id,
            documentNames: [entity.title],
          ),
      };
    }
  }
  final nodeId = tile.nodeId;
  if (nodeId != null) {
    final node = nodes[nodeId];
    if (node != null) {
      final representative =
          _representativePreviewTileFromCache(node, thumbnailStore);
      if (representative != null) {
        return IndexNodePreviewTile(
          kind: representative.kind,
          title: representative.title,
          thumbnailPath: representative.thumbnailPath,
          thumbnailKey: representative.thumbnailKey,
          thumbnailFormat: representative.thumbnailFormat,
          entityId: representative.entityId,
          nodeId: nodeId,
          aspectRatio: representative.aspectRatio,
          audioNames: representative.audioNames,
          documentNames: representative.documentNames,
        );
      }
      return IndexNodePreviewTile(
        kind: IndexNodePreviewTileKind.node,
        title: node.name,
        nodeId: nodeId,
      );
    }
  }
  return tile;
}

IndexNodePreview _buildOverrideIndexNodePreview({
  required String nodeId,
  required List<IndexNodePreviewTile> tiles,
}) {
  final audioNames = _distinctPreviewNames(
    tiles.expand((tile) => tile.audioNames),
  );
  final documentNames = _distinctPreviewNames(
    tiles.expand((tile) => tile.documentNames),
  );
  final hasVisual =
      tiles.any((tile) => tile.kind == IndexNodePreviewTileKind.visual);
  if (!hasVisual) {
    if (audioNames.isNotEmpty && documentNames.isNotEmpty) {
      return IndexNodePreview(
        nodeId: nodeId,
        kind: IndexNodePreviewKind.splitLists,
        audioNames: audioNames,
        documentNames: documentNames,
        customOrderTopToBottom: true,
      );
    }
    return IndexNodePreview(
      nodeId: nodeId,
      kind: audioNames.isNotEmpty
          ? IndexNodePreviewKind.audioList
          : IndexNodePreviewKind.documentList,
      audioNames: audioNames,
      documentNames: documentNames,
      customOrderTopToBottom: true,
    );
  }
  return IndexNodePreview(
    nodeId: nodeId,
    kind: IndexNodePreviewKind.visualGrid,
    tiles: tiles,
    audioNames: audioNames,
    documentNames: documentNames,
    customOrderTopToBottom: true,
  );
}

double _nodePreviewAspectRatio(EntityListItem entity) {
  final width = entity.thumbnailWidth;
  final height = entity.thumbnailHeight;
  if (width == null || height == null || width <= 0 || height <= 0) return 1;
  return width / height;
}

bool _isTextDataPreviewEntity(EntityListItem entity) {
  if (entity.entityType == EntityType.text) return true;
  return switch (entity.format.trim().toLowerCase()) {
    'epub' || 'pdf' || 'docx' || 'txt' || 'md' => true,
    _ => false,
  };
}

String _nodePreviewAudioTitle(EntityListItem entity) {
  final title = entity.title.trim();
  final extension = p.extension(title);
  return extension.isEmpty ? title : p.basenameWithoutExtension(title);
}

IndexNodeEdge _edgeFromRow(Row row) {
  return IndexNodeEdge(
    id: row['id'] as String,
    fromNodeId: row['from_node_id'] as String,
    toNodeId: row['to_node_id'] as String,
    edgeType: row['edge_type'] as String,
    label: row['label'] as String?,
    sortOrder: row['sort_order'] as int,
  );
}

EntityListItem _listItemFromRow(Row row, ThumbnailStore thumbnailStore) {
  final entity = _entityFromRow(row, thumbnailStore);
  return EntityListItem(
    id: entity.id,
    title: entity.name,
    entityType: entity.entityType,
    path: entity.path,
    format: entity.format,
    hash: entity.hash,
    size: entity.size,
    mimeType: entity.mimeType,
    contentExcerpt: entity.contentExcerpt,
    thumbnailStatus: entity.thumbnailStatus,
    thumbnailPath: entity.thumbnailPath,
    thumbnailKey: entity.thumbnailKey,
    thumbnailFormat: entity.thumbnailFormat,
    thumbnailWidth: entity.thumbnailWidth,
    thumbnailHeight: entity.thumbnailHeight,
    modifiedAtMs: entity.sourceModifiedAtMs,
    archived: entity.archived,
    lastOpenedAtMs: entity.lastOpenedAtMs,
    lastPositionMs: entity.lastPositionMs,
    durationMs: entity.durationMs,
    readerScrollOffset: entity.readerScrollOffset,
    zoomScale: entity.zoomScale,
    extraStateJson: entity.extraStateJson,
    localPath: entity.localPath,
  );
}

String _entityOrderBy(EntitySortMode sortMode) {
  return switch (sortMode) {
    EntitySortMode.nameAsc => 'e.name COLLATE NOCASE ASC, e.id ASC',
    EntitySortMode.nameDesc => 'e.name COLLATE NOCASE DESC, e.id ASC',
    EntitySortMode.modifiedDesc => 'e.source_modified_at_ms DESC, e.id ASC',
    EntitySortMode.modifiedAsc => 'e.source_modified_at_ms ASC, e.id ASC',
    EntitySortMode.sizeDesc => 'e.size DESC, e.id ASC',
    EntitySortMode.sizeAsc => 'e.size ASC, e.id ASC',
    EntitySortMode.typeAsc =>
      'e.format COLLATE NOCASE ASC, e.name COLLATE NOCASE ASC, e.id ASC',
  };
}

({String sql, List<Object> parameters}) _entityCursorCondition(
  EntityPageCursor cursor,
  EntitySortMode sortMode, {
  required String alias,
}) {
  if (cursor.sortMode != sortMode) {
    throw ArgumentError('Pagination cursor sort mode does not match query');
  }
  return switch (sortMode) {
    EntitySortMode.nameAsc => (
        sql:
            '$alias.name COLLATE NOCASE > ? OR ($alias.name COLLATE NOCASE = ? AND $alias.id > ?)',
        parameters: [cursor.primary, cursor.primary, cursor.entityId],
      ),
    EntitySortMode.nameDesc => (
        sql:
            '$alias.name COLLATE NOCASE < ? OR ($alias.name COLLATE NOCASE = ? AND $alias.id > ?)',
        parameters: [cursor.primary, cursor.primary, cursor.entityId],
      ),
    EntitySortMode.modifiedDesc => (
        sql:
            '$alias.source_modified_at_ms < ? OR ($alias.source_modified_at_ms = ? AND $alias.id > ?)',
        parameters: [cursor.primary, cursor.primary, cursor.entityId],
      ),
    EntitySortMode.modifiedAsc => (
        sql:
            '$alias.source_modified_at_ms > ? OR ($alias.source_modified_at_ms = ? AND $alias.id > ?)',
        parameters: [cursor.primary, cursor.primary, cursor.entityId],
      ),
    EntitySortMode.sizeDesc => (
        sql: '$alias.size < ? OR ($alias.size = ? AND $alias.id > ?)',
        parameters: [cursor.primary, cursor.primary, cursor.entityId],
      ),
    EntitySortMode.sizeAsc => (
        sql: '$alias.size > ? OR ($alias.size = ? AND $alias.id > ?)',
        parameters: [cursor.primary, cursor.primary, cursor.entityId],
      ),
    EntitySortMode.typeAsc => (
        sql: '''
$alias.format COLLATE NOCASE > ? OR
($alias.format COLLATE NOCASE = ? AND (
  $alias.name COLLATE NOCASE > ? OR
  ($alias.name COLLATE NOCASE = ? AND $alias.id > ?)
))
''',
        parameters: [
          cursor.primary,
          cursor.primary,
          cursor.secondary!,
          cursor.secondary!,
          cursor.entityId,
        ],
      ),
  };
}

bool _isSameOrChild(String path, String possibleParent) {
  final normalizedPath = p.normalize(path).toLowerCase();
  final normalizedParent = p.normalize(possibleParent).toLowerCase();
  return normalizedPath == normalizedParent ||
      p.isWithin(normalizedParent, normalizedPath);
}

bool _pathsOverlap(String left, String right) {
  return _isSameOrChild(left, right) || _isSameOrChild(right, left);
}

bool _isTopLevelIndexRootType(NodeType nodeType) {
  return nodeType == NodeType.customIndexRoot ||
      nodeType == NodeType.graphIndexRoot;
}

String _indexNameForRoot(String rootPath, {String? displayName}) {
  final explicitName = displayName?.trim();
  if (explicitName != null && explicitName.isNotEmpty) return explicitName;
  if (rootPath.startsWith('content://')) return '已选目录';
  final normalized = p.normalize(rootPath);
  final name = p.basename(normalized).trim();
  return name.isEmpty ? '未命名索引' : name;
}

String _normalizeIndexNodeName(String name) {
  final normalized = name.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(name, 'name', 'Index node name cannot be empty');
  }
  return normalized;
}

String _normalizeEntityPath(String path) {
  final trimmed = path.trim();
  if (trimmed.startsWith('content://')) return trimmed;
  final normalized = p.normalize(trimmed);
  if (normalized.isEmpty || normalized == '.') {
    throw ArgumentError.value(path, 'path', 'Entity path cannot be empty');
  }
  return normalized;
}

String _normalizeSourcePath(String sourcePath) {
  final trimmed = sourcePath.trim();
  if (trimmed.startsWith('content://')) return trimmed;
  final normalized = p.normalize(trimmed);
  if (normalized.isEmpty || normalized == '.') {
    throw ArgumentError.value(
      sourcePath,
      'sourcePath',
      'Source path cannot be empty',
    );
  }
  return normalized;
}

String _normalizeEntityText(String value, String argumentName) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(
      value,
      argumentName,
      'Entity $argumentName cannot be empty',
    );
  }
  return normalized;
}

void _validateNonNegativeInt(int value, String argumentName) {
  if (value < 0) {
    throw ArgumentError.value(
      value,
      argumentName,
      'Entity $argumentName cannot be negative',
    );
  }
}

String _normalizeEdgeType(String edgeType) {
  final normalized = edgeType.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(
      edgeType,
      'edgeType',
      'Index node edge type cannot be empty',
    );
  }
  return normalized;
}

String? _normalizeOptionalText(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

ThumbnailStatus _defaultThumbnailStatusFor(EntityType type) {
  return ThumbnailStatus.none;
}

bool _hasGeneratedThumbnail(EntityType type) =>
    type == EntityType.image ||
    type == EntityType.video ||
    type == EntityType.document;
