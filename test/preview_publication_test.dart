import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/core/thumbnails/thumbnail_store.dart';

void main() {
  late AppDatabase database;
  late LibraryRepository library;
  setUp(() {
    database = AppDatabase.openInMemory();
    library = LibraryRepository(database);
  });
  tearDown(() async {
    database.close();
    await Directory(database.storageDirectoryPath).delete(recursive: true);
  });

  Entity entity(String name, {String hash = 'same', int size = 1}) => library
      .upsertEntity(
        path: '/source/$name.jpg',
        name: name,
        format: 'jpg',
        entityType: EntityType.image,
        hash: hash,
        size: size,
        sourceCreatedAtMs: 0,
        sourceModifiedAtMs: 0,
      )
      .entity;

  Future<void> write(EntityPreviewTicket ticket) => library.thumbnailStore
      .writeBytes(
        key: ticket.assetKey,
        format: 'webp',
        bytes: Uint8List.fromList([1, 2, 3]),
      )
      .then((_) {});
  ThumbnailDatabaseUpdate success(EntityPreviewTicket ticket) =>
      ThumbnailDatabaseUpdate.success(
        entityId: ticket.entityId,
        key: ticket.assetKey,
        format: 'webp',
        width: 10,
        height: 20,
      );

  test(
      'equal fast fingerprints never share assets; failed rebuild retains old image',
      () async {
    final first = entity('a');
    final second = entity('b');
    final original = library.beginEntityPreview(first);
    final other = library.beginEntityPreview(second);
    expect(original.assetKey, isNot(other.assetKey));
    await write(original);
    expect(
        library.commitEntityPreview(original, success(original), byteSize: 3),
        isTrue);
    final rebuilding = library.beginEntityPreview(library.getEntity(first.id)!);
    library.commitEntityPreview(
        rebuilding, ThumbnailDatabaseUpdate.failed(first.id, 'decode failed'));
    final after = library.getEntity(first.id)!;
    expect(after.thumbnailKey, original.assetKey);
    expect(after.thumbnailPath, isNotNull);
    expect(File(after.thumbnailPath!).readAsBytesSync(), [1, 2, 3]);
    expect(after.thumbnailError, 'decode failed');
  });

  test(
      'late and changed-source publications cannot overwrite the current pointer',
      () async {
    final original = entity('a');
    final old = library.beginEntityPreview(original);
    final current = library.beginEntityPreview(library.getEntity(original.id)!);
    await write(old);
    await write(current);
    expect(library.commitEntityPreview(current, success(current), byteSize: 3),
        isTrue);
    expect(
        library.commitEntityPreview(old, success(old), byteSize: 3), isFalse);
    final pending = library.beginEntityPreview(library.getEntity(original.id)!);
    final changed = entity('a', hash: 'changed', size: 2);
    expect(changed.sourceRevision, original.sourceRevision + 1);
    expect(
        library.commitEntityPreview(
            pending, ThumbnailDatabaseUpdate.none(original.id)),
        isFalse);
    expect(library.getEntity(original.id)!.thumbnailKey, current.assetKey);
    expect(() => library.beginEntityPreview(original), throwsStateError);
  });

  test(
      'node changes invalidate publication and cleanup only retires unreferenced files',
      () async {
    final root = library.ensureCollectionIndexRoot('collection');
    library.markIndexNodePreviewDirty(root.id);
    final old = library.prepareNodePreviewBuilds([root.id]).single.ticket;
    library.markIndexNodePreviewDirty(root.id);
    final current = library.prepareNodePreviewBuilds([root.id]).single.ticket;
    final file = File(library.nodePreviewAssetPath(current.assetKey, 'webp'));
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
    expect(
        library.publishNodePreview(current,
            signature: 'current', width: 3, height: 1),
        isTrue);
    expect(library.publishNodePreview(old), isFalse);
    expect(
        database.db
            .select('SELECT asset_key FROM node_preview_assets')
            .single['asset_key'],
        current.assetKey);
    expect(
        database.db.select(
            'SELECT * FROM node_preview_dirty WHERE node_id = ?', [root.id]),
        isEmpty);
    database.db.execute('UPDATE retired_preview_assets SET not_before = 0');
    library.collectRetiredPreviewAssets();
    expect(await file.exists(), isTrue);
  });

  test('new keys are sharded by digest while legacy paths remain unchanged',
      () {
    final store = ThumbnailStore('store');
    expect(store.pathFor('v7_abcd', 'webp'), contains('ab'));
    expect(store.pathFor('v6_abcd', 'webp'), contains('v6'));
  });
}
