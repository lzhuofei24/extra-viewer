import 'package:flutter/material.dart';
import 'app_sidebar.dart';

/// Shared floating chrome; insets belong to scroll contents, not the page.
class BrowserPageScaffold extends StatelessWidget {
  const BrowserPageScaffold(
      {super.key,
      required this.body,
      required this.toolbar,
      this.immersive = false,
      this.onExitImmersive,
      this.selectionBar});
  final Widget body, toolbar;
  final bool immersive;
  final VoidCallback? onExitImmersive;
  final Widget? selectionBar;

  static double topInset(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 600 ? 116 : 76;
  static double bottomInset(BuildContext context, {bool selecting = false}) =>
      28 + AppNavigationObstruction.of(context).bottom + (selecting ? 80 : 0);

  @override
  Widget build(BuildContext context) => Stack(children: [
        body,
        if (!immersive)
          Positioned(
              top: 4,
              left: 8,
              right: 8,
              child: Center(
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 960),
                      child: toolbar))),
        if (immersive)
          Positioned(
              top: 8,
              right: 8,
              child: FloatingGlassSurface(
                  borderRadius: 24,
                  child: IconButton(
                      tooltip: '退出沉浸式浏览',
                      onPressed: onExitImmersive,
                      icon: const Icon(Icons.fullscreen_exit_rounded)))),
        if (selectionBar != null)
          Positioned(
              left: 12,
              right: 12,
              bottom: AppNavigationObstruction.of(context).bottom + 8,
              child: Center(
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 960),
                      child: FloatingGlassSurface(
                          borderRadius: 28, child: selectionBar!)))),
      ]);
}

class BrowserSelectionBar extends StatelessWidget {
  const BrowserSelectionBar(
      {super.key,
      required this.count,
      required this.onExit,
      required this.actions,
      required this.onSelectAll,
      required this.onInvert});
  final int count;
  final VoidCallback onExit, onSelectAll, onInvert;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.all(10),
      child: LayoutBuilder(builder: (context, constraints) {
        if (constraints.maxWidth < 700 ||
            MediaQuery.textScalerOf(context).scale(14) > 21) {
          return Row(children: [
            Expanded(
                child: Text('已选 $count 项',
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
            IconButton(
                tooltip: '退出选择',
                onPressed: onExit,
                icon: const Icon(Icons.close)),
            MenuAnchor(
                menuChildren: [
                  MenuItemButton(
                      onPressed: onSelectAll, child: const Text('全选')),
                  MenuItemButton(onPressed: onInvert, child: const Text('反选')),
                  ...actions,
                ],
                builder: (_, controller, __) => IconButton(
                    tooltip: '选择操作',
                    onPressed: () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
                    icon: const Icon(Icons.more_horiz))),
          ]);
        }
        return Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('已选 $count 项'),
              TextButton(onPressed: onExit, child: const Text('退出')),
              TextButton(onPressed: onSelectAll, child: const Text('全选')),
              TextButton(onPressed: onInvert, child: const Text('反选')),
              ...actions
            ]);
      }));
}
