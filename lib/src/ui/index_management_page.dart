import 'package:flutter/material.dart';

import '../core/domain/models.dart';
import '../core/scanner/library_scanner.dart';
import 'design_tokens.dart';
import 'library_widgets.dart';

class IndexManagementPage extends StatelessWidget {
  const IndexManagementPage({
    super.key,
    required this.pathController,
    required this.roots,
    required this.rootCounts,
    required this.scanning,
    required this.progress,
    required this.recoverableJobs,
    required this.recoverableJobSummaries,
    required this.recoverableJobFailures,
    required this.recoverableJobPaths,
    this.errorMessage,
    this.taskHistory = const [],
    required this.onScan,
    this.onPickDirectory,
    required this.onPause,
    required this.onCancel,
    required this.onResume,
    required this.onRecheck,
    required this.onRetryFailed,
    required this.onDiscardRecovery,
    required this.onRename,
    required this.onDelete,
    required this.onUpdateDirectoryIndex,
    required this.onRebuildNodePreviews,
    required this.onCreateCollection,
    required this.onCreateGraph,
    required this.onCreateNodeAtRoot,
    required this.onOpenRoot,
  });

  final TextEditingController pathController;
  final List<IndexNode> roots;
  final Map<String, int> rootCounts;
  final bool scanning;
  final ScanProgress? progress;
  final List<IndexBuildJob> recoverableJobs;
  final Map<String, IndexJobCandidateSummary> recoverableJobSummaries;
  final Map<String, List<IndexJobCandidate>> recoverableJobFailures;
  final Map<String, String> recoverableJobPaths;
  final String? errorMessage;
  final List<IndexJobHistoryEntry> taskHistory;
  final VoidCallback onScan;
  final VoidCallback? onPickDirectory;
  final VoidCallback onPause;
  final VoidCallback onCancel;
  final ValueChanged<IndexBuildJob> onResume;
  final ValueChanged<IndexBuildJob> onRecheck;
  final ValueChanged<IndexBuildJob> onRetryFailed;
  final ValueChanged<IndexBuildJob> onDiscardRecovery;
  final ValueChanged<IndexNode> onRename;
  final ValueChanged<IndexNode> onDelete;
  final ValueChanged<IndexNode> onUpdateDirectoryIndex;
  final ValueChanged<IndexNode> onRebuildNodePreviews;
  final VoidCallback onCreateCollection;
  final VoidCallback onCreateGraph;
  final ValueChanged<IndexNode> onCreateNodeAtRoot;
  final ValueChanged<IndexNode> onOpenRoot;

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
          title: '建立索引',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: pathController,
                decoration: const InputDecoration(
                  labelText: '本地路径',
                  hintText: r'D:\Media\Library',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => onScan(),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: scanning ? null : onScan,
                icon: const Icon(Icons.sync_rounded),
                label: Text(scanning ? '扫描中' : '建立索引'),
              ),
              if (onPickDirectory != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: scanning ? null : onPickDirectory,
                  icon: const Icon(Icons.folder_open_rounded),
                  label: const Text('选择 Android 目录'),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        _IndexCard(
          title: '虚拟索引',
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: onCreateCollection,
                icon: const Icon(Icons.collections_bookmark_outlined),
                label: const Text('新建自定义索引'),
              ),
              OutlinedButton.icon(
                onPressed: onCreateGraph,
                icon: const Icon(Icons.hub_outlined),
                label: const Text('新建图索引'),
              ),
            ],
          ),
        ),
        if (progress != null) ...[
          const SizedBox(height: 16),
          _IndexTaskCard.active(
            progress: progress!,
            running: scanning,
            onPause: onPause,
            onAbandon: onCancel,
          ),
        ],
        if (progress == null && taskHistory.isNotEmpty) ...[
          const SizedBox(height: 16),
          _IndexCard(
            title: '最近任务摘要',
            child: Column(
              children: [
                for (final entry in taskHistory)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(entry.summary),
                    subtitle: Text(
                      entry.sourcePath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text(_jobStatusLabel(entry.status)),
                  ),
              ],
            ),
          ),
        ],
        if (recoverableJobs.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('可恢复任务', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final job in recoverableJobs) ...[
            _IndexTaskCard.recoverable(
              job: job,
              taskPath: recoverableJobPaths[job.id] ?? _rootNameForJob(job),
              summary: recoverableJobSummaries[job.id],
              failedCandidates: recoverableJobFailures[job.id] ?? const [],
              disabled: scanning,
              onDiscard: () => onDiscardRecovery(job),
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
                .where((node) => node.nodeType == NodeType.categoryIndexRoot)
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

  String _rootNameForJob(IndexBuildJob job) {
    for (final root in roots) {
      if (root.id == job.indexRootId) return root.name;
    }
    return job.targetNodeId == null ? '目录索引' : '目录节点';
  }
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
          for (final node in roots) ...[
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                title: Text(node.name),
                subtitle: Text('${rootCounts[node.id] ?? 0} 个实体'),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    TextButton(
                      onPressed: scanning ? null : () => onPrimaryAction(node),
                      child: Text(presentation.primaryActionLabel),
                    ),
                    PopupMenuButton<String>(
                      enabled: !scanning,
                      onSelected: (action) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (action == 'rebuildPreviews') {
                            onRebuildPreviews(node);
                          }
                          if (action == 'rename') onRename(node);
                          if (action == 'delete') onDelete(node);
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
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
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
    required this.running,
    required this.onPause,
    required this.onAbandon,
  })  : job = null,
        taskPath = null,
        summary = null,
        failedCandidates = const [],
        disabled = false,
        onDiscard = null,
        onResume = null,
        onRecheck = null,
        onRetryFailed = null;

  const _IndexTaskCard.recoverable({
    required this.job,
    required this.taskPath,
    required this.summary,
    required this.failedCandidates,
    required this.disabled,
    required this.onDiscard,
    required this.onResume,
    required this.onRecheck,
    required this.onRetryFailed,
  })  : progress = null,
        running = false,
        onPause = null,
        onAbandon = null;

  final ScanProgress? progress;
  final bool running;
  final VoidCallback? onPause;
  final VoidCallback? onAbandon;
  final IndexBuildJob? job;
  final String? taskPath;
  final IndexJobCandidateSummary? summary;
  final List<IndexJobCandidate> failedCandidates;
  final bool disabled;
  final VoidCallback? onDiscard;
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
      title: '任务 · ${_scanPhaseLabel(value.phase)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value.message),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: value.entityProgress),
          const SizedBox(height: 10),
          Text(
              '主进度 · 已发现 ${value.discovered} · 已处理 ${value.processed}/${value.total}'),
          if (value.thumbnailTotal > 0) ...[
            const SizedBox(height: 14),
            LinearProgressIndicator(value: value.thumbnailProgress),
            const SizedBox(height: 10),
            Text('缩略图 ${value.thumbnailProcessed}/${value.thumbnailTotal}'),
          ],
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
                  label: const Text('放弃')),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _buildRecoverable(BuildContext context) {
    final value = job!;
    final candidates = summary;
    final isPartial = value.targetNodeId != null;
    final progress = candidates == null
        ? '${value.processed}/${value.total}'
        : '${candidates.previewed}/${candidates.total}';
    final details = <String>[
      '${_jobStatusLabel(value.status)} · ${_jobPhaseLabel(value.phase)} · $progress',
      value.scanCompleted ? '清单已保存' : '正在建立清单',
      if (candidates != null && candidates.remaining > 0)
        '待继续 ${candidates.remaining}',
      if (candidates != null && candidates.failed > 0)
        '失败 ${candidates.failed}',
      if (value.previewTotal > 0)
        '预览 ${value.previewProcessed}/${value.previewTotal}',
    ];
    return _IndexCard(
      title: '${isPartial ? '部分更新' : '全量构建'} · $taskPath',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(details.join(' · ')),
          if (value.error?.isNotEmpty == true || failedCandidates.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  '错误详情${failedCandidates.isEmpty ? '' : ' (${failedCandidates.length})'}',
                ),
                children: [
                  if (value.error?.isNotEmpty == true)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(value.error!),
                    ),
                  for (final candidate in failedCandidates)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(candidate.relativePath,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(candidate.error ?? '预览生成失败',
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton(
                onPressed: disabled ? null : onResume,
                child: const Text('继续任务'),
              ),
              const SizedBox(width: 8),
              PopupMenuButton<String>(
                enabled: !disabled,
                onSelected: (action) => switch (action) {
                  'discard' => onDiscard?.call(),
                  'recheck' => onRecheck?.call(),
                  'retryFailed' => onRetryFailed?.call(),
                  _ => null,
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'recheck', child: Text('重新检查并更新')),
                  if ((candidates?.failed ?? 0) > 0)
                    const PopupMenuItem(
                        value: 'retryFailed', child: Text('仅重试失败项')),
                  const PopupMenuItem(value: 'discard', child: Text('放弃任务')),
                ],
                child: const OutlinedButton(
                  onPressed: null,
                  child: Text('更多操作'),
                ),
              ),
            ],
          ),
        ],
      ),
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

String _jobStatusLabel(IndexJobStatus status) => switch (status) {
      IndexJobStatus.pending => '等待中',
      IndexJobStatus.running => '运行中',
      IndexJobStatus.paused => '已暂停',
      IndexJobStatus.attentionRequired => '需要处理',
      IndexJobStatus.completed => '已完成',
      IndexJobStatus.failed => '失败',
      IndexJobStatus.abandoned => '已放弃',
    };

String _jobPhaseLabel(IndexJobPhase phase) => switch (phase) {
      IndexJobPhase.discovering => '扫描目录',
      IndexJobPhase.preparing => '提取元数据',
      IndexJobPhase.writing => '写入索引',
      IndexJobPhase.previews => '生成预览',
      IndexJobPhase.completed => '完成',
    };

String _scanPhaseLabel(ScanPhase phase) => switch (phase) {
      ScanPhase.discovering => '扫描目录',
      ScanPhase.processing => '构建索引',
      ScanPhase.completed => '完成',
    };
