import 'package:flutter/material.dart';

import '../core/controllers/library_build_task_controller.dart';
import '../core/domain/models.dart';
import 'design_tokens.dart';
import 'app_sidebar.dart';

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
    this.rules = const [],
    this.taskController,
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
  final List<RuleDefinition> rules;
  final LibraryBuildTaskController? taskController;

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
  ValueChanged<IndexNode> get onCreateNodeAtRoot => actions.onCreateNodeAtRoot;
  VoidCallback get onCreateRule => actions.onCreateRule;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
        length: 2,
        child: Column(children: [
          TabBar(tabs: [
            const Tab(text: '资料管理'),
            Tab(
                child: Text(
                    '任务中心${taskController == null || taskController!.attentionCount == 0 ? '' : ' (${taskController!.attentionCount})'}'))
          ]),
          Expanded(
              child: TabBarView(
                  children: [_buildLibrary(context), _buildTasks(context)])),
        ]));
  }

  Widget _buildTasks(BuildContext context) {
    final jobs = taskController?.tasks ?? [...recoverableJobs, ...taskHistory];
    const groups = ['需要处理', '执行中', '已暂停', '部分失败', '已中断', '已完成', '已取消'];
    String group(LibraryBuildJob job) => switch (job.status) {
          LibraryBuildStatus.running ||
          LibraryBuildStatus.pauseRequested ||
          LibraryBuildStatus.cancelRequested =>
            '执行中',
          LibraryBuildStatus.paused => '已暂停',
          LibraryBuildStatus.completedWithErrors => '部分失败',
          LibraryBuildStatus.interrupted => '已中断',
          LibraryBuildStatus.completed => '已完成',
          LibraryBuildStatus.abandoned => '已取消',
          _ => '需要处理',
        };
    return ListView(
        padding:
            AppTokens.pagePadding.add(AppNavigationObstruction.of(context)),
        children: [
          if (errorMessage != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(errorMessage!),
              ),
            ),
          if (jobs.isEmpty) const Text('暂无任务'),
          for (final label in groups)
            if (jobs.any((j) => group(j) == label)) ...[
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(label,
                      style: Theme.of(context).textTheme.titleMedium)),
              for (final job in jobs.where((j) => group(j) == label)) ...[
                if (activeBuildJob?.id == job.id && progress != null)
                  _IndexTaskCard.active(
                      progress: progress!,
                      job: job,
                      running: scanning,
                      onPause: onPause,
                      onAbandon: onCancel)
                else
                  _IndexTaskCard.recoverable(
                      job: job,
                      disabled: false,
                      onAbandon: () => onAbandon(job),
                      onResume: () => onResume(job),
                      onRecheck: () => onRecheck(job),
                      onRetryFailed: () => onRetryFailed(job)),
                if (taskController != null)
                  Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                          onPressed: () => _showTaskDetails(context, job),
                          child: const Text('查看详情'))),
              ],
            ],
          if (taskController != null && jobs.length >= 100)
            TextButton(
                onPressed: taskController!.loadMoreTasks,
                child: const Text('加载更多历史任务')),
          const SizedBox(height: 100),
        ]);
  }

  Future<void> _showTaskDetails(
      BuildContext context, LibraryBuildJob job) async {
    final details = await taskController!.loadTaskDetails(job.id);
    if (!context.mounted) return;
    final metadata = details['metadata'] as Map;
    final events = details['events'] as List;
    final failures = details['failures'] as List;
    await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(job.displayName ?? '任务详情'),
                content: SizedBox(
                    width: 600,
                    child: SingleChildScrollView(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          SelectableText(
                              '来源：${job.sourcePath}\n范围：${job.scopeNodeId ?? job.sourcePath}\n${job.retryOfTaskId == null ? '' : '重试来源：${job.retryOfTaskId}'}'),
                          Text(metadata.isEmpty
                              ? '历史兼容任务'
                              : '新增 ${metadata['added_count'] ?? 0} · 修改 ${metadata['changed_count'] ?? 0} · 缺失 ${metadata['removed_count'] ?? 0} · 未变化 ${metadata['skipped_count'] ?? 0}'),
                          const SizedBox(height: 12),
                          for (final raw in details['directoryChanges'] as List)
                            Text('目录 ${switch (raw['change_kind']) {
                              'added' => '新增',
                              'removed' => '缺失',
                              _ => '未变化'
                            }} ${raw['count']}'),
                          _BuildStageLadder(
                              job: job,
                              progress: LibraryBuildProgress(
                                  stage: job.stage,
                                  completed: 0,
                                  total: 0,
                                  message: '')),
                          const Text('阶段时间线与操作记录'),
                          for (final raw in events)
                            Text(
                                '${DateTime.fromMillisecondsSinceEpoch(raw['created_at'] as int)} · ${_phaseLabel(raw['phase'] as String?)} · ${_eventLabel(raw['message'] as String? ?? '')}'),
                          const SizedBox(height: 12),
                          const Text('失败明细'),
                          if (failures.isEmpty) const Text('无失败记录'),
                          for (final raw in failures)
                            SelectableText(
                                '${raw['source_path'] ?? raw['item_id']}\n${raw['error']}'),
                        ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'))
                ]));
  }

  Widget _buildLibrary(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: AppTokens.pagePadding.add(AppNavigationObstruction.of(context)),
      children: [
        Text('全部资料', style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        _IndexRootSection(
          onCreate: onCreateDirectoryIndex,
          presentation: IndexRootPresentation.directory,
          roots: roots
              .where((node) => node.nodeType == NodeType.directoryIndexRoot)
              .toList(growable: false),
          rootCounts: rootCounts,
          scanning: false,
          onPrimaryAction: onUpdateDirectoryIndex,
          onRename: onRename,
          onDelete: onDelete,
          onRebuildPreviews: onRebuildNodePreviews,
        ),
        _IndexRootSection(
          onCreate: onCreateCollection,
          presentation: IndexRootPresentation.collection,
          roots: roots
              .where((node) => node.nodeType == NodeType.customIndexRoot)
              .toList(growable: false),
          rootCounts: rootCounts,
          scanning: false,
          onPrimaryAction: onCreateNodeAtRoot,
          onRename: onRename,
          onDelete: onDelete,
          onRebuildPreviews: onRebuildNodePreviews,
        ),
        _RuleManagementSection(
          rules: rules,
          onCreate: onCreateRule,
          onEdit: actions.onEditRule,
          onRename: onRename,
          scanning: false,
          onDelete: actions.onDeleteRule,
        ),
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
    required this.onCreateNodeAtRoot,
    required this.onCreateRule,
    required this.onEditRule,
    required this.onDeleteRule,
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
  final ValueChanged<IndexNode> onCreateNodeAtRoot;
  final VoidCallback onCreateRule;
  final ValueChanged<RuleDefinition> onEditRule;
  final ValueChanged<RuleDefinition> onDeleteRule;
}

class _IndexRootSection extends StatelessWidget {
  const _IndexRootSection({
    required this.onCreate,
    required this.presentation,
    required this.roots,
    required this.rootCounts,
    required this.scanning,
    required this.onRename,
    required this.onDelete,
    required this.onRebuildPreviews,
    required this.onPrimaryAction,
  });

  final VoidCallback? onCreate;
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
              IconButton(
                  tooltip: presentation.title == '目录' ? '添加目录' : '新建分类',
                  onPressed: onCreate,
                  icon: const Icon(Icons.add)),
            ],
          ),
          const SizedBox(height: 8),
          if (roots.isEmpty)
            const Padding(padding: EdgeInsets.all(8), child: Text('暂无资料')),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: roots.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount:
                  MediaQuery.orientationOf(context) == Orientation.portrait
                      ? 2
                      : 4,
              mainAxisExtent: 72 *
                  (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1, 3),
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
              protected: roots[index].isProtected,
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
    required this.protected,
  });

  final IndexNode node;
  final IndexRootPresentation presentation;
  final int entityCount;
  final bool scanning;
  final VoidCallback onPrimaryAction;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onRebuildPreviews;
  final bool protected;

  @override
  Widget build(BuildContext context) {
    return _ManagementItem(
        name: node.name,
        count: entityCount,
        icon: protected ? Icons.lock_outline : presentation.icon,
        actions: _RootActionsMenu(
            enabled: !scanning,
            onRename: onRename,
            onDelete: onDelete,
            onRebuildPreviews: node.nodeType == NodeType.directoryIndexRoot
                ? onPrimaryAction
                : onRebuildPreviews,
            protected: protected));
  }
}

