#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

for task in project build test smoke harness run; do
  expected="./scripts/with-xcode-lock.sh ./scripts/ios-project-task.sh ${task}"
  actual="$(MAKEFLAGS= MAKELEVEL=0 make --no-print-directory --dry-run "${task}")"
  [[ "${actual}" == "${expected}" ]] ||
    fail "make ${task} must run exactly one complete task behind the Xcode lock."
done

shell_scripts=()
while IFS= read -r -d '' script; do
  shell_scripts+=("${script}")
done < <(find scripts -type f -name '*.sh' -print0)

[[ "${#shell_scripts[@]}" -gt 0 ]] || fail "No shell scripts were found under scripts/."

for script in "${shell_scripts[@]}"; do
  [[ -x "${script}" ]] || fail "${script} must be executable."
  /bin/bash -n "${script}"
done

pinned_xcodegen="$(
  sed -n 's/^xcodegen_version="\(.*\)"$/\1/p' scripts/install-xcodegen.sh
)"
[[ -n "${pinned_xcodegen}" ]] ||
  fail "scripts/install-xcodegen.sh must declare a pinned xcodegen_version."
grep -q 'install-xcodegen.sh' scripts/generate-project.sh ||
  fail "scripts/generate-project.sh must provision the pinned XcodeGen."
grep -Fq -- '--use-cache' scripts/generate-project.sh ||
  fail "scripts/generate-project.sh must use XcodeGen's source-aware project cache."
grep -Fq -- '--cache-path "${cache_path}"' scripts/generate-project.sh ||
  fail "scripts/generate-project.sh must keep the XcodeGen cache repository-local."

./scripts/check-app-dependencies.sh

dependency_fixture_dir="$(
  mktemp -d "${TMPDIR:-/tmp}/healthmule-dependencies.XXXXXX"
)"
trap 'rm -rf "${dependency_fixture_dir}"' EXIT
declared_fixture="${dependency_fixture_dir}/project.yml"
lock_fixture="${dependency_fixture_dir}/Package.resolved"

write_declared_fixture() {
  version="${1:-}"
  if [[ -n "${version}" ]]; then
    cat >"${declared_fixture}" <<EOF
packages:
  GoogleSignIn:
    url: https://github.com/google/GoogleSignIn-iOS
    exactVersion: ${version}
EOF
  else
    cat >"${declared_fixture}" <<'EOF'
packages:
  HealthMuleCore:
    path: .
EOF
  fi
}

write_lock_fixture() {
  first_version="${1:-}"
  second_version="${2:-}"
  {
    printf '{"pins":['
    if [[ -n "${first_version}" ]]; then
      printf '{"identity":"googlesignin-ios","state":{"version":"%s"}}' \
        "${first_version}"
    fi
    if [[ -n "${second_version}" ]]; then
      printf ',{"identity":"googlesignin-ios","state":{"version":"%s"}}' \
        "${second_version}"
    fi
    printf ']}\n'
  } >"${lock_fixture}"
}

write_declared_fixture "9.2.0"
write_lock_fixture "9.2.0"
./scripts/check-app-dependencies.sh \
  "${declared_fixture}" \
  "${lock_fixture}" >/dev/null

write_lock_fixture "9.1.0"
if ./scripts/check-app-dependencies.sh \
  "${declared_fixture}" \
  "${lock_fixture}" >/dev/null 2>&1; then
  fail "The app dependency check must reject version drift."
fi

write_declared_fixture
write_lock_fixture "9.2.0"
if ./scripts/check-app-dependencies.sh \
  "${declared_fixture}" \
  "${lock_fixture}" >/dev/null 2>&1; then
  fail "The app dependency check must reject a missing declaration."
fi

write_declared_fixture "9.2.0"
write_lock_fixture
if ./scripts/check-app-dependencies.sh \
  "${declared_fixture}" \
  "${lock_fixture}" >/dev/null 2>&1; then
  fail "The app dependency check must reject a missing pin."
fi

write_lock_fixture "9.2.0" "9.2.0"
if ./scripts/check-app-dependencies.sh \
  "${declared_fixture}" \
  "${lock_fixture}" >/dev/null 2>&1; then
  fail "The app dependency check must reject duplicate pins."
