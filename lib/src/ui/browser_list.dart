import 'package:flutter/material.dart';
import 'browser_state.dart';

class BrowserListMetrics {
  static int columns(BuildContext context,
          {int portraitColumns = 1, int landscapeColumns = 3}) =>
      MediaQuery.orientationOf(context) == Orientation.portrait
          ? portraitColumns.clamp(1, 3)
          : landscapeColumns.clamp(1, 4);
  static double previewSize(BrowserListStyle style) => switch (style) {
        BrowserListStyle.text => 0,
        BrowserListStyle.compact => 36,
        BrowserListStyle.normal => 56,
      };
  static double rowHeight(BuildContext context, BrowserListStyle style) {
    final base = switch (style) {
      BrowserListStyle.text => 48.0,
      BrowserListStyle.compact => 60.0,
      BrowserListStyle.normal => 80.0,
    };
    final textHeight = MediaQuery.textScalerOf(context).scale(16);
    return base +
        (textHeight - 16).clamp(0, double.infinity) *
            (style == BrowserListStyle.normal ? 3 : 2);
  }
}

class BrowserListSliver extends StatelessWidget {
  const BrowserListSliver(
      {super.key,
      this.landscapeColumns = 3,
      this.portraitColumns = 1,
      required this.count,
      required this.style,
      required this.padding,
      required this.itemBuilder});
  final int landscapeColumns, portraitColumns;
  final int count;
  final BrowserListStyle style;
  final double padding;
  final IndexedWidgetBuilder itemBuilder;
  @override
  Widget build(BuildContext context) {
    final columns = BrowserListMetrics.columns(context,
        portraitColumns: portraitColumns, landscapeColumns: landscapeColumns);
    final rows = (count + columns - 1) ~/ columns;
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(padding, padding, padding, 0),
      sliver: SliverList.builder(
          itemCount: rows,
          itemBuilder: (context, row) => ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Column(children: [
                SizedBox(
                    height: BrowserListMetrics.rowHeight(context, style),
                    child: Row(children: [
                      for (var slot = 0; slot < columns; slot++)
                        Expanded(
                            child: row * columns + slot < count
                                ? itemBuilder(context, row * columns + slot)
                                : const SizedBox.shrink()),
                    ])),
                if (row < rows - 1) const Divider(height: 1),
              ]))),
    );
  }
}

class BrowserListTile extends StatelessWidget {
  const BrowserListTile(
      {super.key,
      required this.style,
      required this.title,
      required this.subtitle,
      required this.onTap,
      required this.previewBuilder,
      this.icon = Icons.insert_drive_file_outlined,
      this.selected = false,
      this.onLongPress,
      this.onSecondaryTap});
  final BrowserListStyle style;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final WidgetBuilder previewBuilder;
  final IconData icon;
  final bool selected;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;
  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            onSecondaryTap: onSecondaryTap,
            child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: LayoutBuilder(
                    builder: (context, constraints) => Row(children: [
                          if (style == BrowserListStyle.text)
                            Icon(icon, size: 22)
                          else
                            SizedBox.square(
                                dimension: BrowserListMetrics.previewSize(style)
                                    .clamp(0.0, constraints.maxWidth * .35),
                                child: ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: previewBuilder(context))),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Text(title,
                                    maxLines: style == BrowserListStyle.normal
                                        ? 2
                                        : 1,
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        Theme.of(context).textTheme.bodySmall),
                                if (style != BrowserListStyle.text) ...[
                                  const SizedBox(height: 3),
                                  Text(subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall),
                                ],
                              ])),
                          if (selected)
                            const Icon(Icons.check_circle_rounded, size: 18),
                        ])))),
      );
}
