import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/ui/index_management_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('management roots use two portrait columns', (tester) async {
    await _pumpManagement(tester, const Size(400, 800));
    for (final grid in tester.widgetList<GridView>(find.byType(GridView))) {
      final delegate =
          grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 2);
    }
    expect(tester.takeException(), isNull);
    expect(find.text('添加资料'), findsNothing);
    expect(find.text('全部资料'), findsOneWidget);
    expect(find.byTooltip('添加目录'), findsOneWidget);
    await tester.tap(find.byTooltip('操作').first);
    await tester.pumpAndSettle();
    expect(find.text('更新'), findsOneWidget);
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('management roots use four landscape columns', (tester) async {
    await _pumpManagement(tester, const Size(1000, 600));
    for (final grid in tester.widgetList<GridView>(find.byType(GridView))) {
      final delegate =
          grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 4);
    }
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpManagement(WidgetTester tester, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  const roots = [
    IndexNode(
      id: 'directory',
      name: '目录',
      nodeType: NodeType.directoryIndexRoot,
      viewType: ViewType.tree,
      sortOrder: 0,
      createdAtMs: 0,
      updatedAtMs: 0,
    ),
    IndexNode(
      id: 'collection',
      name: '分类',
      nodeType: NodeType.customIndexRoot,
      viewType: ViewType.tree,
      sortOrder: 1,
      createdAtMs: 0,
      updatedAtMs: 0,
    ),
  ];
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: Scaffold(
        body: IndexManagementPage(
          roots: roots,
          rootCounts: const {},
          scanning: false,
          progress: null,
          recoverableJobs: const [],
          actions: IndexManagementActions(
            onCreateDirectoryIndex: () {},
            onPause: () {},
            onCancel: () {},
            onResume: (_) {},
            onRecheck: (_) {},
            onRetryFailed: (_) {},
            onAbandon: (_) {},
            onRename: (_) {},
            onDelete: (_) {},
            onUpdateDirectoryIndex: (_) {},
            onRebuildNodePreviews: (_) {},
            onCreateCollection: () {},
            onCreateNodeAtRoot: (_) {},
            onCreateRule: () {},
            onEditRule: (_) {},
            onDeleteRule: (_) {},
          ),
        ),
      ),
    ),
  ));
}