fi

cat >"${declared_fixture}" <<'EOF'
--- !ruby/object:Object {}
EOF
write_lock_fixture "9.2.0"
if ./scripts/check-app-dependencies.sh \
  "${declared_fixture}" \
  "${lock_fixture}" >/dev/null 2>&1; then
  fail "The app dependency check must reject tagged YAML objects."
fi

cat >"${declared_fixture}" <<'EOF'
dependency: &google_sign_in
  exactVersion: 9.2.0
packages:
  GoogleSignIn: *google_sign_in
EOF
if ./scripts/check-app-dependencies.sh \
  "${declared_fixture}" \
  "${lock_fixture}" >/dev/null 2>&1; then
  fail "The app dependency check must reject YAML aliases."
fi

grep -Fq "platform: watchOS" project.yml ||
  fail "The project must keep the watchOS companion target."
grep -Fq "INFOPLIST_KEY_WKCompanionAppBundleIdentifier" project.yml ||
  fail "The watchOS target must remain paired to the iPhone app."
grep -Fq "NSHealthUpdateUsageDescription:" project.yml ||
  fail "The iPhone app must declare Apple's required HealthKit update purpose string."
spaced_brand="Health"' '"Mule"
misspelled_brand="Healt"' '"Mule"
branding_scan_status=0
grep -R -n -E "${spaced_brand}|${misspelled_brand}" \
  AGENTS.md README.md project.yml docs HealthMuleApp HealthMuleWatchApp HealthMuleUITests ||
  branding_scan_status=$?
case "${branding_scan_status}" in
  0) fail "User-facing branding must use the canonical one-word HealthMule spelling." ;;
  1) ;;
  *) fail "The user-facing branding scan failed." ;;
esac
identifier_hyphen=-
identifier_underscore=_
legacy_kebab="health${identifier_hyphen}mule"
legacy_upper_snake="HEALTH${identifier_underscore}MULE"
legacy_lower_snake="health${identifier_underscore}mule"
identifier_scan_status=0
git grep -n -E "${legacy_kebab}|${legacy_upper_snake}|${legacy_lower_snake}" -- . ||
  identifier_scan_status=$?
case "${identifier_scan_status}" in
  0) fail "Repository identifiers must use the canonical unsplit HealthMule spelling." ;;
  1) ;;
  *) fail "The repository identifier scan failed." ;;
esac
legacy_ci_variables=(
  "APP${identifier_underscore}STORE${identifier_underscore}CONNECT${identifier_underscore}API${identifier_underscore}KEY${identifier_underscore}PATH"
  "APP${identifier_underscore}STORE${identifier_underscore}CONNECT${identifier_underscore}API${identifier_underscore}PRIVATE${identifier_underscore}KEY"
  "APP${identifier_underscore}STORE${identifier_underscore}CONNECT${identifier_underscore}ISSUER${identifier_underscore}ID"
  "APP${identifier_underscore}STORE${identifier_underscore}CONNECT${identifier_underscore}KEY${identifier_underscore}ID"
  "APPLE${identifier_underscore}TEAM${identifier_underscore}ID"
  "GOOGLE${identifier_underscore}CLIENT${identifier_underscore}ID"
  "GOOGLE${identifier_underscore}REDIRECT${identifier_underscore}SCHEME"
)
for legacy_ci_variable in "${legacy_ci_variables[@]}"; do
  ci_variable_scan_status=0
  git grep -n -w "${legacy_ci_variable}" -- . ||
    ci_variable_scan_status=$?
  case "${ci_variable_scan_status}" in
    0) fail "App-specific configuration variables must use the HEALTHMULE_ namespace." ;;
    1) ;;
    *) fail "The app-specific configuration variable scan failed." ;;
  esac
done
grep -Fq "HealthMuleShared HealthMuleWatchApp" scripts/check-swift-syntax.sh ||
  fail "The fast syntax gate must include the Watch companion sources."
if grep -R -E \
  '^(@preconcurrency )?import (HealthKit|GoogleSignIn)' \
  HealthMuleShared HealthMuleWatchApp; then
  fail "The Watch companion must not own HealthKit or Google dependencies."
