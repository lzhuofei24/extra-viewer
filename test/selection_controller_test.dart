import 'package:best_viewer/src/core/controllers/selection_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('range selection follows the active entity or node anchor', () {
    final selection = SelectionController();

    selection.startEntity('b');
    selection.toggleEntity('d');
    selection.selectRange(
      visibleEntityIds: const ['a', 'b', 'c', 'd', 'e'],
      visibleNodeIds: const [],
    );
    expect(selection.entityIds, {'b', 'c', 'd'});

    selection.startNode('n3');
    selection.toggleNode('n1');
    selection.selectRange(
      visibleEntityIds: const [],
      visibleNodeIds: const ['n1', 'n2', 'n3', 'n4'],
    );
    expect(selection.nodeIds, {'n1', 'n2', 'n3'});
  });

  test('exiting selection mode clears every selection channel', () {
    final selection = SelectionController();
    selection.addDraggedEntities(const ['a', 'b']);
    selection.startNode('node');

    selection.exit();

    expect(selection.enabled, isFalse);
    expect(selection.entityIds, isEmpty);
    expect(selection.nodeIds, isEmpty);
  });
}
