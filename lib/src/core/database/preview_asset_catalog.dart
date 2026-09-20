import 'dart:io';
import 'package:sqlite3/sqlite3.dart';

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
