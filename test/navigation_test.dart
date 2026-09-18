import 'package:best_viewer/src/ui/app_sidebar.dart';
import 'package:best_viewer/src/ui/browser_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('landscape bottom bar shows destinations and switches data roots',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    BrowserRootTab? selectedRootTab;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: AppNavigation(
            current: AppSection.data,
            rootTab: BrowserRootTab.tree,
            onChanged: (_) {},
            onRootTabChanged: (value) => selectedRootTab = value,
          ),
        ),
      ),
    ));

    for (final label in ['目录', '分类', '规则', '管理']) {
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
    expect(find.byTooltip('收起功能栏'), findsNothing);
    expect(find.byType(FloatingGlassSurface), findsOneWidget);
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
              current: AppSection.rules,
              rootTab: BrowserRootTab.directory,
              onChanged: (value) => selectedSection = value,
              onRootTabChanged: (_) {},
            ),
          ),
        ),
      ),
    ));

    for (final label in ['目录', '分类', '规则', '管理']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byType(FloatingGlassSurface), findsOneWidget);
    expect(find.byTooltip('收起功能栏'), findsNothing);

    await tester.tap(find.text('规则'));
    expect(selectedSection, AppSection.rules);
    expect(tester.takeException(), isNull);
  });
}
