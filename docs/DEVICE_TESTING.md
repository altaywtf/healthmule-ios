# Physical-device testing

Use a real iPhone for HealthKit authorization, observer delivery, and
background-behavior acceptance. Use a paired real Apple Watch to prove
background Watch Connectivity delivery. Simulator checks remain useful for both
app shells and deterministic contracts, but they do not prove those delivery
boundaries.

`make harness` is the unattended Simulator lane for agents and CI-capable Macs.

- It boots its selected iPhone Simulator and launches the app through critical
  loading, sync, failure, and automatic-activity fixtures.
- It asserts their visible contracts and exports screenshots with an xcresult
  summary under `.artifacts/agent-harness`.
- The fixtures contain no personal health data or Google credentials.
- They complement, never replace, the physical-device checks in this document.

## Current readiness

| Surface | Status |
| --- | --- |
| Signed install and adaptive Home/Settings shell | Implemented |
| Read-only HealthKit authorization and status display | Implemented |
| Google sign-in and managed Drive-folder discovery or creation | Implemented |
| Daily aggregation, initial backfill, and manual sync | Implemented; signed-device and real-Drive proof pending |
| HealthKit observer changes flowing into staged daily records | Implemented; physical background-delivery proof pending |
| File-backed background upload and relaunch recovery | Implemented; physical interruption proof pending |
| Bounded automatic-activity receipts and schedule status | Implemented; physical cadence proof pending |
| Watch status and reachable sync requests | Implemented; paired-device proof pending |

Implemented rows describe live code paths, not completed platform acceptance.
They still require the signed-device scenarios below.

## Proof matrix

| Behavior | Simulator | Physical iPhone | Paired Watch |
| --- | --- | --- | --- |
| App shell, fixtures, `make harness` | yes | n/a | n/a |
| Deterministic export and sync contracts | `make test-core` | n/a | n/a |
| Foreground HealthKit authorization and queries | fixtures only | required | n/a |
| Daily aggregation, staging, Drive upload | fixtures / mocked Drive | required | n/a |
| HealthKit background observer delivery | no | required | n/a |
| Lock-state protected files, process-surviving uploads | no | required | n/a |
| Reachable Watch sync request | `canRequestSync` is false | n/a | required |
| Background application-context and user-info snapshot | no | n/a | required |

Simulator gates never claim real `HKHealthStore`-to-Drive proof or Watch
Connectivity delivery.

## Prerequisites

- A physical iPhone running iOS 26 or later.
- A paired Apple Watch running watchOS 26 or later for companion acceptance.
- Full Xcode with an Apple Development team capable of signing the app.
- A native iOS Google OAuth client configured as described in
  [Google OAuth setup](GOOGLE_OAUTH.md).
- Health data suitable for the scenario being tested.
- A clean local verification run:

  ```sh
  make verify-full
  ```

## Build and install

1. Create the ignored local signing configuration and set the bundle identifier
   and Apple Development team:

   ```sh
   cp Config/Signing.xcconfig.example Config/Signing.xcconfig
   ```

   The bundle identifier must also match the native iOS Google OAuth client.
2. Generate the Xcode project:

   ```sh
   make project
   ```

3. Open `HealthMule.xcodeproj`.
4. Confirm the HealthKit and Background Delivery capabilities remain present.
5. Select the physical iPhone, build, and run.

The embedded companion installs on the paired Apple Watch. Its bundle ID is the
iPhone bundle ID plus `.watchkitapp`; it has no HealthKit or Google capability.

Do not use a personal production Drive account for destructive or
failure-injection scenarios.

## Onboarding and permissions

- [ ] Launch from a fresh install and confirm the Home and Settings tabs appear.
- [ ] From Home, open Setup, Sync details, and per-metric Health Data status; confirm each drill-in returns to Home and does not obscure content with the tab bar.
- [ ] Confirm the app requests read-only HealthKit access; it must not request write access.
- [ ] Disable Sleep and Body Mass before the first request and confirm the
  authorization sheet omits both types; their status cards must say Not
  included and no observer/query may be registered for them.
- [ ] Enable one of those types afterward and confirm setup changes to Review
  needed; the type must say Not requested and remain excluded from sync until
  the follow-up Health request completes.
- [ ] Grant all requested types and confirm the status screen can surface readable samples.
- [ ] Repeat after denying at least one type. The UI must not claim that read access was denied: HealthKit intentionally does not disclose read-denial state, so “No readable data” is the expected ambiguous state.
- [ ] Make the Health authorization-status query fail temporarily and confirm
  the UI shows Check failed rather than Request complete. A previously
  completed request may continue querying visible types; a never-completed
  request must remain blocked.
- [ ] Connect Google and confirm `Apple Health Sync` and its `daily` child folder are discovered or created.
- [ ] Move the managed root folder elsewhere within My Drive, relaunch the app, and confirm it is still found by ID or app properties rather than by path alone.
- [ ] Trash or delete the managed root or `daily` folder, choose Try Drive
  Again, and confirm a coherent replacement tree receives every local day and a
  fresh manifest. No upload may remain attached to the old folder.
- [ ] Switch to a second Google account and confirm every locally staged day
  plus a fresh manifest is published there before the app reports Up to date.
  Switch back and confirm stable IDs prevent duplicate logical files.

## Foreground sync acceptance

The daily provider, app-to-core reconciliation, protected staging, and Drive
destination are implemented. Run these checks on a signed physical build with a
configured OAuth client and integration Drive account.

