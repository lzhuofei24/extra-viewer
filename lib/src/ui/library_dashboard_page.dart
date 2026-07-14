import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'design_tokens.dart';

class LibraryDashboardPage extends StatelessWidget {
  const LibraryDashboardPage({
    super.key,
    required this.rootsCount,
    required this.itemsCount,
    required this.onOpenSettings,
  });

  final int rootsCount;
  final int itemsCount;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: AppTokens.pagePadding,
      children: [
        _WelcomePanel(
          rootsCount: rootsCount,
          itemsCount: itemsCount,
          onOpenSettings: onOpenSettings,
        ).animate().fadeIn(duration: 350.ms).slideY(begin: 0.08),
        const SizedBox(height: 100),
      ],
    );
  }
}

class _WelcomePanel extends StatelessWidget {
  const _WelcomePanel({
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTokens.radiusLg),
      child: AspectRatio(
        aspectRatio: 16 / 8.2,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              'assets/images/best_viewer_welcome.png',
              fit: BoxFit.cover,
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.black.withValues(alpha: 0.62),
                    Colors.black.withValues(alpha: 0.18),
                    Colors.transparent,
                  ],
                  stops: const [0, 0.48, 1],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(28),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Best Viewer',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '把图片、影片、阅读和音乐，收进一座只属于你的资料室。',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: Colors.white.withValues(alpha: 0.9),
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
                ),
              ),
            ),
          ],
        ),
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
