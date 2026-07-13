import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../core/domain/models.dart';
import 'design_tokens.dart';
import 'library_widgets.dart';

class LibraryDashboardPage extends StatelessWidget {
  const LibraryDashboardPage({
    super.key,
    required this.roots,
    required this.rootCounts,
    required this.onOpenRoot,
    required this.onOpenSettings,
  });

  final List<IndexNode> roots;
  final Map<String, int> rootCounts;
  final ValueChanged<IndexNode> onOpenRoot;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: AppTokens.pagePadding,
          sliver: SliverList.list(
            children: [
              _HeroPanel(
                rootsCount: roots.length,
                itemsCount: rootCounts.values.fold<int>(0, (a, b) => a + b),
                onOpenSettings: onOpenSettings,
              ).animate().fadeIn(duration: 350.ms).slideY(begin: 0.08),
              const SizedBox(height: 26),
              const SectionHeader(
                title: '索引画廊',
                subtitle: '把目录、分类和图索引变成可浏览的内容入口。',
              ),
              const SizedBox(height: 14),
            ],
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: roots.isEmpty
              ? const SliverToBoxAdapter(
                  child: EmptyStateCard(
                    title: '资料库还没有索引',
                    message: '先在设置里输入路径并建立索引，首页会自动生成索引画廊。',
                  ),
                )
              : SliverGrid(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 280,
                    mainAxisExtent: 220,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final root = roots[index];
                      return NodeCard(
                        node: root,
                        subtitle: '${rootCounts[root.id] ?? 0} 个内容项',
                        onTap: () => onOpenRoot(root),
                      );
                    },
                    childCount: roots.length,
                  ),
                ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 120)),
      ],
    );
  }
}

class _HeroPanel extends StatelessWidget {
  const _HeroPanel({
    required this.rootsCount,
    required this.itemsCount,
    required this.onOpenSettings,
  });

  final int rootsCount;
  final int itemsCount;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTokens.radiusLg),
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.surface,
            theme.colorScheme.secondaryContainer.withValues(alpha: 0.55),
            theme.colorScheme.primaryContainer.withValues(alpha: 0.72),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Best Viewer', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 10),
          Text(
            '一个更像陈列台而不是文件夹的本地资料库。索引、筛选、继续阅读与媒体预览都围绕内容本身展开。',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 22),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _MetricChip(label: '索引', value: '$rootsCount'),
              _MetricChip(label: '内容项', value: '$itemsCount'),
              FilledButton.icon(
                onPressed: onOpenSettings,
                icon: const Icon(Icons.tune_rounded),
                label: const Text('索引与设置'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Text('$label  $value', style: theme.textTheme.labelLarge),
      ),
    );
  }
}
