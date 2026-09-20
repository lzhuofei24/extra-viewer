import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';
import '../../modules/sources/source_identity.dart';

void migrateSchemaV12(Database db) {
  final columns =
      db.select('PRAGMA table_info(sources)').map((r) => r['name']).toSet();
  for (final entry in {
    'kind': "TEXT NOT NULL DEFAULT 'legacy'",
    'authority': "TEXT NOT NULL DEFAULT ''",
    'root_identity': 'TEXT'
  }.entries) {
    if (!columns.contains(entry.key)) {
      db.execute('ALTER TABLE sources ADD COLUMN ${entry.key} ${entry.value}');
    }
  }
  db.execute('''CREATE UNIQUE INDEX IF NOT EXISTS idx_source_identity
    ON sources(kind,authority,root_identity) WHERE root_identity IS NOT NULL;
    CREATE TABLE IF NOT EXISTS entity_locations (
      entity_id TEXT PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
      source_id TEXT REFERENCES sources(id) ON DELETE RESTRICT,
      document_identity TEXT, locator TEXT NOT NULL,
      state TEXT NOT NULL CHECK(state IN ('resolved','legacy','conflict')),
      updated_at INTEGER NOT NULL);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_location_identity ON entity_locations(source_id,document_identity)
      WHERE document_identity IS NOT NULL;
    CREATE INDEX IF NOT EXISTS idx_location_source ON entity_locations(source_id);
  ''');
  if (!db
      .select('PRAGMA table_info(entities)')
      .any((r) => r['name'] == 'path')) {
    return;
  }
  for (final row
      in db.select('''SELECT e.id,e.path,n.source_path FROM entities e
    LEFT JOIN index_nodes n ON n.id=e.directory_root_id''')) {
    registerEntityLocation(db, row['id'] as String, row['path'] as String,
        rootLocator: row['source_path'] as String?);
  }
}

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
