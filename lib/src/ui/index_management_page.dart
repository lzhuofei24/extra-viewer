import 'package:flutter/material.dart';

import '../core/controllers/library_build_task_controller.dart';
import '../core/domain/models.dart';
import 'design_tokens.dart';
import 'library_widgets.dart';

class IndexManagementPage extends StatelessWidget {
  const IndexManagementPage({
    super.key,
    required this.roots,
    required this.rootCounts,
    required this.scanning,
    required this.progress,
    this.activeBuildJob,
    required this.recoverableJobs,
    this.errorMessage,
    this.taskHistory = const [],
    required this.actions,
  });

  final List<IndexNode> roots;
  final Map<String, int> rootCounts;
  final bool scanning;
  final LibraryBuildProgress? progress;
  final LibraryBuildJob? activeBuildJob;
  final List<LibraryBuildJob> recoverableJobs;
  final String? errorMessage;
  final List<LibraryBuildJob> taskHistory;
  final IndexManagementActions actions;

  VoidCallback get onCreateDirectoryIndex => actions.onCreateDirectoryIndex;
  VoidCallback get onPause => actions.onPause;
  VoidCallback get onCancel => actions.onCancel;
  ValueChanged<LibraryBuildJob> get onResume => actions.onResume;
  ValueChanged<LibraryBuildJob> get onRecheck => actions.onRecheck;
  ValueChanged<LibraryBuildJob> get onRetryFailed => actions.onRetryFailed;
  ValueChanged<LibraryBuildJob> get onAbandon => actions.onAbandon;
  ValueChanged<IndexNode> get onRename => actions.onRename;
  ValueChanged<IndexNode> get onDelete => actions.onDelete;
  ValueChanged<IndexNode> get onUpdateDirectoryIndex =>
      actions.onUpdateDirectoryIndex;
  ValueChanged<IndexNode> get onRebuildNodePreviews =>
      actions.onRebuildNodePreviews;
  VoidCallback get onCreateCollection => actions.onCreateCollection;
  VoidCallback get onCreateGraph => actions.onCreateGraph;
  ValueChanged<IndexNode> get onCreateNodeAtRoot => actions.onCreateNodeAtRoot;
  ValueChanged<IndexNode> get onOpenRoot => actions.onOpenRoot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: AppTokens.pagePadding,
      children: [
        const SectionHeader(
          title: '索引',
          subtitle: '建立和维护数据入口；不会复制或修改源文件。',
        ),
        const SizedBox(height: 18),
        _IndexCard(
          title: '新增索引',
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: scanning ? null : onCreateDirectoryIndex,
                icon: const Icon(Icons.folder_copy_outlined),
                label: const Text('目录索引'),
              ),
              OutlinedButton.icon(
                onPressed: scanning ? null : onCreateCollection,
                icon: const Icon(Icons.collections_bookmark_outlined),
                label: const Text('自定义索引'),
              ),
              OutlinedButton.icon(
                onPressed: scanning ? null : onCreateGraph,
                icon: const Icon(Icons.hub_outlined),
                label: const Text('图索引'),
              ),
            ],
          ),
        ),
        if (progress != null) ...[
          const SizedBox(height: 16),
          _IndexTaskCard.active(
            progress: progress!,
            job: activeBuildJob,
            running: scanning,
            onPause: onPause,
            onAbandon: onCancel,
          ),
        ],
        if (recoverableJobs.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('可恢复任务', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final job in recoverableJobs) ...[
            _IndexTaskCard.recoverable(
              job: job,
              disabled: scanning,
              onAbandon: () => onAbandon(job),
              onResume: () => onResume(job),
              onRecheck: () => onRecheck(job),
              onRetryFailed: () => onRetryFailed(job),
            ),
            const SizedBox(height: 8),
          ],
        ],
        if (errorMessage != null) ...[
          const SizedBox(height: 16),
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                errorMessage!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        Text('索引管理', style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        if (roots.isEmpty)
          const EmptyStateCard(
            title: '还没有建立索引',
            message: '输入一个本地目录路径，建立第一个索引。',
          )
        else ...[
          _IndexRootSection(
            presentation: IndexRootPresentation.directory,
            roots: roots
                .where((node) => node.nodeType == NodeType.directoryIndexRoot)
                .toList(growable: false),
            rootCounts: rootCounts,
            scanning: scanning,
            onPrimaryAction: onUpdateDirectoryIndex,
            onRename: onRename,
            onDelete: onDelete,
            onRebuildPreviews: onRebuildNodePreviews,
          ),
          _IndexRootSection(
            presentation: IndexRootPresentation.collection,
            roots: roots
                .where((node) => node.nodeType == NodeType.customIndexRoot)
                .toList(growable: false),
            rootCounts: rootCounts,
            scanning: scanning,
            onPrimaryAction: onCreateNodeAtRoot,
            onRename: onRename,
            onDelete: onDelete,
            onRebuildPreviews: onRebuildNodePreviews,
          ),
          _IndexRootSection(
            presentation: IndexRootPresentation.graph,
            roots: roots
                .where((node) => node.nodeType == NodeType.graphIndexRoot)
                .toList(growable: false),
            rootCounts: rootCounts,
            scanning: scanning,
            onPrimaryAction: onOpenRoot,
            onRename: onRename,
            onDelete: onDelete,
            onRebuildPreviews: onRebuildNodePreviews,
          ),
        ],
        const SizedBox(height: 100),
      ],
    );
  }
}

