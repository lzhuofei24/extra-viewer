# Database optimization execution record

## Current storage policy (schema 14)

The user explicitly discarded old library data and migration requirements.
Schema 14 directly creates schema_current.dart; schema 6-13 migration scripts,
legacy asset registration and upgrade/snapshot tests have been removed.
Recognized older file-backed libraries are reset on first open, together with
their exact app-generated database sidecars, backups and preview caches. A
reset marker permits retry after interruption. Current-version libraries and
unknown/future databases are not automatically reset. Original source files,
signing keys and appearance preferences are not cleanup targets.

Reading state now stores document revision, chapter, page, block anchor and
offset in typed columns. Only remaining reader preferences use settings_json;
entity_details reconstructs the existing UI DTO without dual-writing anchors.
Boolean/range/enumeration CHECK constraints and parent-type guards are part of
the fresh schema. System favorites and five rules are seeded exactly once.

The sections below are historical implementation evidence, not the current
migration policy. Migration-chain preservation/fault acceptance is cancelled.
The broader runtime performance and asset-lease tasks remain separate work.

Validation: static analysis passed, all 194 current tests passed, and signed
Android arm64 Release APK built successfully. No device was connected. The
explicit desktop legacy-data deletion command was rejected by automatic
approval policy ("blocked by policy"); those desktop files were not deleted.
Device data will only be reset when this version opens an older recognized
library. No push or installation was performed.

## Scope

Preserve entity IDs, user relationships, rules, playback/reading state and
immutable preview assets. Original sources remain read-only. No push or device
installation is authorized for this change.

## Baseline

Baseline commit: d502c4e, schema 9. Existing Windows-host synthetic probe:
130,000 entities; listRules 102 ms; frequent first page 14 ms; remaining pages
through 1,000 results 121 ms. SQLite reports a temporary B-tree for the final
two frequent-sort terms. This single run is not an Android performance claim.

## Delivery sequence

1. Schema 10: validated migration snapshots, explicit rule scope state,
   constraints, query revisions, dirty statistics and aligned indexes.
2. Schema 11: separate progress/previews, asset variants, relational cover
   overrides, and remove obsolete storage fields.
3. Query summaries, bounded stable sessions, node pagination, local statistics,
   supervised foreground/background reads and idle maintenance.
4. Schema 12: source identity and entity locations, preserving legacy IDs.
5. Full regression, performance comparison and signed arm64 APK.

## Acceptance

Each completed stage records its tests and commit. Migration failures must not
reset the library. Dynamic browse sessions keep membership/order fixed until
refresh. Missing rule scopes must never become unrestricted. Android latency,
SAF permission and removable-media acceptance remain device-only checks.

## Status

- Baseline committed as f3ee5d5.
- Schema 10 safety/index phase: explicit missing scopes, database-protected
  system nodes, ancestry-cycle guard, metadata/rule guards, revision batching,
  dirty statistics, verified unique snapshots and aligned rule indexes.
- Validation: static analysis passed; complete suite passed (174 tests).
  The frequent query plan no longer contains a temporary sort B-tree.
- Schema 11: progress and preview fields moved out of entities; read-only
  entity_details projects existing DTOs without duplicated storage. Cover
  references are ordered foreign-key rows; asset files have explicit variants.
- Rule and recursive browsing use bounded SQLite temporary ordered-ID sessions
  (six sessions, 128 MiB page limit) instead of recomputing every page. These
  currently run in the existing reader; separate scheduling remains pending.
- Read-worker exit/close now fails all pending requests immediately.
- Validation after these changes: full suite passed (180 tests).
- Schema 12: source/location identity records, SAF opaque IDs, URI-alias
  matching during single and batched ingest, and explicit collision state.
  Each schema upgrade now has its own verified snapshot and transaction.
- Validation: analysis and full suite passed (181 tests).
- Query scheduling: rule definitions return without counts; summaries/covers
  load in batches of eight on a separate background reader. Foreground search
  uses rank/name/ID cursors and one batched breadcrumb CTE per page.
- Statistics now recompute dirty ancestors only, including archive and node
  movement invalidation. Duplicate category references count once. Computation
  is still synchronous in the writer; background revision-gated publication
  is not yet delivered.
- Validation: analysis passed; full suite passed (185 tests). Android arm64
  release build succeeded (44,172,599 bytes). No push or device installation.
- Windows synthetic probe, 30 warm first-page requests per dataset:

  | Entities | Rule definitions | First page | Warm P95 | Remaining pages |
  | --- | --- | --- | --- | --- |
  | 1,000 | 12 ms | 22 ms | 6.54 ms | 26 ms |
  | 10,000 | 1 ms | 4 ms | 6.49 ms | 38 ms |
  | 130,000 | 1 ms | 5 ms | 5.60 ms | 48 ms |

  Requests include isolate transport; results are capped at 1,000. The first
  page includes session creation, not application cold startup. Query plans
  use idx_entities_visible_open_count without a temporary sort. At 130k the
  database is 78,487,552 bytes, WAL 79,038,112 bytes after bulk fixture creation,
  and process RSS 248,844,288 bytes (test process, not Android application peak).
  This fixture does not establish recursive 130k snapshot latency, scanning
  concurrency, failure injection, checkpoint recovery or Android targets.
- Background follow-up: read workers recreate failed connections on the next
  request, sharing a single recovery for concurrent callers. Reader-exit,
  repeated recovery and shutdown-during-recovery tests pass. Forced native
  isolate termination still needs handle-release hardening: the Windows fault
  probe observed a locked SQLite file after killing an isolate.
- Statistics run on the existing background reader in batches of 32, then the
  writer publishes only matching dirty revisions. Re-dirtying after publication
  advances beyond the saved revision, preventing stale replay. The app cancels
  maintenance scheduling immediately on disposal. Standalone repositories retain
  synchronous refresh for tooling; application writes use deferred statistics.
- Rule counts/covers cache by query revisions, with exact relative-time expiry.
  Reading progress does not invalidate it. The LRU has a 20,000-entry and 16 MiB
  encoded-payload budget (not a measured heap bound). Writer batches share a
  64-statement LRU; failed statements are disposed and recreated on retry.
- Ordered-ID sessions now live in an independently attached cache database;
  initial rule/recursive snapshots build on the background reader, subsequent
  pages use the interactive reader. The library attachment is SQLite read-only.
  Runtime cache file locks protect live sessions from startup orphan cleanup;
  normal close removes cache files. The six-session LRU still lacks explicit
  active-view pins, and the 128 MiB page budget excludes transient WAL overhead.
- Validation after this follow-up: static analysis passed; complete Flutter
  suite passed (196 tests), including concurrently developed UI changes.
- Schema 13 follow-up: remove the fixed index_nodes.view_type column and all
  runtime SQL reads/writes of it. A new version, with its own verified snapshot,
  is necessary because schema-12 APKs have already been produced. SQL DROP
  COLUMN preserves rowid; migration tests compare exact node rowids/names and
  FTS matches, along with foreign keys. The tree-only DTO field remains a
  compatibility adapter, not duplicated database storage. Legacy migration
  definitions retain the old column so upgrades from actual old schemas work.
- Validation: static analysis passed and all 197 Flutter tests passed.
- Remaining: queued-request cancellation, active-session pins and total disk
  budget enforcement, native crash resource cleanup, folder pagination,
  clean final-schema creation baseline, structured reading-anchor extraction, asset
  leases/retirement integration, lean DTO projections, migration-chain fault
  hardening, source reauthorization acceptance, and expanded performance/device
  acceptance. Schema version 12 alone does not mean the full plan is complete.
