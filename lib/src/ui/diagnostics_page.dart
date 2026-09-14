import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../modules/infrastructure/database_runtime.dart';
import '../core/diagnostics/app_diagnostic_log.dart';
import '../core/domain/models.dart';
import '../core/controllers/library_build_task_controller.dart';
import 'design_tokens.dart';
import 'library_widgets.dart';

class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({
    super.key,
    required this.database,
    required this.log,
    required this.recoverableJobs,
    required this.history,
    this.progress,
  });

  final DatabaseDescriptor database;
  final AppDiagnosticLog log;
  final List<LibraryBuildJob> recoverableJobs;
  final List<LibraryBuildJob> history;
  final LibraryBuildProgress? progress;

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  Future<List<AppDiagnosticRecord>>? _records;
  String _level = '全部';
  bool _showDetails = false;
  Timer? _refreshDebounce;

  @override
  void initState() {
    super.initState();
    _reload();
    widget.log.addListener(_onLogChanged);
  }

  @override
  void dispose() {
    widget.log.removeListener(_onLogChanged);
    _refreshDebounce?.cancel();
    super.dispose();
  }

  void _onLogChanged() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(_reload);
    });
  }

  void _reload() {
    _records = widget.log.readRecent(limit: 160);
  }

  Future<void> _copyDiagnostics(List<AppDiagnosticRecord> records) async {
    final buffer = StringBuffer()
      ..writeln('Best Viewer 诊断摘要')
      ..writeln('平台: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
      ..writeln('Schema: ${DatabaseDescriptor.schemaVersion}')
      ..writeln('日志目录: ${_redact(widget.log.directoryPath ?? '不可用')}')
      ..writeln()
      ..writeln('可恢复任务: ${widget.recoverableJobs.length}')
      ..writeln('历史任务: ${widget.history.length}')
      ..writeln()
      ..writeln('最近事件:');
    for (final record in records.take(100)) {
      buffer.writeln(
        '${record.timestamp.toLocal().toIso8601String()} '
        '[${record.level}] [${record.category}] ${record.event} '
        '${_redact(record.fields.toString())}',
      );
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('诊断摘要已复制')),
      );
    }
  }

  String _redact(String value) {
    return value
        .replaceAll(RegExp(r'[A-Za-z]:\\[^,}\]]+'), '[path]')
        .replaceAll(RegExp(r'content://[^,}\]]+'), '[content-uri]')
        .replaceAll(RegExp(r'/(?:[^\s,}\]]+/){2,}[^\s,}\]]+'), '[path]');
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: AppTokens.pagePadding,
      children: [
        SectionHeader(
          title: '日志',
          subtitle: '用于排查索引、数据库、媒体播放和界面异常。',
          action: Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => setState(_reload),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('刷新'),
              ),
              FilledButton.icon(
                onPressed: () async {
                  final records = await (_records ??= widget.log.readRecent());
                  if (mounted) await _copyDiagnostics(records);
                },
                icon: const Icon(Icons.copy_all_rounded),
                label: const Text('复制诊断'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _StatusCard(
          database: widget.database,
          progress: widget.progress,
          recoverableCount: widget.recoverableJobs.length,
        ),
        const SizedBox(height: 12),
        if (widget.recoverableJobs.isNotEmpty || widget.history.isNotEmpty)
          _TaskSummaryCard(
            recoverableJobs: widget.recoverableJobs,
            history: widget.history,
          ),
        const SizedBox(height: 12),
        FutureBuilder<List<AppDiagnosticRecord>>(
          future: _records,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const _Panel(child: LinearProgressIndicator());
            }
            final records = snapshot.data ?? const <AppDiagnosticRecord>[];
            return _EventPanel(
              records: records,
              level: _level,
              showDetails: _showDetails,
              onLevelChanged: (value) => setState(() => _level = value),
              onShowDetailsChanged: (value) =>
                  setState(() => _showDetails = value),
            );
          },
        ),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.database,
    required this.progress,
    required this.recoverableCount,
  });

  final DatabaseDescriptor database;
  final LibraryBuildProgress? progress;
  final int recoverableCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cache = PaintingBinding.instance.imageCache;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('当前状态', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          Wrap(
            spacing: 24,
            runSpacing: 10,
            children: [
              _StatusItem('平台', Platform.operatingSystem),
              const _StatusItem('Schema', '${DatabaseDescriptor.schemaVersion}'),
              _StatusItem('可恢复任务', '$recoverableCount'),
              _StatusItem('内存图片缓存', '${cache.currentSize}/${cache.maximumSize}'),
              _StatusItem('缓存容量', _formatBytes(cache.currentSizeBytes)),
            ],
          ),
          if (database.databasePath.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              database.databasePath,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (progress != null) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Text('当前阶段：${progress!.message}'),
                const Spacer(),
                Text('${progress!.completed}/${progress!.total}'),
              ],
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: progress!.value),
          ],
        ],
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _TaskSummaryCard extends StatelessWidget {
  const _TaskSummaryCard({required this.recoverableJobs, required this.history});

  final List<LibraryBuildJob> recoverableJobs;
  final List<LibraryBuildJob> history;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('最近任务摘要', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
            for (final job in [...recoverableJobs, ...history].take(6))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                job.status == LibraryBuildStatus.failed
                    ? Icons.error_outline_rounded
                    : Icons.sync_rounded,
                color: job.status == LibraryBuildStatus.failed
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
              title: Text(
                job.sourcePath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${job.stage.name} · ${job.status.name} · '
                '实体预览 ${job.entityPreviewDone}/${job.entityPreviewTotal} · '
                '节点预览 ${job.nodePreviewDone}/${job.nodePreviewTotal}',
              ),
            ),
        ],
      ),
    );
  }
}

