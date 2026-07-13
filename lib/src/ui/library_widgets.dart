import 'dart:typed_data';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/domain/models.dart';
import '../core/formats/file_format_handlers.dart';
import 'design_tokens.dart';

class EntityArtwork extends StatelessWidget {
  const EntityArtwork({
    super.key,
    required this.entityType,
    required this.format,
    this.title,
    this.metadataPreview,
    this.thumbnailStatus = ThumbnailStatus.none,
    this.thumbnailPath,
    this.thumbnailPng,
    this.height,
    this.borderRadius,
  });

  final EntityType entityType;
  final String format;
  final String? title;
  final String? metadataPreview;
  final ThumbnailStatus thumbnailStatus;
  final String? thumbnailPath;
  final Uint8List? thumbnailPng;
  final double? height;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final clip = borderRadius ?? BorderRadius.circular(AppTokens.radiusSm);
    final child = _buildVisual(context);
    return ClipRRect(
      borderRadius: clip,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: child,
      ),
    );
  }

  Widget _buildVisual(BuildContext context) {
    if (thumbnailPng != null && thumbnailPng!.isNotEmpty) {
      return Image.memory(
        thumbnailPng!,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _FallbackArtwork(
          entityType: entityType,
          format: format,
          thumbnailStatus: thumbnailStatus,
        ),
      );
    }
    final path = thumbnailPath;
    if (path != null && path.isNotEmpty) {
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _FallbackArtwork(
          entityType: entityType,
          format: format,
          thumbnailStatus: thumbnailStatus,
        ),
      );
    }
    if (!_isGeneratedMedia(entityType)) {
      return _RuntimePreviewArtwork(
        entityType: entityType,
        format: format,
        title: title,
        metadataPreview: metadataPreview,
      );
    }
    return _FallbackArtwork(
      entityType: entityType,
      format: format,
      thumbnailStatus: thumbnailStatus,
    );
  }
}

class RootArtwork extends StatelessWidget {
  const RootArtwork({super.key, required this.node});

  final IndexNode node;

  @override
  Widget build(BuildContext context) {
    if (node.thumbnailPng != null && node.thumbnailPng!.isNotEmpty) {
      return EntityArtwork(
        entityType: EntityType.image,
        format: _nodeTypeShortLabel(node.nodeType),
        thumbnailPng: node.thumbnailPng,
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        gradient: LinearGradient(
          colors: [
            _indexNodeColor(node.nodeType).withValues(alpha: 0.9),
            _indexNodeColor(node.nodeType).withValues(alpha: 0.55),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          _indexNodeIcon(node.nodeType),
          size: 36,
          color: Colors.white,
        ),
      ),
    );
  }
}

class EntityCard extends StatelessWidget {
  const EntityCard({
    super.key,
    required this.entity,
    required this.onOpen,
    this.selected = false,
    this.selectionMode = false,
    this.immersive = false,
    this.onToggleSelection,
    this.onStartSelection,
    this.onShowMenu,
  });

