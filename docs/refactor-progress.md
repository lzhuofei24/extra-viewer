# Modular refactor execution log

## Contract

Implement the approved seven-module plan. Preserve source files, existing user
data, IDs, references and preview assets. Use incremental schema 5 -> 6.
Local commits only; no push or tablet installation. Keep release signing compatible.

## Baseline

### Source-file ownership and temporary storage

- Replaced path-only SAF session caching and synchronous filesystem eviction
  with SourceFileCache. Keys include entity ID, source revision and locator;
  browser DTOs and restored audio sessions carry the current source revision.
- Every active image/PDF/document/media consumer now owns a SourceFileLease.
  Image prefetch releases after decoding; archive documents release after their
  retained archive session closes; media releases after player stop/disposal.
  Late opens also release their lease. Repeated lease close is idempotent.
- Serialized copy admission reserves capacity before native I/O, shares matching
  versions and evicts only unleased temporary files using asynchronous I/O.
  Normal budget remains 2 GB. Compatibility exception: one known oversized
  source may reserve exclusively; it is removed when its last lease closes.
- Android enforces the granted byte limit while copying and removes partial
  files on failure. Source originals and offline preview assets are untouched.
- Validation: all 96 Flutter tests passed; analyze and Android compileDebugKotlin
  passed (Flutter kernel task excluded, dependencies offline). Regression coverage
  includes concurrent leases, revision changes, failed reservation recovery,
  oversized copies, exclusive large files and source-file preservation.
- Real-device rapid viewer transitions/large SAF streams remain unverified.
  Build-stage transient files retain their separate scan scope; cancellation
  during a blocking native source read and full AppRuntime shutdown remain
  future work. No APK installation or remote push performed.

### Archive preview consolidation

- EPUB/DOCX excerpt and first illustration now share one archive session in a
  cancellable worker. Excerpts are bounded to 500 codepoints plus ellipsis;
  covers preserve aspect ratio at approximately 360000 pixels, WebP quality 80.
- Prepared immutable covers, excerpts, document versions and work completion
  publish in one writer transaction with source/preview/attempt checks. Existing
  valid covers are retained; missing illustrations are a durable normal result.
- Existing schema-6 databases receive the nullable cover revision column without
  deleting document version records. Legacy pending archive thumbnail work moves
  to document work without rescanning or altering the task source scope.
- Removed duplicate archive handling from the entity preview stage. Fixed pause
  propagation so an interrupted decoder is not recorded as a thumbnail failure.
- Validation: full 89-test suite passed; subsequently added stale-result and
  backend-pause regressions passed in targeted suites (6 and 4 tests).
  No tablet installation or release build in this batch. TF-card timings remain
  unverified. Runtime, source leases, navigation and remaining module boundaries
  are still pending.

- Existing work checkpoint: e9755b8.
- Previous audit: analyze passed; 49 tests passed, sidebar and native DLL tests failed.
- Batch 0: scrollable sidebar and standalone native test build implemented.
- Full baseline suite: 51 tests passed, including the compiled WIC backend.

## Remaining batches

### Database transport foundation (2026-09-15)

- Production bootstrap opens/migrates SQLite inside DatabaseHost, not the UI.
- Library and build typed clients route calls to one supervised writer;
  the existing read worker remains dedicated to paged browsing.
- Index-page transaction and finalization now execute in the host.
- Widgets hold a storage descriptor, not a SQLite connection. Async reads are
  moved out of WidgetBuilder/setState; graph selection ignores stale results.
- Progress rendering no longer queries a job on every callback.
- Shutdown waits for database close and worker exit before releasing ports;
  a regression test caught and fixed a Windows database-handle leak.
- Validation: flutter analyze clean; all 58 tests passed.
- This is the transport foundation, not completion of batch 2: generated broad
  access remains transitional. Capability interfaces, domain command receipts,
  durable change notifications and removal of repository worker branches remain.
- All later preview/runtime/navigation/release gates remain outstanding.

### Per-item commit and writer cleanup (2026-09-15)

- Removed nested writer routing and unused sync/async aliases from repositories;
  all production callers already use the host. Removed the unused thumbnail
  update buffer instead of retaining its fire-and-forget writes.
- Inspection failures are persisted per manifest item; successful entities,
  links, item status and cursor commit in the same prepared-SQL transaction.
- Failed reads block deletion reconciliation. Retry resets only failed items;
  the index-write page skips already committed rows and retains successful counts.
- Committed root content becomes visible before previews finish. Abandon retains it.
- Basic metadata writes preserve previously parsed excerpts/duration. Corrected
  the batch unchanged predicate so successful thumbnails do not force rewrites.
- Preview work counters use transactional deltas; duplicate completions and
  results for released, non-processing work do not increment counts.
- Task ownership is reserved before asynchronous creation and released with a
  final UI notification; shutdown waits for the owned task to stop.
- Validation: analyze clean; full suite 60 passed, followed by a new ownership
  regression test passing independently (61 tests total).
- Remaining safeguards: work generation tokens (a released item claimed by a
  newer attempt still needs a token), complete domain command receipts, bounded
  derived-result commits, retention, atomic asset publication and full runtime.

### Versioned preview publication and recovery (2026-09-15)

- Added source/preview revisions and immutable sharded asset keys; old asset
  paths remain readable. Failed rebuilds retain the previous published image.
- Entity and node results publish conditionally against revision tickets.
  Work completion also checks task generation and claim attempt; late callbacks
  cannot advance a newer attempt or replace a newer image.
- Node dirty markers now persist revision changes for affected ancestors.
  Build work processes dirty children before parents instead of rebuilding the
  whole root descriptor cache. Global cross-collection scheduling is still pending.
- Derived files retire through a delayed ledger with reference checks. The old
  index-deletion path now schedules retirement instead of deleting immediately.
