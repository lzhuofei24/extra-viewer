import 'package:flutter/material.dart';

import '../core/domain/models.dart';
import 'design_tokens.dart';
import 'library_widgets.dart';

class EntityDetailSheet extends StatelessWidget {
  const EntityDetailSheet({
    super.key,
    required this.detail,
    this.displayPath,
  });

  final Entity detail;
  final String? displayPath;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
        child: ListView(
          shrinkWrap: true,
          children: [
            SizedBox(
              height: 220,
              child: EntityArtwork(
                entityType: detail.entityType,
                format: detail.format,
                title: detail.name,
                contentExcerpt: detail.contentExcerpt,
                thumbnailPath: detail.thumbnailPath,
                borderRadius: BorderRadius.circular(AppTokens.radiusMd),
              ),
            ),
            const SizedBox(height: 16),
            Text(detail.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            MetaLine(label: '类型', value: entityTypeLabel(detail.entityType)),
            MetaLine(label: '路径', value: displayPath ?? detail.path),
            MetaLine(label: '大小', value: formatSize(detail.size)),
            MetaLine(label: '格式', value: detail.format),
            MetaLine(label: '源创建', value: formatTime(detail.sourceCreatedAtMs)),
            MetaLine(
                label: '源修改', value: formatTime(detail.sourceModifiedAtMs)),
            MetaLine(label: '最近打开', value: formatTime(detail.lastOpenedAtMs)),
            if (detail.entityType == EntityType.audio ||
                detail.entityType == EntityType.video)
              MetaLine(
                label: '播放位置',
                value: formatDurationMs(detail.lastPositionMs),
              ),
            if (detail.entityType == EntityType.audio ||
                detail.entityType == EntityType.video)
              MetaLine(
                  label: '媒体时长', value: formatDurationMs(detail.durationMs)),
            if (detail.entityType == EntityType.text)
              MetaLine(
                label: '阅读位置',
                value: formatScrollOffset(detail.readerScrollOffset),
              ),
          ],
        ),
      ),
    );
  }
}
