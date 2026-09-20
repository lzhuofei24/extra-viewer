import 'package:flutter/foundation.dart';
import '../core/domain/models.dart';
import '../modules/library/library_queries.dart';

class RuleBrowserController extends ChangeNotifier {
  RuleBrowserController(this.queries);
  final LibraryQueries queries;
  List<RuleDefinition> rules = const [];
  Map<String, EntityListItem> covers = const {};
  int _coverGeneration = 0;

  Future<void> refreshCovers() async {
    final generation = ++_coverGeneration;
    try {
      final ids = rules.map((r) => r.node.id).toList();
      for (var offset = 0; offset < ids.length; offset += 8) {
        if (_disposed || generation != _coverGeneration) return;
        final result = await queries.loadRuleSummaries(
            ids.sublist(offset, (offset + 8).clamp(0, ids.length)));
        if (_disposed || generation != _coverGeneration) return;
        covers = {...covers};
        for (final entry in result.entries) {
          if (entry.value.cover != null) {
            covers[entry.key] = entry.value.cover!;
          } else {
            covers.remove(entry.key);
          }
        }
        rules = [
          for (final rule in rules)
            result.containsKey(rule.node.id)
                ? rule.withResultCount(result[rule.node.id]!.count)
                : rule
        ];
        notifyListeners();
      }
    } catch (_) {
      // A failed cover lookup must not hide usable rule entries.
    }
  }

  RuleDefinition? activeRule;
  List<EntityListItem> items = const [];
  RulePageCursor? cursor;
  RuleSortMode? temporarySort;
  bool loading = false, loadingMore = false, hasMore = false;
  Object? error;
  int _generation = 0;
  bool _disposed = false;

  Future<void> loadRules({String? initialRuleId}) async {
    final generation = ++_generation;
    loading = true;
    loadingMore = false;
    error = null;
    notifyListeners();
    try {
      final result = await queries.listRules();
      if (!_current(generation)) return;
      rules = result;
      refreshCovers();
      loading = false;
      notifyListeners();
      if (initialRuleId != null) {
        final matches = rules.where((r) => r.node.id == initialRuleId);
        if (matches.isNotEmpty) await openRule(matches.first);
      }
    } catch (e) {
      if (!_current(generation)) return;
      error = e;
      loading = false;
      notifyListeners();
    }
  }

  Future<void> openRule(RuleDefinition rule) {
    activeRule = rule;
    temporarySort = null;
    return loadPage(reset: true);
  }

  Future<void> closeRule() {
    activeRule = null;
    items = const [];
    cursor = null;
    temporarySort = null;
    hasMore = false;
    return loadRules();
  }

  Future<void> sort(RuleSortMode value) async {
    if (activeRule == null || activeRule!.isBuiltIn) return;
    temporarySort = value;
    await loadPage(reset: true);
  }

  Future<void> refreshDefinitions() async {
    final generation = _generation;
    final updated = await queries.listRules();
    if (!_current(generation)) return;
    rules = updated;
    refreshCovers();
    final active = activeRule;
    if (active != null) {
      final matching = updated.where((rule) => rule.node.id == active.node.id);
      if (matching.isEmpty) {
        await closeRule();
        return;
      }
      activeRule = matching.first;
      await loadPage(reset: true);
      return;
    }
    notifyListeners();
  }

  Future<void> loadPage({bool reset = false}) async {
    final rule = activeRule;
    if (rule == null || (!reset && (loading || loadingMore || !hasMore))) {
      return;
    }
    final generation = reset ? ++_generation : _generation;
    if (reset) {
      loading = true;
      loadingMore = false;
      items = const [];
      cursor = null;
      hasMore = false;
    } else {
      loadingMore = true;
    }
    error = null;
    notifyListeners();
    try {
      final page = await queries.loadRulePage(
          ruleNodeId: rule.node.id,
          sortMode: rule.isBuiltIn ? null : temporarySort,
          after: reset ? null : cursor);
      if (!_current(generation)) return;
      final seen = <String>{};
      items = [
        for (final item in [...items, ...page.items])
          if (seen.add(item.id)) item
      ];
      cursor = page.cursor;
      hasMore = page.hasMore;
      loading = false;
      loadingMore = false;
      notifyListeners();
    } catch (e) {
      if (!_current(generation)) return;
      error = e;
      loading = false;
      loadingMore = false;
      notifyListeners();
    }
  }

  bool _current(int generation) => !_disposed && generation == _generation;
  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