- Document metadata and work status commit together after source/attempt checks;
  corrected the stored document type predicate and removed startup EPUB repair.
- Successful work details are pruned; failed details remain repairable. Completed
  summaries are bounded to 100, while unfinished tasks remain. Completion rejects
  pending/processing preview work and reports partial failures separately.
- Validation: full suite 69 passed; subsequent completion/deletion-boundary
  changes passed 17 targeted tests. No Android install or source-file modification.
- Still outstanding: complete domain command receipts, cross-collection dirty
  scheduling, cancellation through native decode, 100-item/2-second batching,
  one-pass document cover/excerpt, cache budgets, runtime/navigation and releases.

### Domain command receipts (2026-09-15)

- Domain writes and receipts share one host transaction. Explicit read allowlist
  bypasses write transactions; new operations default to commands.
- Commands carry random IDs with issue time. Receipts survive worker restart;
  duplicate IDs never replay. Failed/time-out calls query the serial worker for
  committed/not-committed outcome, retaining unknown if it is unavailable.
- Receipts expire after seven days; expired IDs cannot replay. WAL checkpoint
  and filesystem garbage collection remain outside transactional commands.
- Root listing no longer implicitly creates the global root. Removed unused
  unversioned metadata repair and asset-record deletion APIs.
- Entity and node cascade deletion records asset retirement transactionally;
  rollback cannot leave committed pointers to immediately deleted files.
- Validation: host restart/deduplication/rollback tests passed; full suite had
  71 passes and one outdated minimal schema fixture failure. Updated that fixture
  with the schema-5 preview columns/table; all 7 migration/host tests then passed.
  Analyze clean before the fixture-only follow-up.
- This does not finish module capability separation, native cancellation,
  UI/runtime, cache policy or release/device acceptance.

### Bounded browser warmup (2026-09-15)

- Removed full-node thumbnail-path pagination and its unused read-worker,
  repository, DTO and shell callback paths.
- Visible sliver children decode on demand. After 150 ms of scroll inactivity,
  warm at most 16 neighbors in each direction, in display order, within one
  quarter of the configured image-cache byte budget. No whole-node decode pass.
- Scope/scroll changes invalidate old warmup; only one warmup loop decodes at a
  time. Off-window speculative entries are evicted; displayed images return to
  ordinary LRU ownership. Selection registry drops unmounted keys.
- Original-image prefetch now cleans up failed source reads, skips stale window
  entries and stops queued work on disposal. Removed the viewer's independent
  cache-budget enlargement; the runtime retains sole global budget ownership.
- Validation: full suite 75 passed; after dead-path cleanup, 8 read-worker/budget
  tests passed and the shell test passed after importing Flutter's new explicit
  ScrollCacheExtent type. Real Android scroll/frame profiling remains pending.
- Remaining original-image gate: source leases and a separate measured original
  decode budget (the shared global byte cap is still the current limit).

### Cancellation chain and timed tail commits (2026-09-15)

- Build pause/abandon now reaches ThumbnailCancellationToken and native image/
  video backends. Listeners added after pause also observe the stopped state.
- Android queued cancellations reply exactly once instead of leaving Dart
  awaiting a cancelled Future. Video retrievers are released only by their
  owning worker, not concurrently by the UI cancellation handler.
- Native writes check cancellation at stage boundaries, refuse replacing an
  immutable final asset and clean partial files in finally. Bitmap cleanup also
  runs on failure/cancellation. An in-progress native decode may still finish
  internally before releasing its resources; its late result is ignored.
- Pure Dart node composition can terminate its Isolate on pause. Entry points
  avoid capturing ReceivePorts/repository state; regression tests caught and
  fixed an unsendable closure during implementation.
- Node previews publish individually with result callbacks. Document, entity
  and node work flush pending results every two seconds and at page/pause exit;
  page claims remain bounded to 100 (node batches to 8). Commits are serialized,
  writer failures surface, and already-finished tails survive interruption.
- Progress is refreshed after timed commits through the existing UI throttle.
- Validation: all 82 Flutter tests passed, analyze clean, git diff --check clean.
  Android :app:compileDebugKotlin passed (Flutter kernel build was excluded).
  Real-device cancellation/TF-card resource timing remains unverified.
- Build environment: Windows JDK AF_UNIX failed using the DOS-short temp path.
  For this run, setting jdk.net.unixdomain.tmpdir to app/build/java-tmp resolved
  it. Dependencies were fetched through the existing 127.0.0.1:7897 proxy, using
  JDK 21, two Gradle workers and a 2 GB heap. No persistent system settings changed.
- Remaining gates include single-pass document parsing, source leases, full
  capability separation, global dirty scheduling, runtime/navigation and releases.

### Implemented safety/frontier foundation

- Schema 6 additive migration, schema-5 snapshot before file-backed migration.
- Immutable task scope, explicit preview task kind and blocked status.
- SAF null cursor fails enumeration; document failures expose retry action.
- Durable per-directory frontier; incomplete directory pages are replaced on resume.
- Android per-directory cursor bridge; standalone full-tree count no longer invoked.
- Targeted suite: 8 tests passed; analyze passed before the final test additions.
- Android native changes still require the release build/native-device checks.

1. Scope and scan failure safety.
2. DatabaseHost, module interfaces and supervised workers.
3. Durable directory frontier and per-item recovery.
4. Versioned preview publication, dependency invalidation and cache budgets.
5. Runtime, reading anchors, navigation consolidation and pet removal.
6. Cleanup, full regression and Windows/Android release builds.

Device-dependent acceptance: TF card throughput, Android frame/memory profiling,
and hardware video/SAF interruption tests require the tablet; do not mark these verified
based only on desktop/unit tests.
