import 'package:flutter/material.dart';

import 'app_sidebar.dart';
import 'design_tokens.dart';
import 'gallery_layout_settings.dart';
import 'library_widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.themeChoice,
    required this.layoutPreset,
    required this.onThemeChanged,
    required this.onLayoutPresetChanged,
    this.onOpenDiagnostics,
    this.glassTransparency = 40,
    this.onGlassTransparencyChanged,
  });

  final ViewerThemeChoice themeChoice;
  final GalleryLayoutPreset layoutPreset;
  final ValueChanged<ViewerThemeChoice> onThemeChanged;
  final ValueChanged<GalleryLayoutPreset> onLayoutPresetChanged;
  final VoidCallback? onOpenDiagnostics;
  final int glassTransparency;
  final ValueChanged<int>? onGlassTransparencyChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: AppTokens.pagePadding.add(AppNavigationObstruction.of(context)),
      children: [
        const SectionHeader(
          title: '设置',
          subtitle: '调整应用主题与浏览布局。浏览时的排序和显示方式在右上角设置。',
        ),
        const SizedBox(height: 18),
        _SettingsCard(
          title: '主题',
          child: SegmentedButton<ViewerThemeChoice>(
            segments: const [
              ButtonSegment(
                value: ViewerThemeChoice.system,
                icon: Icon(Icons.brightness_auto_outlined),
                label: Text('跟随系统'),
              ),
              ButtonSegment(
                value: ViewerThemeChoice.galleryLight,
                icon: Icon(Icons.light_mode_outlined),
                label: Text('亮色'),
              ),
              ButtonSegment(
                value: ViewerThemeChoice.galleryDark,
                icon: Icon(Icons.dark_mode_outlined),
                label: Text('暗色'),
              ),
            ],
            selected: {themeChoice},
            onSelectionChanged: (value) => onThemeChanged(value.first),
          ),
        ),
        const SizedBox(height: 18),
        _SettingsCard(
          title: '浏览布局',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<GalleryLayoutPreset>(
                segments: [
                  for (final preset in GalleryLayoutPreset.values)
                    ButtonSegment(
                      value: preset,
                      label: Text(preset.label),
                    ),
                ],
                selected: {layoutPreset},
                onSelectionChanged: (value) =>
                    onLayoutPresetChanged(value.first),
              ),
              const SizedBox(height: 12),
              Text(
                '同时调整页面留白、卡片密度、圆角和文件夹封面大小。沉浸式浏览保持紧凑显示。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        ListTile(
          title: const Text('悬浮透明度'),
          subtitle: const Text('数值越高，背景越通透'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
                tooltip: '降低透明度',
                onPressed: glassTransparency <= 0
                    ? null
                    : () => onGlassTransparencyChanged
                        ?.call((glassTransparency - 5).clamp(0, 90)),
                icon: const Icon(Icons.remove)),
            Text('$glassTransparency%'),
            IconButton(
                tooltip: '提高透明度',
                onPressed: glassTransparency >= 90
                    ? null
                    : () => onGlassTransparencyChanged
                        ?.call((glassTransparency + 5).clamp(0, 90)),
                icon: const Icon(Icons.add)),
          ]),
        ),
        ListTile(
          title: const Text('诊断与日志'),
          subtitle: const Text('错误、接口调用与任务历史'),
          trailing: const Icon(Icons.chevron_right),
          onTap: onOpenDiagnostics,
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
