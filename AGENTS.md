# HealthMule agent guide

HealthMule exports a read-only allowlist of Apple Health metrics as stable
daily JSON files in the user's own Google Drive. There is no developer backend.
The privacy boundaries in Repo rules are non-negotiable.

## Start here

- Generate the Xcode project: `make project`
- Build and launch in Simulator: `make run`
- Required gate before any push: `make verify`

| Question | Doc |
| --- | --- |
| What the app must do and what the JSON contract is | [Product and export contract](docs/specs/healthkit-drive-exporter.md) |
| Module map, sync invariants, privacy boundaries | [Architecture](docs/ARCHITECTURE.md) |
| Connecting a real Drive account | [Google OAuth setup](docs/GOOGLE_OAUTH.md) |
| What only a signed physical device can prove | [Physical-device acceptance](docs/DEVICE_TESTING.md) |
| Shipping a build to testers | [TestFlight delivery](docs/DISTRIBUTION.md) |
| Why the sync store uses a digest index | [Sync-store scaling decision](docs/decisions/sync-store-persistence.md) |

## Runner contract

- Core tests and `make verify` need only a Swift 6 toolchain and run on Linux.
- Everything that compiles the app or the Watch app needs a full Xcode with the
  iOS and watchOS SDKs.
- Always call the `scripts/` wrappers instead of bare `swift`, `xcodebuild`, or
  `xcrun`. They locate `/Applications/Xcode*.app` themselves, so `make verify`
  and `make build` work even when `xcode-select` points at CommandLineTools.
- `make test`, `make smoke`, `make harness`, and `make run` get no such fallback. They need
  `xcode-select` pointed at a full Xcode.
- `xcrun simctl` and every tool that resolves Xcode through `xcode-select`,
  the Claude Code iOS Simulator MCP included, fail until an operator runs
  `sudo xcode-select -s /Applications/Xcode.app`. Use `./scripts/xcrun.sh`
  meanwhile.
- `make test`, `make smoke`, `make harness`, and `make verify-full` boot a cold target and wait
  for it before testing. They shut it down on exit only when that invocation
  booted it; an already-booted Simulator remains running. This avoids the
  `SBMainWorkspace ... Busy` launch race without leaking a headless Simulator.
- XcodeGen is pinned and provisioned into `.artifacts/toolchain` by
  `make project`. Do not install it separately; a different version rewrites the
  whole project file.

## Validation

- Fast contract tests: `make test-core`
- Fast local and required CI gate: `make verify`
- Full iOS and Simulator gate: `make verify-full`
- Runtime smoke test: `make smoke`
- Full command matrix: [Contributing](CONTRIBUTING.md#validation)

What the gates prove:

- `make verify` checks the infrastructure contract, parses all app and iOS test
  Swift, and runs the deterministic core tests on Linux or macOS. Make runs
  those three independent lanes concurrently with a bounded job count.
- Parsing is not type checking, so app, Watch, and UI changes also need
  `make build` or `make smoke` locally.
- This public repository uses standard GitHub-hosted `ubuntu-24.04` and
  `macos-26` (Apple silicon, Xcode 26) runners for every workflow.
- Required CI always runs `make verify` on Linux. It adds `make build` on macOS
  when app, Watch, project, package, build-script, or compile-workflow inputs
  change; documentation-only and unrelated automation changes skip that lane.
- The iOS unit and Simulator UI suites belong to `make verify-full`, which runs
  locally or through the manual `Full Verify` workflow, never on a pull request.

## Repo rules

- Keep `HealthMuleCore` Foundation-only and deterministic.
- HealthKit is read-only. Never add HealthKit write types or entitlements.
- Never log health values, OAuth tokens, record bodies, or raw metadata.
- Preserve explicit JSON `null` values and unknown fields in exported records.
- Keep credentials in `Config/Secrets.xcconfig` and Keychain; neither is
  committed.
- Simulator fixtures are development proof only. HealthKit background delivery
  and real Drive uploads require the physical-device checklist in the docs.

## Repository skills

- Use [Swift concurrency](.agents/skills/swift-concurrency/SKILL.md) for tasks, actor isolation, Sendable, and callback-to-async changes.
- Use [SwiftUI](.agents/skills/swiftui-expert-skill/SKILL.md) for view, state, layout, and accessibility changes.
- Use [Swift testing](.agents/skills/swift-testing-expert/SKILL.md) for test architecture and async test failures; preserve the existing test framework unless migration is requested.
- Use [Xcode build optimization](.agents/skills/xcode-build-orchestrator/SKILL.md) for build timing and optimization work; its five companion skills are installed alongside it. Keep `project.yml` as the project source and use the repository build commands.