/// Callback contract between the application shell and the index-management
/// page. Keeping actions together prevents the page API from exposing the
/// shell's internal state machine one callback at a time.
class IndexManagementActions {
  const IndexManagementActions({
    required this.onCreateDirectoryIndex,
    required this.onPause,
    required this.onCancel,
    required this.onResume,
    required this.onRecheck,
    required this.onRetryFailed,
    required this.onAbandon,
    required this.onRename,
    required this.onDelete,
    required this.onUpdateDirectoryIndex,
    required this.onRebuildNodePreviews,
    required this.onCreateCollection,
    required this.onCreateGraph,
    required this.onCreateNodeAtRoot,
    required this.onOpenRoot,
  });

  final VoidCallback onCreateDirectoryIndex;
  final VoidCallback onPause;
  final VoidCallback onCancel;
  final ValueChanged<LibraryBuildJob> onResume;
  final ValueChanged<LibraryBuildJob> onRecheck;
  final ValueChanged<LibraryBuildJob> onRetryFailed;
  final ValueChanged<LibraryBuildJob> onAbandon;
  final ValueChanged<IndexNode> onRename;
  final ValueChanged<IndexNode> onDelete;
  final ValueChanged<IndexNode> onUpdateDirectoryIndex;
  final ValueChanged<IndexNode> onRebuildNodePreviews;
  final VoidCallback onCreateCollection;
  final VoidCallback onCreateGraph;
  final ValueChanged<IndexNode> onCreateNodeAtRoot;
  final ValueChanged<IndexNode> onOpenRoot;
}

class _IndexRootSection extends StatelessWidget {
  const _IndexRootSection({
    required this.presentation,
    required this.roots,
    required this.rootCounts,
    required this.scanning,
    required this.onRename,
    required this.onDelete,
    required this.onRebuildPreviews,
    required this.onPrimaryAction,
  });

  final IndexRootPresentation presentation;
  final List<IndexNode> roots;
  final Map<String, int> rootCounts;
  final bool scanning;
  final ValueChanged<IndexNode> onRename;
  final ValueChanged<IndexNode> onDelete;
  final ValueChanged<IndexNode> onRebuildPreviews;
  final ValueChanged<IndexNode> onPrimaryAction;

  @override
  Widget build(BuildContext context) {
    if (roots.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(presentation.icon, size: 18),
              const SizedBox(width: 8),
              Text(presentation.title,
                  style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: roots.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisExtent: 76,
              crossAxisSpacing: 8,
              mainAxisSpacing: 1,
            ),
            itemBuilder: (context, index) => _IndexRootGridCard(
              node: roots[index],
              presentation: presentation,
              entityCount: rootCounts[roots[index].id] ?? 0,
              scanning: scanning,
              onPrimaryAction: () => onPrimaryAction(roots[index]),
              onRename: () => onRename(roots[index]),
              onDelete: () => onDelete(roots[index]),
              onRebuildPreviews: () => onRebuildPreviews(roots[index]),
            ),
          ),
        ],
      ),
    );
  }
}

