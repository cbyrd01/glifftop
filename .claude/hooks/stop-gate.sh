#!/bin/sh
# Stop: if code changed since HEAD, what it belongs to must still build: GliffKit (tests
# included) for package changes, the app for Glifftop/, glifftop-askpass/, Config/ or project
# changes. Skipped when none of that code changed since the last stop that built cleanly.
# The full gate, scripts/test.sh, runs before every commit.
. "$(dirname "$0")/lib.sh"

eval "$(fields cwd stop_hook_active)"
[ "$stop_hook_active" = true ] && exit 0
cd_project || exit 0
[ -d Packages/GliffKit ] || exit 0

# Only what the two builds read. -z: git otherwise quotes non-ASCII names, which no pattern
# below would match.
set -- Packages/GliffKit Glifftop glifftop-askpass Config Glifftop.xcodeproj
untracked=$(git ls-files --others --exclude-standard -z -- "$@" 2>/dev/null | tr '\0' '\n')
changed=$( (git diff HEAD --name-only -z -- "$@" 2>/dev/null | tr '\0' '\n'; printf '%s\n' "$untracked"))
touched() { printf '%s\n' "$changed" | grep -Eq "$1"; }
kit=false app=false
touched '^Packages/GliffKit/.*\.swift$' && kit=true
touched '^Glifftop/.*\.swift$|^glifftop-askpass/.*\.swift$|^Config/.*\.xcconfig$|^Glifftop\.xcodeproj/project\.xcproj$' && app=true
$kit || $app || exit 0

# A fingerprint of the toolchain and those paths: Xcode's version, HEAD, their tracked
# changes (a binary's `index` line names its new content) and their untracked files.
stamp="$(git rev-parse --git-dir)/claude-stop-gate"
state=$({
    cat "$(xcode-select -p)/../version.plist"
    git rev-parse HEAD
    git diff HEAD --no-ext-diff --no-textconv -- "$@"
    printf '%s\n' "$untracked" | grep . | tr '\n' '\0' | xargs -0 -r shasum
} 2>/dev/null | shasum)
[ "$state" = "$(cat "$stamp" 2>/dev/null)" ] && exit 0

# fail SUMMARY OUTPUT — show the build's errors (or its last lines) and block the stop.
fail() {
    output=$(printf '%s\n' "$2" | strip_color)
    errors=$(printf '%s\n' "$output" | grep -E '^/.*: error: ' | sort -u | head -20)
    # Package, link and other errors have no file:line; show the end of the log instead.
    [ -n "$errors" ] || errors=$(printf '%s\n' "$output" | tail -20)
    printf '%s\n' "$errors" >&2
    echo "$1; fix it before stopping." >&2
    exit 2
}

# No -q: in this SwiftPM it hides the compiler's diagnostics.
if $kit; then
    output=$(cd Packages/GliffKit && swift build --build-tests 2>&1) || fail "GliffKit no longer builds" "$output"
fi
if $app; then
    output=$(scripts/app-build.sh 2>&1) || fail "The app no longer builds" "$output"
fi
printf '%s\n' "$state" >"$stamp" || true
exit 0
