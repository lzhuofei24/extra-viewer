import 'dart:io';

import 'package:flutter/material.dart';

import '../core/domain/models.dart';

double indexNodePreviewAspectRatio(IndexNodePreview? preview) {
  if (preview == null) return 1;
  // The stored WebP is the source of truth. Its width is deliberately based
  // on 0.4H lower covers, not on the original image dimensions.
  final persistedAspectRatio = preview.visualAssetAspectRatio;
  if (persistedAspectRatio != null && persistedAspectRatio > 0) {
    return persistedAspectRatio;
  }
  return switch (preview.kind) {
    IndexNodePreviewKind.singleVisual ||
    IndexNodePreviewKind.visualGrid =>
      _BookStackLayout.fromTiles(
        // Persistent WebPs contain visual covers only. Use the same tile set
        // as the compositor so their variable width is never stretched back
        // into the legacy mixed-data layout at display time.
        preview.visualAssetPath == null
            ? preview.tiles
            : preview.tiles
                .where((tile) => tile.kind == IndexNodePreviewTileKind.visual)
                .toList(growable: false),
        customOrderTopToBottom: preview.customOrderTopToBottom,
      ).aspectRatio,
    IndexNodePreviewKind.audioList ||
    IndexNodePreviewKind.documentList ||
    IndexNodePreviewKind.splitLists =>
      1,
    IndexNodePreviewKind.empty => 1,
  };
}

class IndexNodeThumbnail extends StatelessWidget {
  const IndexNodeThumbnail({
    super.key,
    required this.preview,
    required this.nodeName,
    required this.hasContent,
  });

  final IndexNodePreview? preview;
  final String nodeName;
  final bool hasContent;

  @override
  Widget build(BuildContext context) {
    final data = preview;
    if (data == null) {
      return _NodeNameTile(title: nodeName);
    }
    if (data.kind == IndexNodePreviewKind.empty) {
      if (hasContent) {
        return _NodeNameTile(title: nodeName);
      }
      return const SizedBox.expand();
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: switch (data.kind) {
          IndexNodePreviewKind.singleVisual ||
          IndexNodePreviewKind.visualGrid =>
            _VisualNodeAsset(
              path: data.visualAssetPath,
              fallback: data.customOrderTopToBottom
                  ? _BookStack(
                      tiles: data.tiles,
                      customOrderTopToBottom: true,
                    )
                  : null,
            ),
          IndexNodePreviewKind.audioList => _BookStack(
              tiles: [
                IndexNodePreviewTile(
                  kind: IndexNodePreviewTileKind.audio,
                  title: nodeName,
                  audioNames: data.audioNames,
                ),
              ],
            ),
          IndexNodePreviewKind.documentList => _BookStack(
              tiles: [
                IndexNodePreviewTile(
                  kind: IndexNodePreviewTileKind.document,
                  title: nodeName,
                  documentNames: data.documentNames,
                ),
              ],
            ),
          IndexNodePreviewKind.splitLists => _BookStack(
              tiles: [
                IndexNodePreviewTile(
                  kind: IndexNodePreviewTileKind.mixedData,
                  title: nodeName,
                  audioNames: data.audioNames,
                  documentNames: data.documentNames,
                ),
              ],
            ),
          IndexNodePreviewKind.empty => const SizedBox.expand(),
        },
      ),
    );
  }
}

class _VisualNodeAsset extends StatelessWidget {
  const _VisualNodeAsset({this.path, this.fallback});

  final String? path;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    final value = path;
    if (value == null || value.isEmpty || !File(value).existsSync()) {
      // Visual node previews are persistent build artifacts. Do not recreate
      // a multi-image layout while scrolling when the asset is unavailable.
      return fallback ?? const SizedBox.expand();
    }
    return Image.file(
      File(value),
      // Node preview WebPs have a fixed height but intentionally variable
      // width. Cover may trim an edge when constraints change; fill would
      // distort every cover's aspect ratio.
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
    );
  }
}

class _BookStack extends StatelessWidget {
  const _BookStack({
    required this.tiles,
    this.customOrderTopToBottom = false,
  });

  final List<IndexNodePreviewTile> tiles;
  final bool customOrderTopToBottom;

