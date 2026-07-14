import 'package:flutter/material.dart';

import '../core/domain/models.dart';
import 'design_tokens.dart';
import 'library_widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.themeChoice,
    required this.sortMode,
    required this.onThemeChanged,
    required this.onSortChanged,
    required this.onResetLocalIndex,
  });

  final ViewerThemeChoice themeChoice;
  final EntitySortMode sortMode;
  final ValueChanged<ViewerThemeChoice> onThemeChanged;
  final ValueChanged<EntitySortMode> onSortChanged;
  final VoidCallback onResetLocalIndex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: AppTokens.pagePadding,
      children: [
        const SectionHeader(
          title: '设置',
          subtitle: '调整应用外观与默认浏览方式。',
        ),
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (context, constraints) {
            final cards = [
              Expanded(
                child: _SettingsCard(
                  title: '外观',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('主题', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 12),
                      SegmentedButton<ViewerThemeChoice>(
                        segments: const [
                          ButtonSegment(
                              value: ViewerThemeChoice.galleryLight,
                              label: Text('亮色')),
                          ButtonSegment(
                              value: ViewerThemeChoice.galleryDark,
                              label: Text('暗色')),
                        ],
                        selected: {themeChoice},
                        onSelectionChanged: (value) =>
                            onThemeChanged(value.first),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: _SettingsCard(
                  title: '浏览',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('默认排序', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 12),
                      SegmentedButton<EntitySortMode>(
                        segments: const [
                          ButtonSegment(
                              value: EntitySortMode.modifiedDesc,
                              label: Text('最近修改')),
                          ButtonSegment(
                              value: EntitySortMode.nameAsc,
                              label: Text('名称 A-Z')),
                          ButtonSegment(
                              value: EntitySortMode.sizeDesc,
                              label: Text('体积最大')),
                        ],
                        selected: {sortMode},
                        onSelectionChanged: (value) =>
                            onSortChanged(value.first),
                      ),
                    ],
                  ),
                ),
              ),
            ];
            if (constraints.maxWidth >= 860) {
              return Row(
                  children: [cards[0], const SizedBox(width: 20), cards[1]]);
            }
            return Column(
                children: [cards[0], const SizedBox(height: 18), cards[1]]);
          },
        ),
        const SizedBox(height: 18),
        _SettingsCard(
          title: '阅读与播放',
          child: Text(
            '阅读字体、默认播放速度和循环策略将作为独立的应用偏好保存。',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 18),
        _SettingsCard(
          title: '本地索引数据',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '重置会删除本应用的索引、构建任务、缩略图和播放缓存。真实资料文件不会被删除或修改。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: onResetLocalIndex,
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('重置本地索引数据'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 100),
      ],
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.title, required this.child});

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
