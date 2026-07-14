/// Pure selection state for library entities and index nodes.
///
/// It intentionally has no Flutter or repository dependency, making range,
/// inversion, and drag selection deterministic and easy to reuse on desktop
/// and touch devices.
class SelectionController {
  final Set<String> _entityIds = <String>{};
  final Set<String> _nodeIds = <String>{};
  bool _enabled = false;
  String? _entityAnchorId;
  String? _entityFocusId;
  String? _nodeAnchorId;
  String? _nodeFocusId;

  bool get enabled => _enabled;
  Set<String> get entityIds => Set<String>.unmodifiable(_entityIds);
  Set<String> get nodeIds => Set<String>.unmodifiable(_nodeIds);

  void toggleMode() {
    _enabled = !_enabled;
    if (!_enabled) clear();
  }

  void exit() {
    _enabled = false;
    clear();
  }

  void clear() {
    _entityIds.clear();
    _nodeIds.clear();
    _entityAnchorId = null;
    _entityFocusId = null;
    _nodeAnchorId = null;
    _nodeFocusId = null;
  }

  void clearEntities({bool exitMode = false}) {
    if (exitMode) _enabled = false;
    _entityIds.clear();
    _entityAnchorId = null;
    _entityFocusId = null;
  }

  void toggleEntity(String entityId) {
    if (!_entityIds.add(entityId)) {
      _entityIds.remove(entityId);
      if (_entityFocusId == entityId) _entityFocusId = null;
      return;
    }
    _entityAnchorId ??= entityId;
    _entityFocusId = entityId;
    _nodeAnchorId = null;
    _nodeFocusId = null;
  }

  void toggleNode(String nodeId) {
    if (!_nodeIds.add(nodeId)) {
      _nodeIds.remove(nodeId);
      if (_nodeFocusId == nodeId) _nodeFocusId = null;
      return;
    }
    _nodeAnchorId ??= nodeId;
    _nodeFocusId = nodeId;
    _entityAnchorId = null;
    _entityFocusId = null;
  }

  void startEntity(String entityId) {
    _enabled = true;
    _entityIds.add(entityId);
    _entityAnchorId ??= entityId;
    _entityFocusId = entityId;
    _nodeAnchorId = null;
    _nodeFocusId = null;
  }

  void startNode(String nodeId) {
    _enabled = true;
    _nodeIds.add(nodeId);
    _nodeAnchorId ??= nodeId;
    _nodeFocusId = nodeId;
    _entityAnchorId = null;
    _entityFocusId = null;
  }

  void addDraggedEntities(Iterable<String> entityIds) {
    final ids = entityIds.toList(growable: false);
    if (ids.isEmpty) return;
    _enabled = true;
    _entityIds.addAll(ids);
    _entityAnchorId ??= ids.first;
    _entityFocusId = ids.last;
  }

  void selectAll({
    required Iterable<String> visibleEntityIds,
    required Iterable<String> visibleNodeIds,
  }) {
    final entities = visibleEntityIds.toList(growable: false);
    _entityIds.addAll(entities);
    _nodeIds.addAll(visibleNodeIds);
    if (entities.isNotEmpty) {
      _entityAnchorId ??= entities.first;
      _entityFocusId = entities.last;
    }
  }

  void invert({
    required Iterable<String> visibleEntityIds,
    required Iterable<String> visibleNodeIds,
  }) {
    for (final id in visibleEntityIds) {
      if (!_entityIds.remove(id)) {
        _entityIds.add(id);
        _entityAnchorId ??= id;
        _entityFocusId = id;
      }
    }
    for (final id in visibleNodeIds) {
      if (!_nodeIds.remove(id)) {
        _nodeIds.add(id);
        _nodeAnchorId ??= id;
        _nodeFocusId = id;
      }
    }
  }

  void selectRange({
    required List<String> visibleEntityIds,
    required List<String> visibleNodeIds,
  }) {
    final nodeAnchor = _nodeAnchorId;
    final nodeFocus = _nodeFocusId;
    if (nodeAnchor != null && nodeFocus != null) {
      _addRange(_nodeIds, visibleNodeIds, nodeAnchor, nodeFocus);
      return;
    }
    final entityAnchor = _entityAnchorId;
    final entityFocus = _entityFocusId;
    if (entityAnchor != null && entityFocus != null) {
      _addRange(_entityIds, visibleEntityIds, entityAnchor, entityFocus);
    }
  }

  void _addRange(
    Set<String> selected,
    List<String> visible,
    String anchor,
    String focus,
  ) {
    final start = visible.indexOf(anchor);
    final end = visible.indexOf(focus);
    if (start < 0 || end < 0) return;
    final lower = start < end ? start : end;
    final upper = start < end ? end : start;
    selected.addAll(visible.sublist(lower, upper + 1));
  }
}
