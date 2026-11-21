#!/bin/sh
# Tests scripts/check-apple-skills.sh in a scratch copy of the repo, with a stub xcrun on PATH
# that "exports" the skills from a fixture directory (no Xcode needed).
set -u
cd "$(dirname "$0")/../.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0

mkdir -p "$T/bin" "$T/repo/scripts" "$T/export/demo/references"
cp scripts/check-apple-skills.sh "$T/repo/scripts/"
printf '#!/bin/sh\n# xcrun agent skills export --output-dir DIR\ncp -R "$STUB_EXPORT"/. "$5"\n' >"$T/bin/xcrun"
chmod +x "$T/bin/xcrun"

# The reviewed export: one adopted skill, plus one Apple ships that isn't adopted.
# Xcode writes a skill's front matter keys in no fixed order; these are in sorted order.
skill() { printf '%s\n' "$@" >"$T/export/demo/SKILL.md"; }
reviewed() { skill --- "description: |" "  first" "  second" "name: demo" --- body; }
reviewed
echo "ref" >"$T/export/demo/references/a.md"
mkdir -p "$T/export/other" && echo "x" >"$T/export/other/SKILL.md"
echo "-  demo/SKILL.md" >"$T/repo/scripts/apple-skills.sha256"  # names the adopted skill
(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" scripts/check-apple-skills.sh --manifest "$T/export") \
    >"$T/manifest" && mv "$T/manifest" "$T/repo/scripts/apple-skills.sha256"

run() { (cd "$T/repo" && STUB_EXPORT="$T/export" PATH="$T/bin:/usr/bin:/bin" scripts/check-apple-skills.sh "$@" 2>&1); }
expect() { case "$2" in *"$3"*) ;; *) echo "FAIL: $1: got: $2"; fail=1 ;; esac; }
status() { run "$@" >/dev/null; echo $?; }

expect "check before install asks for it" "$(run)" "scripts/check-apple-skills.sh --install"
expect "check before install fails" "$(status)" "1"

expect "install of the reviewed export" "$(run --install)" "Installed 1 Apple skill"
[ "$(cat "$T/repo/.claude/skills/demo/references/a.md" 2>/dev/null)" = "ref" ] \
    || { echo "FAIL: install copies the adopted skill"; fail=1; }
[ ! -e "$T/repo/.claude/skills/other" ] || { echo "FAIL: install skips skills not adopted"; fail=1; }
expect "check after install" "$(run)" "match the reviewed copies"

# The same skill exported with its front matter in another order is still the reviewed one.
skill --- "name: demo" "description: |" "  first" "  second" --- body
expect "front matter order doesn't matter" "$(run --install)" "Installed 1 Apple skill"
expect "nor when checking" "$(run)" "match the reviewed copies"

# Lines moved within a key's value are a change.
skill --- "description: |" "  second" "  first" "name: demo" --- body
expect "a value's own lines keep their order" "$(run)" "Adopted Apple skills changed"
reviewed

# Xcode now ships a changed skill: nothing is installed over the reviewed one.
echo "changed" >"$T/export/demo/SKILL.md"
expect "install refuses a changed export" "$(run --install)" "review the export"
expect "install of a changed export fails" "$(status --install)" "1"
[ "$(tail -1 "$T/repo/.claude/skills/demo/SKILL.md")" = "body" ] \
    || { echo "FAIL: a refused install leaves the installed copy"; fail=1; }
expect "check reports the change" "$(run)" "Adopted Apple skills changed"
# The changed export is kept for review, next to the build products.
expect "a changed export is kept" "$(run)" ".build/apple-skills-export"
[ "$(cat "$T/repo/.build/apple-skills-export/demo/SKILL.md" 2>/dev/null)" = "changed" ] \
    || { echo "FAIL: the kept export is the changed one"; fail=1; }

# A link in an export is never installed, even where the checksums match.
reviewed
ln -s /etc/hosts "$T/export/demo/references/link"
expect "install refuses a link" "$(run --install)" "not a plain file"
[ ! -e "$T/repo/.claude/skills/demo/references/link" ] || { echo "FAIL: a link was installed"; fail=1; }
rm "$T/export/demo/references/link"

# Xcode drops an adopted skill: reported as a change, not a silent failure.
mv "$T/export/demo" "$T/demo.away"
expect "a dropped skill is a change" "$(run)" "Adopted Apple skills changed"
mv "$T/demo.away" "$T/export/demo"

expect "unknown argument" "$(run --bogus)" "usage:"

exit $fail