else
  forbidden_import_status=$?
  [[ "${forbidden_import_status}" -eq 1 ]] ||
    fail "The Watch companion dependency scan failed."
fi

expected_parallel_invocation="--no-print-directory --jobs=3 test-infra check-app-syntax test-core"
expected_fast_commands=$'./scripts/test-infrastructure.sh\n./scripts/check-swift-syntax.sh\n./scripts/swift.sh test --parallel --disable-sandbox'
# Inspect default policy even when the caller selects a smaller verification pool.
actual_fast_verify="$(env -u VERIFY_FAST_JOBS MAKEFLAGS= MAKELEVEL=0 make --no-print-directory --dry-run verify)"
parallel_invocation="${actual_fast_verify%%$'\n'*}"
actual_fast_commands="${actual_fast_verify#*$'\n'}"
if [[ "${parallel_invocation}" != "make ${expected_parallel_invocation}" &&
  "${parallel_invocation}" != */make\ "${expected_parallel_invocation}" ]]; then
  fail "make verify must run the three fast verification lanes through Make with bounded concurrency."
fi
[[ "${actual_fast_commands}" == "${expected_fast_commands}" ]] ||
  fail "make verify must remain the fast infrastructure, syntax, and core-test gate."

expected_cached_commands=$'./scripts/test-infrastructure.sh\n./scripts/check-swift-syntax.sh\n./scripts/swift.sh test --skip-build --parallel --disable-sandbox'
actual_cached_verify="$(env -u VERIFY_FAST_JOBS MAKEFLAGS= MAKELEVEL=0 make --no-print-directory --dry-run verify-cached)"
cached_parallel_invocation="${actual_cached_verify%%$'\n'*}"
actual_cached_commands="${actual_cached_verify#*$'\n'}"
if [[ "${cached_parallel_invocation}" != "make --no-print-directory --jobs=3 test-infra check-app-syntax test-core-cached" &&
  "${cached_parallel_invocation}" != */make\ "--no-print-directory --jobs=3 test-infra check-app-syntax test-core-cached" ]]; then
  fail "make verify-cached must run the three cached verification lanes through Make with bounded concurrency."
fi
[[ "${actual_cached_commands}" == "${expected_cached_commands}" ]] ||
  fail "make verify-cached must preserve infrastructure, syntax, and the no-rebuild Swift test bundle."

actual_full_verify="$(env -u VERIFY_FAST_JOBS MAKEFLAGS= MAKELEVEL=0 make --no-print-directory --dry-run verify-full)"
[[ "${actual_full_verify}" == *"${actual_fast_verify}"* ]] ||
  fail "make verify-full must extend the fast gate with the complete iOS test task."
fast_verify_line="$(grep -nF -- "${expected_parallel_invocation}" <<<"${actual_full_verify}" | head -1 | cut -d: -f1)"
ios_test_line="$(grep -nF -- './scripts/with-xcode-lock.sh ./scripts/ios-project-task.sh test' <<<"${actual_full_verify}" | head -1 | cut -d: -f1)"
[[ -n "${fast_verify_line}" && -n "${ios_test_line}" && "${fast_verify_line}" -lt "${ios_test_line}" ]] ||
  fail "make verify-full must finish fast verification before starting its locked iOS test task."

parsed_booted_ids="$(
  printf '%s\n' \
    '    iPhone 17 Pro (22222222-2222-2222-2222-222222222222) (Booted) ' \
    '    iPhone 17 (11111111-1111-1111-1111-111111111111) (Shutdown) ' \
    '    iPad Pro (33333333-3333-3333-3333-333333333333) (Booted) ' |
    ./scripts/parse-booted-iphone-ids.sh
)"
[[ "${parsed_booted_ids}" == "22222222-2222-2222-2222-222222222222" ]] ||
  fail "Booted-device parsing must accept simctl's trailing whitespace and ignore other states."

grep -Fq "./scripts/generate-project.sh" scripts/ios-project-task.sh ||
  fail "The locked task runner must generate the project."
