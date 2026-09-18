import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/ui/app_sidebar.dart';
import 'package:best_viewer/src/ui/browser_state.dart';

void main() {
  testWidgets(
      'five navigation destinations fit a short window and switch data roots',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    BrowserRootTab? selectedRootTab;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AppSidebar(
      current: AppSection.data,
      rootTab: BrowserRootTab.tree,
      onChanged: (_) {},
      onRootTabChanged: (value) => selectedRootTab = value,
      collapsed: false,
      onToggleCollapsed: () {},
    ))));
    for (final label in ['目录', '分类', '最近', '管理', '设置']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('宠物'), findsNothing);
    expect(find.text('首页'), findsNothing);

    for (final entry in {
      '目录': BrowserRootTab.directory,
      '分类': BrowserRootTab.tree,
    }.entries) {
      await tester.ensureVisible(find.text(entry.key));
      await tester.tap(find.text(entry.key));
      expect(selectedRootTab, entry.value);
    }
    expect(tester.takeException(), isNull);
  });
}
