part of 'library_repository.dart';

mixin RuleRepositoryMixin on LibraryRepositoryBase {
  RuleDefinition createRule({
    required String name,
    List<EntityType> entityTypes = const [],
    List<String> extensions = const [],
    String? scopeNodeId,
    int? minSize,
    int? maxSize,
    int? modifiedWithinDays,
    int? openedWithinDays,
    RuleSortMode defaultSort = RuleSortMode.lastOpened,
    int maxResults = 1000,
  }) {
    final ruleRoot = _systemNode('rules');
    if (ruleRoot == null) {
      throw StateError('System rule root is unavailable');
    }
    _validateRuleFields(
      scopeNodeId: scopeNodeId,
      minSize: minSize,
      maxSize: maxSize,
      modifiedWithinDays: modifiedWithinDays,
      openedWithinDays: openedWithinDays,
      maxResults: maxResults,
    );
    return writeTransaction(() {
      final normalizedName = _normalizeIndexNodeName(name);
      final duplicate = database.db.select(
        'SELECT 1 FROM index_nodes WHERE parent_id = ? AND name = ? AND node_type = ? LIMIT 1',
        [ruleRoot.id, normalizedName, NodeType.ruleNode.value],
      );
      if (duplicate.isNotEmpty) {
        throw ArgumentError.value(name, 'name', 'Rule name already exists');
      }
      final now = nowMillis();
      final node = IndexNode(
        id: newId(),
        parentId: ruleRoot.id,
        name: normalizedName,
        nodeType: NodeType.ruleNode,
        viewType: ViewType.tree,
        sortOrder: 100,
        createdAtMs: now,
        updatedAtMs: now,
      );
      database.db.execute('''
        INSERT INTO index_nodes
        (id, parent_id, name, node_type, sort_order, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      ''', [
        node.id,
        node.parentId,
        node.name,
        node.nodeType.value,
        node.sortOrder,
        now,
        now
      ]);
      _writeRule(
        nodeId: node.id,
        entityTypes: entityTypes,
        extensions: extensions,
        scopeNodeId: scopeNodeId,
        minSize: minSize,
        maxSize: maxSize,
        modifiedWithinDays: modifiedWithinDays,
        openedWithinDays: openedWithinDays,
        defaultSort: defaultSort,
        maxResults: maxResults,
      );
      return _ruleById(node.id)!;
    });
  }

  RuleDefinition updateRule({
    required String nodeId,
    required String name,
    List<EntityType> entityTypes = const [],
    List<String> extensions = const [],
    String? scopeNodeId,
    int? minSize,
    int? maxSize,
    int? modifiedWithinDays,
    int? openedWithinDays,
    RuleSortMode defaultSort = RuleSortMode.lastOpened,
    int maxResults = 1000,
  }) {
    final existing = _ruleById(nodeId);
    if (existing == null) {
      throw ArgumentError.value(nodeId, 'nodeId', 'Rule does not exist');
    }
    if (existing.node.isProtected || existing.isBuiltIn) {
      throw StateError('Built-in rules cannot be edited');
    }
    _validateRuleFields(
      scopeNodeId: scopeNodeId,
      minSize: minSize,
      maxSize: maxSize,
      modifiedWithinDays: modifiedWithinDays,
      openedWithinDays: openedWithinDays,
      maxResults: maxResults,
    );
    return writeTransaction(() {
      final normalizedName = _normalizeIndexNodeName(name);
      final duplicate = database.db.select(
        'SELECT 1 FROM index_nodes WHERE parent_id = ? AND name = ? AND node_type = ? AND id <> ? LIMIT 1',
        [
          existing.node.parentId,
          normalizedName,
          NodeType.ruleNode.value,
          nodeId
        ],
      );
      if (duplicate.isNotEmpty) {
        throw ArgumentError.value(name, 'name', 'Rule name already exists');
      }
      database.db.execute(
        'UPDATE index_nodes SET name = ?, updated_at = ? WHERE id = ?',
        [normalizedName, nowMillis(), nodeId],
      );
      _writeRule(
        nodeId: nodeId,
        entityTypes: entityTypes,
        extensions: extensions,
        scopeNodeId: scopeNodeId,
        minSize: minSize,
        maxSize: maxSize,
        modifiedWithinDays: modifiedWithinDays,
        openedWithinDays: openedWithinDays,
        defaultSort: defaultSort,
        maxResults: maxResults,
      );
      database.db.execute(
        'DELETE FROM rule_access_items WHERE rule_id = ?',
        [nodeId],
      );
      return _ruleById(nodeId)!;
    });
  }

  void deleteRule(String nodeId) {
    final rule = _ruleById(nodeId);
    if (rule == null) return;
    if (rule.node.isProtected || rule.isBuiltIn) {
      throw StateError('Built-in rules cannot be deleted');
    }
    database.db.execute('DELETE FROM index_nodes WHERE id = ?', [nodeId]);
  }

  RuleDefinition? getRule(String nodeId) => _ruleById(nodeId);

  void _writeRule({
    required String nodeId,
    required List<EntityType> entityTypes,
    required List<String> extensions,
    required String? scopeNodeId,
    required int? minSize,
    required int? maxSize,
    required int? modifiedWithinDays,
    required int? openedWithinDays,
    required RuleSortMode defaultSort,
    required int maxResults,
  }) {
    final now = nowMillis();
    final normalizedExtensions = extensions
        .map((value) => value.trim().toLowerCase().replaceFirst('.', ''))
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false)
      ..sort();
    database.db.execute(
      '''
      INSERT INTO index_rules
      (node_id, entity_types_json, extensions_json, scope_node_id, min_size,
       max_size, modified_within_days, opened_within_days, default_sort,
       max_results, updated_at, scope_state)
      VALUES (?, ?, ?, NULL, ?, ?, NULL, NULL, ?, ?, ?, 'all')
      ON CONFLICT(node_id) DO UPDATE SET
        entity_types_json = excluded.entity_types_json,
        extensions_json = excluded.extensions_json,
        scope_node_id = excluded.scope_node_id,
        scope_state = excluded.scope_state,
        min_size = excluded.min_size,
        max_size = excluded.max_size,
        modified_within_days = excluded.modified_within_days,
        opened_within_days = excluded.opened_within_days,
        default_sort = excluded.default_sort,
        max_results = excluded.max_results,
        updated_at = excluded.updated_at
      ''',
      [
        nodeId,
        jsonEncode(entityTypes.map((value) => value.value).toList()),
        jsonEncode(normalizedExtensions),
        minSize,
        maxSize,
        defaultSort.name,
        maxResults,
        now,
      ],
    );
  }

  void _validateRuleFields({
    required String? scopeNodeId,
    required int? minSize,
    required int? maxSize,
    required int? modifiedWithinDays,
    required int? openedWithinDays,
    required int maxResults,
  }) {
    if (minSize != null && minSize < 0 || maxSize != null && maxSize < 0) {
      throw ArgumentError('Rule file sizes must be non-negative');
    }
    if (minSize != null && maxSize != null && minSize > maxSize) {
      throw ArgumentError('Rule minimum size exceeds maximum size');
    }
    if (scopeNodeId != null ||
        modifiedWithinDays != null ||
        openedWithinDays != null) {
      throw ArgumentError('Access rules only support type, extension and size');
    }
    if (maxResults < 1 || maxResults > 1000) {
      throw ArgumentError.value(maxResults, 'maxResults');
    }
  }

  IndexNode? _systemNode(String key) {
    final rows = database.db.select(
      'SELECT * FROM index_nodes WHERE system_key = ? LIMIT 1',
      [key],
    );
    return rows.isEmpty ? null : _nodeFromRow(rows.first);
  }

  RuleDefinition? _ruleById(String nodeId) {
    final rows = database.db.select(
      '''
      SELECT node.*, rule.entity_types_json, rule.extensions_json,
             rule.scope_node_id, rule.scope_state, rule.min_size, rule.max_size,
             rule.modified_within_days, rule.opened_within_days,
             rule.default_sort, rule.max_results, rule.built_in_kind,
             rule.updated_at AS rule_updated_at
      FROM index_rules rule
      JOIN index_nodes node ON node.id = rule.node_id
      WHERE node.id = ? AND node.node_type = ?
      LIMIT 1
      ''',
      [nodeId, NodeType.ruleNode.value],
    );
    return rows.isEmpty ? null : _ruleFromRow(rows.first);
  }
}

