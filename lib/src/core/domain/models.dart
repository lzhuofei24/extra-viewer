enum EntityType {
  text('text'),
  image('image'),
  audio('audio'),
  video('video'),
  // Keep the storage value for compatibility with existing databases.
  document('external_link');

  const EntityType(this.value);
  final String value;

  static EntityType fromValue(String value) {
    return EntityType.values.firstWhere(
      (type) => type.value == value,
      orElse: () => EntityType.text,
    );
  }
}

enum ThumbnailStatus {
  none('none'),
  pending('pending'),
  success('success'),
  failed('failed');

  const ThumbnailStatus(this.value);
  final String value;

  static ThumbnailStatus fromValue(String value) {
    return ThumbnailStatus.values.firstWhere(
      (status) => status.value == value,
      orElse: () => ThumbnailStatus.none,
    );
  }
}

enum ThumbnailUpdateType { pending, success, failed, none }

class ThumbnailDatabaseUpdate {
  const ThumbnailDatabaseUpdate.pending(this.entityId)
      : type = ThumbnailUpdateType.pending,
        key = null,
        format = null,
        width = null,
        height = null,
        durationMs = null,
        error = null;

  const ThumbnailDatabaseUpdate.success({
    required this.entityId,
    required this.key,
    required this.format,
    required this.width,
    required this.height,
    this.durationMs,
  })  : type = ThumbnailUpdateType.success,
        error = null;

  const ThumbnailDatabaseUpdate.failed(this.entityId, this.error)
      : type = ThumbnailUpdateType.failed,
        key = null,
        format = null,
        width = null,
        height = null,
        durationMs = null;

  const ThumbnailDatabaseUpdate.none(this.entityId)
      : type = ThumbnailUpdateType.none,
        key = null,
        format = null,
        width = null,
        height = null,
        durationMs = null,
        error = null;

  final ThumbnailUpdateType type;
  final String entityId;
  final String? key;
  final String? format;
  final int? width;
  final int? height;
  final int? durationMs;
  final String? error;
}

enum NodeType {
  root('root'),
  directoryIndexRoot('directory_index_root'),
  // Keep the storage value for compatibility with existing databases.
  customIndexRoot('category_index_root'),
  folder('folder'),
  customNode('category');

  const NodeType(this.value);
  final String value;

  static NodeType fromValue(String value) {
    return NodeType.values.firstWhere(
      (type) => type.value == value,
      orElse: () => NodeType.folder,
    );
  }
}

enum ViewType {
  tree('tree');

  const ViewType(this.value);
  final String value;

  static ViewType fromValue(String value) {
    return ViewType.values.firstWhere(
      (type) => type.value == value,
      orElse: () => ViewType.tree,
    );
  }
}

class Entity {
  const Entity({
    required this.id,
    required this.path,
    required this.name,
    required this.format,
    required this.entityType,
    required this.hash,
    required this.size,
    required this.sourceCreatedAtMs,
    required this.sourceModifiedAtMs,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.shuffleRemaining = const [],
    this.history = const [],
    this.contentExcerpt,
    this.thumbnailStatus = ThumbnailStatus.none,
    this.thumbnailKey,
    this.thumbnailFormat,
    this.thumbnailWidth,
    this.thumbnailHeight,
    this.thumbnailError,
    this.thumbnailPath,
    this.archived = false,
    this.lastOpenedAtMs,
    this.lastPositionMs,
    this.durationMs,
    this.readerScrollOffset,
    this.zoomScale,
    this.extraStateJson,
    this.directoryRootId,
    this.localPath,
    this.sourceRevision = 1,
    this.previewRevision = 1,
  });

