import 'package:best_viewer/src/ui/app_sidebar.dart';
import 'package:best_viewer/src/ui/browser_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('landscape rail shows five destinations and switches data roots',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    BrowserRootTab? selectedRootTab;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.centerLeft,
          child: AppNavigation(
            layout: AppNavigationLayout.rail,
            current: AppSection.data,
            rootTab: BrowserRootTab.tree,
            onChanged: (_) {},
            onRootTabChanged: (value) => selectedRootTab = value,
            collapsed: false,
            onToggleCollapsed: () {},
          ),
        ),
      ),
    ));

    for (final label in ['目录', '分类', '最近', '管理', '设置']) {
      expect(find.text(label), findsOneWidget);
    }

    for (final entry in {
      '目录': BrowserRootTab.directory,
      '分类': BrowserRootTab.tree,
    }.entries) {
      await tester.ensureVisible(find.text(entry.key));
      await tester.tap(find.text(entry.key));
      expect(selectedRootTab, entry.value);
    }
    expect(find.byTooltip('收起功能栏'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('portrait bottom navigation keeps all destinations visible',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    AppSection? selectedSection;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: AppNavigation(
              layout: AppNavigationLayout.bottom,
              current: AppSection.gallery,
              rootTab: BrowserRootTab.directory,
              onChanged: (value) => selectedSection = value,
              onRootTabChanged: (_) {},
              collapsed: false,
              onToggleCollapsed: () {},
            ),
          ),
        ),
      ),
    ));

    for (final label in ['目录', '分类', '最近', '管理', '设置']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byTooltip('收起功能栏'), findsNothing);

    await tester.tap(find.text('设置'));
    expect(selectedSection, AppSection.settings);
    expect(tester.takeException(), isNull);
  });

  testWidgets('diagnostics is selected as settings in bottom navigation',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppNavigation(
          layout: AppNavigationLayout.bottom,
          current: AppSection.logs,
          rootTab: BrowserRootTab.directory,
          onChanged: (_) {},
          onRootTabChanged: (_) {},
          collapsed: false,
          onToggleCollapsed: () {},
        ),
      ),
    ));

    expect(
      find.bySemanticsLabel('设置'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    handle.dispose();
  });
}
