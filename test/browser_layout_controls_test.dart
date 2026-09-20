import 'package:best_viewer/src/ui/browser_toolbar.dart';
import 'package:best_viewer/src/ui/browser_state.dart';
import 'package:best_viewer/src/ui/browser_list.dart';
import 'package:best_viewer/src/ui/design_tokens.dart';
import 'package:best_viewer/src/ui/gallery_layout_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'options order and live counts remain independent by style and orientation',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var state = const BrowserState(gridLayout: BrowserGridLayout.equalWidth);
    var layout = const GalleryLayoutSettings();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatefulBuilder(
                builder: (context, update) => BrowserToolbar(
                      leading: const Text('目录'),
                      browserState: state,
                      showFolders: false,
                      onSortChanged: (v) =>
                          update(() => state = state.copyWith(sortMode: v)),
                      onDisplayModeChanged: (v) =>
                          update(() => state = state.copyWith(displayMode: v)),
                      onGridLayoutChanged: (v) =>
                          update(() => state = state.copyWith(gridLayout: v)),
                      onListStyleChanged: (v) =>
                          update(() => state = state.copyWith(listStyle: v)),
                      themeChoice: ViewerThemeChoice.system,
                      onThemeChanged: (_) {},
                      layoutSettings: layout,
                      onLayoutChanged: (v) => update(() => layout = v),
                    )))));
    await tester.tap(find.byTooltip('浏览选项'));
    await tester.pumpAndSettle();
    final labels = ['排序', '主题', '显示', '样式', '布局'];
    for (var i = 1; i < labels.length; i++) {
      expect(tester.getTopLeft(find.text(labels[i])).dy,
          greaterThan(tester.getTopLeft(find.text(labels[i - 1])).dy));
    }
    await tester.tap(find.byTooltip('增加每行数量'));
    await tester.pumpAndSettle();
    expect(layout.portraitEqualWidthColumns, 4);
    expect(
        find.byKey(const ValueKey('browser-options-surface')), findsOneWidget);
    await tester.tap(find.text('方形'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('减少每行数量'));
    await tester.pumpAndSettle();
    expect(layout.portraitSquareColumns, 2);
    expect(layout.portraitEqualWidthColumns, 4);
    await tester.tap(find.text('等高'));
    await tester.pumpAndSettle();
    expect(find.text('高度级别'), findsOneWidget);
    await tester.tap(find.byTooltip('增加高度级别'));
    await tester.pumpAndSettle();
    expect(layout.portraitEqualHeightLevel, 7);
    await tester.tap(find.text('列表'));
    await tester.pumpAndSettle();
    expect(find.text('每行 1 项（竖屏）'), findsOneWidget);
    expect(find.byTooltip('增加每行数量'), findsNothing);
    tester.view.physicalSize = const Size(1400, 800);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('浏览选项'));
    await tester.pumpAndSettle();
    final increase =
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add));
    expect(increase.onPressed, isNull);
    await tester.ensureVisible(find.byTooltip('减少每行数量'));
    await tester.tap(find.byTooltip('减少每行数量'));
    await tester.pumpAndSettle();
    expect(layout.landscapeListColumns, 2);
    expect(layout.portraitEqualHeightLevel, 7);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'list uses configurable landscape columns but always one portrait column',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CustomScrollView(slivers: [
      BrowserListSliver(
          count: 4,
          style: BrowserListStyle.text,
          padding: 8,
          landscapeColumns: 2,
          itemBuilder: (_, i) => Text('item $i')),
    ]))));
    expect(tester.getTopLeft(find.text('item 0')).dy,
        tester.getTopLeft(find.text('item 1')).dy);
    expect(tester.getTopLeft(find.text('item 2')).dy,
        greaterThan(tester.getTopLeft(find.text('item 1')).dy));
    tester.view.physicalSize = const Size(600, 1000);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('item 1')).dy,
        greaterThan(tester.getTopLeft(find.text('item 0')).dy));
    expect(tester.takeException(), isNull);
  });
}
