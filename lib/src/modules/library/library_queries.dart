import '../../core/domain/models.dart';

abstract interface class LibraryQueries {
  Future<NodeSearchPage> searchNodes(NodeSearchQuery query);
  Future<List<RuleDefinition>> listRules();
  Future<RuleResultPage> loadRulePage({
    required String ruleNodeId,
    RuleSortMode? sortMode,
    RulePageCursor? after,
    int limit = 60,
  });
  Future<RuleFilterOptions> listRuleFilterOptions(
      {List<EntityType> entityTypes = const []});
}