- [ ] An initial 30-day backfill creates one deterministic daily JSON object per calendar date and a manifest.
- [ ] During that backfill the progress bar advances through both phases: it
  counts days while staging, then counts files while uploading. It must not sit
  pinned at 100% for the duration of the upload.
- [ ] Retry pending uploads shows upload progress rather than no progress bar.
- [ ] Running sync again without source changes creates no duplicate file and no semantic rewrite.
- [ ] Adding or editing a workout updates only affected dates and the manifest.
- [ ] Missing or unreadable values are encoded as explicit `null` values rather than omitted fields.
- [ ] Sleep intervals are unioned without double-counting overlaps.
- [ ] Workouts are deduplicated and totals are deterministic.
- [ ] Exported data contains no raw routes, heart-rate samples, or other unapproved health fields.
- [ ] The manifest is updated only after all corresponding daily current files succeed.

## Apple Watch companion acceptance

- [ ] On a first Watch launch before any snapshot arrives, confirm the headline
  says Waiting for iPhone and Retry iPhone is available. It must not say Ready
  or spin indefinitely.
- [ ] Launch the Watch app and confirm it shows only readiness, sync activity,
  last-success time, and queue counts. No health values, account details, Drive
  IDs, or error strings may cross the companion message.
- [ ] Create pending, retryable, and blocked work on the iPhone and confirm the
  Watch shows each nonzero count as an independent row while preserving Last
  confirmed when one exists.
- [ ] With the iPhone reachable, tap Sync and confirm the Watch reports that
  the request was accepted before the iPhone completes reconciliation.
- [ ] Disable reachability and confirm Sync is unavailable rather than
  claiming that work was queued or completed. The headline must say Phone
  Unavailable and must not say Up to Date.
- [ ] Leave a previously synced snapshot without a phone update for more than
  30 minutes and confirm the Watch labels it out of date while retaining its
  last confirmed time and counts. It must not say Up to Date.
- [ ] Restore reachability, request another sync, and confirm the iPhone's
  existing reconciliation path publishes a fresh status snapshot.
- [ ] Leave the Watch app, allow background delivery, and confirm the latest
  snapshot appears after reopening it. The iPhone publishes that snapshot
  through application context and a queued user-info transfer.

## Background acceptance

HealthKit observer staging, `BGAppRefreshTask` reconciliation, and protected
file-backed Drive transfer are implemented but still require physical-device
proof. The app reconnects its background `URLSession` on a matching system
launch event and reconciles completed or interrupted work through the durable
queue.

- [ ] With the app backgrounded, add a relevant Health sample and confirm the affected daily record is eventually updated.
- [ ] Trigger an app-refresh task and confirm the Sync screen records one
  Background refresh receipt with its outcome. Confirm the schedule row reports
  Submitted, Existing request kept, or a closed failure reason. A receipt proves
  that the app observed an opportunity or requested scheduling; it does not
  prove prompt, periodic, or future execution.
- [ ] Interrupt connectivity during an upload and confirm retry preserves the same logical operation without duplicate Drive files.
- [ ] While an upload is waiting for connectivity, switch accounts or replace
      the managed folder tree. Confirm the app does not report the new
      destination Connected until the old transfer receives a definitive HTTP
      response. If draining times out, confirm Drive remains temporarily
      unavailable for retry rather than optimistically activating the new tree.
      Reconnect the unchanged destination separately and confirm its transfer
      remains scheduled.
- [ ] Leave connectivity unavailable for more than 15 seconds and confirm the
      visible sync operation returns to a pending/retry state while the
      background transfer remains scheduled.
- [ ] Lock the device during staging and confirm protected files are handled safely after the first unlock.
- [ ] Terminate the process during an upload and confirm a file-backed background transfer can be reconciled after relaunch.
- [ ] Force-quit the app and confirm documentation and UI do not promise background execution before the next launch.

For development-only task simulation, attach LLDB to the running app and use Apple’s private debug selector:

```text
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"dev.uinaf.healthmule.refresh"]
```

The current handler runs the integrated reconciliation and in-process queue
flush while iOS grants execution time. It does not prove HealthKit observer
delivery, a process-surviving upload, or relaunch recovery. See Apple’s
[Starting and Terminating Tasks During
Development](https://developer.apple.com/documentation/backgroundtasks/starting-and-terminating-tasks-during-development).

## Privacy and resilience

- [ ] Console logs contain no health values, OAuth tokens, Drive file bodies, or raw HealthKit metadata.
- [ ] Shared diagnostics remain bounded and redact sensitive fields.
- [ ] Protected outbox, anchor, saved day-boundary, and automatic-activity
  receipt files use data protection and remain excluded from backups.
- [ ] Automatic-activity receipt JSON remains bounded to 20 entries and contains
  no health values, record bodies, raw metadata, OAuth tokens, account details,
  or Drive identifiers.
- [ ] Disconnecting or resetting local state does not delete existing Drive exports.
- [ ] Revoking Google access returns the app to a recoverable Reconnect state.
- [ ] Complete Google sign-in, terminate the app before the pending queue
  resumes, then relaunch. Restored valid credentials must unblock the persisted
  reauthorization queue.
- [ ] Launching once while offline shows a temporary Google failure, then
  foregrounding online restores the connection without requesting a new grant.

## Evidence to retain

Record for each scenario:

- app version or commit
- iOS version
- permission combination
- foreground or background state
- pass or fail result

Sanitize screenshots and diagnostics before sharing them. Do not retain personal
health values, account identifiers, access tokens, or device identifiers.
