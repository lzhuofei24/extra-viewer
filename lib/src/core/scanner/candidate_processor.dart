import '../database/library_repository.dart';
import '../domain/models.dart';

typedef CandidateLink = ({String entityId, String indexNodeId});

class CandidateWriteRequest {
  const CandidateWriteRequest({
    required this.jobId,
    required this.path,
    required this.name,
    required this.format,
    required this.entityType,
    required this.hash,
    required this.size,
    required this.sourceCreatedAtMs,
    required this.sourceModifiedAtMs,
    required this.directoryRootId,
    this.metadataPreview,
    this.durationMs,
    this.localPath,
    this.existing,
  });

  final String jobId;
  final String path;
  final String name;
  final String format;
  final EntityType entityType;
  final String hash;
  final int size;
  final int sourceCreatedAtMs;
  final int sourceModifiedAtMs;
  final String directoryRootId;
  final String? metadataPreview;
  final int? durationMs;
  final String? localPath;
  final Entity? existing;
}

class CandidateProcessor {
  CandidateProcessor(this.repository);

  final LibraryRepository repository;

  EntityUpsertResult write(CandidateWriteRequest request) {
    final existing = request.existing;
    if (existing != null &&
        (existing.hash != request.hash ||
            existing.format != request.format ||
            existing.entityType != request.entityType ||
            existing.size != request.size ||
            existing.metadataPreview != request.metadataPreview ||
            existing.durationMs != request.durationMs ||
            existing.directoryRootId != request.directoryRootId ||
            existing.localPath != request.localPath)) {
      repository.snapshotEntityForIndexJob(request.jobId, existing);
    }
    final result = repository.upsertEntity(
      path: request.path,
      localPath: request.localPath,
      name: request.name,
      format: request.format,
      entityType: request.entityType,
      hash: request.hash,
      size: request.size,
      sourceCreatedAtMs: request.sourceCreatedAtMs,
      sourceModifiedAtMs: request.sourceModifiedAtMs,
      metadataPreview: request.metadataPreview,
      durationMs: request.durationMs,
      directoryRootId: request.directoryRootId,
      knownExisting: existing,
      existingLookupCompleted: true,
    );
    if (result.status == EntityUpsertStatus.inserted) {
      repository.recordCreatedEntityForIndexJob(
          request.jobId, result.entity.id);
    }
    return result;
  }

  /// Records only links introduced by this task, then writes the full batch
  /// in one transaction. Both source adapters use this same rollback-aware
  /// association path.
  void writeLinks(
    String jobId,
    Iterable<CandidateLink> links, {
    bool transactional = true,
  }) {
    final batch = links.toList(growable: false);
    if (batch.isEmpty) return;
    void write() {
      repository.snapshotIndexJobLinks(jobId, batch);
      repository.linkEntitiesToIndexNodes(batch, rebuildStats: false);
    }

    if (transactional) {
      repository.writeTransaction(write);
    } else {
      write();
    }
  }
}