class _IndexRootGridCard extends StatelessWidget {
  const _IndexRootGridCard({
    required this.node,
    required this.presentation,
    required this.entityCount,
    required this.scanning,
    required this.onPrimaryAction,
    required this.onRename,
    required this.onDelete,
    required this.onRebuildPreviews,
  });

  final IndexNode node;
  final IndexRootPresentation presentation;
  final int entityCount;
  final bool scanning;
  final VoidCallback onPrimaryAction;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onRebuildPreviews;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
        child: Row(
          children: [
            Icon(
              presentation.icon,
              size: 21,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    node.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$entityCount 个实体',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: scanning ? null : onPrimaryAction,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(presentation.primaryActionLabel),
            ),
            _RootActionsMenu(
              enabled: !scanning,
              onRename: onRename,
              onDelete: onDelete,
              onRebuildPreviews: onRebuildPreviews,
            ),
          ],
        ),
      ),
    );
  }
}

class _RootActionsMenu extends StatelessWidget {
  const _RootActionsMenu({
    required this.enabled,
    required this.onRename,
    required this.onDelete,
    required this.onRebuildPreviews,
  });

  final bool enabled;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onRebuildPreviews;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        enabled: enabled,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        iconSize: 19,
        onSelected: (action) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            switch (action) {
              case 'rebuildPreviews':
                onRebuildPreviews();
              case 'rename':
                onRename();
              case 'delete':
                onDelete();
            }
          });
        },
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: 'rebuildPreviews',
            child: Text('重新生成节点预览'),
          ),
          PopupMenuItem(value: 'rename', child: Text('重命名')),
          PopupMenuItem(value: 'delete', child: Text('删除')),
        ],
      );
}

class IndexRootPresentation {
  const IndexRootPresentation._({
    required this.title,
    required this.icon,
    required this.primaryActionLabel,
  });

  static const directory = IndexRootPresentation._(
    title: '目录索引',
    icon: Icons.folder_copy_outlined,
    primaryActionLabel: '更新',
  );
  static const collection = IndexRootPresentation._(
    title: '自定义索引',
    icon: Icons.collections_bookmark_outlined,
    primaryActionLabel: '新建节点',
  );
  static const graph = IndexRootPresentation._(
    title: '图索引',
    icon: Icons.hub_outlined,
    primaryActionLabel: '打开画布',
  );

  final String title;
  final IconData icon;
  final String primaryActionLabel;
}

class _IndexTaskCard extends StatelessWidget {
  const _IndexTaskCard.active({
    required this.progress,
    required this.job,
    required this.running,
    required this.onPause,
    required this.onAbandon,
  })  : disabled = false,
        onResume = null,
        onRecheck = null,
        onRetryFailed = null;

  const _IndexTaskCard.recoverable({
    required this.job,
    required this.disabled,
    required this.onAbandon,
    required this.onResume,
    required this.onRecheck,
    required this.onRetryFailed,
  })  : progress = null,
        running = false,
        onPause = null;

  final LibraryBuildProgress? progress;
  final bool running;
  final VoidCallback? onPause;
  final VoidCallback? onAbandon;
  final LibraryBuildJob? job;
  final bool disabled;
  final VoidCallback? onResume;
  final VoidCallback? onRecheck;
  final VoidCallback? onRetryFailed;

  @override
  Widget build(BuildContext context) {
    if (progress != null) return _buildActive();
    return _buildRecoverable(context);
  }

