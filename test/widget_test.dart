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
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('首页'), findsWidgets);
    expect(find.byIcon(Icons.collections_bookmark_outlined), findsOneWidget);
    expect(find.byIcon(Icons.star_outline_rounded), findsNothing);
    expect(find.byIcon(Icons.search_outlined), findsNothing);
    expect(find.byIcon(Icons.tune_outlined), findsOneWidget);
  });
}
