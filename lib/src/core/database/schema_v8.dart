const schemaV8Upgrade = '''
DELETE FROM library_build_jobs
WHERE index_root_id IN (
  SELECT id FROM index_nodes WHERE node_type = 'graph_index_root'
);

DELETE FROM index_nodes
WHERE node_type = 'graph_index_root';

DROP TABLE IF EXISTS index_node_edges;
DROP TABLE IF EXISTS graph_node_positions;

UPDATE index_nodes SET view_type = 'tree'
WHERE view_type <> 'tree';

INSERT INTO index_node_search(index_node_search) VALUES ('rebuild');
''';
