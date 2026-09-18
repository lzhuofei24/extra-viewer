import 'package:best_viewer/src/app.dart';
import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/ui/app_preferences.dart';
import 'package:best_viewer/src/ui/app_sidebar.dart';
import 'package:best_viewer/src/ui/browser_state.dart';
import 'package:best_viewer/src/ui/collection_browser_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'data tabs restore independent locations and scrolling without home flash',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late IndexNode directory, dirA, dirB, collection, category;
    late String databasePath;
    final prefs = AppPreferencesController.memory(const AppPreferencesData(
        displayMode: BrowserDisplayMode.list,
        listStyle: BrowserListStyle.text));
    addTearDown(prefs.dispose);
    await tester.pumpWidget(BestViewerApp(
        preferences: prefs,
        databaseFactory: () async {
          final db = AppDatabase.openInMemory();
          databasePath = '${db.storageDirectoryPath}/test-library.db';
          final repo = LibraryRepository(db);
          directory =
              repo.ensureDirectoryIndexRoot('/library', displayName: '目录来源');
          dirA = await repo.ensureDirectoryFolderAsync(
              parentId: directory.id, name: '目录甲', relativePath: 'a');
          dirB = await repo.ensureDirectoryFolderAsync(
              parentId: directory.id, name: '目录乙', relativePath: 'b');
          collection = repo.ensureCollectionIndexRoot('分类来源');
          category =
              repo.createCustomNode(parentId: collection.id, name: '子分类');
          for (var i = 0; i < 60; i++) {
            repo.createCustomNode(parentId: category.id, name: '叶子$i');
          }
          // This navigation test does not run background cover generation.
          db.db.execute('DELETE FROM node_preview_dirty');
          return db;
        }));
    await settleUntil(
        tester,
        () =>
            find.byType(CollectionBrowserPage).evaluate().isNotEmpty &&
            !page(tester).loading);
    expect(find.byTooltip('添加目录'), findsOneWidget);
    page(tester).onOpenNode(directory);
    await tester.pump();
    expect(page(tester).currentNode!.id, directory.id);
    expect(page(tester).childNodes.any((node) => node.id == directory.id),
        isFalse);
    await settleUntil(tester, () => !page(tester).loading);
    expect(find.byTooltip('添加目录'), findsNothing);
    page(tester).onOpenNode(dirA);
    await tester.pump();
    page(tester).onOpenNode(dirB);
    await tester.pump();
    await settleUntil(tester, () => !page(tester).loading);
    expect(page(tester).currentNode!.id, dirB.id);
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
      expect(page(tester).currentNode!.id, dirB.id);
    }

    navigation(tester).onRootTabChanged(BrowserRootTab.tree);
    await tester.pump();
    await settleUntil(tester, () => !page(tester).loading);
    expect(page(tester).currentNode, isNull);
    expect(find.byTooltip('新建分类'), findsOneWidget);
    page(tester).onOpenNode(collection);
    await tester.pump();
    await settleUntil(tester, () => !page(tester).loading);
    page(tester).onOpenNode(category);
    await tester.pump();
    await settleUntil(tester, () => !page(tester).loading);
    expect(find.byTooltip('新建子分类'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -650));
    await tester.pumpAndSettle();
    final offset = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!
        .offset;
    expect(offset, greaterThan(0));

    navigation(tester).onRootTabChanged(BrowserRootTab.directory);
    await tester.pump();
    expect(page(tester).currentNode!.id, dirB.id);
    await settleUntil(tester, () => !page(tester).loading);
    navigation(tester).onRootTabChanged(BrowserRootTab.tree);
    await tester.pump();
    expect(page(tester).currentNode!.id, category.id);
    await settleUntil(tester, () => !page(tester).loading);
    expect(
        tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller!
            .offset,
        closeTo(offset, 1));
    navigation(tester).onRootTabChanged(BrowserRootTab.tree);
    await tester.pump();
    expect(page(tester).currentNode!.id, category.id);
    navigation(tester).onChanged(AppSection.indexes);
    await tester.pump();
    await tester.runAsync(() async {
      // Simulate a node removed while this browser location is inactive.
      final db = AppDatabase.openAtPathForTesting(databasePath);
      LibraryRepository(db).deleteIndexNode(category.id);
      db.db.execute('DELETE FROM node_preview_dirty');
      db.close();
    });
    navigation(tester).onRootTabChanged(BrowserRootTab.tree);
    await tester.pump();
    await settleUntil(
        tester,
        () =>
            !page(tester).loading &&
            page(tester).currentNode?.id == collection.id);
    expect(page(tester).childNodes.any((n) => n.id == category.id), isFalse);
    page(tester).onOpenRootIndex();
    await tester.pump();
    await settleUntil(tester, () => !page(tester).loading);
    expect(page(tester).currentNode, isNull);
    expect(tester.takeException(), isNull);

    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump(const Duration(seconds: 3));
  });
}

CollectionBrowserPage page(WidgetTester tester) =>
    tester.widget(find.byType(CollectionBrowserPage));
AppNavigation navigation(WidgetTester tester) =>
    tester.widget(find.byType(AppNavigation));
Future<void> settleUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 150; i++) {
    if (ready()) return;
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
  expect(ready(), isTrue, reason: 'worker navigation did not settle');
}
