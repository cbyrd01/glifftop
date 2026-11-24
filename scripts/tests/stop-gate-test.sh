#!/bin/sh
# Tests the Stop hook (.claude/hooks/stop-gate.sh, or the hook given as $1) in a throwaway
# repo with stub swift and xcodebuild that log each build: what it builds, and that it skips
# a rebuild when nothing changed since its last clean pass.
set -u
cd "$(dirname "$0")/../.."
root=$PWD
hook=${1:-.claude/hooks/stop-gate.sh}
hook=$(cd "$(dirname "$hook")" && pwd)/$(basename "$hook")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0

mkdir -p "$T/bin" "$T/repo/.claude/hooks" "$T/repo/scripts" "$T/repo/Packages/GliffKit/Sources" \
    "$T/repo/Glifftop" "$T/repo/Config"
# Each stub logs its build and fails while $T/broken-<tool> exists.
for tool in swift xcodebuild; do
    printf '#!/bin/sh\necho %s >>"%s/builds"\n[ ! -e "%s/broken-%s" ]\n' "$tool" "$T" "$T" "$tool" >"$T/bin/$tool"
done
printf '#!/bin/sh\nexit 0\n' >"$T/bin/xcrun"
chmod +x "$T/bin/"*
cp "$hook" "$T/repo/.claude/hooks/stop-gate.sh"
cp "$root/.claude/hooks/lib.sh" "$T/repo/.claude/hooks/"
cp "$root/scripts/app-build.sh" "$T/repo/scripts/"
printf '\000\001' >"$T/repo/Glifftop/icon.bin"
cd "$T/repo"
# A fixed identity and no signing, whatever the machine's git config says.
commit() { git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false commit -q -m "$1"; }
git init -q . && git add -A && commit base || { echo "FAIL: could not commit in the test repo"; exit 1; }

payload="{\"cwd\": \"$T/repo\", \"stop_hook_active\": false}"
stop() { : >"$T/builds"; printf '%s' "$payload" | PATH="$T/bin:$PATH" .claude/hooks/stop-gate.sh >/dev/null 2>&1; rc=$?; }
expect() {  # NAME RC BUILDS
    got=$(tr '\n' ' ' <"$T/builds")
    [ "$rc" = "$2" ] && [ "$got" = "$3" ] || { echo "FAIL: $1: rc=$rc builds=[$got], expected rc=$2 [$3]"; fail=1; }
}

stop; expect "clean tree builds nothing" 0 ""
echo a >Packages/GliffKit/Sources/A.swift
stop; expect "GliffKit change builds GliffKit" 0 "swift "
stop; expect "unchanged since a clean pass: skipped" 0 ""
echo a >Glifftop/Résumé.swift
stop; expect "non-ASCII app file builds both" 0 "swift xcodebuild "
echo b >>Glifftop/Résumé.swift
touch "$T/broken-swift"
stop; expect "a failing build blocks the stop" 2 "swift "
stop; expect "and is retried, not skipped" 2 "swift "
rm "$T/broken-swift"
touch "$T/broken-xcodebuild"
stop; expect "a failing app build blocks the stop" 2 "swift xcodebuild "
rm "$T/broken-xcodebuild"
stop; expect "fixed: builds again and passes" 0 "swift xcodebuild "
echo d >>CLAUDE.md
stop; expect "an edit outside the built code: skipped" 0 ""
echo c >Config/Shared.xcconfig
stop; expect "xcconfig change builds" 0 "swift xcodebuild "
printf '\000\002' >Glifftop/icon.bin
stop; expect "binary change builds" 0 "swift xcodebuild "
printf '\000\003' >Glifftop/icon.bin
stop; expect "a second binary change builds again" 0 "swift xcodebuild "
git add -A && commit next
stop; expect "after a commit, a clean tree builds nothing" 0 ""
mkdir -p glifftop-askpass Glifftop.xcodeproj/xcuserdata
echo a >glifftop-askpass/main.swift
stop; expect "the askpass helper's change builds the app" 0 "xcodebuild "
echo a >Glifftop.xcodeproj/project.xcproj
stop; expect "a project change builds the app" 0 "xcodebuild "
git add -A && commit helper
echo a >Glifftop.xcodeproj/xcuserdata/state
stop; expect "Xcode's per-user state: skipped" 0 ""

[ "$fail" -eq 0 ] && echo "stop-gate: all cases passed"
exit "$fail"
