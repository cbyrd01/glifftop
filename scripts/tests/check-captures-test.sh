#!/bin/sh
# Tests scripts/check-captures.sh and approve-capture.sh's terminal check in a temp git repo
# (no network).
set -u
# git must act on the temp repo below, never on a checkout named by the caller's environment.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
cd "$(dirname "$0")/../.."
scripts=$PWD/scripts
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0

git init -q "$T/repo"
cd "$T/repo"
git config user.email test@example.invalid
git config user.name test
printf '# header\n' >captures.sha256
git add captures.sha256
# No hooks or signing prompts in the temp repo; a failed commit ends the test.
commit() { git -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm "$1" || { echo "FAIL: commit $1"; exit 1; }; }
commit init

# As the maintainer commits (no CLAUDECODE), and as Claude Code does.
check() { env -u CLAUDECODE "$scripts/check-captures.sh" 2>&1; echo "[rc=$?]"; }
check_as_claude() { env CLAUDECODE=1 "$scripts/check-captures.sh" 2>&1; echo "[rc=$?]"; }
expect() { case "$2" in *"$3"*) ;; *) echo "FAIL: $1: got: $2"; fail=1 ;; esac; }
reject() { case "$2" in *"$3"*) echo "FAIL: $1: got: $2"; fail=1 ;; esac; }
put() { mkdir -p "$(dirname "$1")"; printf '%s' "${2:-pixels}" >"$1"; git add "$1"; }
approve() { printf '%s  %s\n' "$(shasum -a 256 <"$1" | cut -d' ' -f1)" "$1" >>captures.sha256; git add captures.sha256; }
reset() { git reset -q --hard; git clean -qfd; }

put docs/media/a.png
out=$(check)
expect "unapproved capture is refused" "$out" "[rc=1]"
expect "names the file" "$out" "docs/media/a.png"
expect "says how to approve" "$out" "scripts/approve-capture.sh"
approve docs/media/a.png
expect "approved capture passes" "$(check)" "[rc=0]"
put docs/media/a.png "other pixels"
expect "approved then modified is refused" "$(check)" "[rc=1]"
reset

put docs/media/a.png
approve docs/media/a.png
git reset -q captures.sha256
expect "approval must be staged" "$(check)" "[rc=1]"
reset

put Packages/GliffKit/Tests/GliffVideoTests/Fixtures/synthetic/bars.h264
expect "synthetic fixture passes" "$(check)" "[rc=0]"
reset
put Glifftop/Assets.xcassets/AppIcon.appiconset/icon.png
expect "app asset passes" "$(check)" "[rc=0]"
reset
put x.PNG
expect "extension is case-insensitive" "$(check)" "[rc=1]"
reset
put docs/media/notes.txt
expect "anything under docs/media needs approval" "$(check)" "[rc=1]"
reset
put Packages/GliffKit/Tests/GliffVideoTests/Fixtures/recorded/omarchy.bin
expect "recorded fixtures need approval" "$(check)" "[rc=1]"
reset
put rec/glifftop-20261119-150405.gliffrec
expect "a recording needs approval" "$(check)" "[rc=1]"
reset
put Sources/main.swift
expect "other files pass" "$(check)" "[rc=0]"
reset
for name in a.webp a.AVIF a.webm a.mkv a.m4v; do
    put "$name"
    expect "$name needs approval" "$(check)" "[rc=1]"
    reset
done
put .recordings/dump.bin
expect "anything forced in from .recordings needs approval" "$(check)" "[rc=1]"
reset
for name in shot.tif a.bmp a.pdf a.heif a.avi a.mpg a.hevc a.h265 frames.yuv; do
    put "$name"
    expect "$name needs approval" "$(check)" "[rc=1]"
    reset
done
put .recordings/omarchy/Fixtures/synthetic/screen.png
expect "the synthetic exemption doesn't reach .recordings" "$(check)" "[rc=1]"
reset
put docs/media/Fixtures/synthetic/demo.mov
expect "nor docs/media" "$(check)" "[rc=1]"
reset

# A capture that replaces a symlink (a type change) is still checked.
mkdir -p docs/media
ln -s elsewhere docs/media/demo.mov
git add docs/media/demo.mov
commit symlink
rm docs/media/demo.mov
put docs/media/demo.mov
expect "a type change is checked" "$(check)" "[rc=1]"
git reset -q --hard HEAD~1
reset

# The hash is of the staged bytes, whatever diff drivers say.
printf '*.png diff=fake\n' >.gitattributes
git config diff.fake.textconv "sed s/^/X/"
put docs/media/a.png
approve docs/media/a.png
expect "a textconv driver doesn't change the hash" "$(check)" "[rc=0]"
git config --unset diff.fake.textconv
rm .gitattributes
reset

# Approval is the maintainer's: Claude's commits can't add an approval line, only keep the header.
put docs/media/a.png
approve docs/media/a.png
out=$(check_as_claude)
expect "Claude can't stage an approval" "$out" "[rc=1]"
expect "and is told why" "$out" "captures.sha256"
git reset -q docs/media/a.png
expect "not even without the capture" "$(check_as_claude)" "[rc=1]"
reset
git config color.ui always
put docs/media/a.png
approve docs/media/a.png
expect "not with coloured diffs" "$(check_as_claude)" "[rc=1]"
git config --unset color.ui
reset
printf 'captures.sha256 -diff\n' >.gitattributes
put docs/media/a.png
approve docs/media/a.png
expect "not with captures.sha256 marked binary" "$(check_as_claude)" "[rc=1]"
rm .gitattributes
reset
printf '# another comment\n' >>captures.sha256
git add captures.sha256
expect "Claude may change the header" "$(check_as_claude)" "[rc=0]"
reset
put docs/media/a.png
approve docs/media/a.png
commit approved
put Sources/main.swift
expect "Claude commits beside an approved capture" "$(check_as_claude)" "[rc=0]"
reset

put "docs/media/a b.png"
out=$(check)
expect "a space in the name is refused" "$out" "[rc=1]"
expect "and named whole" "$out" "docs/media/a b.png"
approve "docs/media/a b.png"
expect "a space in the name can be approved" "$(check)" "[rc=0]"
commit capture
git rm -q "docs/media/a b.png"
expect "deleting a capture passes" "$(check)" "[rc=0]"
reset

out=$("$scripts/approve-capture.sh" docs/media/x.png </dev/null 2>&1; echo "[rc=$?]")
expect "approval needs a terminal" "$out" "[rc=1]"
expect "says so" "$out" "terminal"
reject "approval writes nothing without a terminal" "$(cat captures.sha256)" "x.png"

[ "$fail" -eq 0 ] && echo "check-captures: all cases passed"
exit "$fail"
