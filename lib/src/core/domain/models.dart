enum EntityType {
  text('text'),
  image('image'),
  audio('audio'),
  video('video'),
  externalLink('external_link');

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

enum ThumbnailBuildStatus {
  pending('pending'),
  running('running'),
  paused('paused'),
  completed('completed'),
  failed('failed'),
  abandoned('abandoned');

  const ThumbnailBuildStatus(this.value);
  final String value;

  static ThumbnailBuildStatus fromValue(String value) =>
      ThumbnailBuildStatus.values.firstWhere(
        (status) => status.value == value,
        orElse: () => paused,
      );
}

enum ThumbnailBuildEntryState {
  pending('pending'),
  processing('processing'),
  completed('completed'),
  failed('failed'),
  skipped('skipped');

  const ThumbnailBuildEntryState(this.value);
  final String value;

  static ThumbnailBuildEntryState fromValue(String value) =>
      ThumbnailBuildEntryState.values.firstWhere(
        (state) => state.value == value,
        orElse: () => pending,
      );
}

class ThumbnailBuildJob {
  const ThumbnailBuildJob({
    required this.id,
    required this.status,
    required this.total,
    required this.processed,
    required this.failed,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.indexRootId,
    this.error,
  });

  final String id;
  final String? indexRootId;
  final ThumbnailBuildStatus status;
  final int total;
  final int processed;
  final int failed;
  final String? error;
  final int createdAtMs;
  final int updatedAtMs;

  int get remaining => total - processed - failed;
  double? get progress => total == 0 ? null : (processed + failed) / total;
}

class ThumbnailBuildEntry {
  const ThumbnailBuildEntry({
    required this.jobId,
    required this.entityId,
    required this.state,
    required this.attempts,
    required this.updatedAtMs,
    this.error,
  });

  final String jobId;
  final String entityId;
  final ThumbnailBuildEntryState state;
  final String? error;
  final int attempts;
  final int updatedAtMs;
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
  categoryIndexRoot('category_index_root'),
  graphIndexRoot('graph_index_root'),
  folder('folder'),
  category('category'),
  graphNode('graph_node');

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
  tree('tree'),
  graph('graph'),
  grid('grid'),
  timeline('timeline');

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
    this.metadataPreview,
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
  });

  final String id;
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
  final String? metadataPreview;
  final ThumbnailStatus thumbnailStatus;
  final String? thumbnailKey;
  final String? thumbnailFormat;
  final int? thumbnailWidth;
  final int? thumbnailHeight;
  final String? thumbnailError;
  final String? thumbnailPath;
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
  });

  final String nodeId;
  final IndexNodePreviewKind kind;
  final List<IndexNodePreviewTile> tiles;
  final List<String> audioNames;
  final List<String> documentNames;
  final bool customOrderTopToBottom;
  final String? visualAssetPath;
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

class IndexNodeEdge {
  const IndexNodeEdge({
    required this.id,
    required this.fromNodeId,
    required this.toNodeId,
    required this.edgeType,
    required this.sortOrder,
    this.label,
  });

  final String id;
  final String fromNodeId;
  final String toNodeId;
  final String edgeType;
  final String? label;
  final int sortOrder;
}

class GraphNodePosition {
  const GraphNodePosition(
      {required this.nodeId, required this.x, required this.y});

  final String nodeId;
  final double x;
  final double y;
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
    this.fileDeleteFailures = const [],
  });

  final int deletedEntityCount;
  final List<String> fileDeleteFailures;

  bool get completed => fileDeleteFailures.isEmpty;
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
    required this.id,
    required this.title,
    required this.entityType,
    required this.path,
    required this.format,
    this.hash = '',
    required this.size,
    required this.modifiedAtMs,
    this.mimeType,
    this.metadataPreview,
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

  final String id;
  final String title;
  final EntityType entityType;
  final String path;
  final String format;
  final String hash;
  final int size;
  final String? mimeType;
  final String? metadataPreview;
  final ThumbnailStatus thumbnailStatus;
  final String? thumbnailPath;
  final String? thumbnailKey;
  final String? thumbnailFormat;
  final int? thumbnailWidth;
  final int? thumbnailHeight;
  final int modifiedAtMs;
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
  nodeRepeat('节点内循环'),
  nodeShuffle('节点内随机');

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

