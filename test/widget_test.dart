import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/app.dart';

void main() {
  testWidgets('shows redesigned Best Viewer shell',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      BestViewerApp(databaseFactory: () async => AppDatabase.openInMemory()),
    );
    // Database startup uses real isolate messages, which fake timer pumps do
    // not advance. Give the worker a bounded real-time startup window.
    for (var attempt = 0; attempt < 100 && find.text('首页').evaluate().isEmpty; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('首页'), findsWidgets);
    expect(find.byIcon(Icons.folder_copy_outlined), findsOneWidget);
    expect(find.byIcon(Icons.star_outline_rounded), findsNothing);
    expect(find.byIcon(Icons.search_outlined), findsNothing);
    expect(find.byIcon(Icons.tune_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  });
}
