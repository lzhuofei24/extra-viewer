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
    required this.onScan,
    this.onPickDirectory,
    required this.onPause,
    required this.onCancel,
    required this.onResume,
    required this.onRetryFailed,
    required this.onShowRecoveryFailures,
    required this.onDiscardRecovery,
    required this.onImport,
    required this.onRename,
    required this.onDelete,
    required this.onUpdateDirectoryIndex,
    required this.onRebuildNodePreviews,
    required this.onCreateCollection,
    required this.onCreateGraph,
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
  final VoidCallback onScan;
  final VoidCallback? onPickDirectory;
  final VoidCallback onPause;
  final VoidCallback onCancel;
  final ValueChanged<IndexBuildJob> onResume;
  final ValueChanged<IndexBuildJob> onRetryFailed;
  final ValueChanged<IndexBuildJob> onShowRecoveryFailures;
  final ValueChanged<IndexBuildJob> onDiscardRecovery;
  final VoidCallback onImport;
  final ValueChanged<IndexNode> onRename;
  final ValueChanged<IndexNode> onDelete;
  final ValueChanged<IndexNode> onUpdateDirectoryIndex;
  final ValueChanged<IndexNode> onRebuildNodePreviews;
  final VoidCallback onCreateCollection;
  final VoidCallback onCreateGraph;

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
        const SizedBox(height: 16),
        _IndexCard(
          title: '高级工具',
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: scanning ? null : onImport,
                icon: const Icon(Icons.unarchive_outlined),
                label: const Text('导入索引包 (.bvi)'),
              ),
            ],
          ),
        ),
        if (progress != null) ...[
          const SizedBox(height: 16),
          _IndexCard(
            title: '扫描任务',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(progress!.message, style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: progress!.entityProgress,
                ),
                const SizedBox(height: 10),
                Text(
                    '已发现 ${progress!.discovered} · 已处理 ${progress!.processed}/${progress!.total}'),
                if (progress!.thumbnailTotal > 0) ...[
                  const SizedBox(height: 14),
                  LinearProgressIndicator(value: progress!.thumbnailProgress),
                  const SizedBox(height: 10),
                  Text(
                    '缩略图 ${progress!.thumbnailProcessed}/${progress!.thumbnailTotal}',
                  ),
                ],
                if (scanning) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: onPause,
                        icon: const Icon(Icons.pause_rounded),
                        label: const Text('暂停'),
                      ),
                      TextButton.icon(
                        onPressed: onCancel,
                        icon: const Icon(Icons.close_rounded),
                        label: const Text('取消'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
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
                    onRetryFailed: () => onRetryFailed(job),
                    onShowFailures: () => onShowRecoveryFailures(job),
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
        Text('已有索引', style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        if (roots.isEmpty)
          const EmptyStateCard(
            title: '还没有建立索引',
            message: '输入一个本地目录路径，建立第一个索引。',
          )
        else
          for (final node in roots) ...[
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                leading: const Icon(Icons.account_tree_outlined),
                title: Text(node.name),
                subtitle: Text(
                    '${_nodeTypeLabel(node.nodeType)} · ${rootCounts[node.id] ?? 0} 个实体'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (node.nodeType == NodeType.directoryIndexRoot)
                      IconButton(
                        tooltip: '更新索引',
                        onPressed: scanning
                            ? null
                            : () => onUpdateDirectoryIndex(node),
                        icon: const Icon(Icons.sync_rounded),
                      ),
                    PopupMenuButton<String>(
                      onSelected: (action) {
                        // Let PopupMenuRoute finish disposing before opening a
                        // second modal route. Opening a dialog synchronously here
                        // can leave inherited dependents attached on Android.
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (action == 'rebuildPreviews') {
                            onRebuildNodePreviews(node);
                          }
                          if (action == 'rename') onRename(node);
                          if (action == 'delete') onDelete(node);
                        });
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'rebuildPreviews',
                          child: Text('重新生成节点预览'),
                        ),
                        const PopupMenuItem(
                            value: 'rename', child: Text('重命名')),
                        const PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
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

class _RecoverableJobTile extends StatelessWidget {
  const _RecoverableJobTile({
    required this.job,
    required this.taskPath,
    this.summary,
    required this.disabled,
    required this.onDiscard,
    required this.onResume,
    required this.onRetryFailed,
    required this.onShowFailures,
  });

  final IndexBuildJob job;
  final String taskPath;
  final IndexJobCandidateSummary? summary;
  final bool disabled;
  final VoidCallback onDiscard;
  final VoidCallback onResume;
  final VoidCallback onRetryFailed;
  final VoidCallback onShowFailures;

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
        '${job.previewTotal > 0 ? ' · 预览 ${job.previewProcessed}/${job.previewTotal}' : ''}',
      ),
      trailing: Wrap(
        spacing: 4,
        children: [
          TextButton.icon(
            onPressed: disabled ? null : onDiscard,
            icon: const Icon(Icons.close_rounded, size: 18),
            label: const Text('取消'),
          ),
          if ((summary?.failed ?? 0) > 0) ...[
            TextButton(
              onPressed: disabled ? null : onShowFailures,
              child: const Text('失败详情'),
            ),
            FilledButton.tonal(
              onPressed: disabled ? null : onRetryFailed,
              child: const Text('仅重试失败项'),
            ),
          ],
          FilledButton.tonal(
            onPressed: disabled ? null : onResume,
            child: const Text('继续任务'),
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

String _nodeTypeLabel(NodeType type) {
  return switch (type) {
    NodeType.directoryIndexRoot => '目录索引',
    NodeType.categoryIndexRoot => '自定义索引',
    NodeType.graphIndexRoot => '图索引',
    _ => '索引节点',
  };
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
