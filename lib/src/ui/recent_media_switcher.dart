import 'package:flutter/material.dart';

import 'app_sidebar.dart';

class RecentMediaSwitcher extends StatelessWidget {
  const RecentMediaSwitcher({
    super.key,
    required this.current,
    required this.onChanged,
    this.embedded = false,
  });

  final AppSection current;
  final ValueChanged<AppSection> onChanged;
  final bool embedded;

  static const _items = <(AppSection, String, IconData)>[
    (AppSection.gallery, '图片', Icons.image_outlined),
    (AppSection.video, '视频', Icons.videocam_outlined),
    (AppSection.reading, '阅读', Icons.menu_book_outlined),
    (AppSection.music, '音乐', Icons.music_note_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final content = Material(
      color: Colors.transparent,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in _items)
            _MediaButton(
              label: item.$2,
              icon: item.$3,
              selected: current == item.$1,
              onPressed: () => onChanged(item.$1),
            ),
        ],
      ),
    );
    final scrollable = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: content,
    );
    return embedded
        ? scrollable
        : FloatingGlassSurface(
            borderRadius: 24,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: scrollable,
          );
  }
}

class _MediaButton extends StatelessWidget {
  const _MediaButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? colors.secondaryContainer.withValues(alpha: .68)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 19),
              const SizedBox(width: 5),
              Text(label, maxLines: 1),
            ],
          ),
        ),
      ),
    );
  }
}
