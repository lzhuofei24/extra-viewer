# Modular refactor execution log

## Contract

Implement the approved seven-module plan. Preserve source files, existing user
data, IDs, references and preview assets. Use incremental schema 5 -> 6.
Local commits only; no push or tablet installation. Keep release signing compatible.

## Baseline

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
