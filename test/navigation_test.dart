import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/ui/app_sidebar.dart';
import 'package:best_viewer/src/ui/browser_state.dart';

void main() {
  testWidgets(
      'five navigation destinations fit a short window and preserve graph selection',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AppSidebar(
      current: AppSection.data,
      rootTab: BrowserRootTab.graph,
      onChanged: (_) {},
      onRootTabChanged: (_) {},
      collapsed: false,
      onToggleCollapsed: () {},
    ))));
    for (final label in ['资料目录', '资料集', '最近浏览', '任务', '设置']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('宠物'), findsNothing);
    expect(find.text('首页'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
