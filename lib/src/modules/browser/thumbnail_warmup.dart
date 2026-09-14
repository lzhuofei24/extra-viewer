import '../../core/domain/models.dart';

/// A bounded window in display order. Paths with unknown dimensions use the
/// largest historical thumbnail target as a conservative decoded-size estimate.
List<EntityListItem> thumbnailWarmupWindow(
  List<EntityListItem> entries, {
  required int firstVisible,
  required int lastVisible,
  required int cacheBytes,
}) {
  if (firstVisible < 0 ||
      lastVisible < firstVisible ||
      lastVisible >= entries.length) {
    return const [];
  }
  var remaining = cacheBytes ~/ 4;
  final selected = <EntityListItem>[];
  final paths = <String>{};
  for (var offset = 1; offset <= 16; offset++) {
    for (final index in [lastVisible + offset, firstVisible - offset]) {
      if (index < 0 || index >= entries.length) continue;
      final entity = entries[index];
      final path = entity.thumbnailPath;
      if (path == null || !paths.add(path)) continue;
      final bytes = thumbnailDecodedBytes(entity);
      if (bytes > remaining) continue;
      remaining -= bytes;
      selected.add(entity);
    }
  }
  return List.unmodifiable(selected);
}

int thumbnailDecodedBytes(EntityListItem entity) {
  final width = entity.thumbnailWidth;
  final height = entity.thumbnailHeight;
  return width != null && width > 0 && height != null && height > 0
      ? width * height * 4
      : 480000 * 4;
}
