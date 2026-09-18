import 'package:best_viewer/src/ui/app_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/app.dart';

void main() {
  testWidgets('shows redesigned Best Viewer shell',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      BestViewerApp(databaseFactory: () async => AppDatabase.openInMemory()),
    );
    // Database startup uses real isolate messages, which fake timer pumps do
    // not advance. Give the worker a bounded real-time startup window.
    for (var attempt = 0;
        attempt < 100 && find.text('目录').evaluate().isEmpty;
        attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('目录'), findsWidgets);
    expect(find.text('分类'), findsOneWidget);
    expect(find.text('规则'), findsOneWidget);
    expect(find.text('管理'), findsOneWidget);
    expect(find.text('宠物'), findsNothing);
    expect(find.byIcon(Icons.folder_copy_rounded), findsWidgets);
    expect(find.byIcon(Icons.star_outline_rounded), findsNothing);
    expect(find.byIcon(Icons.search_outlined), findsNothing);
    expect(find.byIcon(Icons.receipt_long_outlined), findsNothing);
    expect(find.byTooltip('收起功能栏'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('规则'));
    for (var attempt = 0;
        attempt < 100 && find.text('常用').evaluate().isEmpty;
        attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
    expect(find.text('常用'), findsOneWidget);

    await tester.binding.setSurfaceSize(const Size(1000, 600));
    await tester.pumpAndSettle();
    expect(find.text('常用'), findsOneWidget);
    expect(find.byTooltip('收起功能栏'), findsNothing);
    expect(find.byType(FloatingGlassSurface), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    for (var attempt = 0; attempt < 5; attempt++) {
      await tester.pump(const Duration(seconds: 3));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
  });
}
