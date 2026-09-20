# HealthMule

HealthMule is an open-source iPhone and Apple Watch app that exports a small,
read-only selection of Apple Health metrics as stable daily JSON files in your
Google Drive.

- The iPhone owns HealthKit access, Google authorization, protected local
  staging, and Drive uploads.
- The Watch companion displays sanitized sync status and can request a sync
  while the phone is reachable.
- There is no developer backend, analytics, ads, or telemetry.

**Implemented:** the complete sync path, covered by deterministic core tests,
Watch presentation-contract tests, and Simulator checks.

**Unproven:** HealthKit background delivery, real Drive uploads, and
process-interruption recovery. Prove them with a signed build against the
[physical-device checklist](docs/DEVICE_TESTING.md).

## Quick start

Requirements:

- A full Xcode installation with the iOS 26 and watchOS 26 SDKs
- Matching iOS and watchOS Simulator runtimes for app builds and launches
- Swift 6

[XcodeGen](https://github.com/yonaskolb/XcodeGen) needs no separate install.
`make project` downloads the official release pinned in
`scripts/install-xcodegen.sh`, verifies its published SHA-256 digest, and keeps
it under `.artifacts/toolchain`.

Generate the project and launch the phone app in the first available iPhone
Simulator. Xcode also builds and embeds the Watch companion:

```sh
make project
make run
```

Set `SIMULATOR_UDID` to target a specific available simulator:

```sh
SIMULATOR_UDID=<simulator-udid> make run
```

Run the unattended agent harness to boot a compatible iPhone Simulator,
exercise the critical loading, sync, failure, and automatic-activity states,
and retain screenshots plus a machine-readable test summary:

```sh
make harness
```

- Each run writes a new directory under `.artifacts/agent-harness`.
- Set `HEALTHMULE_HARNESS_OUTPUT` to place those artifacts elsewhere.
- The fixtures are deterministic development data. They prove neither real
  HealthKit background delivery nor real Drive uploads.

The default build intentionally has no Google credentials. The UI and automated
tests work in that state. Follow [Google OAuth setup](docs/GOOGLE_OAUTH.md) when
you are ready to connect a Drive account.

## Develop and validate

Run `make verify` for the fast required gate. App and UI changes also need an
appropriate Xcode or Simulator check. The complete command matrix and pull
request expectations live in [Contributing](CONTRIBUTING.md).

Releases are archived and uploaded by the manual, main-only GitHub Actions
workflow rather than a developer Mac. See
[TestFlight distribution](docs/DISTRIBUTION.md).

## Privacy boundary

- HealthKit access is read-only and limited to the types in the product spec.
- The app has no developer backend, analytics, ads, or telemetry.
- Google access uses the narrow `drive.file` scope.
- Health values, OAuth tokens, exported records, and raw HealthKit metadata must
  never appear in logs or diagnostics.
- Local health staging, anchors, and saved day boundaries use file protection
  and are excluded from device backups.

## Documentation

- [Google OAuth setup](docs/GOOGLE_OAUTH.md)
- [Physical-device acceptance testing](docs/DEVICE_TESTING.md)
- [Architecture and privacy boundaries](docs/ARCHITECTURE.md)
- [Product and export contract](docs/specs/healthkit-drive-exporter.md)
- [TestFlight distribution](docs/DISTRIBUTION.md)
- [Sync-store scaling decision](docs/decisions/sync-store-persistence.md)
- [Security reporting](https://github.com/altaywtf/.github/blob/main/SECURITY.md)

## Contributing

Issues and pull requests are welcome. See [Contributing](CONTRIBUTING.md) for
the development setup, validation commands, and privacy requirements.

## License

HealthMule is available under the [MIT License](LICENSE).
