# FileSyncStore v2 migration design

## Status

`draft`

- Date: 2026-09-14
- Parent ADR: [Sync store persistence scaling](sync-store-persistence.md)
- Production baseline remains schema v1 in `Sources/HealthMuleCore/Sync/FileSyncStore.swift`

This document is **not** production authorization. It does not change
`FileSyncStore`, the on-disk schema, or the export JSON contract. A later
implementation plan is required after human review of this design, plus the
proof listed below.

## Goal

Split bulk semantic and content bytes out of the monolithic `sync-state.json`
index so each `stageDaily` no longer rewrites every prior artifact’s payload.
Keep a small atomic metadata index. Preserve artifact-first staging, exact
local and uploaded revisions, retry/block/manifest-refresh state, cancellation-
safe recovery, canonical encoding, explicit JSON nulls, unknown fields, iOS
file protection, backup exclusion, and Foundation-only `HealthMuleCore`.

Do not adopt SQLite unless a reviewed file-based v2 fails those constraints.

## On-disk contract

**Recommendation** (not decided): keep `daily/<date>.json` as the sole content
bytes for daily artifacts. Do not add a second sidecar copy of the record body.

**Recommendation** (not decided): replace `ArtifactState.semanticData` and
`contentData` with fixed-size digests plus byte lengths:

| Field | Role |
|---|---|
| `id` | unchanged `ExportArtifactID` |
| `localRevision` / `uploadedRevision` | unchanged |
| `semanticDigest` | SHA-256 of `DailyHealthRecordCodec.semanticData` |
| `contentDigest` | SHA-256 of canonical encoded artifact bytes |
| `contentByteCount` | encoded size, for cheap mismatch detection |

**Recommendation** (not decided): store those fields in `sync-state.json` with
`schemaVersion: 2`. Manifest and other non-daily artifacts keep their existing
artifact files; the index holds only digests for them as well.

Draft names (replace only in an implementation plan):

- `sync-state.json` — v2 metadata index
- `daily/<date>.json` — canonical daily artifact (unchanged path)
- `manifest.json` — canonical manifest artifact (unchanged path)
- `sync-state.v1.json` — retained v1 index during migration, never deleted
  until every artifact, revision, and retry item has round-tripped

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

Recommended sequence (still not authorized):

| State | On disk | Reader |
|---|---|---|
| `v1-only` | `sync-state.json` schema 1 | current app |
| `v2-building` | v1 index untouched; v2 index in a temp name under the same protected root | current app ignores the temp file |
| `v2-published` | atomic rename of the temp v2 index to `sync-state.json`; v1 copy kept as `sync-state.v1.json` | new app |
| `rolled-back` | restore `sync-state.v1.json` over `sync-state.json` | older app |

Older app after `v2-published`: `schemaVersion != 1` currently throws
`unsupportedStateVersion`. **Recommendation**: keep a v1 copy until the
compatibility window ends, and teach the old binary nothing. If a user
installs an older build, that build must see v1 at `sync-state.json`.
Therefore v2 publication should not overwrite `sync-state.json` until the
shipping app can both read v2 *and* the product has accepted dropping older
builds — or the new app dual-writes v1 until that window closes.

**Recommendation** for the compatibility window: dual-write v1 and v2 until
the next app version that refuses v1, then stop writing v1. Dual-write keeps
constraint 5 without teaching old binaries a new schema. Measure dual-write
cost against the ADR tables before committing to it in code.

Interruption: each step is idempotent. Re-running migration from `v1-only`
rebuilds the temp v2 index from artifacts plus the v1 revision/retry fields.
It must not bump `localRevision` merely because the digest was computed
again.

## Corruption behavior

- Unreadable artifact JSON: fail `recover()` with the existing invalid-artifact
  path. Do not delete files.
- Unreadable v2 index: if `sync-state.v1.json` exists, rebuild v2 from v1 plus
  artifact files into temp storage; do not publish until validation passes.
- Digest mismatch with a readable artifact: treat as a local content change
  (revision bump + retry), matching v1’s payload mismatch.
- `schemaVersion` other than 1 or 2: fail closed (`unsupportedStateVersion`).
- Partial temp index: ignore and rebuild.

Never log record bodies, health values, paths, tokens, or identifiers.

## Proof required before any production PR

- Re-run `./scripts/swift.sh run -c release SyncStoreBenchmark` with the same
  four-field CSV, locale hardening, and redaction rules as the parent ADR.
- Target: cumulative state bytes grow linearly with day count, not with the
  square of day count, on the 30 / 90 / 365 / 1,825 empty-record matrix.
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
| Digest algorithm | SHA-256 | recommendation |
| Store full digest vs truncated | full 32-byte digest, hex in JSON | recommendation |
| Extra semantic sidecar files | no; derive from `daily/*.json` | recommendation |
| Dual-write v1 during compatibility | yes, until an explicit drop-old-builds release | recommendation |
| SQLite | out unless file-based v2 fails proof | rejected for now |
| PERF-03 decode-all-records | independent of this design | out of scope |

## Follow-up

Implementation, if authorized, is a new plan: characterization tests first, no
schema flip in the same change as unrelated HealthKit or Drive work.