RuleDefinition _ruleFromRow(Row row) {
  List<String> strings(String column) =>
      (jsonDecode(row[column] as String) as List).cast<String>();
  final builtIn = row['built_in_kind'] as String?;
  return RuleDefinition(
    node: _nodeFromRow(row),
    entityTypes: strings('entity_types_json')
        .map(EntityType.fromValue)
        .toList(growable: false),
    extensions: strings('extensions_json'),
    scopeNodeId: null,
    scopeMissing: false,
    minSize: row['min_size'] as int?,
    maxSize: row['max_size'] as int?,
    modifiedWithinDays: null,
    openedWithinDays: null,
    defaultSort: RuleSortMode.values.byName(row['default_sort'] as String),
    maxResults: row['max_results'] as int,
    builtInKind:
        builtIn == null ? null : BuiltInRuleKind.values.byName(builtIn),
    updatedAtMs: row['rule_updated_at'] as int,
  );
}

String _accessRuleOrderBy(RuleSortMode sort, {String alias = 'e'}) =>
    switch (sort) {
      RuleSortMode.lastOpened =>
        'COALESCE($alias.last_opened_at, 0) DESC, $alias.id ASC',
      RuleSortMode.openCount =>
        '$alias.open_count DESC, COALESCE($alias.last_opened_at, 0) DESC, $alias.id ASC',
      RuleSortMode.modified =>
        '$alias.source_modified_at_ms DESC, $alias.id ASC',
      RuleSortMode.name => '$alias.name COLLATE NOCASE ASC, $alias.id ASC',
      RuleSortMode.size => '$alias.size DESC, $alias.id ASC',
    };
