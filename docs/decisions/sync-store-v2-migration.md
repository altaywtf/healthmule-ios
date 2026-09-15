# FileSyncStore v2 migration design

## Status

`implemented`

- Date: 2026-09-15
- Parent ADR: [Sync store persistence scaling](sync-store-persistence.md)
- Production baseline is schema v2 in `Sources/HealthMuleCore/Sync/FileSyncStore.swift`

The live index is schema 2. Recover still reads schema 1, copies it to
`sync-state.v1.json` once, and publishes v2 atomically. Older builds cannot
read a v2 `sync-state.json`. Restoring the frozen v1 copy is a pre-migration
rollback only; later days recover from artifact files.

Live dual-write of v1 was rejected: it would restore the quadratic rewrite the
parent ADR measured.

## Goal

Split bulk semantic and content bytes out of the monolithic `sync-state.json`
index so each `stageDaily` no longer rewrites every prior artifact’s payload.
Keep a small atomic metadata index. Preserve artifact-first staging, exact
local and uploaded revisions, retry/block/manifest-refresh state, cancellation-
safe recovery, canonical encoding, explicit JSON nulls, unknown fields, iOS
file protection, backup exclusion, and Foundation-only `HealthMuleCore`.

Do not adopt SQLite unless a reviewed file-based v2 fails those constraints.

## On-disk contract

Keep `daily/<date>.json` as the sole content bytes for daily artifacts. Do not
add a second sidecar copy of the record body.

Replace `ArtifactState.semanticData` and `contentData` with fixed-size digests
plus byte lengths:

| Field | Role |
|---|---|
| `id` | unchanged `ExportArtifactID` |
| `localRevision` / `uploadedRevision` | unchanged |
| `semanticDigest` | SHA-256 of `DailyHealthRecordCodec.semanticData` |
| `contentDigest` | SHA-256 of canonical encoded artifact bytes |
| `contentByteCount` | encoded size, for cheap mismatch detection |

Those fields live in `sync-state.json` with `schemaVersion: 2`. Manifest and
other non-daily artifacts keep their existing artifact files; the index holds
only digests for them as well.

Names:

- `sync-state.json` — v2 metadata index
- `daily/<date>.json` — canonical daily artifact (unchanged path)
- `manifest.json` — canonical manifest artifact (unchanged path)
- `sync-state.v1.json` — frozen v1 index written once at migration
- `sync-state.v2.tmp.json` — ignored and deleted if present after interruption

Sidecar-per-artifact copies of `semanticData`/`contentData` are rejected: they
would duplicate `daily/*.json` and reintroduce rewrite amplification.

## Artifact-first staging and atomic publication

v1 writes the artifact file, then atomically rewrites the whole index. v2 keeps
that order:

1. Encode the candidate with the current codec (nulls and unknown fields
   preserved).
2. Write or replace the artifact file atomically with the same iOS protection
   and backup-exclusion policy as today.
3. Compute digests from the bytes that landed on disk.
4. Publish a new index with one atomic write of `sync-state.json`.

Semantic no-op detection compares digests, not embedded payloads. If the
artifact file matches the indexed digests, `stageDaily` returns `.unchanged`
without bumping revision.

Retry queue, `manifestNeedsRefresh`, and revision counters stay in the index.
They are not derived from Drive.

## Recovery after crash between artifact write and index publish

v1 recovery already walks `daily/*.json`, re-encodes, and compares against
index payloads. v2 recovery:

1. Load the last published v2 index if present and `schemaVersion == 2`.
2. Walk artifact files. For each file, decode, re-encode, hash.
3. If the file is missing from the index, or digests differ, treat it as a
   new local revision (same bump rules as v1) and enqueue retry.
4. If the file is absent but the index still lists it, drop the index row
   only when v1 would have (manifest invalidation already has this case).
5. Do not invent uploaded revisions. `uploadedRevision` comes only from the
   last published index.

A crash after artifact write and before index publish is therefore a digest
mismatch on the next `recover()`, which restages rather than skipping upload.

## Migration states

The parent ADR rollback constraints remain mandatory:

1. Continue reading schema v1 until a v2 migration has been fully verified.
2. Build v2 state in temporary protected storage and publish it atomically.
3. Preserve the v1 state until every artifact, revision, and retry item has
   round-tripped through v2 validation.
4. Make interruption at every migration step safe to retry without revision
   changes or duplicate uploads.
5. Define how an older app recovers or rolls back after v2 publication; a
   one-way version flip without a compatibility path is not acceptable.
6. Re-run the fixed `SyncStoreBenchmark` and the complete `FileSyncStore`
   correctness suite before the migration can be proposed for release.

Implemented sequence:

| State | On disk | Reader |
|---|---|---|
| `v1-only` | `sync-state.json` schema 1 | this app migrates on recover |
| `v2-published` | v2 at `sync-state.json`; frozen v1 at `sync-state.v1.json` | this app |
| `rolled-back` | restore `sync-state.v1.json` over `sync-state.json` | older app, pre-migration only |

This app reads schema 1 or 2. It writes schema 2. It does not dual-write a live
v1 index. An older build that only accepts schema 1 must not be installed over
a v2 index. Operator rollback is restore the frozen v1 copy (loses post-migration
revisions) or delete `sync-state.json` and recover from artifact files.

Interruption: each step is idempotent. Re-running migration from `v1-only`
rebuilds v2 from artifacts plus the v1 revision/retry fields. It must not bump
`localRevision` merely because the digest was computed again.

## Corruption behavior

- Unreadable artifact JSON: fail `recover()` with the existing invalid-artifact
  path. Do not delete files.
- Unreadable v2 index: if `sync-state.v1.json` exists, rebuild v2 from v1 plus
  artifact files; do not publish until validation passes.
- Digest mismatch with a readable artifact: treat as a local content change
  (revision bump + retry), matching v1’s payload mismatch.
- `schemaVersion` other than 1 or 2: fail closed (`unsupportedStateVersion`).
- Partial temp index: ignore and rebuild.

Never log record bodies, health values, paths, tokens, or identifiers.

## Proof required before any production PR

- Re-run `./scripts/swift.sh run -c release SyncStoreBenchmark` with the same
  four-field CSV, locale hardening, and redaction rules as the parent ADR.
- Target: final state bytes grow linearly with day count. Cumulative bytes stay
  quadratic at a smaller constant while the atomic index is rewritten in full.
- Full `FileSyncStore` suite, including cancellation, semantic equality,
  unknown-field preservation, and destination republish.
- Characterization tests that pin v1 → v2 revision and retry identity for
  interrupted migration.

## Privacy

Same redaction rules as the parent ADR. Benchmark and test output stay
four-field CSV plus pass/fail. No hostname, serial, local path, record body,
health value, temporary identifier, or real export data.

## Open questions

| Question | Recommendation | Status |
|---|---|---|
| Digest algorithm | SHA-256 | accepted |
| Store full digest vs truncated | full 32-byte digest, hex in JSON | accepted |
| Extra semantic sidecar files | no; derive from `daily/*.json` | accepted |
| Dual-write v1 during compatibility | no; freeze v1 at migration | accepted |
| SQLite | out unless file-based v2 fails proof | rejected for now |
| PERF-03 decode-all-records | independent of this design | out of scope |
