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
    required this.recoverableJobPaths,
    this.errorMessage,
    this.taskHistory,
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
  final Map<String, String> recoverableJobPaths;
  final String? errorMessage;
  final String? taskHistory;
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
          _ActiveIndexTaskCard(
            progress: progress!,
            running: scanning,
            onPause: onPause,
            onAbandon: onCancel,
          ),
        ],
        if (progress == null && taskHistory != null) ...[
          const SizedBox(height: 16),
          _IndexCard(
            title: '最近任务摘要',
            child: Text(taskHistory!, style: theme.textTheme.bodyMedium),
          ),
        ],
        if (recoverableJobs.isNotEmpty) ...[
          const SizedBox(height: 16),
          _IndexCard(
            title: '可恢复任务',
            child: Column(
              children: [
                for (final job in recoverableJobs)
                  _RecoverableJobTile(
                    job: job,
                    taskPath:
                        recoverableJobPaths[job.id] ?? _rootNameForJob(job),
                    summary: recoverableJobSummaries[job.id],
                    disabled: scanning,
                    onDiscard: () => onDiscardRecovery(job),
                    onResume: () => onResume(job),
                    onRecheck: () => onRecheck(job),
                    onRetryFailed: () => onRetryFailed(job),
                  ),
              ],
            ),
          ),
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
            title: '目录索引',
            icon: Icons.folder_copy_outlined,
            roots: roots
                .where((node) => node.nodeType == NodeType.directoryIndexRoot)
                .toList(growable: false),
            rootCounts: rootCounts,
            scanning: scanning,
            onUpdate: onUpdateDirectoryIndex,
            onRename: onRename,
            onDelete: onDelete,
            onRebuildPreviews: onRebuildNodePreviews,
          ),
          _IndexRootSection(
            title: '自定义索引',
            icon: Icons.collections_bookmark_outlined,
            roots: roots
                .where((node) => node.nodeType == NodeType.categoryIndexRoot)
                .toList(growable: false),
            rootCounts: rootCounts,
            scanning: scanning,
            onCreateNode: onCreateNodeAtRoot,
            onRename: onRename,
            onDelete: onDelete,
            onRebuildPreviews: onRebuildNodePreviews,
          ),
          _IndexRootSection(
            title: '图索引',
            icon: Icons.hub_outlined,
            roots: roots
                .where((node) => node.nodeType == NodeType.graphIndexRoot)
                .toList(growable: false),
            rootCounts: rootCounts,
            scanning: scanning,
            onOpen: onOpenRoot,
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
    required this.title,
    required this.icon,
    required this.roots,
    required this.rootCounts,
    required this.scanning,
    required this.onRename,
    required this.onDelete,
    required this.onRebuildPreviews,
    this.onUpdate,
    this.onCreateNode,
    this.onOpen,
  });

  final String title;
  final IconData icon;
  final List<IndexNode> roots;
  final Map<String, int> rootCounts;
  final bool scanning;
  final ValueChanged<IndexNode> onRename;
  final ValueChanged<IndexNode> onDelete;
  final ValueChanged<IndexNode> onRebuildPreviews;
  final ValueChanged<IndexNode>? onUpdate;
  final ValueChanged<IndexNode>? onCreateNode;
  final ValueChanged<IndexNode>? onOpen;

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
              Icon(icon, size: 18),
              const SizedBox(width: 8),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
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
                    if (onUpdate != null)
                      TextButton(
                        onPressed: scanning ? null : () => onUpdate!(node),
                        child: const Text('更新'),
                      ),
                    if (onCreateNode != null)
                      TextButton(
                        onPressed: scanning ? null : () => onCreateNode!(node),
                        child: const Text('新建节点'),
                      ),
                    if (onOpen != null)
                      TextButton(
                        onPressed: () => onOpen!(node),
                        child: const Text('打开画布'),
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

class _ActiveIndexTaskCard extends StatelessWidget {
  const _ActiveIndexTaskCard({
    required this.progress,
    required this.running,
    required this.onPause,
    required this.onAbandon,
  });

  final ScanProgress progress;
  final bool running;
  final VoidCallback onPause;
  final VoidCallback onAbandon;

  @override
  Widget build(BuildContext context) {
    return _IndexCard(
      title: '任务 · ${_scanPhaseLabel(progress.phase)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(progress.message),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: progress.entityProgress),
          const SizedBox(height: 10),
          Text(
              '主进度 · 已发现 ${progress.discovered} · 已处理 ${progress.processed}/${progress.total}'),
          if (progress.thumbnailTotal > 0) ...[
            const SizedBox(height: 14),
            LinearProgressIndicator(value: progress.thumbnailProgress),
            const SizedBox(height: 10),
            Text(
                '缩略图 ${progress.thumbnailProcessed}/${progress.thumbnailTotal}'),
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
}

class _RecoverableJobTile extends StatelessWidget {
  const _RecoverableJobTile({
    required this.job,
    required this.taskPath,
    this.summary,
    required this.disabled,
    required this.onDiscard,
    required this.onResume,
    required this.onRecheck,
    required this.onRetryFailed,
  });

  final IndexBuildJob job;
  final String taskPath;
  final IndexJobCandidateSummary? summary;
  final bool disabled;
  final VoidCallback onDiscard;
  final VoidCallback onResume;
  final VoidCallback onRecheck;
  final VoidCallback onRetryFailed;

  @override
  Widget build(BuildContext context) {
    final isPartial = job.targetNodeId != null;
    final progress = summary == null
        ? '${job.processed}/${job.total}'
        : '${summary!.previewed}/${summary!.total}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('${isPartial ? '部分更新' : '全量构建'} · $taskPath'),
      subtitle: Text(
        '${_jobStatusLabel(job.status)} · ${_jobPhaseLabel(job.phase)} · '
        '$progress${job.scanCompleted ? ' · 清单已保存' : ' · 正在建立清单'}'
        '${summary != null && summary!.remaining > 0 ? ' · 待继续 ${summary!.remaining}' : ''}'
        '${summary != null && summary!.failed > 0 ? ' · 失败 ${summary!.failed}' : ''}'
        '${job.previewTotal > 0 ? ' · 预览 ${job.previewProcessed}/${job.previewTotal}' : ''}'
        '${job.error?.isNotEmpty == true ? '\n${job.error}' : ''}',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Wrap(
        spacing: 4,
        children: [
          TextButton(
            onPressed: disabled ? null : onDiscard,
            child: const Text('放弃任务'),
          ),
          TextButton(
            onPressed: disabled ? null : onResume,
            child: const Text('继续任务'),
          ),
          TextButton(
            onPressed: disabled ? null : onRecheck,
            child: const Text('重新检查并更新'),
          ),
          if ((summary?.failed ?? 0) > 0) ...[
            FilledButton.tonal(
              onPressed: disabled ? null : onRetryFailed,
              child: const Text('仅重试失败项'),
            ),
          ],
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
      IndexJobStatus.completed => '已完成',
      IndexJobStatus.failed => '失败',
      IndexJobStatus.canceled => '已取消',
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
