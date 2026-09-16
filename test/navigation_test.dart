import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/ui/app_sidebar.dart';
import 'package:best_viewer/src/ui/browser_state.dart';

void main() {
  testWidgets(
      'six navigation destinations fit a short window and preserve graph selection',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    BrowserRootTab? selectedRootTab;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AppSidebar(
      current: AppSection.data,
      rootTab: BrowserRootTab.graph,
      onChanged: (_) {},
      onRootTabChanged: (value) => selectedRootTab = value,
      collapsed: false,
      onToggleCollapsed: () {},
    ))));
    for (final label in ['目录索引', '树索引', '图索引', '最近', '管理', '设置']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('宠物'), findsNothing);
    expect(find.text('首页'), findsNothing);

    for (final entry in {
      '目录索引': BrowserRootTab.directory,
      '树索引': BrowserRootTab.tree,
      '图索引': BrowserRootTab.graph,
    }.entries) {
      await tester.ensureVisible(find.text(entry.key));
      await tester.tap(find.text(entry.key));
      expect(selectedRootTab, entry.value);
    }
    expect(tester.takeException(), isNull);
  });
}
