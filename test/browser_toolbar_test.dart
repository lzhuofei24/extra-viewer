import 'package:best_viewer/src/ui/browser_state.dart';
import 'package:best_viewer/src/ui/browser_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('browser options and management actions use separate menus',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BrowserToolbar(
          leading: const Text('位置'),
          browserState: const BrowserState(),
          onSortChanged: (_) {},
          onDisplayModeChanged: (_) {},
          onGridLayoutChanged: (_) {},
          onSearch: () {},
          onToggleImmersive: () {},
          onToggleSelection: () {},
          moreActions: [
            BrowserToolbarAction(
              label: '新建分类',
              icon: Icons.create_new_folder_outlined,
              onPressed: () {},
            ),
          ],
        ),
      ),
    ));
    await tester.tap(find.byTooltip('浏览选项'));
    await tester.pumpAndSettle();
    expect(find.text('浏览选项'), findsOneWidget);
    expect(find.text('卡片对齐方式'), findsOneWidget);
    expect(find.text('新建分类'), findsNothing);
    await tester.tap(find.byTooltip('浏览选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('新建分类'), findsOneWidget);
    expect(find.text('排序'), findsNothing);
  });

  testWidgets('list display hides card alignment choices', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BrowserToolbar(
          leading: const Text('位置'),
          browserState:
              const BrowserState(displayMode: BrowserDisplayMode.list),
          onSortChanged: (_) {},
          onDisplayModeChanged: (_) {},
          onGridLayoutChanged: (_) {},
        ),
      ),
    ));
    await tester.tap(find.byTooltip('浏览选项'));
    await tester.pumpAndSettle();
    expect(find.text('显示方式'), findsOneWidget);
    expect(find.text('卡片对齐方式'), findsNothing);
  });
}