class _ManagementItem extends StatelessWidget {
  const _ManagementItem(
      {required this.name,
      required this.count,
      required this.icon,
      required this.actions});
  final String name;
  final int count;
  final IconData icon;
  final Widget actions;
  @override
  Widget build(BuildContext context) => Card(
      margin: EdgeInsets.zero,
      child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(children: [
            Icon(icon, size: 18),
            const SizedBox(width: 6),
            Expanded(
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text('$count 个文件',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall),
                ])),
            actions,
          ])));
}

class _RootActionsMenu extends StatelessWidget {
  const _RootActionsMenu({
    required this.enabled,
    required this.onRename,
    required this.onDelete,
    required this.onRebuildPreviews,
    required this.protected,
  });

  final bool enabled;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onRebuildPreviews;
  final bool protected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        enabled: enabled,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        tooltip: '操作',
        child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Text('操作')),
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
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'rebuildPreviews',
            child: Text('更新'),
          ),
          PopupMenuItem(
              value: 'rename', enabled: !protected, child: const Text('重命名')),
          PopupMenuItem(
              value: 'delete', enabled: !protected, child: const Text('删除')),
        ],
      );
}

class _RuleManagementSection extends StatelessWidget {
  const _RuleManagementSection({
    required this.onRename,
    required this.scanning,
    required this.onCreate,
    required this.rules,
    required this.onEdit,
    required this.onDelete,
  });