  final String id;
  final int sourceRevision;
  final int previewRevision;
  final String path;
  final String name;
  final String format;
  final EntityType entityType;
  final String hash;
  final int size;
  final int sourceCreatedAtMs;
  final int sourceModifiedAtMs;
  final int createdAtMs;
  final int updatedAtMs;
  final List<int> shuffleRemaining;
  final List<int> history;
  final String? contentExcerpt;
  final ThumbnailStatus thumbnailStatus;
  final String? thumbnailKey;
  final String? thumbnailFormat;
  final int? thumbnailWidth;
  final int? thumbnailHeight;
  final String? thumbnailError;
  final String? thumbnailPath;

  /// Internal visibility compatibility flag. There is no user-facing archive
  /// workflow; normal queries expose only non-archived entities.
  final bool archived;
  final int? lastOpenedAtMs;
  final int? lastPositionMs;
  final int? durationMs;
  final double? readerScrollOffset;
  final double? zoomScale;
  final String? extraStateJson;

  /// The directory index root that owns the real source file, if any.
  final String? directoryRootId;

  /// A readable app-private materialization for a URI-backed source.
  final String? localPath;

  String get title => name;
  String get mimeType => entityType.value;
}

class EntityPreviewTicket {
  const EntityPreviewTicket(
      {required this.entityId,
      required this.sourceRevision,
      required this.previewRevision,
      required this.assetKey});
  final String entityId;
  final int sourceRevision;
  final int previewRevision;
  final String assetKey;
}

class NodePreviewTicket {
  const NodePreviewTicket(
      {required this.nodeId,
      required this.revision,
      required this.publication,
      required this.assetKey});
  final String nodeId;
  final int revision;
  final int publication;
  final String assetKey;
}

class NodePreviewBuildInput {
  const NodePreviewBuildInput(this.ticket, this.preview);
  final NodePreviewTicket ticket;
  final IndexNodePreview preview;
}

enum NodeSearchScope { all, directory, collection }

class NodeSearchQuery {
  const NodeSearchQuery(
      {required this.text,
      this.scope = NodeSearchScope.all,
      this.offset = 0,
      this.limit = 60});
  final String text;
  final NodeSearchScope scope;
  final int offset;
  final int limit;
}

class NodeSearchResult {
  NodeSearchResult(
      {required this.node,
      required this.root,
      required List<IndexNode> breadcrumb,
      required this.matchRank})
      : breadcrumb = List.unmodifiable(breadcrumb);
  final IndexNode node;
  final IndexNode root;
  final List<IndexNode> breadcrumb;
  final int matchRank;
}

class NodeSearchPage {
  NodeSearchPage({required List<NodeSearchResult> items, required this.hasMore})
      : items = List.unmodifiable(items);
  final List<NodeSearchResult> items;
  final bool hasMore;

  Map<String, Object?> toMessage() => {
        'hasMore': hasMore,
        'items': items
            .map((item) => {
                  'node': _nodeMessage(item.node),
                  'root': _nodeMessage(item.root),
                  'breadcrumb':
                      item.breadcrumb.map(_nodeMessage).toList(growable: false),
                  'matchRank': item.matchRank,
                })
            .toList(growable: false),
      };

  factory NodeSearchPage.fromMessage(Map<Object?, Object?> message) =>
      NodeSearchPage(
        hasMore: message['hasMore'] == true,
        items: (message['items'] as List<Object?>).map((raw) {
          final item = raw as Map<Object?, Object?>;
          return NodeSearchResult(
            node: _nodeFromMessage(item['node'] as Map<Object?, Object?>),
            root: _nodeFromMessage(item['root'] as Map<Object?, Object?>),
            breadcrumb: (item['breadcrumb'] as List<Object?>)
                .map(
                    (value) => _nodeFromMessage(value as Map<Object?, Object?>))
                .toList(growable: false),
            matchRank: item['matchRank'] as int,
          );
        }).toList(growable: false),
      );
}

Map<String, Object?> _nodeMessage(IndexNode node) => {
      'id': node.id,
      'parentId': node.parentId,
      'name': node.name,
      'nodeType': node.nodeType.value,
      'viewType': node.viewType.value,
      'sortOrder': node.sortOrder,
      'createdAtMs': node.createdAtMs,
      'updatedAtMs': node.updatedAtMs,
      'sourcePath': node.sourcePath,
      'previewJson': node.previewJson,
      'lastBuiltAtMs': node.lastBuiltAtMs,
      'isStaging': node.isStaging,
    };

