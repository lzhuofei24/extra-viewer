import 'package:best_viewer/src/ui/design_tokens.dart';
import 'package:best_viewer/src/ui/gallery_layout_settings.dart';
import 'package:best_viewer/src/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('settings owns theme and layout but not browse choices',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var resetCount = 0;
    GalleryLayoutSettings? changedLayout;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsPage(
          themeChoice: ViewerThemeChoice.system,
          layoutSettings: const GalleryLayoutSettings(),
          onThemeChanged: (_) {},
          onLayoutChanged: (value) => changedLayout = value,
          onResetLayout: () => resetCount++,
        ),
      ),
    ));

    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('浏览布局'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(find.byTooltip('减少'), findsNWidgets(9));
    expect(find.byTooltip('增加'), findsNWidgets(9));
    expect(find.text('等宽 · 竖屏'), findsOneWidget);
    expect(find.text('方格 · 横屏'), findsOneWidget);
    expect(find.text('默认排序'), findsNothing);
    expect(find.text('卡片对齐方式'), findsNothing);
    expect(find.text('本地资料数据'), findsNothing);
    expect(find.text('清除本地资料数据'), findsNothing);
    await tester.tap(find.byTooltip('增加').first);
    expect(changedLayout?.pageMargin, 10);
    await tester.tap(find.text('恢复默认布局'));
    expect(resetCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape settings use two responsive groups', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(1000, 600)),
        child: Scaffold(
          body: SettingsPage(
            themeChoice: ViewerThemeChoice.system,
            layoutSettings: const GalleryLayoutSettings(),
            onThemeChanged: (_) {},
            onLayoutChanged: (_) {},
            onResetLayout: () {},
          ),
        ),
      ),
    ));

    expect(find.text('外观'), findsOneWidget);
    expect(find.text('卡片'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('portrait settings remain usable on a narrow screen',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(360, 640)),
        child: Scaffold(
          body: SettingsPage(
            themeChoice: ViewerThemeChoice.system,
            layoutSettings: const GalleryLayoutSettings(),
            onThemeChanged: (_) {},
            onLayoutChanged: (_) {},
            onResetLayout: () {},
          ),
        ),
      ),
    ));

    expect(find.byType(Slider), findsNothing);
    expect(find.byTooltip('增加'), findsNWidgets(9));
    expect(tester.takeException(), isNull);
  });
}