/// A lightweight cursor page used by node-scoped thumbnail warming. It avoids
/// materializing every entity card merely to preload its already-built WebP.
class ThumbnailPreloadPage {
  const ThumbnailPreloadPage({
    required this.paths,
    this.nextEntityId,
  });

  final List<String> paths;
  final String? nextEntityId;

  bool get hasMore => nextEntityId != null;
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

enum IndexJobStatus {
  pending('pending'),
  running('running'),
  paused('paused'),
  attentionRequired('attention_required'),
  completed('completed'),
  failed('failed'),
  abandoned('abandoned');

  const IndexJobStatus(this.storageValue);

  final String storageValue;

  static IndexJobStatus fromStorageValue(String value) {
    if (value == 'attentionRequired') return attentionRequired;
    return IndexJobStatus.values.firstWhere(
      (status) => status.storageValue == value,
      orElse: () => throw ArgumentError.value(value, 'value', 'status'),
    );
  }
}

/// The only recoverable build state machine. Stages before asset generation
/// deliberately restart as a whole; asset stages checkpoint their work rows.
enum LibraryBuildStage {
  manifest,
  indexWrite,
  finalize,
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
  paused,
  failed,
  abandoned,
  completed;

  static LibraryBuildStatus fromStorageValue(String value) =>
      LibraryBuildStatus.values.firstWhere(
        (status) => status.name == value,
        orElse: () => throw ArgumentError.value(value, 'value', 'status'),
      );
}

enum LibraryBuildOperation { rootScan, subtreeRefresh }

enum LibraryBuildWorkState { pending, processing, completed, failed, skipped }

class LibraryBuildJob {
  const LibraryBuildJob({
    required this.id,
    required this.sourcePath,
    required this.operation,
    required this.stage,
    required this.status,
    required this.manifestTotal,
    required this.indexedTotal,
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
  });

  final String id;
  final String sourcePath;
  final LibraryBuildOperation operation;
  final String? targetNodeId;
  final String? indexRootId;
  final String? stagingRootId;
  final LibraryBuildStage stage;
  final LibraryBuildStatus status;
  final int manifestTotal;
  final int indexedTotal;
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
    this.metadataPreview,
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
  final String? metadataPreview;
  final int? durationMs;
  final int sourceCreatedAtMs;
  final int sourceModifiedAtMs;
}

enum IndexJobPhase {
  discovering,
  preparing,
  writing,
  previews,
  completed;
}

/// Describes which persisted source scope an index job owns. This is stored
/// with the job so recovery never has to infer intent from a path string.
enum IndexJobOperationType {
  rootScan('root_scan'),
  subtreeRefresh('subtree_refresh');

  const IndexJobOperationType(this.storageValue);

  final String storageValue;

  static IndexJobOperationType fromStorageValue(String value) =>
      IndexJobOperationType.values.firstWhere(
        (operation) => operation.storageValue == value,
        orElse: () => throw ArgumentError.value(value, 'value', 'operation'),
      );
}

/// The user-visible recovery operations for a persisted index task.
///
/// Keeping this separate from [IndexJobStatus] prevents callers from
/// inferring work from a combination of status, phase, and candidate rows.
enum IndexJobAction {
  resume,
  recheck,
  retryFailed,
}

/// The exact stage a recovery command is allowed to enter. Recovery callers
/// must choose this plan once; scanners do not infer a new operation from a
/// mixture of counters and candidate rows halfway through a run.
enum IndexJobRecoveryStage { discovery, preparation, writing, previews }

class IndexJobRecoveryPlan {
  const IndexJobRecoveryPlan({
    required this.action,
    required this.stage,
    required this.requiresCompleteManifest,
  });

  final IndexJobAction action;
  final IndexJobRecoveryStage stage;
  final bool requiresCompleteManifest;

