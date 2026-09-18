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
          themeChoice: ViewerThemeChoice.system,
          onThemeChanged: (_) {},
          layoutPreset: GalleryLayoutPreset.standard,
          onLayoutPresetChanged: (_) {},
          onSearch: () {},
          onToggleImmersive: () {},
          onToggleSelection: () {},
        ),
      ),
    ));
    await tester.tap(find.byTooltip('浏览选项'));
    await tester.pumpAndSettle();
    expect(find.text('浏览选项'), findsOneWidget);
    final panel = find.byKey(const ValueKey('browser-options-surface'));
    expect(panel, findsOneWidget);
    expect(
        tester.widget<FloatingGlassSurface>(panel).independentBackdrop, isTrue);
    final container =
        find.descendant(of: panel, matching: find.byType(GlassContainer)).first;
    final inherited = tester
        .element(container)
        .getInheritedWidgetOfExactType<InheritedLiquidGlass>()!;
    expect(inherited.avoidsRefraction, isFalse);
    expect(inherited.isBlurProvidedByAncestor, isFalse);
    final anchor = tester.widget<MenuAnchor>(find.byType(MenuAnchor).first);
    expect(anchor.clipBehavior, Clip.none);
    expect(anchor.style!.backgroundColor!.resolve({}), Colors.transparent);
    expect(find.text('样式'), findsOneWidget);
    expect(find.text('主题'), findsOneWidget);
    expect(find.text('布局'), findsOneWidget);
    expect(find.text('新建分类'), findsNothing);
    await tester.tap(find.byTooltip('浏览选项'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
    expect(find.byTooltip('选择模式'), findsOneWidget);
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
          onListStyleChanged: (_) {},
          themeChoice: ViewerThemeChoice.system,
          onThemeChanged: (_) {},
          layoutPreset: GalleryLayoutPreset.standard,
          onLayoutPresetChanged: (_) {},
        ),
      ),
    ));
    await tester.tap(find.byTooltip('浏览选项'));
    await tester.pumpAndSettle();
    expect(find.text('显示'), findsOneWidget);
    expect(find.text('文本'), findsOneWidget);
    expect(find.text('紧凑'), findsNWidgets(2));
    expect(find.text('正常'), findsOneWidget);
    expect(find.text('卡片对齐方式'), findsNothing);
  });
}
