import 'package:best_viewer/src/ui/design_tokens.dart';
import 'package:best_viewer/src/ui/gallery_layout_settings.dart';
import 'package:best_viewer/src/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('settings exposes only the three layout presets', (tester) async {
    GalleryLayoutPreset? changedPreset;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsPage(
          themeChoice: ViewerThemeChoice.system,
          layoutPreset: GalleryLayoutPreset.standard,
          onThemeChanged: (_) {},
          onLayoutPresetChanged: (value) => changedPreset = value,
        ),
      ),
    ));

    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('浏览布局'), findsOneWidget);
    expect(find.text('紧凑'), findsOneWidget);
    expect(find.text('默认'), findsOneWidget);
    expect(find.text('宽阔'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(find.byTooltip('增加'), findsNothing);
    expect(find.text('恢复默认布局'), findsNothing);
    expect(find.text('本地资料数据'), findsNothing);

    await tester.tap(find.text('紧凑'));
    expect(changedPreset, GalleryLayoutPreset.compact);
    expect(tester.takeException(), isNull);
  });

  testWidgets('layout presets fit portrait and landscape', (tester) async {
    for (final size in [const Size(360, 640), const Size(1000, 600)]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: size),
          child: Scaffold(
            body: SettingsPage(
              themeChoice: ViewerThemeChoice.system,
              layoutPreset: GalleryLayoutPreset.standard,
              onThemeChanged: (_) {},
              onLayoutPresetChanged: (_) {},
            ),
          ),
        ),
      ));
      expect(find.text('紧凑'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.binding.setSurfaceSize(null);
  });
}