  factory IndexJobRecoveryPlan.fromJob(
    IndexBuildJob job,
    IndexJobAction action,
  ) {
    if (action == IndexJobAction.recheck) {
      return const IndexJobRecoveryPlan(
        action: IndexJobAction.recheck,
        stage: IndexJobRecoveryStage.discovery,
        requiresCompleteManifest: false,
      );
    }
    if (action == IndexJobAction.retryFailed) {
      return const IndexJobRecoveryPlan(
        action: IndexJobAction.retryFailed,
        stage: IndexJobRecoveryStage.previews,
        requiresCompleteManifest: true,
      );
    }
    final stage = switch (job.phase) {
      IndexJobPhase.discovering => IndexJobRecoveryStage.discovery,
      IndexJobPhase.preparing => IndexJobRecoveryStage.preparation,
      IndexJobPhase.writing => IndexJobRecoveryStage.writing,
      IndexJobPhase.previews => IndexJobRecoveryStage.previews,
      IndexJobPhase.completed => IndexJobRecoveryStage.previews,
    };
    return IndexJobRecoveryPlan(
      action: action,
      stage: stage,
      requiresCompleteManifest: stage == IndexJobRecoveryStage.writing ||
          stage == IndexJobRecoveryStage.previews,
    );
  }
}

enum IndexJobCandidateState { pending, prepared, written, previewed, failed }

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

/// Identifies the source and attachment point of one directory build.
/// Platform scanners only need this value object; lifecycle handling stays
/// independent from Windows paths and Android SAF URIs.
class ScanScope {
  const ScanScope.root({required this.sourcePath})
      : indexRootId = null,
        targetNodeId = null,
        relativePath = null;

  const ScanScope.subtree({
    required this.sourcePath,
    required this.indexRootId,
    required this.targetNodeId,
    this.relativePath,
  });

  final String sourcePath;
  final String? indexRootId;
  final String? targetNodeId;
  final String? relativePath;

  bool get isRoot => targetNodeId == null;

  IndexJobOperationType get operationType => isRoot
      ? IndexJobOperationType.rootScan
      : IndexJobOperationType.subtreeRefresh;
}

class IndexJobCandidate {
  const IndexJobCandidate({
    required this.jobId,
    required this.sourcePath,
    required this.relativePath,
    required this.sequence,
    required this.state,
    required this.updatedAtMs,
    this.format,
    this.entityType,
    this.fingerprint,
    this.size,
    this.metadataPreview,
    this.durationMs,
    this.sourceCreatedAtMs,
    this.sourceModifiedAtMs,
    this.error,
  });

  final String jobId;
  final String sourcePath;
  final String relativePath;
  final int sequence;
  final IndexJobCandidateState state;
  final String? format;
  final EntityType? entityType;
  final String? fingerprint;
  final int? size;
  final String? metadataPreview;
  final int? durationMs;
  final int? sourceCreatedAtMs;
  final int? sourceModifiedAtMs;
  final String? error;
  final int updatedAtMs;
}

class IndexJobCandidateSummary {
  const IndexJobCandidateSummary({
    required this.pending,
    required this.prepared,
    required this.written,
    required this.previewed,
    required this.failed,
  });

  final int pending;
  final int prepared;
  final int written;
  final int previewed;
  final int failed;

  int get total => pending + prepared + written + previewed + failed;
  int get remaining => pending + prepared + written;
}

class IndexBuildJob {
  const IndexBuildJob({
    required this.id,
    required this.sourcePath,
    required this.status,
    required this.phase,
    required this.discovered,
    required this.total,
    required this.processed,
    required this.previewTotal,
    required this.previewProcessed,
    required this.scanCompleted,
    required this.createdAtMs,
    required this.updatedAtMs,
    required this.operationType,
    required this.scopePath,
    this.indexRootId,
    this.targetNodeId,
    this.stagingRootId,
    this.error,
  });

  final String id;
  final String sourcePath;
  final String? indexRootId;
  final IndexJobStatus status;
  final IndexJobPhase phase;
  final int discovered;
  final int total;
  final int processed;
  final int previewTotal;
  final int previewProcessed;
  final bool scanCompleted;
  final String? error;
  final String? targetNodeId;
  final String? stagingRootId;
  final int createdAtMs;
  final int updatedAtMs;
  final IndexJobOperationType operationType;
  final String scopePath;
}

class IndexJobHistoryEntry {
  const IndexJobHistoryEntry({
    required this.id,
    required this.sourcePath,
    required this.status,
    required this.summary,
    required this.createdAtMs,
    required this.completedAtMs,
    this.indexRootId,
    this.targetNodeId,
  });

  final String id;
  final String sourcePath;
  final String? indexRootId;
  final String? targetNodeId;
  final IndexJobStatus status;
  final String summary;
  final int createdAtMs;
  final int completedAtMs;
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