  final ValueChanged<IndexNode> onRename;
  final bool scanning;
  final List<RuleDefinition> rules;
  final VoidCallback? onCreate;
  final ValueChanged<RuleDefinition> onEdit;
  final ValueChanged<RuleDefinition> onDelete;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.rule_outlined, size: 18),
            const SizedBox(width: 8),
            Text('规则', style: Theme.of(context).textTheme.titleMedium),
            IconButton(
                tooltip: '新建规则',
                onPressed: onCreate,
                icon: const Icon(Icons.add)),
          ]),
          const SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: rules.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount:
                  MediaQuery.orientationOf(context) == Orientation.portrait
                      ? 2
                      : 4,
              mainAxisExtent: 72 *
                  (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1, 3),
              crossAxisSpacing: 8,
              mainAxisSpacing: 1,
            ),
            itemBuilder: (context, index) {
              final rule = rules[index];
              return _ManagementItem(
                  name: rule.node.name,
                  count: rule.resultCount ?? 0,
                  icon:
                      rule.isBuiltIn ? Icons.lock_outline : Icons.rule_outlined,
                  actions: _RootActionsMenu(
                      enabled: !scanning && !rule.isBuiltIn,
                      onRename: () => onRename(rule.node),
                      onDelete: () => onDelete(rule),
                      onRebuildPreviews: () => onEdit(rule),
                      protected: rule.isBuiltIn));
            },
          ),
        ]),
      );
}

class IndexRootPresentation {
  const IndexRootPresentation._({
    required this.title,
    required this.icon,
    required this.primaryActionLabel,
  });

  static const directory = IndexRootPresentation._(
    title: '目录',
    icon: Icons.folder_copy_outlined,
    primaryActionLabel: '更新',
  );
  static const collection = IndexRootPresentation._(
    title: '分类',
    icon: Icons.collections_bookmark_outlined,
    primaryActionLabel: '新建分类',
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
          ? '资料已可用 · 预览待重试 · $progress'
          : '${_buildStatusLabel(value.status)} · ${_buildStageLabel(value.stage)} · $progress',
      if (value.entityPreviewFailed > 0) '文件预览失败 ${value.entityPreviewFailed}',
      if (value.nodePreviewFailed > 0) '目录封面失败 ${value.nodePreviewFailed}',
    ];
    return _IndexCard(
      title:
          '${value.displayName ?? (isPartial ? '文件夹' : '目录')} · ${switch (value.taskKind) {
        'import' => '导入',
        'update' => '更新',
        'retryPreview' => '预览重试',
        _ => '封面修复'
      }}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(details.join(' · ')),
          Text(value.sourcePath, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (value.currentItem != null)
            Text(value.currentItem!,
                maxLines: 2, overflow: TextOverflow.ellipsis),
          Text(
              '成功 ${value.documentPreviewDone + value.entityPreviewDone + value.nodePreviewDone} · 未变化 ${value.taskMetadata['skipped_count'] ?? 0} · 失败 ${value.indexFailed + value.documentPreviewFailed + value.entityPreviewFailed + value.nodePreviewFailed}'),
          Text(
              '创建 ${DateTime.fromMillisecondsSinceEpoch(value.createdAtMs)}\n更新 ${DateTime.fromMillisecondsSinceEpoch(value.updatedAtMs)}'),
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
              if (!value.isTerminal &&
                  value.status != LibraryBuildStatus.cancelRequested)
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
              if (!value.isTerminal ||
                  value.status == LibraryBuildStatus.completedWithErrors)
                TextButton(
                  onPressed: disabled ? null : onAbandon,
                  child: const Text('取消任务'),
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
                  ? 2
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
      LibraryBuildStatus.interrupted => '已中断',
      LibraryBuildStatus.cancelRequested => '正在取消并释放资源',
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
      LibraryBuildStage.manifest => '读取目录',
      LibraryBuildStage.indexWrite => '保存文件',
      LibraryBuildStage.finalize => '完成更新',
      LibraryBuildStage.documentPreviews => '读取文档',
      LibraryBuildStage.entityPreviews => '生成文件预览',
      LibraryBuildStage.nodePreviews => '生成目录封面',
      LibraryBuildStage.completed => '完成',
    };

String _eventLabel(String value) {
  for (final status in LibraryBuildStatus.values) {
    if (status.name == value) return _buildStatusLabel(status);
  }
  return value;
}

String _phaseLabel(String? value) {
  for (final stage in LibraryBuildStage.values) {
    if (stage.name == value) return _buildStageLabel(stage);
  }
  return '';
}
