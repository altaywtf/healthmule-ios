# Sync store persistence scaling

## Status

`implemented`

- Date: 2026-07-30
- Production baseline: schema v2 as of the FileSyncStore digest-index change
- Benchmark implementation: `af54e46`, output hardening: `83c7f56`

Schema v1 remains readable on recover. The live index is schema v2.

Follow-up:
[FileSyncStore v2 migration design](sync-store-v2-migration.md).

## Command

```sh
./scripts/swift.sh run -c release SyncStoreBenchmark
```

The command was run twice from the same clean benchmark source. Each reported
row is the median of three isolated trials. Every trial used a unique temporary
directory, deterministic empty synthetic records, and the public
`FileSyncStore.stageDaily` API. The benchmark read only the byte size of
`sync-state.json` after each stage and removed its temporary directory.
After review hardening, a third run under a comma-decimal locale preserved the
same four-field CSV shape and byte results; it is verification rather than an
input to the decision tables.

Sanitized environment:

- Apple M5 Pro, arm64
- macOS 26.5.2
- Apple Swift 6.3.3
- release configuration

No hostname, serial number, local path, record body, health value, temporary
identifier, or real export data was captured.

## v1 results

Run 1:

| Days | Median elapsed (ms) | Final state bytes | Cumulative state bytes |
|---:|---:|---:|---:|
| 30 | 14.733 | 38,027 | 590,535 |
| 90 | 62.928 | 113,927 | 5,187,105 |
| 365 | 657.795 | 461,802 | 84,523,780 |
| 1,825 | 14,048.977 | 2,308,702 | 2,107,915,150 |

Run 2:

| Days | Median elapsed (ms) | Final state bytes | Cumulative state bytes |
|---:|---:|---:|---:|
| 30 | 15.261 | 38,027 | 590,535 |
| 90 | 68.129 | 113,927 | 5,187,105 |
| 365 | 640.246 | 461,802 | 84,523,780 |
| 1,825 | 14,176.319 | 2,308,702 | 2,107,915,150 |

Scaling:

| Range | Day-count ratio | Cumulative-byte ratio | Run 1 elapsed ratio | Run 2 elapsed ratio |
|---|---:|---:|---:|---:|
| 90 / 30 | 3.000 | 8.784 | 4.271 | 4.464 |
| 365 / 90 | 4.056 | 16.295 | 10.453 | 9.398 |
| 1,825 / 365 | 5.000 | 24.939 | 21.358 | 22.142 |

Final state size is effectively linear at 1,267.57, 1,265.86, 1,265.21, and
1,265.04 bytes per day. Cumulative bytes closely track the square of the
day-count ratios because every stage rewrites all prior artifact state.
Elapsed results varied by at most 7.9% between the two samples and show the same
superlinear curve.

## v2 results

Same command, machine class, four-field CSV, and empty synthetic records after
the digest-index change. One release run:

| Days | Median elapsed (ms) | Final state bytes | Cumulative state bytes |
|---:|---:|---:|---:|
| 30 | 17.321 | 11,717 | 182,730 |
| 90 | 105.212 | 34,997 | 1,595,790 |
| 365 | 580.048 | 141,697 | 25,944,565 |
| 1,825 | 11,541.472 | 708,177 | 646,635,825 |

Final state size stays linear at about 388 bytes per day. Cumulative writes
remain Θ(n²) because each `stageDaily` still rewrites the whole index; the
constant dropped about 3.3× versus v1 (2.11 GB → 647 MB at 1,825 days). Elapsed
time at 1,825 days improved only modestly (14.1 s → 11.5 s); encoding each new
daily artifact still dominates.

## Correctness and privacy constraints

Any replacement must preserve:

- artifact-first staging and atomic state publication;
- exact local and uploaded revisions plus retry, block, and manifest-refresh
  state;
- cancellation-safe and idempotent recovery after interruption;
- canonical record encoding and semantic equality behavior;
- explicit JSON nulls and unknown record fields;
- iOS file protection and backup exclusion on every persisted component;
- Foundation-only, deterministic `HealthMuleCore` behavior;
- no logs or benchmark output containing record bodies, health values,
  metadata, paths, tokens, or identifiers.

## Alternatives

### Retain monolithic JSON

This preserves the simplest recovery model and requires no migration. It also
retains full semantic and content bytes for every artifact in each atomic state
rewrite. The measured cumulative writes and latency make this unsuitable as the
long-term format.

### Split content bytes from state

Keep a small atomic metadata index while moving per-artifact semantic/content
material to protected sidecars or deriving it from the existing canonical
artifact files. This directly targets the measured amplification while
retaining file-based recovery and avoiding a database dependency. It is the
preferred direction for a state-v2 design investigation.

### Append journal

An append-only journal reduces steady-state rewrites, but introduces replay,
compaction, partial-tail recovery, and bounded-growth contracts. Those new
correctness surfaces need stronger justification than the split-state option.

### SQLite

Transactions and incremental updates address amplification, but add a database
boundary, migration tooling, backup handling, and more operational complexity.
It should be reconsidered only if the file-based v2 design cannot meet
correctness or performance goals.

## Decision

The evidence required a file-based v2 index that stores SHA-256 digests instead
of embedding every artifact payload. Final index size is linear. Cumulative
writes stay quadratic at a smaller constant because the atomic index is still
rewritten in full. SQLite stays out unless a later proof needs incremental
writes.

## Rollback and migration constraints

The v2 implementation satisfies:

1. Recover still reads schema 1.
2. v2 is published with an atomic write of `sync-state.json`.
3. The original v1 bytes are copied once to `sync-state.v1.json`.
4. Re-running migration does not bump revisions merely to recompute digests.
5. Older builds cannot read v2. Rollback is restore the frozen v1 copy
   (pre-migration only) or delete the index and recover from artifact files.
6. Re-run this fixed benchmark and the complete `FileSyncStore` suite on the
   digest index.
