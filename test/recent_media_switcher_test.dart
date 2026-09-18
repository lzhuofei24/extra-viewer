import 'package:best_viewer/src/ui/app_sidebar.dart';
import 'package:best_viewer/src/ui/recent_media_switcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('recent media switcher exposes four sections', (tester) async {
    AppSection? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecentMediaSwitcher(
            current: AppSection.gallery,
            onChanged: (value) => selected = value,
          ),
        ),
      ),
    );

    for (final label in ['图片', '视频', '阅读', '音乐']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byType(FloatingGlassSurface), findsOneWidget);

    await tester.tap(find.text('音乐'));
    expect(selected, AppSection.music);
  });
}
