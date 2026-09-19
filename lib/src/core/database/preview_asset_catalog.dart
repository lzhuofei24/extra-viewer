import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import '../thumbnails/thumbnail_store.dart';

void createPreviewAssetCatalog(Database db, String directory) {
  db.execute('''CREATE TABLE IF NOT EXISTS preview_assets (
    asset_key TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK(kind IN ('entity','node')),
    recipe TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('candidate','published','incomplete')),
    created_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS preview_asset_files (
      asset_key TEXT NOT NULL REFERENCES preview_assets(asset_key) ON DELETE CASCADE,
      variant TEXT NOT NULL, path TEXT NOT NULL, format TEXT NOT NULL,
      width INTEGER, height INTEGER, byte_size INTEGER NOT NULL CHECK(byte_size>=0),
      PRIMARY KEY(asset_key,variant));''');
  for (final row in db.select(
      'SELECT * FROM entity_previews WHERE thumbnail_key IS NOT NULL')) {
    final key = row['thumbnail_key'] as String;
    final format = row['thumbnail_format'] as String? ?? 'webp';
    registerPreviewAsset(
        db,
        key,
        'entity',
        'legacy',
        {
          'thumbnail': (
            path: ThumbnailStore(directory).pathFor(key, format),
            width: row['thumbnail_width'] as int?,
            height: row['thumbnail_height'] as int?
          )
        },
        format: format,
        requireFiles: false);
  }
  for (final row in db.select('SELECT * FROM node_preview_assets')) {
    final key = row['asset_key'] as String;
    final format = row['format'] as String;
    final complete = registerPreviewAsset(
        db,
        key,
        'node',
        'legacy',
        {
          'stacked': (
            path: nodePreviewAssetPathFor(directory, key, format),
            width: row['width'] as int?,
            height: row['height'] as int?
          ),
          'square': (
            path: portraitNodePreviewAssetPathFor(directory, key, format),
            width: null,
            height: null
          )
        },
        format: format,
        requireFiles: false);
    if (!complete) {
      db.execute(
          '''INSERT INTO node_preview_dirty(node_id,revision,reason,updated_at)
        VALUES(?,1,'missing_variant',?) ON CONFLICT(node_id) DO NOTHING''',
          [row['node_id'], DateTime.now().millisecondsSinceEpoch]);
    }
  }
}

bool registerPreviewAsset(Database db, String key, String kind, String recipe,
    Map<String, ({String path, int? width, int? height})> variants,
    {String format = 'webp', bool requireFiles = true}) {
  final files = <String, int>{};
  for (final entry in variants.entries) {
    final file = File(entry.value.path);
    files[entry.key] = file.existsSync() ? file.lengthSync() : 0;
  }
  final complete = files.values.every((size) => size > 0);
  if (requireFiles && !complete) {
    throw StateError('Preview variants are incomplete');
  }
  db.execute('''INSERT INTO preview_assets VALUES(?,?,?,?,?)
    ON CONFLICT(asset_key) DO UPDATE SET state=excluded.state''', [
    key,
    kind,
    recipe,
    complete ? 'published' : 'incomplete',
    DateTime.now().millisecondsSinceEpoch
  ]);
  for (final entry in variants.entries) {
    db.execute('''INSERT INTO preview_asset_files VALUES(?,?,?,?,?,?,?)
      ON CONFLICT(asset_key,variant) DO NOTHING''', [
      key,
      entry.key,
      entry.value.path,
      format,
      entry.value.width,
      entry.value.height,
      files[entry.key]
    ]);
  }
  return complete;
}
