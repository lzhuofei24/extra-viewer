import 'package:flutter/material.dart';

import '../core/sync/auto_sync_coordinator.dart';
import 'app_preferences.dart';
import 'app_sidebar.dart';

Future<void> showAutoSyncPanel(
  BuildContext context, {
  required AutoSyncCoordinator coordinator,
  required AppPreferencesController preferences,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => AutoSyncPanel(
      coordinator: coordinator,
      preferences: preferences,
    ),
  );
}

class AutoSyncPanel extends StatelessWidget {
  const AutoSyncPanel({
    super.key,
    required this.coordinator,
    required this.preferences,
  });

  final AutoSyncCoordinator coordinator;
  final AppPreferencesController preferences;

  String _status(AutoSyncStatus status) => switch (status) {
        AutoSyncStatus.disabled => '未开启',
        AutoSyncStatus.scanning => '正在第一阶段扫描',
        AutoSyncStatus.awaitingConfirmation => '等待确认',
        AutoSyncStatus.queued => '已排队等待第二阶段',
        AutoSyncStatus.running => '正在执行第二阶段',
      };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: coordinator,
        builder: (context, _) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FloatingGlassSurface(
              role: GlassSurfaceRole.panel,
              borderRadius: 20,
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    const Icon(Icons.sync_rounded),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('目录自动同步')),
                    Switch(
                      value: preferences.value.autoSyncEnabled,
                      onChanged: preferences.setAutoSyncEnabled,
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Text('同步周期', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 6),
                  SegmentedButton<AutoSyncInterval>(
                    segments: const [
                      ButtonSegment(
                          value: AutoSyncInterval.fiveSeconds,
                          label: Text('5 秒')),
                      ButtonSegment(
                          value: AutoSyncInterval.thirtyMinutes,
                          label: Text('30 分钟')),
                      ButtonSegment(
                          value: AutoSyncInterval.daily, label: Text('每天')),
                    ],
                    selected: {preferences.value.autoSyncInterval},
                    onSelectionChanged: (value) =>
                        preferences.setAutoSyncInterval(value.first),
                  ),
                  const SizedBox(height: 12),
                  Text('当前状态：${_status(coordinator.status)}'),
                  if (coordinator.lastScan != null) ...[
                    const SizedBox(height: 8),
                    Text(
                        '上次扫描：${coordinator.lastScan!.scanCompletedAt.toLocal()}'),
                    Text(
                        '更新 ${coordinator.lastScan!.updatedCount}  ·  缺失 ${coordinator.lastScan!.missingCount}  ·  新增 ${coordinator.lastScan!.addedCount}'),
                    Text('暂时不可访问目录 ${coordinator.lastScan!.unavailableCount}'),
                  ] else if (coordinator.hasSyncRoots == false)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('没有可同步目录'),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('尚未完成第一阶段扫描'),
                    ),
                  if (coordinator.awaitingConfirmation)
                    FilledButton.icon(
                      onPressed: coordinator.confirmUpdates,
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('确认更新'),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
}
