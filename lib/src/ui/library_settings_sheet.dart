import 'package:flutter/material.dart';
import 'package:smooth_sheets/smooth_sheets.dart';

import '../core/domain/models.dart';
import '../core/scanner/library_scanner.dart';
import 'design_tokens.dart';

class LibrarySettingsSheet extends StatelessWidget {
  const LibrarySettingsSheet({
    super.key,
    this.wrapInSheet = true,
    required this.themeChoice,
    required this.indexPathController,
    required this.sortMode,
    required this.scanning,
    required this.scanProgress,
    required this.onThemeChanged,
    required this.onSortChanged,
    required this.onScan,
  });

  final bool wrapInSheet;
  final ViewerThemeChoice themeChoice;
  final TextEditingController indexPathController;
  final EntitySortMode sortMode;
  final bool scanning;
  final ScanProgress? scanProgress;
  final ValueChanged<ViewerThemeChoice> onThemeChanged;
  final ValueChanged<EntitySortMode> onSortChanged;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
      child: ListView(
        shrinkWrap: true,
        children: [
          Text('设置与索引', style: theme.textTheme.titleLarge),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 920;
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
                              label: Text('亮色'),
                            ),
                            ButtonSegment(
                              value: ViewerThemeChoice.galleryDark,
                              label: Text('暗色'),
                            ),
                          ],
                          selected: {themeChoice},
                          onSelectionChanged: (value) {
                            onThemeChanged(value.first);
                          },
                        ),
                        const SizedBox(height: 22),
                        Text('默认排序', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 12),
                        SegmentedButton<EntitySortMode>(
                          segments: const [
                            ButtonSegment(
                              value: EntitySortMode.modifiedDesc,
                              label: Text('最近修改'),
                            ),
                            ButtonSegment(
                              value: EntitySortMode.nameAsc,
                              label: Text('名称 A-Z'),
                            ),
                            ButtonSegment(
                              value: EntitySortMode.sizeDesc,
                              label: Text('体积最大'),
                            ),
                          ],
                          selected: {sortMode},
                          onSelectionChanged: (value) {
                            onSortChanged(value.first);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: _SettingsCard(
                    title: '索引建立',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '输入本地路径后按目录结构建立索引，不复制源文件。',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 18),
                        TextField(
                          controller: indexPathController,
                          decoration: const InputDecoration(
                            labelText: '建立索引路径',
                            hintText: r'D:\Media\Library',
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => onScan(),
                        ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton.icon(
                            onPressed: scanning ? null : onScan,
                            icon: const Icon(Icons.sync_rounded),
                            label: Text(scanning ? '扫描中' : '建立索引'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ];
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    cards[0],
                    const SizedBox(width: 20),
                    cards[1],
                  ],
                );
              }
              return Column(
                children: [
                  cards[0],
                  const SizedBox(height: 18),
                  cards[1],
                ],
              );
            },
          ),
          if (scanProgress != null) ...[
            const SizedBox(height: 18),
            _SettingsCard(
              title: '扫描状态',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    scanProgress!.message,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: scanProgress!.total <= 0
                        ? null
                        : scanProgress!.processed / scanProgress!.total,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '发现 ${scanProgress!.discovered} · 处理 ${scanProgress!.processed}/${scanProgress!.total}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
    if (!wrapInSheet) return content;
    return SheetContentScaffold(body: content);
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      color: theme.colorScheme.surface.withValues(alpha: 0.96),
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
