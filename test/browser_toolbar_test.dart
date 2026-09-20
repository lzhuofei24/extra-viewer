import 'package:best_viewer/src/ui/app_sidebar.dart';
import 'package:best_viewer/src/ui/browser_state.dart';
import 'package:best_viewer/src/ui/browser_toolbar.dart';
import 'package:best_viewer/src/ui/design_tokens.dart';
import 'package:best_viewer/src/ui/gallery_layout_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

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
          onListStyleChanged: (_) {},
          onFolderCoverChanged: (_) {},
          themeChoice: ViewerThemeChoice.system,
          onThemeChanged: (_) {},
          layoutSettings: const GalleryLayoutSettings(),
          onLayoutChanged: (_) {},
          onSearch: () {},
          onToggleImmersive: () {},
          onToggleSelection: () {},
        ),
      ),
    ));
    await tester.tap(find.byTooltip('浏览选项'));
    await tester.pumpAndSettle();
    expect(find.text('浏览选项'), findsNothing);
    final panel = find.byKey(const ValueKey('browser-options-surface'));
    expect(panel, findsOneWidget);
    expect(tester.widget<FloatingGlassSurface>(panel).role,
        GlassSurfaceRole.panel);
    final options = tester
        .widgetList<GlassSegmentedControl>(find.byType(GlassSegmentedControl));
    for (final option in options) {
      expect(option.backgroundColor, Colors.transparent);
      expect(option.settings!.glassColor.a, lessThan(.3));
      expect(option.selectedTextStyle!.color, const Color(0xFF080808));
    }
    expect(
        tester.widget<FloatingGlassSurface>(panel).independentBackdrop, isTrue);
    final container =
        find.descendant(of: panel, matching: find.byType(GlassContainer)).first;
    final inherited = tester
        .element(container)
        .getInheritedWidgetOfExactType<InheritedLiquidGlass>()!;
    expect(inherited.avoidsRefraction, isFalse);
    expect(inherited.isBlurProvidedByAncestor, isFalse);
    expect(find.text('文件夹设置'), findsOneWidget);
    expect(find.text('文件设置'), findsOneWidget);
    expect(find.text('显示'), findsNothing);
    expect(find.text('主题'), findsOneWidget);
    await tester.tap(find.text('文件夹设置'));
    await tester.pumpAndSettle();
    expect(find.text('叠加卡片'), findsOneWidget);
    expect(find.text('方形卡片'), findsOneWidget);
    expect(find.text('自动'), findsNothing);
    expect(find.text('布局'), findsOneWidget);
    expect(find.text('新建分类'), findsNothing);
    await tester.tapAt(const Offset(20, 580));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
    expect(find.byTooltip('选择模式'), findsOneWidget);
    expect(find.text('排序'), findsNothing);
  });

  testWidgets('list display hides card alignment choices', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: BrowserToolbar(
          leading: const Text('位置'),
          browserState:
              const BrowserState(displayMode: BrowserDisplayMode.list),
          onFolderCoverChanged: (_) {},
          onSortChanged: (_) {},
          onDisplayModeChanged: (_) {},
          onGridLayoutChanged: (_) {},
          onListStyleChanged: (_) {},
          themeChoice: ViewerThemeChoice.system,
          onThemeChanged: (_) {},
          layoutSettings: const GalleryLayoutSettings(),
          onLayoutChanged: (_) {},
        ),
      ),
    ));
    await tester.tap(find.byTooltip('浏览选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件设置'));
    await tester.pumpAndSettle();
    expect(find.text('显示'), findsOneWidget);
    expect(find.text('文件夹封面'), findsNothing);
    expect(find.text('列表'), findsOneWidget);
    expect(find.text('紧凑列表'), findsOneWidget);
    expect(find.text('布局'), findsNothing);
    expect(find.text('卡片对齐方式'), findsNothing);
    for (final option in tester.widgetList<GlassSegmentedControl>(
        find.byType(GlassSegmentedControl))) {
      expect(option.selectedTextStyle!.color, const Color(0xFFFFFFFF));
      expect(option.unselectedIconColor, const Color(0xFFFFFFFF));
    }
  });
}
