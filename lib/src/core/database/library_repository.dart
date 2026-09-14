import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../domain/models.dart';
import '../diagnostics/app_diagnostic_log.dart';
import '../thumbnails/thumbnail_store.dart';
import '../utils/ids.dart';
import '../../modules/library/library_access.dart';
import 'app_database.dart';
import 'library_write_worker.dart';

part 'library_repository_helpers.dart';
part 'library_repository_base.dart';
part 'entity_repository.dart';
part 'thumbnail_repository.dart';
part 'index_node_repository.dart';
part 'index_build_mixin.dart';
part 'node_preview_repository.dart';
part 'index_stats_repository.dart';
part 'audio_playback_repository.dart';

/// Central repository for all library database operations.
///
/// This class is a thin facade that combines domain-specific mixins:
/// - [EntityRepositoryMixin] — entity CRUD and lookup
/// - [ThumbnailRepositoryMixin] — thumbnail status and asset lifecycle
/// - [IndexNodeRepositoryMixin] — index node CRUD, graph, tree traversal
/// - [IndexBuildMixin] — directory index scan lifecycle
/// - [NodePreviewRepositoryMixin] — node preview cache and overrides
/// - [IndexStatsRepositoryMixin] — aggregated entity counts
/// - [AudioPlaybackRepositoryMixin] — audio playback session persistence
///
/// All methods are available directly on this class via mixin composition.
/// External callers (e.g. [LibraryBuildRepository]) continue to access
/// [database] and [thumbnailStore] inside the database host only.
class LibraryRepository extends LibraryRepositoryBase
    with
        EntityRepositoryMixin,
        ThumbnailRepositoryMixin,
        IndexNodeRepositoryMixin,
        IndexBuildMixin,
        NodePreviewRepositoryMixin,
        IndexStatsRepositoryMixin,
        AudioPlaybackRepositoryMixin
    implements LibraryAccess {
  LibraryRepository(super.database);
}
