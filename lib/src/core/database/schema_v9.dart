const schemaV9Objects = '''
CREATE UNIQUE INDEX IF NOT EXISTS idx_index_nodes_system_key
ON index_nodes(system_key) WHERE system_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS index_rules (
  node_id TEXT PRIMARY KEY,
  entity_types_json TEXT NOT NULL DEFAULT '[]',
  extensions_json TEXT NOT NULL DEFAULT '[]',
  scope_node_id TEXT,
  min_size INTEGER,
  max_size INTEGER,
  modified_within_days INTEGER,
  opened_within_days INTEGER,
  default_sort TEXT NOT NULL DEFAULT 'lastOpened',
  max_results INTEGER NOT NULL DEFAULT 1000,
  built_in_kind TEXT,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY(node_id) REFERENCES index_nodes(id) ON DELETE CASCADE,
  FOREIGN KEY(scope_node_id) REFERENCES index_nodes(id) ON DELETE SET NULL
);
''';

const schemaV9Indexes = '''
CREATE INDEX IF NOT EXISTS idx_entities_visible_last_opened
ON entities(archived, last_opened_at DESC, id);
CREATE INDEX IF NOT EXISTS idx_entities_visible_open_count
ON entities(archived, open_count DESC, last_opened_at DESC, id);
CREATE INDEX IF NOT EXISTS idx_entities_type_last_opened
ON entities(media_type, last_opened_at DESC, id);
CREATE INDEX IF NOT EXISTS idx_entities_source_modified
ON entities(source_modified_at_ms DESC, id);
''';

const schemaV9SystemNodes = '''
INSERT OR IGNORE INTO index_nodes
(id, name, node_type, view_type, sort_order, created_at, updated_at)
VALUES ('system-root', 'Root', 'root', 'tree', 0,
        CAST(strftime('%s','now') AS INTEGER) * 1000,
        CAST(strftime('%s','now') AS INTEGER) * 1000);

UPDATE index_nodes
SET system_key = 'favorites', is_protected = 1, sort_order = -1000
WHERE id = (
  SELECT node.id
  FROM index_nodes node
  JOIN index_nodes root ON root.id = node.parent_id
  WHERE root.node_type = 'root'
    AND node.node_type = 'category_index_root'
    AND node.name = '收藏'
  ORDER BY node.created_at ASC, node.id ASC
  LIMIT 1
);

INSERT OR IGNORE INTO index_nodes
(id, parent_id, name, node_type, view_type, system_key, is_protected,
 sort_order, created_at, updated_at)
SELECT 'system-favorites', root.id, '收藏', 'category_index_root', 'tree',
       'favorites', 1, -1000,
       CAST(strftime('%s','now') AS INTEGER) * 1000,
       CAST(strftime('%s','now') AS INTEGER) * 1000
FROM index_nodes root
WHERE root.node_type = 'root'
  AND NOT EXISTS (SELECT 1 FROM index_nodes WHERE system_key = 'favorites')
LIMIT 1;

INSERT OR IGNORE INTO index_nodes
(id, parent_id, name, node_type, view_type, system_key, is_protected,
 sort_order, created_at, updated_at)
SELECT 'system-rules', root.id, '规则', 'rule_index_root', 'tree',
       'rules', 1, -900,
       CAST(strftime('%s','now') AS INTEGER) * 1000,
       CAST(strftime('%s','now') AS INTEGER) * 1000
FROM index_nodes root
WHERE root.node_type = 'root'
LIMIT 1;

INSERT OR IGNORE INTO index_nodes
(id, parent_id, name, node_type, view_type, system_key, is_protected,
 sort_order, created_at, updated_at)
SELECT 'system-rule-' || value.key, root.id, value.name, 'rule', 'tree',
       'rule.' || value.key, 1, value.position,
       CAST(strftime('%s','now') AS INTEGER) * 1000,
       CAST(strftime('%s','now') AS INTEGER) * 1000
FROM index_nodes root
JOIN (
  SELECT 'frequent' key, '常用' name, 0 position
  UNION ALL SELECT 'recentImages', '最近图片', 1
  UNION ALL SELECT 'recentVideos', '最近视频', 2
  UNION ALL SELECT 'recentText', '最近文本', 3
  UNION ALL SELECT 'recentMusic', '最近音乐', 4
) value
WHERE root.system_key = 'rules';

INSERT OR IGNORE INTO index_rules
(node_id, entity_types_json, extensions_json, default_sort, max_results,
 built_in_kind, updated_at)
SELECT node.id,
       CASE node.system_key
         WHEN 'rule.recentImages' THEN '["image"]'
         WHEN 'rule.recentVideos' THEN '["video"]'
         WHEN 'rule.recentText' THEN '["text","external_link"]'
         WHEN 'rule.recentMusic' THEN '["audio"]'
         ELSE '[]'
       END,
       '[]',
       CASE node.system_key WHEN 'rule.frequent' THEN 'openCount'
                            ELSE 'lastOpened' END,
       1000,
       substr(node.system_key, 6),
       CAST(strftime('%s','now') AS INTEGER) * 1000
FROM index_nodes node
WHERE node.system_key LIKE 'rule.%';
''';
