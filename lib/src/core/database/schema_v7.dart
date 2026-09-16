const schemaV7Upgrade = '''
CREATE VIRTUAL TABLE index_node_search USING fts5(
  name, content='index_nodes', content_rowid='rowid', tokenize='trigram'
);
CREATE TRIGGER index_node_search_insert AFTER INSERT ON index_nodes BEGIN
  INSERT INTO index_node_search(rowid, name) VALUES (new.rowid, new.name);
END;
CREATE TRIGGER index_node_search_delete AFTER DELETE ON index_nodes BEGIN
  INSERT INTO index_node_search(index_node_search, rowid, name)
  VALUES ('delete', old.rowid, old.name);
END;
CREATE TRIGGER index_node_search_update AFTER UPDATE OF name ON index_nodes BEGIN
  INSERT INTO index_node_search(index_node_search, rowid, name)
  VALUES ('delete', old.rowid, old.name);
  INSERT INTO index_node_search(rowid, name) VALUES (new.rowid, new.name);
END;
INSERT INTO index_node_search(index_node_search) VALUES ('rebuild');
''';
