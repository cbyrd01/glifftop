#!/bin/sh
# Builds the app into repo-local DerivedData (.build/xcode, keeping Claude's builds out of
# Xcode's). On failure, ends with the build's error messages from its result bundle. Used
# by scripts/test.sh and the Stop hook (.claude/hooks/stop-gate.sh).
set -u
cd "$(dirname "$0")/.."
# A result bundle per run, so the gate and the Stop hook can't delete each other's.
results=$(mktemp -d)
trap 'rm -rf "$results"' EXIT
xcodebuild -quiet -project Glifftop.xcodeproj -scheme Glifftop -destination 'platform=macOS' \
    -derivedDataPath .build/xcode -resultBundlePath "$results/build.xcresult" build && exit 0
xcrun xcresulttool get build-results --path "$results/build.xcresult" 2>/dev/null |
    /usr/bin/python3 -I -c '
import json, sys
try:
    issues = json.load(sys.stdin).get("errors", [])
except ValueError:
    sys.exit(0)
for issue in issues[:20]:
    print("error:", issue.get("message", issue))
'
exit 1