  final EntityListItem entity;
  final VoidCallback onOpen;
  final bool selected;
  final bool selectionMode;
  final bool immersive;
  final VoidCallback? onToggleSelection;
  final VoidCallback? onStartSelection;
  final VoidCallback? onShowMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final duration = (entity.entityType == EntityType.video ||
            entity.entityType == EntityType.audio)
        ? formatDurationMs(entity.durationMs)
        : '-';
    final aspectRatio = entity.thumbnailWidth != null &&
            entity.thumbnailHeight != null &&
            entity.thumbnailWidth! > 0 &&
            entity.thumbnailHeight! > 0
        ? entity.thumbnailWidth! / entity.thumbnailHeight!
        : entity.entityType == EntityType.audio
            ? 16 / 9
            : 4 / 3;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(immersive ? 1 : 8),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.65),
          width: 1,
        ),
      ),
      child: InkWell(
        onTap: selectionMode ? onToggleSelection : onOpen,
        onLongPress: onStartSelection ?? onShowMenu ?? onToggleSelection,
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              EntityArtwork(
                entityType: entity.entityType,
                format: entity.format,
                title: entity.title,
                metadataPreview: entity.metadataPreview,
                thumbnailStatus: entity.thumbnailStatus,
                thumbnailPath: entity.thumbnailPath,
                borderRadius: BorderRadius.zero,
              ),
              if (duration != '-')
                Positioned(
                  top: 8,
                  right: 9,
                  child: Text(
                    duration,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.78),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      shadows: const [
                        Shadow(blurRadius: 3, color: Colors.black54),
                      ],
                    ),
                  ),
                ),
              if (selected)
                Positioned(
                  top: 8,
                  left: 8,
                  child: Icon(Icons.check_circle_rounded,
                      color: theme.colorScheme.primary),
                ),
              if (!immersive)
                Positioned(
                  right: 0,
                  bottom: 0,
                  left: 0,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.transparent, Color(0x99000000)],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 20, 10, 9),
                      child: Text(
                        entity.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                          shadows: const [
                            Shadow(blurRadius: 3, color: Colors.black54),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class NodeCard extends StatelessWidget {
  const NodeCard({
    super.key,
    required this.node,
    required this.subtitle,
    required this.onTap,
  });

  final IndexNode node;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: RootArtwork(node: node)),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    node.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AudioRuntimePreviewArtwork extends StatelessWidget {
  const _AudioRuntimePreviewArtwork();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = theme.colorScheme.onTertiaryContainer;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.78),
      ),
      child: Center(
        child: SizedBox(
          width: double.infinity,
          height: 62,
          child: CustomPaint(
            painter: _AudioWaveformPainter(
              color: foreground.withValues(alpha: 0.64),
            ),
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.7),
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(9),
                  child: Icon(Icons.play_arrow_rounded,
                      color: foreground, size: 23),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AudioWaveformPainter extends CustomPainter {
  const _AudioWaveformPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    const bars = 19;
    for (var index = 0; index < bars; index++) {
      final phase = index / (bars - 1) * math.pi * 3.2;
      final height = size.height * (0.18 + 0.68 * math.sin(phase).abs());
      final x = size.width * (index + 0.5) / bars;
      canvas.drawLine(
        Offset(x, (size.height - height) / 2),
        Offset(x, (size.height + height) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AudioWaveformPainter oldDelegate) =>
      oldDelegate.color != color;
}

class SearchHero extends StatelessWidget {
  const SearchHero({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.hintText,
    this.trailing,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hintText;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTokens.radiusLg),
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.surface,
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.78),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: hintText,
                filled: true,
                fillColor: theme.colorScheme.surface.withValues(alpha: 0.65),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                ),
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.action,
  });

  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (action != null) action!,
      ],
    );
  }
}

class EmptyStateCard extends StatelessWidget {
  const EmptyStateCard({
    super.key,
    required this.title,
    required this.message,
    this.action,
  });

  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 10),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: 18),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class MetaLine extends StatelessWidget {
  const MetaLine({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          SelectableText(value),
        ],
      ),
    );
  }
}

class _FallbackArtwork extends StatelessWidget {
  const _FallbackArtwork({
    required this.entityType,
    required this.format,
    this.thumbnailStatus = ThumbnailStatus.none,
  });

  final EntityType entityType;
  final String format;
  final ThumbnailStatus thumbnailStatus;

  @override
  Widget build(BuildContext context) {
    final colors = switch (entityType) {
      EntityType.image => [const Color(0xFFB8CDB6), const Color(0xFF5D7B63)],
      EntityType.text => [const Color(0xFFE2D7BE), const Color(0xFF9C7C43)],
      EntityType.audio => [const Color(0xFFB8C9D9), const Color(0xFF4D6A86)],
      EntityType.video => [const Color(0xFFD0C7BC), const Color(0xFF726658)],
      EntityType.externalLink => [
          const Color(0xFFC7D5CB),
          const Color(0xFF587163)
        ],
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_iconForType(entityType), size: 42, color: Colors.white),
            const SizedBox(height: 8),
            Text(
              thumbnailStatus == ThumbnailStatus.failed
                  ? '生成失败'
                  : thumbnailStatus == ThumbnailStatus.pending
                      ? '生成中'
                      : format.toUpperCase(),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RuntimePreviewArtwork extends StatelessWidget {
  const _RuntimePreviewArtwork({
    required this.entityType,
    required this.format,
    required this.title,
    required this.metadataPreview,
  });

  final EntityType entityType;
  final String format;
  final String? title;
  final String? metadataPreview;

  @override
  Widget build(BuildContext context) {
    if (entityType == EntityType.audio) {
      return const _AudioRuntimePreviewArtwork();
    }
    final theme = Theme.of(context);
    final preview = metadataPreview?.trim();
    final colors = switch (entityType) {
      EntityType.text => (const Color(0xFFF5F0E4), const Color(0xFF5D4B2E)),
      EntityType.audio => (const Color(0xFFE7EFF4), const Color(0xFF2B5C76)),
      EntityType.externalLink => (
          const Color(0xFFEBF0E9),
          const Color(0xFF38644D)
        ),
      _ => (
          theme.colorScheme.surfaceContainerHighest,
          theme.colorScheme.onSurface
        ),
    };
    return DecoratedBox(
      decoration: BoxDecoration(color: colors.$1),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final textStyle = theme.textTheme.bodySmall?.copyWith(
            color: colors.$2.withValues(alpha: 0.84),
            height: 1.55,
          );
          final fontSize = textStyle?.fontSize ?? 12;
          final lineHeight = fontSize * (textStyle?.height ?? 1.55);
          final maxLines = math.max(
            1,
            ((constraints.maxHeight - 28) / lineHeight).floor(),
          );
          return Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              preview?.isNotEmpty == true
                  ? preview!
                  : _runtimePreviewDescription(entityType, format),
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: textStyle,
            ),
          );
        },
      ),
    );
  }
}