IndexNode _nodeFromMessage(Map<Object?, Object?> map) => IndexNode(
      id: map['id'] as String,
      parentId: map['parentId'] as String?,
      name: map['name'] as String,
      nodeType: NodeType.fromValue(map['nodeType'] as String),
      viewType: ViewType.fromValue(map['viewType'] as String),
      sortOrder: map['sortOrder'] as int,
      createdAtMs: map['createdAtMs'] as int,
      updatedAtMs: map['updatedAtMs'] as int,
      sourcePath: map['sourcePath'] as String?,
      previewJson: map['previewJson'] as String?,
      lastBuiltAtMs: map['lastBuiltAtMs'] as int?,
      isStaging: map['isStaging'] == true,
    );

class IndexNode {
  const IndexNode({
    required this.id,
    required this.name,
    required this.nodeType,
    required this.viewType,
    required this.sortOrder,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.parentId,
    this.sourcePath,
    this.previewJson,
    this.lastBuiltAtMs,
    this.isStaging = false,
  });

  final String id;
  final String? parentId;
  final String name;
  final NodeType nodeType;
  final ViewType viewType;
  final String? sourcePath;
  final String? previewJson;
  final int sortOrder;
  final int createdAtMs;
  final int updatedAtMs;
  final int? lastBuiltAtMs;
  final bool isStaging;
}

/// A lightweight, non-recursive description for rendering an index-node
/// thumbnail. Text is kept as data and rendered by Flutter, never rasterized
/// into a database BLOB.
enum IndexNodePreviewKind {
  empty,
  singleVisual,
  visualGrid,
  audioList,
  documentList,
  splitLists,
}

enum IndexNodePreviewTileKind { visual, node, audio, document, mixedData }

class IndexNodePreviewTile {
  const IndexNodePreviewTile({
    required this.kind,
    required this.title,
    this.thumbnailPath,
    this.thumbnailKey,
    this.thumbnailFormat,
    this.entityId,
    this.nodeId,
    this.aspectRatio = 1,
    this.audioNames = const [],
    this.documentNames = const [],
  });

  final IndexNodePreviewTileKind kind;
  final String title;
  final String? thumbnailPath;
  final String? thumbnailKey;
  final String? thumbnailFormat;
  final String? entityId;
  final String? nodeId;
  final double aspectRatio;
  final List<String> audioNames;
  final List<String> documentNames;
}

class IndexNodePreview {
  const IndexNodePreview({
    required this.nodeId,
    required this.kind,
    this.tiles = const [],
    this.audioNames = const [],
    this.documentNames = const [],
    this.customOrderTopToBottom = false,
    this.visualAssetPath,
    this.visualAssetAspectRatio,
  });

  final String nodeId;
  final IndexNodePreviewKind kind;
  final List<IndexNodePreviewTile> tiles;
  final List<String> audioNames;
  final List<String> documentNames;
  final bool customOrderTopToBottom;
  final String? visualAssetPath;

  /// The persisted composite has a variable width. Keep its measured ratio so
  /// the card does not crop away the lower-layer shadows with BoxFit.cover.
  final double? visualAssetAspectRatio;
}

/// One selectable source for a manually composed index-node preview.
/// The candidate remains lightweight so large node trees can be queried in
/// pages instead of materializing every descendant for the picker dialog.
class NodePreviewCandidate {
  const NodePreviewCandidate({
    required this.kind,
    required this.title,
    this.thumbnailPath,
    this.thumbnailKey,
    this.thumbnailFormat,
    this.entityId,
    this.nodeId,
    this.aspectRatio = 1,
  });

  final IndexNodePreviewTileKind kind;
  final String title;
  final String? thumbnailPath;
  final String? thumbnailKey;
  final String? thumbnailFormat;
  final String? entityId;
  final String? nodeId;
  final double aspectRatio;

