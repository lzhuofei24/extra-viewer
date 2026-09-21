import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/sync/auto_sync_coordinator.dart';
import 'app_preferences.dart';
import 'app_sidebar.dart';

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
  Widget build(BuildContext context) => MediaQuery.withNoTextScaling(
        child: ListenableBuilder(
          listenable: coordinator,
          builder: (context, _) => FloatingGlassSurface(
            role: GlassSurfaceRole.panel,
            independentBackdrop: true,
            borderRadius: 20,
            padding: const EdgeInsets.all(12),
            child: SingleChildScrollView(
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
                  const Text('同步周期'),
                  const SizedBox(height: 6),
                  _AutoSyncIntervalSelector(
                    selected: preferences.value.autoSyncInterval,
                    onSelected: preferences.setAutoSyncInterval,
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
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 40),
                        visualDensity: VisualDensity.compact,
                        textStyle: Theme.of(context).textTheme.bodyMedium,
                      ),
                      onPressed: coordinator.confirmUpdates,
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('确认更新'),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
}

class _AutoSyncIntervalSelector extends StatelessWidget {
  const _AutoSyncIntervalSelector({
    required this.selected,
    required this.onSelected,
  });

  final AutoSyncInterval selected;
  final ValueChanged<AutoSyncInterval> onSelected;

  @override
  Widget build(BuildContext context) {
    final appearance = GlassAppearance.of(context);
    const values = AutoSyncInterval.values;
    return SizedBox(
      width: double.infinity,
      child: GlassSegmentedControl(
        height: 40,
        useOwnLayer: true,
        quality: ImageFilter.isShaderFilterSupported
            ? GlassQuality.premium
            : GlassQuality.minimal,
        settings: appearance.indicatorSettings,
        indicatorSettings: appearance.indicatorSettings,
        backgroundColor: Colors.transparent,
        indicatorColor: appearance.selectedBackground,
        selectedTextStyle: TextStyle(
          color: appearance.foreground,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
        unselectedTextStyle: TextStyle(
          color: appearance.foreground,
          fontWeight: FontWeight.w400,
          fontSize: 14,
        ),
        selectedIconColor: appearance.foreground,
        unselectedIconColor: appearance.foreground,
        segments: const [
          GlassSegment(label: '5 秒'),
          GlassSegment(label: '30 分钟'),
          GlassSegment(label: '每天'),
        ],
        selectedIndex: values.indexOf(selected),
        onSegmentSelected: (index) => onSelected(values[index]),
      ),
    );
  }
}
