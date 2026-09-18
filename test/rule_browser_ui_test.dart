import 'dart:async';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/modules/library/library_queries.dart';
import 'package:best_viewer/src/ui/app_preferences.dart';
import 'package:best_viewer/src/ui/browser_entity_sliver.dart';
import 'package:best_viewer/src/ui/browser_list.dart';
import 'package:best_viewer/src/ui/browser_state.dart';
import 'package:best_viewer/src/ui/browser_toolbar.dart';
import 'package:best_viewer/src/ui/gallery_layout_settings.dart';
import 'package:best_viewer/src/ui/index_node_thumbnail.dart';
import 'package:best_viewer/src/ui/justified_entity_gallery.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:best_viewer/src/ui/rule_browser_controller.dart';
import 'package:best_viewer/src/ui/rule_index_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

RuleDefinition rule(String id, {bool builtIn = false}) => RuleDefinition(
    node: IndexNode(
        id: id,
        name: id,
        nodeType: NodeType.ruleNode,
        viewType: ViewType.tree,
        sortOrder: 0,
        createdAtMs: 0,
        updatedAtMs: 0),
    builtInKind: builtIn ? BuiltInRuleKind.frequent : null,
    defaultSort: RuleSortMode.name,
    updatedAtMs: 0);

EntityListItem entity(String id) => EntityListItem(
    id: id,
    title: id,
    entityType: EntityType.text,
    path: id,
    format: 'txt',
    size: 10,
    modifiedAtMs: 0);