  IndexNodePreviewTile toPreviewTile() => IndexNodePreviewTile(
        kind: kind,
        title: title,
        thumbnailPath: thumbnailPath,
        thumbnailKey: thumbnailKey,
        thumbnailFormat: thumbnailFormat,
        entityId: entityId,
        nodeId: nodeId,
        aspectRatio: aspectRatio,
      );
}

class NodePreviewCandidatePage {
  const NodePreviewCandidatePage({
    required this.items,
    required this.hasMore,
  });

  final List<NodePreviewCandidate> items;
  final bool hasMore;
}

class IndexNodeSummary {
  const IndexNodeSummary({
    required this.directEntityCount,
    required this.descendantEntityCount,
    required this.childNodeCount,
  });

  final int directEntityCount;
  final int descendantEntityCount;
  final int childNodeCount;
}

enum EntityUpsertStatus { inserted, skipped, updated }

class EntityUpsertResult {
  const EntityUpsertResult({
    required this.entity,
    required this.status,
  });

  final Entity entity;
  final EntityUpsertStatus status;
}

class DirectoryIndexDeletionConflict {
  const DirectoryIndexDeletionConflict({
    required this.entityId,
    required this.entityName,
    required this.entityPath,
    required this.indexNames,
  });

  final String entityId;
  final String entityName;
  final String entityPath;
  final List<String> indexNames;
}

class DirectoryIndexDeletionReport {
  const DirectoryIndexDeletionReport({
    required this.root,
    required this.entityCount,
    required this.conflictCount,
    required this.conflicts,
  });

  final IndexNode root;
  final int entityCount;
  final int conflictCount;
  final List<DirectoryIndexDeletionConflict> conflicts;

  bool get hasConflicts => conflictCount > 0;
}

class DirectoryIndexDeletionResult {
  const DirectoryIndexDeletionResult({
    required this.deletedEntityCount,
  });

  final int deletedEntityCount;
}

class IndexTreeNode {
  const IndexTreeNode({
    required this.item,
    required this.children,
    required this.entityCount,
  });

  final IndexNode item;
  final List<IndexTreeNode> children;
  final int entityCount;
}

class IndexTreeSnapshot {
  const IndexTreeSnapshot({
    required this.tree,
    required this.entityCounts,
  });

  final List<IndexTreeNode> tree;
  final Map<String, int> entityCounts;
}

class EntityListItem {
  const EntityListItem({
    this.sourceRevision = 1,
    required this.id,
    required this.title,
    required this.entityType,
    required this.path,
    required this.format,
    this.hash = '',
    required this.size,
    required this.modifiedAtMs,
    this.mimeType,
    this.contentExcerpt,
    this.thumbnailStatus = ThumbnailStatus.none,
    this.thumbnailPath,
    this.thumbnailKey,
    this.thumbnailFormat,
    this.thumbnailWidth,
    this.thumbnailHeight,
    this.archived = false,
    this.lastOpenedAtMs,
    this.lastPositionMs,
    this.durationMs,
    this.readerScrollOffset,
    this.zoomScale,
    this.extraStateJson,
    this.localPath,
  });

  final int sourceRevision;
  final String id;
  final String title;
  final EntityType entityType;
  final String path;
  final String format;
  final String hash;
  final int size;
  final String? mimeType;
  final String? contentExcerpt;
  final ThumbnailStatus thumbnailStatus;
  final String? thumbnailPath;
  final String? thumbnailKey;
  final String? thumbnailFormat;
  final int? thumbnailWidth;
  final int? thumbnailHeight;
  final int modifiedAtMs;

  /// Internal visibility compatibility flag. There is no user-facing archive
  /// workflow; normal queries expose only non-archived entities.
  final bool archived;
  final int? lastOpenedAtMs;
  final int? lastPositionMs;
  final int? durationMs;
  final double? readerScrollOffset;
  final double? zoomScale;
  final String? extraStateJson;
  final String? localPath;
}

