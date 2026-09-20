import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';
import '../../modules/sources/source_identity.dart';

String? findEntityByIdentity(Database db, String locator,
    {String? rootLocator}) {
  final identity = SourceIdentity.parse(locator, rootLocator: rootLocator);
  if (identity == null) return null;
  final rows = db.select(
      '''SELECT l.entity_id FROM entity_locations l JOIN sources s ON s.id=l.source_id
    WHERE s.kind=? AND s.authority=? AND s.root_identity=? AND l.document_identity=? AND l.state='resolved' ''',
      [
        identity.kind,
        identity.authority,
        identity.rootId,
        identity.documentId
      ]);
  return rows.isEmpty ? null : rows.single['entity_id'] as String;
}

void registerEntityLocation(Database db, String entityId, String locator,
    {String? rootLocator}) {
  final identity = SourceIdentity.parse(locator, rootLocator: rootLocator);
  String? sourceId;
  String? documentId;
  var state = 'legacy';
  if (identity != null) {
    sourceId =
        'source:${base64Url.encode(utf8.encode('${identity.kind}\u0000${identity.authority}\u0000${identity.rootId}'))}';
    final existing = db.select(
        'SELECT id FROM sources WHERE (kind=? AND authority=? AND root_identity=?) OR locator=? LIMIT 1',
        [
          identity.kind,
          identity.authority,
          identity.rootId,
          identity.rootLocator
        ]);
    if (existing.isNotEmpty) sourceId = existing.single['id'] as String;
    if (existing.isEmpty) {
      db.execute('''INSERT INTO sources(id,locator,kind,authority,root_identity)
        VALUES(?,?,?,?,?)''', [
        sourceId,
        identity.rootLocator,
        identity.kind,
        identity.authority,
        identity.rootId
      ]);
    } else {
      db.execute(
          'UPDATE sources SET kind=?,authority=?,root_identity=? WHERE id=?',
          [identity.kind, identity.authority, identity.rootId, sourceId]);
    }
    final conflict = db.select(
        'SELECT entity_id FROM entity_locations WHERE source_id=? AND document_identity=? AND entity_id<>?',
        [sourceId, identity.documentId, entityId]);
    state = conflict.isEmpty ? 'resolved' : 'conflict';
    documentId = conflict.isEmpty ? identity.documentId : null;
  }
  db.execute(
      '''INSERT INTO entity_locations VALUES(?,?,?,?,?,?)
    ON CONFLICT(entity_id) DO UPDATE SET source_id=excluded.source_id,
      document_identity=excluded.document_identity,locator=excluded.locator,state=excluded.state,updated_at=excluded.updated_at''',
      [
        entityId,
        sourceId,
        documentId,
        locator,
        state,
        DateTime.now().millisecondsSinceEpoch
      ]);
}
