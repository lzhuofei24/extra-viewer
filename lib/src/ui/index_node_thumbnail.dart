import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/domain/models.dart';

double indexNodePreviewAspectRatio(IndexNodePreview? preview) {
  if (preview == null) return 1;
  return switch (preview.kind) {
    IndexNodePreviewKind.singleVisual ||
    IndexNodePreviewKind.visualGrid =>
      _JustifiedMosaicLayout.fromTiles(preview.tiles).aspectRatio,
    // Compact list previews reserve less vertical space than visual mosaics.
    // Keep audio and book-only nodes visually aligned.
    IndexNodePreviewKind.audioList ||
    IndexNodePreviewKind.documentList =>
      1.875,
    IndexNodePreviewKind.splitLists => .85,
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
      return _NodeThumbnailFailure(
        message: '节点预览描述缺失\n节点：$nodeName',
      );
    }
    if (data.kind == IndexNodePreviewKind.empty) {
      if (hasContent) {
        return _NodeThumbnailFailure(
          message: '节点有内容但预览为空\n节点：$nodeName',
        );
      }
      return const SizedBox.expand();
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(7),
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: switch (data.kind) {
          IndexNodePreviewKind.singleVisual =>
            _PreviewTile(tile: data.tiles.single),
          IndexNodePreviewKind.visualGrid => _PreviewGrid(
              tiles: data.tiles,
              nodeName: nodeName,
            ),
          IndexNodePreviewKind.audioList => _DataListTile(
              audioNames: data.audioNames,
              documentNames: const [],
            ),
          IndexNodePreviewKind.documentList => _DataListTile(
              audioNames: const [],
              documentNames: data.documentNames,
              useAudioPalette: true,
            ),
          IndexNodePreviewKind.splitLists => Column(
              children: [
                Expanded(
                  child: _DataListTile(
                    audioNames: const [],
                    documentNames: data.documentNames,
                    useAudioPalette: true,
                  ),
                ),
                Divider(
                  height: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                Expanded(
                  child: _DataListTile(
                    audioNames: data.audioNames,
                    documentNames: const [],
                  ),
                ),
              ],
            ),
          IndexNodePreviewKind.empty => const SizedBox.expand(),
        },
      ),
    );
  }
}

class _PreviewGrid extends StatelessWidget {
  const _PreviewGrid({required this.tiles, required this.nodeName});

  final List<IndexNodePreviewTile> tiles;
  final String nodeName;

  @override
  Widget build(BuildContext context) {
    if (tiles.isEmpty) {
      return _NodeThumbnailFailure(
        message: '拼图预览没有候选项\n节点：$nodeName',
      );
    }
    return _JustifiedMosaic(tiles: tiles);
  }
}

class _JustifiedMosaic extends StatelessWidget {
  const _JustifiedMosaic({required this.tiles});

  final List<IndexNodePreviewTile> tiles;

  @override
  Widget build(BuildContext context) {
    final layout = _JustifiedMosaicLayout.fromTiles(tiles);
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        fit: StackFit.expand,
        children: [
          for (final cell in layout.cells)
            Positioned(
              left: cell.left * constraints.maxWidth,
              top: cell.top * constraints.maxHeight,
              width: cell.width * constraints.maxWidth,
              height: cell.height * constraints.maxHeight,
              child: ClipRect(child: _PreviewTile(tile: cell.tile)),
            ),
        ],
      ),
    );
  }
}

class _JustifiedMosaicLayout {
  const _JustifiedMosaicLayout({
    required this.aspectRatio,
    required this.cells,
  });

  final double aspectRatio;
  final List<_MosaicCell> cells;

  factory _JustifiedMosaicLayout.fromTiles(List<IndexNodePreviewTile> tiles) {
    if (tiles.isEmpty) {
      return const _JustifiedMosaicLayout(aspectRatio: 1, cells: []);
    }
    _JustifiedMosaicLayout? best;
    var bestScore = double.infinity;
    final boundaryCount = tiles.length - 1;
    for (var mask = 0; mask < (1 << boundaryCount); mask++) {
      final rows = <List<IndexNodePreviewTile>>[];
      var row = <IndexNodePreviewTile>[];
      for (var index = 0; index < tiles.length; index++) {
        row.add(tiles[index]);
        if (index == tiles.length - 1 || (mask & (1 << index)) != 0) {
          rows.add(row);
          row = <IndexNodePreviewTile>[];
        }
      }
      final candidate = _JustifiedMosaicLayout._fromRows(rows);
      final counts = rows.map((items) => items.length).toList(growable: false);
      final imbalance = counts.reduce(math.max) - counts.reduce(math.min);
      final score = math.log(candidate.aspectRatio).abs() + imbalance * .28;
      if (score < bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    return best!;
  }

  factory _JustifiedMosaicLayout._fromRows(
    List<List<IndexNodePreviewTile>> rows,
  ) {
    final rowHeights = <double>[];
    for (final row in rows) {
      final sum = row.fold<double>(
        0,
        (value, tile) => value + tile.aspectRatio.clamp(.18, 5),
      );
      rowHeights.add(1 / sum);
    }
    final totalHeight = rowHeights.reduce((a, b) => a + b);
    final cells = <_MosaicCell>[];
    var y = 0.0;
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final row = rows[rowIndex];
      final height = rowHeights[rowIndex] / totalHeight;
      final sum = row.fold<double>(
        0,
        (value, tile) => value + tile.aspectRatio.clamp(.18, 5),
      );
      var x = 0.0;
      for (final tile in row) {
        final width = tile.aspectRatio.clamp(.18, 5) / sum;
        cells.add(_MosaicCell(
          tile: tile,
          left: x,
          top: y,
          width: width,
          height: height,
        ));
        x += width;
      }
      y += height;
    }
    return _JustifiedMosaicLayout(
      aspectRatio: 1 / totalHeight,
      cells: cells,
    );
  }
}

class _MosaicCell {
  const _MosaicCell({
    required this.tile,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final IndexNodePreviewTile tile;
  final double left;
  final double top;
  final double width;
  final double height;
}

class _PreviewTile extends StatelessWidget {
  const _PreviewTile({required this.tile});

  final IndexNodePreviewTile tile;

  @override
  Widget build(BuildContext context) {
    if (tile.kind == IndexNodePreviewTileKind.visual &&
        tile.thumbnailPath != null &&
        tile.thumbnailPath!.isNotEmpty) {
      return Image.file(
        File(tile.thumbnailPath!),
        fit: BoxFit.cover,
        alignment: Alignment.center,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, error, __) => _NodeThumbnailFailure(
          message: '实体缩略图解码失败\n${tile.title}\n$error',
        ),
      );
    }
    if (tile.kind == IndexNodePreviewTileKind.visual) {
      return _NodeThumbnailFailure(
        message: '实体缩略图路径为空\n${tile.title}',
      );
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

class _NodeThumbnailFailure extends StatelessWidget {
  const _NodeThumbnailFailure({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color:
            Theme.of(context).colorScheme.errorContainer.withValues(alpha: .72),
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: SelectableText(
            message,
            maxLines: 7,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                  fontFamily: 'Consolas',
                  fontSize: 9,
                  height: 1.15,
                ),
          ),
        ),
      );
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