class Queries implements LibraryQueries {
  List<RuleDefinition> rules = [rule('常用', builtIn: true), rule('自定义')];
  Future<RuleResultPage> Function(String, RuleSortMode?, RulePageCursor?)?
      loader;
  @override
  Future<List<RuleDefinition>> listRules() async => rules;
  @override
  Future<RuleResultPage> loadRulePage(
          {required String ruleNodeId,
          RuleSortMode? sortMode,
          RulePageCursor? after,
          int limit = 60}) async =>
      loader == null
          ? RuleResultPage(items: [entity('文件')], hasMore: false)
          : loader!(ruleNodeId, sortMode, after);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('ordinary result scroll position returns after immersive mode',
      (tester) async {
    final queries = Queries();
    queries.loader = (_, __, ___) async => RuleResultPage(
        items: List.generate(80, (i) => entity('文件$i')), hasMore: false);
    await pumpRulePage(tester, queries,
        state: const BrowserState(
            displayMode: BrowserDisplayMode.list,
            listStyle: BrowserListStyle.text));
    await tester.tap(find.textContaining('自定义').first);
    await tester.pumpAndSettle();
    final scroller = find.byType(CustomScrollView);
    await tester.drag(scroller, const Offset(0, -700));
    await tester.pumpAndSettle();
    final offset = tester.widget<CustomScrollView>(scroller).controller!.offset;
    expect(offset, greaterThan(0));
    await tester.tap(find.byTooltip('沉浸式浏览'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('退出沉浸式浏览'));
    await tester.pumpAndSettle();
    expect(tester.widget<CustomScrollView>(scroller).controller!.offset,
        closeTo(offset, 1));
  });

  testWidgets('file layout styles select shared geometry', (tester) async {
    for (final layout in BrowserGridLayout.values) {
      await pumpRulePage(tester, Queries(),
          state: BrowserState(gridLayout: layout));
      await tester.tap(find.text('自定义'));
      await tester.pumpAndSettle();
      expect(find.byType(BrowserEntitySliver), findsOneWidget);
      if (layout == BrowserGridLayout.equalHeight) {
        expect(find.byType(JustifiedEntityGallerySliver), findsOneWidget);
      } else if (layout == BrowserGridLayout.equalWidth) {
        expect(find.byType(SliverMasonryGrid), findsOneWidget);
      } else {
        final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
        expect(
            (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
                .childAspectRatio,
            1);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  });

  testWidgets(
      'custom sort stays local and does not emit shared preference changes',
      (tester) async {
    final queries = Queries();
    RuleSortMode? queriedSort;
    queries.loader = (_, sort, __) async {
      queriedSort = sort;
      return RuleResultPage(items: [entity('one')], hasMore: false);
    };
    var globalChanges = 0;
    await pumpRulePage(tester, queries,
        onBrowserChanged: (_) => globalChanges++);
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('浏览选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('大小'));
    await tester.pumpAndSettle();
    expect(queriedSort, RuleSortMode.size);
    expect(globalChanges, 0);
  });

  testWidgets(
      'narrow large text and rotation keep toolbar and selection accessible',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpRulePage(tester, Queries(), textScale: 2);
    await tester.longPress(find.text('自定义'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('选择操作'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('late pages and errors cannot replace a newer rule or sort', () async {
    final queries = Queries();
    final pending = <Completer<RuleResultPage>>[];
    queries.loader = (_, __, ___) {
      final result = Completer<RuleResultPage>();
      pending.add(result);
      return result.future;
    };
    final controller = RuleBrowserController(queries);
    addTearDown(controller.dispose);
    final first = controller.openRule(rule('A'));
    final second = controller.openRule(rule('B'));
    pending[1].complete(RuleResultPage(items: [entity('B')], hasMore: false));
    await second;
    pending[0].completeError(StateError('late failure'));
    await first;
    expect(controller.items.single.id, 'B');
    expect(controller.error, isNull);
    final oldSort = controller.sort(RuleSortMode.name);
    final newSort = controller.sort(RuleSortMode.size);
    pending[3].complete(RuleResultPage(items: [entity('new')], hasMore: false));
    await newSort;
    pending[2].complete(RuleResultPage(items: [entity('old')], hasMore: false));
    await oldSort;
    expect(controller.items.single.id, 'new');
    expect(controller.temporarySort, RuleSortMode.size);
  });

  test('pagination deduplicates and closing invalidates in-flight work',
      () async {
    final queries = Queries();
    final pending = Completer<RuleResultPage>();
    queries.loader = (_, __, cursor) async => cursor == null
        ? RuleResultPage(
            items: [entity('a')],
            hasMore: true,
            cursor:
                const RulePageCursor(primary: 1, entityId: 'a', consumed: 1))
        : pending.future;
    final controller = RuleBrowserController(queries);
    addTearDown(controller.dispose);
    await controller.openRule(rule('A'));
    final more = controller.loadPage();
    pending.complete(
        RuleResultPage(items: [entity('a'), entity('b')], hasMore: false));
    await more;
    expect(controller.items.map((e) => e.id), ['a', 'b']);
    final late = Completer<RuleResultPage>();
    queries.loader = (_, __, ___) => late.future;
    final loading = controller.openRule(rule('B'));
    await controller.closeRule();
    late.complete(RuleResultPage(items: [entity('late')], hasMore: false));
    await loading;
    expect(controller.activeRule, isNull);
    expect(controller.items, isEmpty);
    expect(controller.loading, isFalse);
  });

  testWidgets('rule home shares toolbar and protects built-in selection',
      (tester) async {
    final selection = <bool>[];
    await pumpRulePage(tester, Queries(), onSelection: selection.add);
    expect(find.byType(BrowserToolbar), findsOneWidget);
    expect(find.byTooltip('沉浸式浏览'), findsNothing);
    await tester.tap(find.byTooltip('浏览选项'));
    await tester.pumpAndSettle();
    expect(find.text('排序'), findsNothing);
    expect(find.text('样式'), findsNothing);
    expect(find.text('显示'), findsOneWidget);
    expect(find.text('主题'), findsOneWidget);
    await tester.tap(find.byTooltip('浏览选项'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('常用'));
    await tester.pumpAndSettle();
    expect(selection, [true]);
    expect(find.text('内置规则不可修改'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '删除'))
            .onPressed,
        isNull);
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    expect(selection, [true, false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'rule results use shared layout and fixed sort and restore list after immersive',
      (tester) async {
    await pumpRulePage(tester, Queries(),
        state: const BrowserState(
            displayMode: BrowserDisplayMode.list,
            listStyle: BrowserListStyle.text));
    await tester.tap(find.textContaining('常用').first);
    await tester.pumpAndSettle();
    expect(find.byType(BrowserEntitySliver), findsOneWidget);
    expect(find.byType(BrowserListSliver), findsOneWidget);
    await tester.tap(find.byTooltip('浏览选项'));
    await tester.pumpAndSettle();
    expect(find.text('排序'), findsNothing);
    expect(find.text('固定排序：访问次数'), findsOneWidget);
    await tester.tap(find.byTooltip('浏览选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('沉浸式浏览'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('退出沉浸式浏览'), findsOneWidget);
    expect(find.byType(BrowserListSliver), findsNothing);
    await tester.tap(find.byTooltip('退出沉浸式浏览'));
    await tester.pumpAndSettle();
    expect(find.byType(BrowserListSliver), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading and failed rule home retain navigation', (tester) async {
    final queries = FailingQueries();
    await pumpRulePage(tester, queries);
    expect(find.byType(BrowserToolbar), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('empty folder cover scales from thumbnail to large card',
      (tester) async {
    for (final size in [36.0, 320.0]) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Center(
                  child: SizedBox(
                      width: size,
                      height: size,
                      child: const IndexNodeThumbnail(
                          preview: null,
                          nodeName: '空目录',
                          hasContent: false))))));
      expect(find.byType(EmptyFolderCover), findsOneWidget);
      expect(find.byIcon(Icons.folder_open_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}

class FailingQueries extends Queries {
  @override
  Future<List<RuleDefinition>> listRules() async => throw StateError('offline');
}

Future<void> pumpRulePage(WidgetTester tester, Queries queries,
    {BrowserState state = const BrowserState(),
    ValueChanged<bool>? onSelection,
    ValueChanged<BrowserState>? onBrowserChanged,
    double textScale = 1}) async {
  final prefs = AppPreferencesController.memory();
  addTearDown(prefs.dispose);
  await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!),
      home: Scaffold(
          body: RuleIndexPage(
        queries: queries,
        browserState: state,
        layoutSettings: GalleryLayoutPreset.standard.settings,
        preferences: prefs,
        onOpenEntity: (_, __) {},
        onThumbnailNeeded: (_) {},
        onSearch: () {},
        onBrowserStateChanged: onBrowserChanged ?? (_) {},
        onAddToCollection: (_) async {},
        onEditRule: (_) async {},
        onDeleteRule: (_) async {},
        onSelectionModeChanged: onSelection ?? (_) {},
      ))));
  await tester.pumpAndSettle();
}
