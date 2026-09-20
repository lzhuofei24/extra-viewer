import 'dart:convert';
import 'package:best_viewer/src/ui/collection_browser_page.dart';
import 'package:best_viewer/src/ui/browser_list.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/ui/app_preferences.dart';
import 'package:best_viewer/src/ui/browser_state.dart';
import 'package:best_viewer/src/ui/browser_toolbar.dart';
import 'package:best_viewer/src/ui/browser_node_grid.dart';
import 'package:best_viewer/src/ui/design_tokens.dart';
import 'package:best_viewer/src/ui/gallery_layout_settings.dart';
import 'package:best_viewer/src/ui/index_node_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
      'folder cards coexist with text file lists without thumbnail requests',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var requests = 0;
    const node = IndexNode(
        id: 'folder',
        name: 'folder',
        nodeType: NodeType.folder,
        viewType: ViewType.tree,
        sortOrder: 0,
        createdAtMs: 0,
        updatedAtMs: 0);
    const files = [
      EntityListItem(
          id: 'photo',
          title: 'photo',
          entityType: EntityType.image,
          path: 'photo.jpg',
          format: 'jpg',
          size: 1,
          modifiedAtMs: 0)
    ];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CollectionBrowserPage(
      currentNode: node,
      nodePath: const [node],
      childNodes: const [node],
      nodeSummaries: const {},
      nodePreviews: const {},
      entities: files,
      hasMoreEntities: false,
      loadingMoreEntities: false,
      browserState: const BrowserState(
          displayMode: BrowserDisplayMode.list,
          listStyle: BrowserListStyle.text),
      layoutSettings: const GalleryLayoutSettings(),
      onOpenRootIndex: () {},
      onSortChanged: (_) {},
      onDisplayModeChanged: (_) {},
      onGridLayoutChanged: (_) {},
      onListStyleChanged: (_) {},
      themeChoice: ViewerThemeChoice.system,
      onThemeChanged: (_) {},
      onLayoutChanged: (_) {},
      immersiveBrowsing: false,
      onToggleImmersiveBrowsing: () {},
      selectionMode: false,
      onToggleSelectionMode: () {},
      onCloneCurrentNodeTree: () {},
      canUpdateDirectoryNode: false,
      onUpdateDirectoryNode: () {},
      canDeleteCurrentNode: false,
      onDeleteCurrentNode: () {},
      onOpenNode: (_) {},
      onPathNodeSelected: (_) {},
      onOpenEntity: (_) {},
      onShowEntityMenu: (_) {},
      onThumbnailNeeded: (_) => requests++,
      onThumbnailEntityNeeded: (_) {},
      onLoadMoreEntities: () {},
      selectedEntityIds: const {},
      onToggleEntitySelection: (_) {},
      onStartEntitySelection: (_) {},
      onSelectEntitiesByDrag: (_) {},
      selectedNodeIds: const {},
      onToggleNodeSelection: (_) {},
      onStartNodeSelection: (_) {},
      onClearEntitySelection: () {},
      onSelectAllVisible: () {},
      onInvertVisibleSelection: () {},
      onSelectRange: () {},
      onAddToCollection: () {},
      onCreateCollection: () {},
      onRemoveFromCurrentNode: () {},
      canRemoveFromCurrentNode: false,
      canManageCurrentCustomIndex: false,
      onRebuildSelectedNodePreview: () {},
      onCustomizeSelectedNodePreview: () {},
      onClearSelectedNodePreviewOverride: () {},
    ))));
    await tester.pumpAndSettle();
    expect(find.byType(IndexNodePreviewCard), findsOneWidget);
    expect(find.byType(BrowserListTile), findsOneWidget);
    expect(requests, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow large-text subpanels stay within safe bounds',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!),
        home: Scaffold(
            body: BrowserToolbar(
          leading: const Text('目录'),
          browserState: const BrowserState(),
          onSortChanged: (_) {},
          onDisplayModeChanged: (_) {},
          onGridLayoutChanged: (_) {},
          onListStyleChanged: (_) {},
          themeChoice: ViewerThemeChoice.system,
          onThemeChanged: (_) {},
          layoutSettings: const GalleryLayoutSettings(),
          onLayoutChanged: (_) {},
        ))));
    await tester.tap(find.byTooltip('浏览选项'));
    await tester.pumpAndSettle();
    for (final label in ['文件夹设置', '文件设置']) {
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      final panel =
          tester.getRect(find.byKey(const ValueKey('browser-options-surface')));
      expect(panel.left, greaterThanOrEqualTo(0));
      expect(panel.right, lessThanOrEqualTo(320));
      expect(panel.bottom, lessThanOrEqualTo(600));
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  });

  test(
      'legacy folder and list preferences migrate without changing file geometry',
      () async {
    for (final cover in ['automatic', 'square', 'stacked']) {
      SharedPreferences.setMockInitialValues({
        'preferences.browser.folderCover': cover,
        'preferences.browser.listStyle': 'compact',
        'preferences.gallery.counts.v1': jsonEncode({
          'portraitFolderColumns': 5,
          'landscapeFolderColumns': 6,
          'portraitEqualHeightLevel': 7,
          'landscapeListColumns': 2,
        }),
      });
      final store = SharedPreferencesAppPreferencesStore(
          await SharedPreferences.getInstance());
      final prefs = await store.load();
      expect(prefs.layout.portraitFolders.columns, 5);
      expect(prefs.layout.landscapeFolders.columns, 6);
      expect(prefs.layout.portraitEqualHeightLevel, 7);
      expect(prefs.layout.landscapeTextListColumns, 2);
      expect(prefs.listStyle, BrowserListStyle.normal);
      expect(prefs.layout.portraitFolders.display,
          cover == 'stacked' ? FolderDisplay.stacked : FolderDisplay.square);
      expect(prefs.layout.landscapeFolders.display,
          cover == 'square' ? FolderDisplay.square : FolderDisplay.stacked);
      final changed = prefs.layout.withFolders(true,
          prefs.layout.portraitFolders.copyWith(display: FolderDisplay.list));
      await store.save(prefs.copyWith(layout: changed));
      expect((await store.load()).layout, changed);
    }
    SharedPreferences.setMockInitialValues({
      'preferences.browser.display': 'list',
      'preferences.browser.listStyle': 'text',
    });
    final migrated = await SharedPreferencesAppPreferencesStore(
            await SharedPreferences.getInstance())
        .load();
    expect(migrated.layout.portraitFolders.display, FolderDisplay.list);
    expect(migrated.listStyle, BrowserListStyle.text);
  });

  testWidgets(
      'subpanels share one surface and back navigates before dismissing',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    var browser = const BrowserState();
    var layout = const GalleryLayoutSettings();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatefulBuilder(
      builder: (context, update) => BrowserToolbar(
        leading: const Text('目录'),
        browserState: browser,
        onSortChanged: (v) =>
            update(() => browser = browser.copyWith(sortMode: v)),
        onDisplayModeChanged: (v) =>
            update(() => browser = browser.copyWith(displayMode: v)),
        onListStyleChanged: (v) =>
            update(() => browser = browser.copyWith(listStyle: v)),
        onGridLayoutChanged: (v) =>
            update(() => browser = browser.copyWith(gridLayout: v)),
        onFileDisplayChanged: (display, style) => update(() =>
            browser = browser.copyWith(displayMode: display, listStyle: style)),
        themeChoice: ViewerThemeChoice.system,
        onThemeChanged: (_) {},
        layoutSettings: layout,
        onLayoutChanged: (v) => update(() => layout = v),
      ),
    ))));
    await tester.tap(find.byTooltip('浏览选项'));
    await tester.pumpAndSettle();
    expect(find.text('浏览选项'), findsNothing);
    await tester.tap(find.text('文件夹设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('叠加卡片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('等高'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('增加高度级别'));
    await tester.pumpAndSettle();
    expect(layout.portraitFolders.stackedHeightLevel, 7);
    expect(layout.portraitFolders.squareHeightLevel, 6);
    expect(browser.displayMode, BrowserDisplayMode.grid);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('排序'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('browser-options-surface')), findsOneWidget);
    await tester.tap(find.text('文件设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('紧凑列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('增加每行数量'));
    await tester.pumpAndSettle();
    expect(browser.listStyle, BrowserListStyle.text);
    expect(layout.portraitTextListColumns, 2);
    expect(layout.portraitListColumns, 1);
    expect(layout.portraitFolders.display, FolderDisplay.stacked);
    expect(find.text('布局'), findsNothing);
    tester.view.physicalSize = const Size(1000, 600);
    await tester.pumpAndSettle();
    expect(layout.landscapeFolders, FolderViewSettings.landscape);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('browser-options-surface')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'folder preview variants retain their aspect ratio in both layouts',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const node = IndexNode(
        id: 'folder',
        name: 'folder',
        nodeType: NodeType.folder,
        viewType: ViewType.tree,
        sortOrder: 0,
        createdAtMs: 0,
        updatedAtMs: 0);
    const preview = IndexNodePreview(
        nodeId: 'folder',
        kind: IndexNodePreviewKind.visualGrid,
        visualAssetAspectRatio: 1.5);
    for (final display in [FolderDisplay.square, FolderDisplay.stacked]) {
      for (final geometry in FolderCardLayout.values) {
        final folders =
            FolderViewSettings(display: display).copyWith(cardLayout: geometry);
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: CustomScrollView(slivers: [
          BrowserNodeGridSliver(
              nodes: const [node],
              summaries: const {},
              previews: const {'folder': preview},
              onOpenNode: (_) {},
              onThumbnailEntityNeeded: (_) {},
              selectedNodeIds: const {},
              selectionMode: false,
              onToggleNodeSelection: (_) {},
              onStartNodeSelection: (_) {},
              layoutSettings: GalleryLayoutSettings(portraitFolders: folders)),
        ]))));
        await tester.pumpAndSettle();
        final size = tester.getSize(find.byType(IndexNodePreviewCard));
        expect(size.width / size.height,
            closeTo(display == FolderDisplay.square ? 1 : 1.5, .001));
        expect(
            tester
                .widget<IndexNodeThumbnail>(find.byType(IndexNodeThumbnail))
                .portrait,
            display == FolderDisplay.square);
        if (geometry == FolderCardLayout.equalHeight) {
          expect(size.height, closeTo((400 - 16 - 16) / 3, .001));
        }
        expect(tester.takeException(), isNull);
      }
    }
  });
}