  Widget _buildActive() {
    final value = progress!;
    return _IndexCard(
      title: '任务 · ${_buildStageLabel(value.stage)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value.message),
          const SizedBox(height: 12),
          _BuildStageLadder(job: job, progress: value),
          if (running) ...[
            const SizedBox(height: 14),
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(
                  onPressed: onPause,
                  icon: const Icon(Icons.pause_rounded),
                  label: const Text('暂停')),
              TextButton.icon(
                  onPressed: onAbandon,
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('放弃任务')),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _buildRecoverable(BuildContext context) {
    final value = job!;
    final isPartial = value.targetNodeId != null;
    final assetOnlyFailure = value.status == LibraryBuildStatus.failed &&
        value.stage == LibraryBuildStage.nodePreviews &&
        (value.documentPreviewFailed > 0 ||
            value.entityPreviewFailed > 0 ||
            value.nodePreviewFailed > 0);
    final progress = switch (value.stage) {
      LibraryBuildStage.manifest => '${value.manifestTotal} 项',
      LibraryBuildStage.indexWrite ||
      LibraryBuildStage.finalize =>
        '${value.indexedTotal}/${value.manifestTotal}',
      LibraryBuildStage.documentPreviews =>
        '${value.documentPreviewDone}/${value.documentPreviewTotal}',
      LibraryBuildStage.entityPreviews =>
        '${value.entityPreviewDone}/${value.entityPreviewTotal}',
      LibraryBuildStage.nodePreviews =>
        '${value.nodePreviewDone}/${value.nodePreviewTotal}',
      LibraryBuildStage.completed => '完成',
    };
    final details = <String>[
      assetOnlyFailure
          ? '索引已可用 · 预览待重试 · $progress'
          : '${_buildStatusLabel(value.status)} · ${_buildStageLabel(value.stage)} · $progress',
      if (value.entityPreviewFailed > 0) '实体失败 ${value.entityPreviewFailed}',
      if (value.nodePreviewFailed > 0) '节点失败 ${value.nodePreviewFailed}',
    ];
    return _IndexCard(
      title: isPartial ? '部分更新任务' : '目录索引任务',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(details.join(' · ')),
          if (value.error?.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('错误详情'),
                children: [
                  if (value.error?.isNotEmpty == true)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(value.error!),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!value.isCompleted)
                FilledButton(
                  onPressed: disabled ? null : onResume,
                  child: const Text('继续任务'),
                ),
              if (value.kind == LibraryBuildKind.scanScope)
                OutlinedButton(
                  onPressed: disabled ? null : onRecheck,
                  child: const Text('重新检查并更新'),
                ),
              if (value.indexFailed > 0 ||
                  value.documentPreviewFailed > 0 ||
                  value.entityPreviewFailed > 0 ||
                  value.nodePreviewFailed > 0)
                OutlinedButton(
                  onPressed: disabled ? null : onRetryFailed,
                  child: const Text('仅重试失败项'),
                ),
              TextButton(
                onPressed: disabled ? null : onAbandon,
                child: const Text('放弃任务'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BuildStageLadder extends StatelessWidget {
  const _BuildStageLadder({required this.job, required this.progress});

  final LibraryBuildJob? job;
  final LibraryBuildProgress progress;

  @override
  Widget build(BuildContext context) {
    final current = progress.stage.index;
    final theme = Theme.of(context);
    const stages = [
      LibraryBuildStage.manifest,
      LibraryBuildStage.indexWrite,
      LibraryBuildStage.finalize,
      LibraryBuildStage.documentPreviews,
      LibraryBuildStage.entityPreviews,
      LibraryBuildStage.nodePreviews,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < stages.length; index++)
          Padding(
            padding:
                EdgeInsets.only(left: index * 18.0, top: index == 0 ? 0 : 4),
            child: _BuildStageLine(
              stage: stages[index],
              state: index < current
                  ? _BuildStageLineState.completed
                  : index == current
                      ? _BuildStageLineState.active
                      : _BuildStageLineState.pending,
              completed: index == current
                  ? progress.completed
                  : index < current
                      ? _storedProgress(stages[index]).$1
                      : 0,
              total: index == current
                  ? progress.total
                  : index < current
                      ? _storedProgress(stages[index]).$2
                      : 0,
              failed: index == current
                  ? progress.failed
                  : _failedFor(stages[index]),
              activeMessage: index == current ? progress.message : null,
              theme: theme,
            ),
          ),
      ],
    );
  }

  int _failedFor(LibraryBuildStage stage) => switch (stage) {
        LibraryBuildStage.documentPreviews => job?.documentPreviewFailed ?? 0,
        LibraryBuildStage.entityPreviews => job?.entityPreviewFailed ?? 0,
        LibraryBuildStage.nodePreviews => job?.nodePreviewFailed ?? 0,
        _ => 0,
      };

  (int, int) _storedProgress(LibraryBuildStage stage) {
    final value = job;
    if (value == null) return (0, 0);
    return switch (stage) {
      LibraryBuildStage.manifest => (value.manifestTotal, value.manifestTotal),
      LibraryBuildStage.indexWrite => (value.indexedTotal, value.manifestTotal),
      LibraryBuildStage.finalize => (1, 1),
      LibraryBuildStage.documentPreviews => (
          value.documentPreviewDone + value.documentPreviewFailed,
          value.documentPreviewTotal,
        ),
      LibraryBuildStage.entityPreviews => (
          value.entityPreviewDone + value.entityPreviewFailed,
          value.entityPreviewTotal,
        ),
      LibraryBuildStage.nodePreviews => (
          value.nodePreviewDone + value.nodePreviewFailed,
          value.nodePreviewTotal,
        ),
      LibraryBuildStage.completed => (0, 0),
    };
  }
}

enum _BuildStageLineState { pending, active, completed }

class _BuildStageLine extends StatelessWidget {
  const _BuildStageLine({
    required this.stage,
    required this.state,
    required this.completed,
    required this.total,
    required this.failed,
    required this.theme,
    this.activeMessage,
  });

  final LibraryBuildStage stage;
  final _BuildStageLineState state;
  final int completed;
  final int total;
  final int failed;
  final ThemeData theme;
  final String? activeMessage;

  @override
  Widget build(BuildContext context) {
    final active = state == _BuildStageLineState.active;
    final completedStage = state == _BuildStageLineState.completed;
    final color = completedStage || active
        ? theme.colorScheme.primary
        : theme.colorScheme.outlineVariant;
    final label = activeMessage ?? _buildStageLabel(stage);
    final details = total > 0
        ? '$completed/$total${failed > 0 ? ' · 失败 $failed' : ''}'
        : completed > 0
            ? '$completed 项${failed > 0 ? ' · 失败 $failed' : ''}'
            : '等待中';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 92,
              child: Text(
                _buildStageLabel(stage),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: active || completedStage
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: Text(
                details,
                textAlign: TextAlign.right,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        LinearProgressIndicator(
          minHeight: 4,
          value: active && total <= 0
              ? null
              : completedStage
                  ? 1
                  : total <= 0
                      ? 0
                      : completed.clamp(0, total) / total,
          color: color,
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
        if (active && activeMessage != null) ...[
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _IndexCard extends StatelessWidget {
  const _IndexCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            Divider(color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

String _buildStatusLabel(LibraryBuildStatus status) => switch (status) {
      LibraryBuildStatus.pending => '等待中',
      LibraryBuildStatus.running => '运行中',
      LibraryBuildStatus.pauseRequested => '正在暂停',
      LibraryBuildStatus.blocked => '等待处理',
      LibraryBuildStatus.completedWithErrors => '已完成，有待修复项',
      LibraryBuildStatus.paused => '已暂停',
      LibraryBuildStatus.completed => '已完成',
      LibraryBuildStatus.failed => '失败',
      LibraryBuildStatus.abandoned => '已放弃',
    };

String _buildStageLabel(LibraryBuildStage stage) => switch (stage) {
      LibraryBuildStage.manifest => '建立清单',
      LibraryBuildStage.indexWrite => '写入索引',
      LibraryBuildStage.finalize => '整理并提交',
      LibraryBuildStage.documentPreviews => '解析文档预览',
      LibraryBuildStage.entityPreviews => '构建实体预览',
      LibraryBuildStage.nodePreviews => '构建节点预览',
      LibraryBuildStage.completed => '完成',
    };
