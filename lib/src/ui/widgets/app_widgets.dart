import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/domain/models.dart';
import '../../core/media/app_audio_controller.dart';
import '../collapse_grip_icon.dart';
import '../app_sidebar.dart';

/// Entity context menu action enum.
enum EntityMenuAction { select, regenerateThumbnail }

/// Compact floating audio player shown at the bottom-right of the screen.
class MiniAudioPlayer extends StatelessWidget {
  const MiniAudioPlayer({
    super.key,
    required this.controller,
    required this.onOpen,
    required this.collapsed,
    required this.onToggleCollapsed,
  });

  final AppAudioController controller;
  final VoidCallback onOpen;
  final bool collapsed;
  final VoidCallback onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final entity = controller.current!;
    final player = controller.player;
    final appearance = GlassAppearance.of(context);
    final title = p.basenameWithoutExtension(entity.title);
    final titleStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: appearance.foreground,
            ) ??
        const TextStyle(fontWeight: FontWeight.w700);
    final titlePainter = TextPainter(
      text: TextSpan(text: title, style: titleStyle),
      textDirection: Directionality.of(context),
      maxLines: 1,
      ellipsis: '...',
    )..layout(maxWidth: 250);
    final titleWidth = titlePainter.width.clamp(72.0, 250.0).toDouble();
    final availableWidth =
        (MediaQuery.sizeOf(context).width - 8).clamp(280.0, 500.0).toDouble();
    final expandedWidth =
        (titleWidth + 224).clamp(280.0, availableWidth).toDouble();
    final radius = collapsed ? 24.0 : 28.0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: collapsed ? 48 : expandedWidth,
      height: collapsed ? 48 : 56,
      child: FloatingGlassSurface(
        borderRadius: radius,
        child: Material(
          color: Colors.transparent,
          child: collapsed
              ? IconButton(
                  tooltip: '展开播放器',
                  onPressed: onToggleCollapsed,
                  icon: const CollapseGripIcon(),
                )
              : InkWell(
                  onTap: onOpen,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                    child: Row(
                      children: [
                        MiniPlayerControl(
                          tooltip: '收起播放器',
                          onPressed: onToggleCollapsed,
                          iconWidget: const CollapseGripIcon(),
                        ),
                        Icon(Icons.graphic_eq_rounded,
                            color: appearance.foreground),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: titleStyle,
                              ),
                              const SizedBox(height: 5),
                              StreamBuilder<Duration>(
                                stream: player.stream.position,
                                initialData: player.state.position,
                                builder: (context, snapshot) {
                                  final duration =
                                      player.state.duration.inMilliseconds;
                                  final position =
                                      snapshot.data?.inMilliseconds ?? 0;
                                  return LinearProgressIndicator(
                                    minHeight: 2,
                                    value: duration <= 0
                                        ? 0
                                        : (position / duration).clamp(0.0, 1.0),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        MiniPlayerControl(
                          tooltip: '上一首',
                          onPressed: controller.previous,
                          icon: Icons.skip_previous_rounded,
                        ),
                        StreamBuilder<bool>(
                          stream: player.stream.playing,
                          initialData: player.state.playing,
                          builder: (context, snapshot) => MiniPlayerControl(
                            tooltip: snapshot.data == true ? '暂停' : '播放',
                            onPressed: player.playOrPause,
                            filled: true,
                            icon: snapshot.data == true
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                        ),
                        MiniPlayerControl(
                          tooltip: '下一首',
                          onPressed: controller.next,
                          icon: Icons.skip_next_rounded,
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

class MiniPlayerControl extends StatelessWidget {
  const MiniPlayerControl({
    super.key,
    required this.tooltip,
    required this.onPressed,
    this.icon,
    this.iconWidget,
    this.filled = false,
  }) : assert(icon != null || iconWidget != null);

  final String tooltip;
  final VoidCallback onPressed;
  final IconData? icon;
  final Widget? iconWidget;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final button = filled
        ? IconButton.filled(
            style: IconButton.styleFrom(
                backgroundColor:
                    GlassAppearance.of(context).selectedBackground),
            tooltip: tooltip,
            onPressed: onPressed,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 34, height: 34),
            icon: iconWidget ?? Icon(icon, size: 19),
          )
        : IconButton(
            tooltip: tooltip,
            onPressed: onPressed,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 34, height: 34),
            visualDensity: VisualDensity.compact,
            icon: iconWidget ?? Icon(icon, size: 20),
          );
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: button,
    );
  }
}

/// Banner shown when the read worker is unavailable.
class ReadUnavailableBanner extends StatelessWidget {
  const ReadUnavailableBanner({
    super.key,
    required this.message,
    required this.retrying,
    required this.onRetry,
  });

  final String message;
  final bool retrying;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer.withValues(alpha: .94),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 18,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '读取服务暂时不可用：$message',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: retrying ? null : onRetry,
                child: retrying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        '重试',
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tile for choosing which directory node to update.
class DirectoryUpdateNodeTile extends StatelessWidget {
  const DirectoryUpdateNodeTile({
    super.key,
    required this.node,
    required this.initiallyExpanded,
    this.isRoot = false,
    required this.onSelected,
  });

  final IndexTreeNode node;
  final bool initiallyExpanded;
  final bool isRoot;
  final ValueChanged<IndexNode> onSelected;

  @override
  Widget build(BuildContext context) {
    final title = Text(
      isRoot ? '${node.item.name}（整个目录）' : node.item.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final subtitle = Text('${node.entityCount} 个文件');
    if (node.children.isEmpty) {
      return ListTile(
        dense: true,
        leading: IconButton(
          tooltip: isRoot ? '更新整个目录' : '更新此文件夹',
          onPressed: () => onSelected(node.item),
          icon: const Icon(Icons.sync_rounded),
        ),
        title: title,
        subtitle: subtitle,
        onTap: () => onSelected(node.item),
      );
    }
    return ExpansionTile(
      initiallyExpanded: initiallyExpanded,
      leading: IconButton(
        tooltip: isRoot ? '更新整个目录' : '更新此文件夹',
        onPressed: () => onSelected(node.item),
        icon: const Icon(Icons.sync_rounded),
      ),
      title: title,
      subtitle: subtitle,
      childrenPadding: const EdgeInsets.only(left: 18),
      children: node.children
          .map(
            (child) => DirectoryUpdateNodeTile(
              node: child,
              initiallyExpanded: false,
              isRoot: false,
              onSelected: onSelected,
            ),
          )
          .toList(growable: false),
    );
  }
}

/// Checkbox tile for choosing collection targets when adding to index.
class CollectionTargetNodeTile extends StatelessWidget {
  const CollectionTargetNodeTile({
    super.key,
    required this.treeNode,
    required this.selectedIds,
    required this.initiallyExpanded,
    required this.onChanged,
  });

  final IndexTreeNode treeNode;
  final Set<String> selectedIds;
  final bool initiallyExpanded;
  final void Function(IndexNode node, bool checked) onChanged;

  @override
  Widget build(BuildContext context) {
    final node = treeNode.item;
    final selected = selectedIds.contains(node.id);
    final title = Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis);
    final subtitle = Text('${treeNode.entityCount} 个文件');
    if (treeNode.children.isEmpty) {
      return CheckboxListTile(
        key: PageStorageKey('collection-target-${node.id}'),
        dense: true,
        contentPadding: const EdgeInsets.only(left: 20, right: 8),
        value: selected,
        title: title,
        subtitle: subtitle,
        onChanged: (checked) => onChanged(node, checked ?? false),
      );
    }
    return ExpansionTile(
      key: PageStorageKey('collection-target-${node.id}'),
      initiallyExpanded: initiallyExpanded,
      leading: Checkbox(
        value: selected,
        onChanged: (checked) => onChanged(node, checked ?? false),
      ),
      title: title,
      subtitle: subtitle,
      tilePadding: const EdgeInsets.only(left: 8, right: 8),
      childrenPadding: const EdgeInsets.only(left: 22),
      children: treeNode.children
          .map(
            (child) => CollectionTargetNodeTile(
              treeNode: child,
              selectedIds: selectedIds,
              initiallyExpanded: false,
              onChanged: onChanged,
            ),
          )
          .toList(growable: false),
    );
  }
}
