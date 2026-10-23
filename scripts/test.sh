#!/bin/bash
set -eo pipefail
cd "$(dirname "$0")/.."
unset LIBRARY_PATH CPATH   # shell profile points these at the macOS SDK, which breaks the iOS link
xcodegen generate
SIM="${SIM:-iPhone 17}"   # needs a simulator for the SDK's iOS version (xcrun simctl list devices available)
xcodebuild -project Whiteboard.xcodeproj -scheme Whiteboard \
  -destination "platform=iOS Simulator,name=$SIM" test 2>&1 | grep -E "error:|warning: .*\.swift|Test Case .* (passed|failed)|failed:|\*\* TEST|Executed" | grep -v "^ld: warning" || true
test "${PIPESTATUS[0]}" -eq 0
