import 'package:flutter/material.dart';

import 'design_tokens.dart';
import 'gallery_layout_settings.dart';
import 'library_widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.themeChoice,
    required this.layoutSettings,
    required this.onThemeChanged,
    required this.onLayoutChanged,
    required this.onResetLayout,
    this.onOpenDiagnostics,
  });

  final ViewerThemeChoice themeChoice;
  final GalleryLayoutSettings layoutSettings;
  final ValueChanged<ViewerThemeChoice> onThemeChanged;
  final ValueChanged<GalleryLayoutSettings> onLayoutChanged;
  final VoidCallback onResetLayout;
  final VoidCallback? onOpenDiagnostics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: AppTokens.pagePadding,
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
                  label: Text('跟随系统')),
              ButtonSegment(
                  value: ViewerThemeChoice.galleryLight,
                  icon: Icon(Icons.light_mode_outlined),
                  label: Text('亮色')),
              ButtonSegment(
                  value: ViewerThemeChoice.galleryDark,
                  icon: Icon(Icons.dark_mode_outlined),
                  label: Text('暗色')),
            ],
            selected: {themeChoice},
            onSelectionChanged: (value) => onThemeChanged(value.first),
          ),
        ),
        const SizedBox(height: 18),
        _SettingsCard(
          title: '浏览布局',
          trailing: TextButton.icon(
            onPressed: onResetLayout,
            icon: const Icon(Icons.restart_alt_rounded),
            label: const Text('恢复默认布局'),
          ),
          child: Column(
            children: [
              _slider(
                  '页面边距',
                  layoutSettings.pageMargin,
                  0,
                  24,
                  GalleryLayoutSettings.defaultPageMargin,
                  (v) => layoutSettings.copyWith(pageMargin: v)),
              _slider(
                  '卡片间距',
                  layoutSettings.cardGap,
                  0,
                  24,
                  GalleryLayoutSettings.defaultCardGap,
                  (v) => layoutSettings.copyWith(cardGap: v)),
              _slider(
                  '卡片圆角',
                  layoutSettings.cardRadius,
                  0,
                  32,
                  GalleryLayoutSettings.defaultCardRadius,
                  (v) => layoutSettings.copyWith(cardRadius: v)),
              _slider(
                  '等宽卡片宽度',
                  layoutSettings.equalWidthTarget,
                  160,
                  480,
                  GalleryLayoutSettings.defaultEqualWidthTarget,
                  (v) => layoutSettings.copyWith(equalWidthTarget: v),
                  32),
              _slider(
                  '等高卡片高度',
                  layoutSettings.equalHeightTarget,
                  160,
                  600,
                  GalleryLayoutSettings.defaultEqualHeightTarget,
                  (v) => layoutSettings.copyWith(equalHeightTarget: v),
                  44),
              _slider(
                  '方格边长',
                  layoutSettings.squareSize,
                  160,
                  480,
                  GalleryLayoutSettings.defaultSquareSize,
                  (v) => layoutSettings.copyWith(squareSize: v),
                  32),
              _slider(
                  '文件夹封面高度',
                  layoutSettings.folderHeight,
                  140,
                  480,
                  GalleryLayoutSettings.defaultFolderHeight,
                  (v) => layoutSettings.copyWith(folderHeight: v),
                  34),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('沉浸式浏览始终使用 1dp 间距和 2dp 圆角。',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
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

  Widget _slider(String label, double value, double min, double max,
          double defaultValue, GalleryLayoutSettings Function(double) update,
          [int divisions = 24]) =>
      _LayoutSlider(
          label: label,
          value: value,
          min: min,
          max: max,
          defaultValue: defaultValue,
          divisions: divisions,
          onChanged: (value) => onLayoutChanged(update(value)));
}

class _LayoutSlider extends StatelessWidget {
  const _LayoutSlider(
      {required this.label,
      required this.value,
      required this.min,
      required this.max,
      required this.defaultValue,
      required this.divisions,
      required this.onChanged});

  final String label;
  final double value;
  final double min;
  final double max;
  final double defaultValue;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          SizedBox(width: 116, child: Text(label)),
          Expanded(
              child: Slider(
                  value: value.clamp(min, max),
                  min: min,
                  max: max,
                  divisions: divisions,
                  label: '${value.round()} dp',
                  onChanged: onChanged)),
          SizedBox(
              width: 58,
              child: Text('${value.round()} dp',
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.labelMedium)),
          IconButton(
              tooltip: '恢复默认值',
              onPressed:
                  value == defaultValue ? null : () => onChanged(defaultValue),
              icon: const Icon(Icons.restart_alt_rounded, size: 19)),
        ]),
      );
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard(
      {required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
        child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
          if (trailing != null) trailing!
        ]),
        const SizedBox(height: 16),
        Divider(color: theme.colorScheme.outlineVariant),
        const SizedBox(height: 16),
        child,
      ]),
    ));
  }
}