class _EventPanel extends StatelessWidget {
  const _EventPanel({
    required this.records,
    required this.level,
    required this.showDetails,
    required this.onLevelChanged,
    required this.onShowDetailsChanged,
  });

  final List<AppDiagnosticRecord> records;
  final String level;
  final bool showDetails;
  final ValueChanged<String> onLevelChanged;
  final ValueChanged<bool> onShowDetailsChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = level == '全部'
        ? records
        : records.where((item) => item.level == level).toList(growable: false);
    final errors = records.where((item) => item.level == 'error').toList();
    final errorGroups = <String, List<AppDiagnosticRecord>>{};
    for (final error in errors) {
      errorGroups.putIfAbsent(error.errorSignature, () => []).add(error);
    }
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('事件流', style: theme.textTheme.titleMedium),
              const Spacer(),
              if (errors.isNotEmpty)
                Chip(
                  avatar: Icon(Icons.error_outline,
                      size: 16, color: theme.colorScheme.error),
                  label: Text('${errors.length} 个错误'),
                ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('详情'),
                selected: showDetails,
                onSelected: onShowDetailsChanged,
              ),
            ],
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: '全部', label: Text('全部')),
              ButtonSegment(value: 'info', label: Text('信息')),
              ButtonSegment(value: 'warning', label: Text('警告')),
              ButtonSegment(value: 'error', label: Text('错误')),
            ],
            selected: {level},
            onSelectionChanged: (value) => onLevelChanged(value.first),
          ),
          const SizedBox(height: 10),
          if (filtered.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('暂无日志记录')),
            )
          else ...[
            if (errorGroups.isNotEmpty)
              _ErrorSummary(groups: errorGroups),
            for (final record in filtered.take(120))
              _EventTile(record: record, expanded: showDetails),
          ],
        ],
      ),
    );
  }
}

class _ErrorSummary extends StatelessWidget {
  const _ErrorSummary({required this.groups});

  final Map<String, List<AppDiagnosticRecord>> groups;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = groups.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: .28),
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('错误聚合', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          for (final entry in entries.take(8))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${entry.value.length}×',
                      style: TextStyle(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w700,
                      )),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entry.key,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.record, required this.expanded});

  final AppDiagnosticRecord record;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (record.level) {
      'error' => theme.colorScheme.error,
      'warning' => Colors.amber.shade700,
      _ => theme.colorScheme.onSurfaceVariant,
    };
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      initiallyExpanded: expanded && record.level != 'info',
      leading: Icon(
        record.level == 'error'
            ? Icons.error_outline_rounded
            : record.level == 'warning'
                ? Icons.warning_amber_rounded
                : Icons.info_outline_rounded,
        color: color,
        size: 20,
      ),
      title: Text('${record.category} · ${record.event}'),
      subtitle: Text(
        '${record.timestamp.toLocal().toString().split('.').first}  ${record.message}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      children: [
        if (record.fields.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SelectableText(
              record.fields.entries.map((entry) => '${entry.key}: ${entry.value}').join('\n'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
      ],
    );
  }
}

class _StatusItem extends StatelessWidget {
  const _StatusItem(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        Text(value, style: Theme.of(context).textTheme.titleSmall),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .55),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      ),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}