bool _isGeneratedMedia(EntityType type) {
  return type == EntityType.image || type == EntityType.video;
}

String _runtimePreviewDescription(EntityType type, String format) {
  return switch (type) {
    EntityType.audio => '音频文件\n${format.toUpperCase()}',
    EntityType.externalLink => '文档或链接\n${format.toUpperCase()}',
    _ => format.toUpperCase(),
  };
}

String entityTypeLabel(EntityType type) {
  return switch (type) {
    EntityType.text => '文本',
    EntityType.image => '图片',
    EntityType.audio => '音频',
    EntityType.video => '视频',
    EntityType.externalLink => '链接',
  };
}

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(1)} GB';
}

String formatTime(int? timestamp) {
  if (timestamp == null) return '-';
  final milliseconds = timestamp < 1000000000000 ? timestamp * 1000 : timestamp;
  final time = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  return '${time.year.toString().padLeft(4, '0')}-'
      '${time.month.toString().padLeft(2, '0')}-'
      '${time.day.toString().padLeft(2, '0')} '
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
}

String formatDurationMs(int? milliseconds) {
  if (milliseconds == null || milliseconds <= 0) return '-';
  final duration = Duration(milliseconds: milliseconds);
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) return '$hours:$minutes:$seconds';
  return '$minutes:$seconds';
}

String formatScrollOffset(double? offset) {
  if (offset == null || offset <= 0) return '-';
  return '${offset.round()} px';
}

String formatZoomScale(double? scale) {
  if (scale == null || scale <= 0) return '-';
  return '${scale.toStringAsFixed(2)}x';
}

String openButtonLabel(ViewerKind viewerKind) {
  return switch (viewerKind) {
    ViewerKind.externalLauncher => '系统打开',
    ViewerKind.textReader ||
    ViewerKind.pdfReader ||
    ViewerKind.epubReader ||
    ViewerKind.docxReader ||
    ViewerKind.imageViewer ||
    ViewerKind.audioPlayer ||
    ViewerKind.videoPlayer =>
      '内置预览',
  };
}

String _nodeTypeShortLabel(NodeType type) {
  return switch (type) {
    NodeType.directoryIndexRoot || NodeType.folder => 'DIR',
    NodeType.categoryIndexRoot || NodeType.category => 'IDX',
    NodeType.graphIndexRoot || NodeType.graphNode => 'MAP',
    NodeType.root => 'ROOT',
  };
}

IconData _iconForType(EntityType type) {
  return switch (type) {
    EntityType.image => Icons.image_outlined,
    EntityType.audio => Icons.music_note_outlined,
    EntityType.video => Icons.movie_outlined,
    EntityType.text => Icons.description_outlined,
    EntityType.externalLink => Icons.link_outlined,
  };
}

IconData _indexNodeIcon(NodeType type) {
  return switch (type) {
    NodeType.root => Icons.account_tree_outlined,
    NodeType.directoryIndexRoot => Icons.folder_special_outlined,
    NodeType.categoryIndexRoot => Icons.category_outlined,
    NodeType.graphIndexRoot => Icons.hub_outlined,
    NodeType.folder => Icons.folder_outlined,
    NodeType.category => Icons.sell_outlined,
    NodeType.graphNode => Icons.circle_outlined,
  };
}

Color _indexNodeColor(NodeType type) {
  return switch (type) {
    NodeType.root => const Color(0xFF475569),
    NodeType.directoryIndexRoot => const Color(0xFF4F7D52),
    NodeType.categoryIndexRoot => const Color(0xFF8A6A3D),
    NodeType.graphIndexRoot => const Color(0xFF58708A),
    NodeType.folder => const Color(0xFF638459),
    NodeType.category => const Color(0xFFA27C49),
    NodeType.graphNode => const Color(0xFF657A9A),
  };
}
