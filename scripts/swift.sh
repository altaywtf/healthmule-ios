#!/usr/bin/env bash
set -euo pipefail

swift_tool="${HEALTHMULE_SWIFT_TOOL:-swift}"
if [[ "${swift_tool}" != "swift" && "${swift_tool}" != "swiftc" ]]; then
  echo "error: HEALTHMULE_SWIFT_TOOL must be swift or swiftc." >&2
  exit 1
fi

swift_command=()
if [[ -x /usr/bin/xcodebuild ]] && /usr/bin/xcodebuild -version >/dev/null 2>&1; then
  developer_dir="$(/usr/bin/xcode-select -p)"
else
  developer_dir=""
  for xcode_app in /Applications/Xcode.app /Applications/Xcode-*.app; do
    candidate="${xcode_app}/Contents/Developer"
    if [[ -x "${candidate}/usr/bin/xcodebuild" ]]; then
      developer_dir="${candidate}"
      break
    fi
  done
fi

if [[ -n "${developer_dir}" ]]; then
  export DEVELOPER_DIR="${developer_dir}"
  swift_command=(/usr/bin/xcrun "${swift_tool}")
elif command -v "${swift_tool}" >/dev/null 2>&1; then
  swift_command=("${swift_tool}")
else
  echo "error: A Swift 6 toolchain is required." >&2
  exit 1
fi

module_cache="${HEALTHMULE_MODULE_CACHE:-${TMPDIR:-/tmp}/healthmule-module-cache}"
mkdir -p "${module_cache}/clang" "${module_cache}/swiftpm"
export CLANG_MODULE_CACHE_PATH="${module_cache}/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${module_cache}/swiftpm"
exec "${swift_command[@]}" "$@"
