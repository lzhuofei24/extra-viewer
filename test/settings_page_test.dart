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
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsPage(
          themeChoice: ViewerThemeChoice.system,
          layoutSettings: const GalleryLayoutSettings(),
          onThemeChanged: (_) {},
          onLayoutChanged: (_) {},
          onResetLayout: () => resetCount++,
          onResetLocalIndex: () {},
        ),
      ),
    ));

    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('浏览布局'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(7));
    expect(find.text('默认排序'), findsNothing);
    expect(find.text('卡片对齐方式'), findsNothing);
    await tester.tap(find.text('恢复默认布局'));
    expect(resetCount, 1);
    expect(tester.takeException(), isNull);
  });
}
