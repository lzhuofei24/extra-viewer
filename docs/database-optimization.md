# Database optimization execution record

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
- Remaining: schema 11/12, bounded sessions, split read scheduling, local
  statistics publication and expanded performance/device acceptance.
