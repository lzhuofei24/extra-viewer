import 'dart:io';

import '../../core/domain/models.dart';
import '../../core/thumbnails/cancellable_thumbnail_task.dart';
import '../../core/thumbnails/lossy_webp_encoder.dart';
import '../../core/thumbnails/thumbnail_cancellation.dart';
import '../library/library_access.dart';
import 'archive_document_preview.dart';

class ArchivePreviewPipeline {
  ArchivePreviewPipeline(this.library);
  final LibraryAccess library;

  /// Writes an immutable asset but leaves publication to the document-work
  /// transaction, so text, cover and attempt completion have one commit point.
  Future<DocumentPreviewMetadata> prepare(Entity entity, File source,
      {ThumbnailCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final keepCover = entity.thumbnailStatus == ThumbnailStatus.success &&
        entity.thumbnailPath != null &&
        await File(entity.thumbnailPath!).exists();
    final ticket = keepCover ? null : await library.beginEntityPreview(entity);
    final content = await runCancellableThumbnailTask(
        archiveDocumentPreviewAction(source.path, entity.format,
            includeCover: !keepCover),
        cancellationToken: cancellationToken);
    if (ticket == null) {
      return DocumentPreviewMetadata(
          sourceRevision: entity.sourceRevision,
          excerpt: content.excerpt,
          coverRevision: entity.previewRevision);
    }
    final pixels = content.pixels;
    PreparedEntityPreview preview;
    if (pixels == null) {
      preview = PreparedEntityPreview(
          ticket, ThumbnailDatabaseUpdate.none(entity.id));
    } else {
      final path = await library.thumbnailStore
          .prepareNativeOutputPath(ticket.assetKey, 'webp');
      cancellationToken?.throwIfCancelled();
      await encodeRgbaCanvasToWebp(
          pixels: pixels,
          width: content.width,
          height: content.height,
          outputPath: path);
      cancellationToken?.throwIfCancelled();
      preview = PreparedEntityPreview(
          ticket,
          ThumbnailDatabaseUpdate.success(
              entityId: entity.id,
              key: ticket.assetKey,
              format: 'webp',
              width: content.width,
              height: content.height),
          byteSize: await File(path).length());
    }
    return DocumentPreviewMetadata(
        sourceRevision: entity.sourceRevision,
        excerpt: content.excerpt,
        coverRevision: ticket.previewRevision,
        preview: preview);
  }
}
