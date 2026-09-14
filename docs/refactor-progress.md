# Modular refactor execution log

## Contract

Implement the approved seven-module plan. Preserve source files, existing user
data, IDs, references and preview assets. Use incremental schema 5 -> 6.
Local commits only; no push or tablet installation. Keep release signing compatible.

## Baseline

### Source session shutdown ownership

- AppRuntime stops session source reads before draining work and closes the
  source cache in the cache phase. Android materialization now receives the
  session cancellation token, including requests waiting for initialization.
- SourceFileCache close is idempotent: queued acquisitions are rejected, late
  produced files are removed, idle files are deleted, and active leased files
  survive until their final release. Original local files are never owned.
- Document loading snapshots the entity before awaiting file acquisition so
  diagnostic source paths stay associated with the requested document during
  rapid navigation. Parser selection was already captured before the await.
- Targeted cache/runtime/shell suite: 10 passed; analyze clean. Full viewer
  session registration and native-device interruption acceptance remain pending.

### Book fragment anchors and restoration cancellation

- Book pagination records original block and text-fragment position. Font,
  padding and viewport changes resolve the anchor into the new pagination;
  legacy records without anchors continue to use their stored page.
- Captured first-block anchors are explicitly tracked instead of being mistaken
  for missing positions. Chapter changes, user drags, bookmarks and disposal
  invalidate pending scroll restoration; stale continuations cannot move the
  new chapter or clear a newer restoration's state.
- Pagination TextPainters are disposed after measurement. Cross-mode fractions
  remain approximate (text offset versus rendered height), and far lazy-list
  restoration is still bounded to 40 frames. Full reader acceptance is pending.
- Validation after cancellation hardening: all 111 Flutter tests passed,
  static analysis and git diff --check passed. No device installation performed.

### Scroll content anchors

- ReadingPosition now persists content digest, block index and within-block
  fraction. Matching prefers the original index, then the nearest identical
  digest, with bounded index fallback for removed content.
- Scroll reader captures the top visible block at interaction boundaries.
  Lazy restoration adjusts toward the anchor for at most 40 frames, stops after
  disposal and suppresses intermediate position writes. Block digests/spine
  lists are cached per document/chapter rather than recomputed per build.
- Added insertion, duplicate-content and serialization regression coverage.
  Book pagination fragment-to-source anchors and cross-mode semantic conversion
  remain pending; this step does not claim complete reader or plan acceptance.

### Structured reflow reading coordinates

- Added immutable ReadingPosition with source revision, chapter index/title,
  scroll coordinate, page coordinate and mode. Reflow reader callbacks merge
  this record with typography settings instead of overwriting it with settings.
- EPUB/DOCX/text restore chapter identity; an inserted chapter can be matched
  by title. Changed source revisions reset unsafe within-chapter coordinates.
  Legacy epubChapter/scroll state remains readable. Malformed/future versions
  are ignored safely. Book pages no longer save as scroll pixels.
- Spread PageController starts at its stored page and clamps against available
  pages. Chapter changes reset the spread key; layout recreation samples the
  old controller before disposing it. Legacy book offsets are not guessed to
  be page numbers.
- Validation: 12 targeted reading/parser/shell tests and analyze passed before
  the final legacy conversion addition; final checks recorded with commit.
- This is coordinate/merge repair, not complete reading-anchor delivery:
  visible content-block anchors, within-block relocation and cross-mode semantic
  position conversion remain pending, together with the broader plan backlog.

### Global dirty-preview scheduling

- Added durable dirty-root discovery across directory, custom and graph roots.
  Roots with unfinished tasks are excluded so automatic repair does not resume
  user-paused tasks. Startup and two-second polling recover missed wakeups.
- DirtyPreviewScheduler coalesces unchanged signatures, serializes rebuilds,
  stops dispatch on shutdown and drains its active task. It reuses durable node
  preview tasks with force=false; failed signatures do not spin within a process.
- Node override references now propagate dirty marks through a deduplicating
  recursive dependency query, including cross-collection references and cycles.
  Entity preview publication also invalidates explicit override consumers.
- Automatic frontend refresh callbacks now wake the scheduler instead of forcing
  additional revisions; explicit manual rebuild remains available.
- Validation: full 106 tests and analyze passed before final callback routing;
  targeted follow-up covers scheduler, publication and shell behavior.
- Remaining: full capability separation, Runtime/session ownership, reflow
  anchors, recursive browse cache/selection predicates, toolbar consolidation,
  pressure tests and releases. Cross-root dependency publication ordering needs
  further acceptance coverage; no claim of whole-plan completion.

### Original-image decode admission

- Read encoded image dimensions through ImageDescriptor before speculative
  decode. Reserve width * height * 4 against half the global image cache budget;
  remove farthest neighbors first, preserving the displayed image. Retain the
  global ImageCache byte limit and six-image window.
- The admission policy is a pure browser module function with regressions for
  distance ordering and an oversized displayed image. Header buffers/descriptors
  are disposed; SAF provider keys are tracked for actual eviction.
- Targeted budget and shell tests passed (3 tests). This bounds decoded prefetch
  admission, not native encoded-buffer memory or the necessary displayed image.

### Runtime, source cancellation, reconciliation and navigation integration

- Bootstrap is tracked and drained during shutdown; services finishing startup
  after shutdown begins are closed instead of attached. Browse thumbnail close
  now drains active operations before database shutdown.
- Android materialization uses request IDs, exactly-once replies and cancellation.
  Cancellation attempts to close the input stream off the UI thread; late files
  and partial copies are removed. Build audio/document reads pass their token.
  A provider blocked before returning its stream can still finish internally.
- Directory reconciliation uses indexed manifest SQL and a temporary stale-ID
  relation instead of collecting the entire manifest in Dart. Validation rejects
  incomplete writes/wrong scopes; unrelated collection references survive.
- Removed pet controllers, UI, bindings, packed assets and obsolete home page.
  Sidebar has five destinations; recent media and collection kinds use in-page
  choices, diagnostics is reached through settings. Task-page management still
  needs relocation to its owning source; old pet user config is not yet cleaned.
- Original prefetch tracks decoded bytes and evicts farthest neighbors over half
  the global cache budget, including SAF paths. This is post-decode enforcement;
  pre-decode peak admission remains pending. PDF stops writing pages as pixels
  and records a versioned position object, retaining legacy page restoration.
- Validation: full 100 tests and analyze passed before the final browse-close
  change; Kotlin compilation passed. After browse-close and cleanup changes,
  analyze and 15 runtime/navigation/repository/shell tests passed.
- Not complete: full service ownership, viewer registration, module capabilities,
  dirty-node scheduler, recursive session cache/selection predicates, reflow
  anchors, toolbar consolidation, pressure tests and release artifacts.

### Runtime shutdown coordinator foundation

- Added AppRuntime with ordered shutdown phases, idempotent shared completion,
  registration rejection after closing, and aggregated per-service failures.
- AppShell registers scheduler/build, audio, thumbnail, reader, writer and log
  shutdown. A failed service no longer prevents subsequent cleanup. Failures
  are recorded before diagnostics closes; read startup is drained before writer
  shutdown. New bootstrap/read-worker startup is rejected during closing.
- Validation: analyze clean; both runtime tests and shell regression passed.
- This is the shutdown coordinator foundation, not complete Runtime ownership:
  service construction, overlay session registration, bootstrap cancellation and
  native source-copy cancellation still require integration. No release build,
  tablet installation or remote push performed in this step.

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