  @override
  Widget build(BuildContext context) {
    final layout = _BookStackLayout.fromTiles(
      tiles,
      customOrderTopToBottom: customOrderTopToBottom,
    );
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        children: [
          for (var index = 0; index < layout.tiles.length; index++)
            Positioned(
              left: layout.leftOffsets[index] * constraints.maxHeight,
              top: 0,
              width: layout.coverWidths[index] * constraints.maxHeight,
              height: constraints.maxHeight,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  color: Color(0x66000000),
                ),
                child: ClipRRect(
                  // Internal stacked seams are square; only the leading
                  // outer edge keeps the cover's rounded silhouette.
                  borderRadius: index == 0
                      ? const BorderRadius.horizontal(
                          left: Radius.circular(16),
                        )
                      : BorderRadius.zero,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .outlineVariant
                            .withValues(alpha: .75),
                      ),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _PreviewTile(tile: layout.tiles[index]),
                        if (index < layout.tiles.length - 1 &&
                            layout.tiles[index].kind ==
                                IndexNodePreviewTileKind.visual)
                          Positioned(
                            left: (layout.coverWidths[index] - .15)
                                    .clamp(0.0, layout.coverWidths[index]) *
                                constraints.maxHeight,
                            top: 0,
                            width: constraints.maxHeight * .15,
                            height: constraints.maxHeight,
                            child: const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.centerLeft,
                                  end: Alignment.centerRight,
                                  colors: [
                                    Color(0x00000000),
                                    Color(0x66000000),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BookStackLayout {
  const _BookStackLayout({
    required this.aspectRatio,
    required this.tiles,
    required this.coverWidths,
    required this.leftOffsets,
  });

  final double aspectRatio;
  final List<IndexNodePreviewTile> tiles;
  final List<double> coverWidths;
  final List<double> leftOffsets;

  factory _BookStackLayout.fromTiles(
    List<IndexNodePreviewTile> tiles, {
    bool customOrderTopToBottom = false,
  }) {
    if (tiles.isEmpty) {
      return const _BookStackLayout(
        aspectRatio: 1,
        tiles: [],
        coverWidths: [],
        leftOffsets: [],
      );
    }
    if (customOrderTopToBottom) {
      return _BookStackLayout._fromBottomToTop(
        tiles.reversed.toList(growable: false),
      );
    }
    final dataTiles = tiles.where(_isBookDataTile).toList(growable: false);
    final visualTiles =
        tiles.where((tile) => !_isBookDataTile(tile)).toList(growable: true);
    if (visualTiles.length > 1) {
      var topIndex = 0;
      for (var index = 1; index < visualTiles.length; index++) {
        final candidate = visualTiles[index];
        final top = visualTiles[topIndex];
        // Larger height/width means a more portrait-oriented cover.
        if (candidate.aspectRatio < top.aspectRatio ||
            (candidate.aspectRatio == top.aspectRatio &&
                candidate.title.compareTo(top.title) < 0)) {
          topIndex = index;
        }
      }
      final top = visualTiles.removeAt(topIndex);
      visualTiles.add(top);
    }
    return _BookStackLayout._fromBottomToTop([...dataTiles, ...visualTiles]);
  }

  factory _BookStackLayout._fromBottomToTop(
    List<IndexNodePreviewTile> ordered,
  ) {
    final widths = <double>[
      for (var index = 0; index < ordered.length; index++)
        _bookCoverWidth(
          ordered[index],
          isTop: index == ordered.length - 1,
        ),
    ];
    final offsets = <double>[];
    var offset = 0.0;
    for (var index = 0; index < ordered.length; index++) {
      offsets.add(offset);
      offset += widths[index];
    }
    return _BookStackLayout(
      aspectRatio: offset,
      tiles: ordered,
      coverWidths: widths,
      leftOffsets: offsets,
    );
  }
}

bool _isBookDataTile(IndexNodePreviewTile tile) =>
    tile.kind == IndexNodePreviewTileKind.audio ||
    tile.kind == IndexNodePreviewTileKind.document ||
    tile.kind == IndexNodePreviewTileKind.mixedData;

double _bookCoverWidth(IndexNodePreviewTile tile, {required bool isTop}) {
  if (_isBookDataTile(tile)) return 1;
  // Match the persistent compositor: every lower visual is a real 0.4H
  // cover, while only the top cover keeps a source-derived width.
  return isTop ? tile.aspectRatio.clamp(.4, 1.0).toDouble() : .4;
}

class _PreviewTile extends StatelessWidget {
  const _PreviewTile({required this.tile});

  final IndexNodePreviewTile tile;

  @override
  Widget build(BuildContext context) {
    if (tile.kind == IndexNodePreviewTileKind.visual &&
        tile.thumbnailPath != null &&
        tile.thumbnailPath!.isNotEmpty) {
      return ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Image.file(
          File(tile.thumbnailPath!),
          fit: BoxFit.cover,
          alignment: Alignment.center,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, __, ___) => _NodeNameTile(title: tile.title),
        ),
      );
    }
    if (tile.kind == IndexNodePreviewTileKind.visual) {
      return _NodeNameTile(title: tile.title);
    }
    return switch (tile.kind) {
      IndexNodePreviewTileKind.visual ||
      IndexNodePreviewTileKind.node =>
        _NodeNameTile(title: tile.title),
      IndexNodePreviewTileKind.audio =>
        _DataListTile(audioNames: tile.audioNames, documentNames: const []),
      IndexNodePreviewTileKind.document => _DataListTile(
          audioNames: const [],
          documentNames: tile.documentNames,
          useAudioPalette: true,
        ),
      IndexNodePreviewTileKind.mixedData => _DataListTile(
          audioNames: tile.audioNames,
          documentNames: tile.documentNames,
        ),
    };
  }
}

class _NodeNameTile extends StatelessWidget {
  const _NodeNameTile({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.primaryContainer.withValues(alpha: .72),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Text(
            title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onPrimaryContainer,
                  height: 1.15,
                ),
          ),
        ),
      ),
    );
  }
}