enum AudioPlaybackMode {
  sequential('顺序播放'),
  singleRepeat('单曲循环'),
  nodeRepeat('列表循环'),
  nodeShuffle('列表随机');

  const AudioPlaybackMode(this.label);
  final String label;
}

class AudioPlaybackSession {
  const AudioPlaybackSession({
    required this.id,
    required this.name,
    required this.mode,
    required this.entries,
    required this.currentIndex,
    required this.positionMs,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.sourceNodeId,
    this.sourceNodeName,
    this.active = false,
    this.shuffleRemaining = const [],
    this.history = const [],
  });

  final String id;
  final String name;
  final String? sourceNodeId;
  final String? sourceNodeName;
  final AudioPlaybackMode mode;
  final List<EntityListItem> entries;
  final int currentIndex;
  final int positionMs;
  final bool active;
  final int createdAtMs;
  final int updatedAtMs;
  final List<int> shuffleRemaining;
  final List<int> history;

  EntityListItem? get current =>
      currentIndex >= 0 && currentIndex < entries.length
          ? entries[currentIndex]
          : null;
}

class EntityPage {
  const EntityPage({
    required this.items,
    required this.hasMore,
    this.recursiveCursor,
  });

  final List<EntityListItem> items;
  final bool hasMore;
  final RecursiveEntityPageCursor? recursiveCursor;
}

enum EntitySortMode {
  nameAsc,
  nameDesc,
  modifiedDesc,
  modifiedAsc,
  sizeDesc,
  sizeAsc,
  typeAsc;
}

/// Durable scan frontiers and per-item preview work share one task lifecycle.
enum LibraryBuildStage {
  manifest,
  indexWrite,
  finalize,
  documentPreviews,
  entityPreviews,
  nodePreviews,
  completed;

  static LibraryBuildStage fromStorageValue(String value) =>
      LibraryBuildStage.values.firstWhere(
        (stage) => stage.name == value,
        orElse: () => throw ArgumentError.value(value, 'value', 'stage'),
      );
}

enum LibraryBuildStatus {
  pending,
  running,
  pauseRequested,
  paused,
  blocked,
  failed,
  abandoned,
  completedWithErrors,
  completed;

  static LibraryBuildStatus fromStorageValue(String value) =>
      LibraryBuildStatus.values.firstWhere(
        (status) => status.name == value,
        orElse: () => throw ArgumentError.value(value, 'value', 'status'),
      );
}

enum LibraryBuildOperation { rootScan, subtreeRefresh }

enum LibraryBuildKind { scanScope, rebuildPreviews }

enum LibraryBuildWorkState { pending, processing, completed, failed, skipped }

class BuildWorkAttempt {
  const BuildWorkAttempt({required this.generation, required this.number});
  final int generation;
  final int number;
}

class DocumentPreviewMetadata {
  const DocumentPreviewMetadata(
      {required this.sourceRevision,
      this.excerpt,
      this.durationMs,
      this.coverRevision,
      this.preview});
  final int sourceRevision;
  final String? excerpt;
  final int? durationMs;
  final int? coverRevision;
  final PreparedEntityPreview? preview;
}

class PreparedEntityPreview {
  const PreparedEntityPreview(this.ticket, this.update, {this.byteSize = 0});
  final EntityPreviewTicket ticket;
  final ThumbnailDatabaseUpdate update;
  final int byteSize;
}

class LibraryBuildJob {
  bool get isCompleted =>
      status == LibraryBuildStatus.completed ||
      status == LibraryBuildStatus.completedWithErrors;
  const LibraryBuildJob({
    required this.id,
    required this.sourcePath,
    required this.operation,
    required this.stage,
    required this.status,
    required this.manifestTotal,
    required this.indexedTotal,
    required this.documentPreviewTotal,
    required this.documentPreviewDone,
    required this.documentPreviewFailed,
    required this.entityPreviewTotal,
    required this.entityPreviewDone,
    required this.entityPreviewFailed,
    required this.nodePreviewTotal,
    required this.nodePreviewDone,
    required this.nodePreviewFailed,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.targetNodeId,
    this.indexRootId,
    this.stagingRootId,
    this.error,
    this.kind = LibraryBuildKind.scanScope,
    this.scopeNodeId,
    this.manifestComplete = false,
    this.indexCursor = -1,
    this.indexFailed = 0,
  });