grep -Fq 'destination="$(./scripts/simulator-destination.sh)"' scripts/ios-project-task.sh ||
  fail "The locked task runner must resolve test destinations."
grep -Fq './scripts/with-simulator-lifecycle.sh' scripts/ios-project-task.sh ||
  fail "Simulator tests must use the ownership-aware lifecycle wrapper."
grep -Fq 'simctl shutdown "${simulator_id}"' scripts/with-simulator-lifecycle.sh ||
  fail "The Simulator lifecycle wrapper must shut down devices it boots."
grep -Fq 'if is_booted; then' scripts/with-simulator-lifecycle.sh ||
  fail "The Simulator lifecycle wrapper must preserve already-booted devices."
if grep -Fq 'with-simulator-lifecycle.sh' scripts/run-simulator.sh; then
  fail "make run must leave its interactive Simulator running."
fi
grep -Fq "testAgentHarnessCapturesCriticalStates" scripts/ios-project-task.sh ||
  fail "The agent harness must run the critical-state UI scenario."
grep -Fq "xcresulttool export attachments" scripts/ios-project-task.sh ||
  fail "The agent harness must export durable screenshot attachments."
if grep -Fq "/usr/bin/xcrun" scripts/ios-project-task.sh; then
  fail "The locked task runner must not bypass repository Xcode wrappers."
fi
for package_flag in -disableAutomaticPackageResolution -skipPackageUpdates; do
  grep -Fq -- "${package_flag}" scripts/ios-project-task.sh ||
    fail "Locked Xcode verification must include ${package_flag}."
  grep -Fq -- "${package_flag}" scripts/run-simulator.sh ||
    fail "Interactive Xcode builds must include ${package_flag}."
done
grep -Fq 'selected}/usr/bin/simctl' scripts/ios-project-task.sh ||
  fail "Simulator tasks must validate the xcode-select toolchain directly."

compatible_ids=$'11111111-1111-1111-1111-111111111111\n22222222-2222-2222-2222-222222222222'
selected="$(
  ./scripts/select-simulator-id.sh \
    "${compatible_ids}" \
    "22222222-2222-2222-2222-222222222222"
)"
[[ "${selected}" == "22222222-2222-2222-2222-222222222222" ]] ||
  fail "Simulator selection must prefer an already-booted compatible iPhone."

selected="$(
  ./scripts/select-simulator-id.sh \
    "${compatible_ids}" \
    "22222222-2222-2222-2222-222222222222" \
    "11111111-1111-1111-1111-111111111111"
)"
[[ "${selected}" == "11111111-1111-1111-1111-111111111111" ]] ||
  fail "SIMULATOR_UDID must override the booted-device preference."

selected="$(
  ./scripts/select-simulator-id.sh \
    "${compatible_ids}" \
    "33333333-3333-3333-3333-333333333333"
)"
[[ "${selected}" == "11111111-1111-1111-1111-111111111111" ]] ||
  fail "Simulator selection must fall back to the first compatible iPhone."

if ./scripts/select-simulator-id.sh \
  "${compatible_ids}" \
  "" \
  "33333333-3333-3333-3333-333333333333" >/dev/null 2>&1; then
  fail "Simulator selection must reject an incompatible explicit override."
fi

open_line="$(grep -nF "/usr/bin/open -a Simulator --args -CurrentDeviceUDID" scripts/run-simulator.sh | cut -d: -f1)"
launch_line="$(grep -nF 'simctl launch "${simulator_id}"' scripts/run-simulator.sh | cut -d: -f1)"
[[ -n "${open_line}" && -n "${launch_line}" && "${open_line}" -lt "${launch_line}" ]] ||
  fail "make run must open the selected Simulator before launching the app."
if grep -Fq -- "-sdk iphonesimulator" scripts/run-simulator.sh; then
  fail "make run must let Xcode select the Watch companion SDK from the destination."
fi

