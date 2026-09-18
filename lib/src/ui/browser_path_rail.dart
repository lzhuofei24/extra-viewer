import 'package:flutter/material.dart';
import '../core/domain/models.dart';
import 'design_tokens.dart';

class BrowserPathRail extends StatelessWidget {
  const BrowserPathRail({
    super.key,
    required this.currentNode,
    required this.path,
    required this.onOpenRootIndex,
    required this.onPathNodeSelected,
  });

  final IndexNode? currentNode;
  final List<IndexNode> path;
  final VoidCallback onOpenRootIndex;
  final ValueChanged<IndexNode> onPathNodeSelected;

  @override
  Widget build(BuildContext context) {
    final visiblePath = <IndexNode>[];
    final seen = <String>{};
    for (final node in path) {
      if (seen.add(node.id)) visiblePath.add(node);
    }
    return _HorizontalNodeRail(
      children: [
        _NodeRailEntry(
          label: '首页',
          selected: currentNode == null,
          onTap: onOpenRootIndex,
        ),
        for (final node in visiblePath)
          _NodeRailEntry(
            label: node.name,
            selected: node.id == currentNode?.id,
            onTap: () => onPathNodeSelected(node),
          ),
      ],
    );
  }
}

class _HorizontalNodeRail extends StatelessWidget {
  const _HorizontalNodeRail({
    required this.children,
  });

  final List<_NodeRailEntry> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 42,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        key: ValueKey(children.map((entry) => entry.label).join('/')),
        reverse: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (var index = 0; index < children.length; index++) ...[
              if (index > 0)
                _RailSeparator(color: theme.colorScheme.outlineVariant),
              children[index],
            ],
          ],
        ),
      ),
    );
  }
}

class _RailSeparator extends StatelessWidget {
  const _RailSeparator({this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.zero,
      child: Text(
        '|',
        style: theme.textTheme.titleSmall?.copyWith(
          color: color ?? theme.colorScheme.outline,
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }
}

class _NodeRailEntry extends StatelessWidget {
  const _NodeRailEntry({
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: selected
                            ? theme.colorScheme.primary
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          softWrap: false,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: foreground,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