  final String id;
  final LibraryBuildKind kind;
  final String? scopeNodeId;
  final bool manifestComplete;
  final int indexCursor;
  final int indexFailed;
  final String sourcePath;
  final LibraryBuildOperation operation;
  final String? targetNodeId;
  final String? indexRootId;
  final String? stagingRootId;
  final LibraryBuildStage stage;
  final LibraryBuildStatus status;
  final int manifestTotal;
  final int indexedTotal;
  final int documentPreviewTotal;
  final int documentPreviewDone;
  final int documentPreviewFailed;
  final int entityPreviewTotal;
  final int entityPreviewDone;
  final int entityPreviewFailed;
  final int nodePreviewTotal;
  final int nodePreviewDone;
  final int nodePreviewFailed;
  final String? error;
  final int createdAtMs;
  final int updatedAtMs;
}

class LibraryBuildManifestItem {
  const LibraryBuildManifestItem({
    required this.jobId,
    required this.sourcePath,
    required this.relativePath,
    required this.sequence,
    required this.name,
    required this.format,
    required this.entityType,
    required this.size,
    required this.sourceCreatedAtMs,
    required this.sourceModifiedAtMs,
    this.fingerprint,
    this.contentExcerpt,
    this.durationMs,
  });

  final String jobId;
  final String sourcePath;
  final String relativePath;
  final int sequence;
  final String name;
  final String format;
  final EntityType entityType;
  final String? fingerprint;
  final int size;
  final String? contentExcerpt;
  final int? durationMs;
  final int sourceCreatedAtMs;
  final int sourceModifiedAtMs;
}

enum IndexPreviewRebuildScope { node, subtree }

class DirtyIndexPreviewNode {
  const DirtyIndexPreviewNode({
    required this.nodeId,
    required this.rootId,
    required this.scope,
    required this.dirtyAtMs,
    this.reason,
  });

  final String nodeId;
  final String rootId;
  final IndexPreviewRebuildScope scope;
  final int dirtyAtMs;
  final String? reason;
}

class EntityPageCursor {
  const EntityPageCursor({
    required this.sortMode,
    required this.primary,
    required this.entityId,
    this.secondary,
  });

  final EntitySortMode sortMode;
  final Object primary;
  final Object? secondary;
  final String entityId;

  factory EntityPageCursor.fromEntity(
    EntityListItem entity,
    EntitySortMode sortMode,
  ) {
    return switch (sortMode) {
      EntitySortMode.nameAsc || EntitySortMode.nameDesc => EntityPageCursor(
          sortMode: sortMode,
          primary: entity.title,
          entityId: entity.id,
        ),
      EntitySortMode.modifiedDesc ||
      EntitySortMode.modifiedAsc =>
        EntityPageCursor(
          sortMode: sortMode,
          primary: entity.modifiedAtMs,
          entityId: entity.id,
        ),
      EntitySortMode.sizeDesc || EntitySortMode.sizeAsc => EntityPageCursor(
          sortMode: sortMode,
          primary: entity.size,
          entityId: entity.id,
        ),
      EntitySortMode.typeAsc => EntityPageCursor(
          sortMode: sortMode,
          primary: entity.format,
          secondary: entity.title,
          entityId: entity.id,
        ),
    };
  }
}

class RecursiveEntityPageCursor {
  const RecursiveEntityPageCursor({
    required this.hierarchyPath,
    required this.entityCursor,
  });

  final String hierarchyPath;
  final EntityPageCursor entityCursor;
}