for workflow in .github/workflows/*.yml; do
  if grep -Fq "brew install xcodegen" "${workflow}"; then
    fail "CI must not install an unpinned Homebrew XcodeGen formula."
  fi
  if grep -Fq "./scripts/install-xcodegen.sh" "${workflow}"; then
    fail "CI must let make project provision the pinned XcodeGen."
  fi
done
checkout_action="actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
for workflow in \
  .github/workflows/verify.yml \
  .github/workflows/full-verify.yml \
  .github/workflows/testflight.yml \
  .github/workflows/dependency-watch.yml; do
  grep -Fq "uses: ${checkout_action}" "${workflow}" ||
    fail "${workflow} must pin the supported Node 24 checkout action."
done
scan_reference='^        uses: uinaf/\.github/\.github/actions/scan@[0-9a-f]{40} # v[0-9.]+$'
grep -Eq "${scan_reference}" .github/workflows/verify.yml ||
  fail "Verify must pin the shared scan action to a full SHA annotated with its release tag."
grep -Eq '^  workflow_dispatch:' .github/workflows/verify.yml ||
  fail "Verify must support manual full-history scans."
grep -Fq "uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9" .github/workflows/verify.yml ||
  fail "Fast CI must pin the Swift build cache action."
grep -Eq '^        uses: uinaf/\.github/\.github/actions/changes@[0-9a-f]{40} # v[0-9.]+$' .github/workflows/verify.yml ||
  fail "Fast CI must pin the shared app compile path selector to a full SHA annotated with its release tag."
grep -Fq "compile: \${{ contains(fromJSON(steps.changes.outputs.changes), 'compile') }}" .github/workflows/verify.yml ||
  fail "Fast CI must expose the app compile selection."
grep -Fq "if: needs.changes.outputs.compile == 'true'" .github/workflows/verify.yml ||
  fail "The macOS compile lane must run only for selected app changes."
for compile_input in \
  "HealthMuleApp/**" \
  "HealthMuleShared/**" \
  "HealthMuleWatchApp/**" \
  "Sources/**" \
  "Package.swift" \
  "project.yml" \
  "scripts/**" \
  "HealthMule.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"; do
  grep -Fq -- "- '${compile_input}'" .github/workflows/verify.yml ||
    fail "The macOS compile selector must include ${compile_input}."
done
grep -Fq "id: xcode-toolchain" .github/workflows/verify.yml ||
  fail "The macOS compile lane must fingerprint its Xcode toolchain."
grep -Fq "key: verify-xcode-dependencies-v4-" .github/workflows/verify.yml ||
  fail "The macOS compile lane must keep a versioned dependency cache."
for xcode_cache_path in \
  ".artifacts/toolchain" \
  ".artifacts/xcodegen" \
  ".artifacts/DerivedData/SourcePackages" \
  "HealthMule.xcodeproj" \
  "HealthMuleApp/Resources/Info.plist"; do
  grep -Fq "${xcode_cache_path}" .github/workflows/verify.yml ||
    fail "The macOS dependency cache must preserve ${xcode_cache_path}."
done
grep -Fq "id: swift-build-cache" .github/workflows/verify.yml ||
  fail "Fast CI must expose exact cache-hit state."
grep -Eq '^[[:space:]]+path:[[:space:]]+\.build[[:space:]]*$' .github/workflows/verify.yml ||
  fail "Fast CI must cache only the local Swift build directory."
grep -Fq "key: verify-swift-build-v1-" .github/workflows/verify.yml ||
  fail "Fast CI must keep a versioned Swift build cache key."
grep -Fq '${{ github.event.repository.name }}' .github/workflows/verify.yml ||
  fail "Fast CI must scope path-bound Swift build caches to the repository name."
grep -Fq "'Package.resolved', 'Sources/**', 'Tests/**', 'Makefile', 'scripts/swift.sh'" .github/workflows/verify.yml ||
  fail "Fast CI must invalidate its build cache for every SwiftPM input."
grep -Fq 'HEALTHMULE_MODULE_CACHE: ${{ github.workspace }}/.build/module-cache' .github/workflows/verify.yml ||
  fail "Fast CI must keep Swift module caches inside the cached build directory."
grep -Fq "if: steps.swift-build-cache.outputs.cache-hit == 'true'" .github/workflows/verify.yml ||
  fail "Exact cache hits must use the no-rebuild verification path."
grep -Eq '^[[:space:]]+run:[[:space:]]+make verify-cached[[:space:]]*$' .github/workflows/verify.yml ||
  fail "Exact cache hits must call the canonical cached verification graph."
if grep -Fq 'swift --version' .github/workflows/verify.yml; then
  fail "Fast CI must fingerprint the Swift executable without launching the compiler before cache restore."
fi
grep -Fq 'sha256sum "${swift_binary}"' .github/workflows/verify.yml ||
  fail "Fast CI must bind cached Swift artifacts to the installed executable."
grep -Fq "if: steps.swift-build-cache.outputs.cache-hit != 'true'" .github/workflows/verify.yml ||
  fail "Cache misses must use the canonical build-and-test path."
grep -Eq '^[[:space:]]+runs-on:[[:space:]]+ubuntu-24\.04[[:space:]]*$' .github/workflows/verify.yml ||
  fail "Fast CI must use the standard GitHub-hosted Ubuntu 24.04 runner."
grep -Eq '^[[:space:]]+timeout-minutes:[[:space:]]+5[[:space:]]*$' .github/workflows/verify.yml ||
  fail "Fast CI must stay capped at five minutes."
grep -Eq '^[[:space:]]+run:[[:space:]]+make verify[[:space:]]*$' .github/workflows/verify.yml ||
  fail "Fast CI must call the canonical fast gate."
grep -Eq '^  workflow_dispatch:[[:space:]]*$' .github/workflows/full-verify.yml ||
  fail "Full CI must remain manually dispatched."
if grep -Eq '^  (pull_request|push|schedule):' .github/workflows/full-verify.yml; then
  fail "Full CI must not run automatically."
fi
grep -Eq '^[[:space:]]+run:[[:space:]]+make verify-full[[:space:]]*$' .github/workflows/full-verify.yml ||
  fail "Full CI must call the explicit full gate."
testflight_workflow=.github/workflows/testflight.yml
grep -Eq '^  workflow_dispatch:[[:space:]]*$' "${testflight_workflow}" ||
  fail "TestFlight uploads must remain manually dispatched."
if grep -Eq '^  (pull_request|pull_request_target|push|schedule):' "${testflight_workflow}"; then
  fail "TestFlight uploads must not run automatically or from pull requests."
fi
grep -Fq 'RELEASE_REF: ${{ github.ref }}' "${testflight_workflow}" ||
  fail "TestFlight must validate the selected release ref before loading its environment."
grep -Fq 'refs/heads/main' "${testflight_workflow}" ||
  fail "TestFlight uploads must be restricted to main."
grep -Fq 'cancel-in-progress: false' "${testflight_workflow}" ||
  fail "An in-progress TestFlight upload must never be cancelled by another dispatch."
awk '
  $0 == "    environment:" { in_environment = 1; next }
  in_environment && $0 == "      name: beta" { found = 1; next }
  in_environment && $0 !~ /^      / { in_environment = 0 }
  END { exit(found ? 0 : 1) }
' "${testflight_workflow}" ||
  fail "TestFlight credentials must come from the dedicated GitHub Environment."
grep -Eq '^[[:space:]]+run:[[:space:]]+make verify-full[[:space:]]*$' "${testflight_workflow}" ||
  fail "TestFlight must run the complete verification gate before credentials are configured."
grep -Fq 'run: ./scripts/ci/configure-testflight.sh' "${testflight_workflow}" ||
  fail "TestFlight must use the repository-owned credential setup script."
grep -Fq 'run: ./scripts/ci/upload-testflight.sh' "${testflight_workflow}" ||
  fail "TestFlight must use the repository-owned archive and upload script."
awk '
  $0 == "      - name: Remove release credentials" { in_cleanup = 1; next }
  in_cleanup && $0 == "        if: always()" { found_always = 1; next }
  in_cleanup && $0 == "        run: ./scripts/ci/cleanup-testflight.sh" && found_always {
    found_cleanup = 1
  }
  in_cleanup && $0 ~ /^      - name:/ { in_cleanup = 0; found_always = 0 }
  END { exit(found_cleanup ? 0 : 1) }
' "${testflight_workflow}" ||
  fail "TestFlight cleanup must use the repository script with always() on the same step."
upload_step_line="$(grep -nF -- '- name: Archive and upload to App Store Connect' "${testflight_workflow}" | cut -d: -f1)"
cleanup_step_line="$(grep -nF -- '- name: Remove release credentials' "${testflight_workflow}" | cut -d: -f1)"
[[ -n "${upload_step_line}" && -n "${cleanup_step_line}" && "${cleanup_step_line}" -gt "${upload_step_line}" ]] ||
  fail "TestFlight cleanup must run after the archive and upload step."
grep -Fq 'HEALTHMULE_APP_STORE_CONNECT_API_PRIVATE_KEY: ${{ secrets.HEALTHMULE_APP_STORE_CONNECT_API_PRIVATE_KEY }}' "${testflight_workflow}" ||
  fail "The App Store Connect private key must be sourced from an Environment secret."
grep -Fq 'method -string app-store-connect' scripts/ci/upload-testflight.sh ||
  fail "TestFlight export must use the current App Store Connect distribution method."
grep -Fq 'destination -string upload' scripts/ci/upload-testflight.sh ||
  fail "TestFlight export must upload directly instead of leaving a local IPA."
grep -Fq 'signingStyle -string automatic' scripts/ci/upload-testflight.sh ||
  fail "TestFlight must use Xcode-managed automatic signing."
if grep -Fq 'Apple Distribution' project.yml scripts/ci/upload-testflight.sh; then
  fail "Automatic TestFlight signing must not force a manual distribution identity."
fi
grep -Fq -- '-allowProvisioningUpdates' scripts/ci/upload-testflight.sh ||
  fail "TestFlight must allow Xcode to manage CI provisioning assets."
grep -Fq -- '-authenticationKeyPath' scripts/ci/upload-testflight.sh ||
  fail "TestFlight signing must authenticate with the App Store Connect API key."
grep -Fq 'exec ./scripts/with-xcode-lock.sh "$0"' scripts/ci/upload-testflight.sh ||
  fail "TestFlight must serialize project generation, archive, and export behind one Xcode lock."

valid_testflight_environment=(
  env
  HEALTHMULE_APPLE_TEAM_ID=54QY62678F
  HEALTHMULE_APP_STORE_CONNECT_API_PRIVATE_KEY=$'-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----'
  HEALTHMULE_APP_STORE_CONNECT_ISSUER_ID=12345678-1234-1234-1234-123456789abc
  HEALTHMULE_APP_STORE_CONNECT_KEY_ID=ABC123DEFG
  HEALTHMULE_GOOGLE_CLIENT_ID=123-valid.apps.googleusercontent.com
  HEALTHMULE_GOOGLE_REDIRECT_SCHEME=com.googleusercontent.apps.123-valid
)
"${valid_testflight_environment[@]}" ./scripts/ci/validate-testflight-configuration.sh
if "${valid_testflight_environment[@]}" \
  HEALTHMULE_APP_STORE_CONNECT_ISSUER_ID=12345678-12341234-1234-123456789abc \
  ./scripts/ci/validate-testflight-configuration.sh >/dev/null 2>&1; then
  fail "TestFlight validation must reject a non-canonical issuer UUID."
fi
if "${valid_testflight_environment[@]}" \
  HEALTHMULE_GOOGLE_REDIRECT_SCHEME=com.googleusercontent.apps.wrong \
  ./scripts/ci/validate-testflight-configuration.sh >/dev/null 2>&1; then
  fail "TestFlight validation must reject an OAuth redirect scheme from another client."
fi
if "${valid_testflight_environment[@]}" \
  HEALTHMULE_GOOGLE_CLIENT_ID=123-valid.googleusercontent.com \
  ./scripts/ci/validate-testflight-configuration.sh >/dev/null 2>&1; then
  fail "TestFlight validation must reject a non-iOS Google OAuth client ID."
fi
grep -Eq 'xcodegen_sha256="[0-9a-f]{64}"' scripts/install-xcodegen.sh ||
  fail "The XcodeGen installer must pin a SHA-256 digest."
