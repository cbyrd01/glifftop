#!/bin/sh
# Tests scripts/check-upstream.sh against canned release lists, with a stub gh on PATH (no
# network). The pinned version comes from the real tools/fake-server/Cargo.lock.
set -u
cd "$(dirname "$0")/../.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pinned=v$(awk '/^name = "gliff-proto"$/ { getline; gsub(/version = |"/, ""); print; exit }' \
    tools/fake-server/Cargo.lock)
fail=0

mkdir "$T/bin" "$T/failbin"
printf '#!/bin/sh\ncat "$STUB_DIR/releases.json"\n' >"$T/bin/gh"
printf '#!/bin/sh\necho "gh: offline" >&2; exit 1\n' >"$T/failbin/gh"
chmod +x "$T/bin/gh" "$T/failbin/gh"

rel() { printf '{"tagName":"%s","publishedAt":"%s","isPrerelease":%s}' "$1" "$2" "$3"; }
releases() { d=$(mktemp -d "$T/case.XXXXXX"); echo "[$*]" | sed 's/} {/},{/g' >"$d/releases.json"; echo "$d"; }
run() { STUB_DIR="$1" PATH="$T/bin:/usr/bin:/bin" scripts/check-upstream.sh ${2:-} 2>&1; }
expect() { case "$2" in *"$3"*) ;; *) echo "FAIL: $1: got: $2"; fail=1 ;; esac; }

d=$(releases "$(rel "$pinned" 2026-11-12T14:46:57Z false)" "$(rel v0.4.2 2026-11-05T02:53:44Z false)")
expect "up to date" "$(run "$d")" "up to date with $pinned"
expect "quiet when current" "[$(run "$d" --quiet)]" "[]"

d=$(releases "$(rel v99.0.0 2027-12-03T10:00:00Z false)" "$(rel v98.1.0 2027-11-25T10:00:00Z true)" \
    "$(rel "$pinned" 2026-11-12T14:46:57Z false)")
out=$(run "$d")
expect "counts newer releases" "$out" "2 releases newer than pinned $pinned"
expect "names one with date and link" "$out" "v99.0.0 (2027-12-03) https://github.com/omacom/gliff/releases/tag/v99.0.0"
expect "marks a pre-release" "$out" "v98.1.0 (2027-11-25) pre-release"
expect "quiet still reports news" "$(run "$d" --quiet)" "v99.0.0"

# A backport of an older line, published after the pin, is not newer.
d=$(releases "$(rel v0.0.9 2027-12-01T10:00:00Z false)" "$(rel "$pinned" 2026-11-12T14:46:57Z false)")
expect "older version published later" "$(run "$d")" "up to date with $pinned"

# A suffixed pre-release of a newer version is news; one of the pinned version itself is not.
d=$(releases "$(rel v99.0.0-rc.1 2027-12-03T10:00:00Z true)" "$(rel "$pinned-rc.1" 2026-11-01T10:00:00Z true)" \
    "$(rel "$pinned" 2026-11-12T14:46:57Z false)")
out=$(run "$d")
expect "suffixed pre-release" "$out" "1 release newer than pinned $pinned"
expect "names it" "$out" "v99.0.0-rc.1 (2027-12-03) pre-release"

d=$(releases "$(rel v99.0.0 2027-12-03T10:00:00Z false)")
expect "pinned version has no release" "$(run "$d")" "no upstream release $pinned"
expect "rejects unknown option" "$(run "$d" --verbose)" "usage:"

out=$(PATH="$T/failbin:/usr/bin:/bin" scripts/check-upstream.sh 2>&1) && fail=1
expect "gh failure is reported" "$out" "gh: offline"
expect "gh failure is silent when quiet" \
    "[$(PATH="$T/failbin:/usr/bin:/bin" scripts/check-upstream.sh --quiet 2>&1; echo "rc=$?")]" "[rc=0]"
expect "missing gh is named" "$(PATH="/usr/bin:/bin" scripts/check-upstream.sh 2>&1)" "gh not found"

[ "$fail" -eq 0 ] && echo "check-upstream: all cases passed"
exit "$fail"
