import 'package:flutter/material.dart';

import '../core/domain/models.dart';
import '../core/media/app_audio_controller.dart';
import 'design_tokens.dart';
import 'app_sidebar.dart';

class MusicPage extends StatelessWidget {
  const MusicPage({
    super.key,
    required this.sessions,
    required this.controller,
    required this.onRestore,
    required this.onPlayEntry,
    required this.onDelete,
  });

  final List<AudioPlaybackSession> sessions;
  final AppAudioController controller;
  final ValueChanged<AudioPlaybackSession> onRestore;
  final Future<void> Function(AudioPlaybackSession session, int index)
      onPlayEntry;
  final ValueChanged<AudioPlaybackSession> onDelete;

  @override
  Widget build(BuildContext context) {
    final activeId = controller.session?.id;
    final obstruction = AppNavigationObstruction.of(context);
    return SafeArea(
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          28 + obstruction.left,
          26,
          28,
          40 + obstruction.bottom,
        ),
        children: [
          Text('音乐', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 6),
          Text('当前播放与保存的歌单', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 22),
          if (sessions.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 70),
              child: Center(child: Text('从目录或分类中打开一首音频后，歌单会保留在这里。')),
            ),
          for (final session in sessions)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _SessionCard(
                session: session,
                active: session.id == activeId,
                onRestore: () => onRestore(session),
                onPlayEntry: (index) => onPlayEntry(session, index),
                onDelete: () => onDelete(session),
              ),
            ),
        ],
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard(
      {required this.session,
      required this.active,
      required this.onRestore,
      required this.onPlayEntry,
      required this.onDelete});
  final AudioPlaybackSession session;
  final bool active;
  final VoidCallback onRestore;
  final Future<void> Function(int index) onPlayEntry;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = session.current;
    return Material(
      color: active
          ? theme.colorScheme.secondaryContainer.withValues(alpha: .7)
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: .55),
      borderRadius: BorderRadius.circular(AppTokens.radiusSm),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        onTap: onRestore,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Icon(active ? Icons.graphic_eq_rounded : Icons.queue_music_rounded,
                color: theme.colorScheme.primary),
            const SizedBox(width: 14),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(session.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                      '${current?.title ?? '无可播放项目'}  ·  ${session.currentIndex + 1} / ${session.entries.length}  ·  ${session.mode.label}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall),
                ])),
            IconButton(
                tooltip: '恢复播放',
                onPressed: onRestore,
                icon: const Icon(Icons.play_arrow_rounded)),
            IconButton(
              tooltip: '查看歌单',
              onPressed: () => _showEntries(context),
              icon: const Icon(Icons.queue_music_rounded),
            ),
            IconButton(
                tooltip: '删除歌单',
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline_rounded)),
          ]),
        ),
      ),
    );
  }

  Future<void> _showEntries(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 760),
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .62,
          child: ListView.builder(
            itemCount: session.entries.length,
            itemBuilder: (context, index) {
              final entry = session.entries[index];
              final selected = index == session.currentIndex;
              return ListTile(
                selected: selected,
                leading: SizedBox(
                    width: 28,
                    child: Center(
                        child: selected
                            ? const Icon(Icons.graphic_eq_rounded)
                            : Text('${index + 1}'))),
                title: Text(entry.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(entry.format.toUpperCase()),
                onTap: () async {
                  Navigator.of(context).pop();
                  await onPlayEntry(index);
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