class _DataListTile extends StatelessWidget {
  const _DataListTile({
    required this.audioNames,
    required this.documentNames,
    this.useAudioPalette = false,
  });

  final List<String> audioNames;
  final List<String> documentNames;
  final bool useAudioPalette;

  @override
  Widget build(BuildContext context) {
    // Books and other document previews share the music palette so a node
    // never changes to the legacy yellow background merely due to its type.
    final usesAudioPalette =
        audioNames.isNotEmpty || documentNames.isNotEmpty || useAudioPalette;
    final names = [...audioNames, ...documentNames];
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: usesAudioPalette
            ? scheme.tertiaryContainer.withValues(alpha: .78)
            : scheme.secondaryContainer.withValues(alpha: .75),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (audioNames.isNotEmpty)
            Align(
              alignment: Alignment.center,
              child: SizedBox(
                width: double.infinity,
                height: 26,
                child: CustomPaint(
                  painter: _WavePainter(
                    color: scheme.onTertiaryContainer.withValues(alpha: .19),
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(6),
            child: _NameList(
              names: names,
              color: usesAudioPalette
                  ? scheme.onTertiaryContainer
                  : scheme.onSecondaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}

class _NameList extends StatelessWidget {
  const _NameList({required this.names, required this.color});

  final List<String> names;
  final Color color;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          const lineHeight = 15.0;
          final lineCount =
              (constraints.maxHeight / lineHeight).floor().clamp(1, 8);
          final reserveOverflowLine = names.length > lineCount;
          final visible = names
              .take(reserveOverflowLine ? lineCount - 1 : lineCount)
              .toList(growable: false);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < visible.length; index++)
                SizedBox(
                  height: lineHeight,
                  child: Text(
                    visible[index],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: color,
                          height: 1.1,
                        ),
                  ),
                ),
              if (names.length > visible.length)
                Text('...',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: color)),
            ],
          );
        },
      );
}

class _WavePainter extends CustomPainter {
  const _WavePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    const bars = 22;
    for (var index = 0; index < bars; index++) {
      final ratio = index / (bars - 1);
      final amplitude = .16 + ((index * 17) % 9) / 12;
      final height = size.height * amplitude;
      final x = ratio * size.width;
      canvas.drawLine(
        Offset(x, (size.height - height) / 2),
        Offset(x, (size.height + height) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) =>
      oldDelegate.color != color;
}
