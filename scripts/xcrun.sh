#!/usr/bin/env bash
set -euo pipefail

if [[ -x /usr/bin/xcodebuild ]] && /usr/bin/xcodebuild -version >/dev/null 2>&1; then
  exec /usr/bin/xcrun "$@"
fi

for xcode_app in /Applications/Xcode.app /Applications/Xcode-*.app; do
  developer_dir="${xcode_app}/Contents/Developer"
  if [[ -x "${developer_dir}/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR="${developer_dir}"
    exec /usr/bin/xcrun "$@"
  fi
done

echo "error: A full Xcode installation is required." >&2
exit 1
