import 'dart:async';
import 'dart:collection';

import '../../modules/library/library_access.dart';
import '../domain/models.dart';
import '../formats/file_format_handlers.dart';
import 'android_image_thumbnail_backend.dart';
import 'android_video_thumbnail_backend.dart';
import 'native_image_thumbnail_backend.dart';
import 'thumbnail_cancellation.dart';
import 'thumbnail_service.dart';
import 'windows_wic_webp_thumbnail_backend.dart';

/// Generates derived previews only for entities requested by browse views.
/// Index construction never owns this queue or its LRU lifecycle.
class BrowsingThumbnailController {
  BrowsingThumbnailController(
    this.repository, {
    required this.onCacheChanged,
    this.maxConcurrent = 3,
  }) : _service = ThumbnailService(
          repository,
          androidImageBackend: AndroidImageThumbnailBackend(),
          androidVideoBackend: AndroidVideoThumbnailBackend(),
          nativeImageBackend: NativeImageThumbnailBackend(),
          windowsWicBackend: WindowsWicWebpThumbnailBackend(),
        );

  final LibraryAccess repository;
  final void Function(String? entityId) onCacheChanged;
  final int maxConcurrent;
  final ThumbnailService _service;
  final ThumbnailCancellationToken _cancellation = ThumbnailCancellationToken();
  final Queue<String> _pending = Queue<String>();
  final Set<String> _queued = <String>{};
  final Set<String> _running = <String>{};
  bool _closed = false;
  final Set<Future<void>> _operations = {};
  Future<void>? _closing;

  void request(EntityListItem item) {
    if (_closed) return;
    final handler = FileFormatRegistry.resolveFormat(item.format);
    if (handler == null || !handler.supportsGeneratedThumbnail) return;
    _enqueue(item.id);
  }

  Future<void> requestEntityId(String entityId) async {
    if (_closed) return;
    final entity = (await repository.getEntity(entityId));
    if (entity == null) return;
    final handler = FileFormatRegistry.resolveFormat(entity.format);
    if (handler == null || !handler.supportsGeneratedThumbnail) return;
    _enqueue(entityId);
  }

  void _enqueue(String entityId) {
    if (!_queued.add(entityId)) return;
    _pending.add(entityId);
    _drain();
  }

  void retry(String entityId) {
    if (_closed || _queued.contains(entityId)) return;
    _queued.add(entityId);
    _pending.addFirst(entityId);
    _drain(force: true);
  }

  void _drain({bool force = false}) {
    if (_closed) return;
    while (_running.length < maxConcurrent && _pending.isNotEmpty) {
      final entityId = _pending.removeFirst();
      _running.add(entityId);
      late final Future<void> operation;
      operation = _generate(entityId, force: force).whenComplete(() {
        _operations.remove(operation);
      });
      _operations.add(operation);
      unawaited(operation.catchError((Object _, StackTrace __) {}));
    }
  }

  Future<void> _generate(String entityId, {required bool force}) async {
    try {
      final entity = (await repository.getEntity(entityId));
      if (entity == null) return;
      final generated = await _service.ensureThumbnail(
        entity,
        force: force,
        cancellationToken: _cancellation,
      );
      if (generated && !_closed) {
        onCacheChanged(entityId);
      }
    } on ThumbnailTaskCanceledException {
      // Closing the browse controller is not a thumbnail failure.
    } finally {
      _running.remove(entityId);
      _queued.remove(entityId);
      _drain();
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _pending.clear();
    _queued.clear();
    _cancellation.cancel();
    await Future.wait(_operations.toList().map(
        (operation) => operation.catchError((Object _, StackTrace __) {})));
  }
}
