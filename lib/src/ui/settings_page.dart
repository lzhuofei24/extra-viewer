import 'package:flutter/material.dart';

import 'design_tokens.dart';
import 'app_sidebar.dart';
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              final appearance = _SettingsGroup(
                title: '外观',
                children: [
                  _stepper(
                    '页面边距',
                    layoutSettings.pageMargin.round(),
                    0,
                    24,
                    2,
                    'dp',
                    (value) => layoutSettings.copyWith(
                      pageMargin: value.toDouble(),
                    ),
                  ),
                  _stepper(
                    '卡片间距',
                    layoutSettings.cardGap.round(),
                    0,
                    24,
                    2,
                    'dp',
                    (value) => layoutSettings.copyWith(
                      cardGap: value.toDouble(),
                    ),
                  ),
                  _stepper(
                    '卡片圆角',
                    layoutSettings.cardRadius.round(),
                    0,
                    32,
                    2,
                    'dp',
                    (value) => layoutSettings.copyWith(
                      cardRadius: value.toDouble(),
                    ),
                  ),
                ],
              );
              final cards = _SettingsGroup(
                title: '卡片',
                children: [
                  _stepper(
                    '等宽 · 竖屏',
                    layoutSettings.portraitEqualWidthColumns,
                    1,
                    8,
                    1,
                    '列',
                    (value) => layoutSettings.copyWith(
                      portraitEqualWidthColumns: value,
                    ),
                  ),
                  _stepper(
                    '等宽 · 横屏',
                    layoutSettings.landscapeEqualWidthColumns,
                    1,
                    8,
                    1,
                    '列',
                    (value) => layoutSettings.copyWith(
                      landscapeEqualWidthColumns: value,
                    ),
                  ),
                  _stepper(
                    '方格 · 竖屏',
                    layoutSettings.portraitSquareColumns,
                    1,
                    8,
                    1,
                    '列',
                    (value) => layoutSettings.copyWith(
                      portraitSquareColumns: value,
                    ),
                  ),
                  _stepper(
                    '方格 · 横屏',
                    layoutSettings.landscapeSquareColumns,
                    1,
                    8,
                    1,
                    '列',
                    (value) => layoutSettings.copyWith(
                      landscapeSquareColumns: value,
                    ),
                  ),
                  _stepper(
                    '等高卡片高度',
                    layoutSettings.equalHeightTarget.round(),
                    160,
                    600,
                    20,
                    'dp',
                    (value) => layoutSettings.copyWith(
                      equalHeightTarget: value.toDouble(),
                    ),
                  ),
                  _stepper(
                    '文件夹封面高度',
                    layoutSettings.folderHeight.round(),
                    140,
                    480,
                    20,
                    'dp',
                    (value) => layoutSettings.copyWith(
                      folderHeight: value.toDouble(),
                    ),
                  ),
                ],
              );
              final landscape =
                  MediaQuery.orientationOf(context) == Orientation.landscape;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (landscape)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: appearance),
                        const SizedBox(width: 28),
                        Expanded(child: cards),
                      ],
                    )
                  else ...[
                    appearance,
                    const SizedBox(height: 20),
                    cards,
                  ],
                  const SizedBox(height: 12),
                  Text(
                    '自适应布局使用当前方向的等宽列数。沉浸式浏览始终使用 1dp 间距和 2dp 圆角。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              );
            },
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

  Widget _stepper(
    String label,
    int value,
    int min,
    int max,
    int step,
    String unit,
    GalleryLayoutSettings Function(int) update,
  ) =>
      _LayoutStepper(
        label: label,
        value: value,
        min: min,
        max: max,
        step: step,
        unit: unit,
        onChanged: (value) => onLayoutChanged(update(value)),
      );
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Divider(),
          const SizedBox(height: 4),
          ...children,
        ],
      );
}

class _LayoutStepper extends StatelessWidget {
  const _LayoutStepper({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.unit,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final int step;
  final String unit;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final controls = _StepperControls(
      value: value,
      unit: unit,
      onDecrease:
          value <= min ? null : () => onChanged((value - step).clamp(min, max)),
      onIncrease:
          value >= max ? null : () => onChanged((value + step).clamp(min, max)),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 310) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                const SizedBox(height: 6),
                Align(alignment: Alignment.centerRight, child: controls),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: Text(label)),
              const SizedBox(width: 12),
              controls,
            ],
          );
        },
      ),
    );
  }
}

class _StepperControls extends StatelessWidget {
  const _StepperControls({
    required this.value,
    required this.unit,
    required this.onDecrease,
    required this.onIncrease,
  });

  final int value;
  final String unit;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '减少',
              onPressed: onDecrease,
              constraints: const BoxConstraints.tightFor(width: 44, height: 44),
              icon: const Icon(Icons.remove_rounded),
            ),
            SizedBox(
              width: 66,
              child: Text(
                '$value $unit',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            IconButton(
              tooltip: '增加',
              onPressed: onIncrease,
              constraints: const BoxConstraints.tightFor(width: 44, height: 44),
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ),
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
