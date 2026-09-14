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
