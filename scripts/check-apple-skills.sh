#!/bin/sh
# Apple's Xcode agent skills, used by Claude Code from .claude/skills/. Apple's licence doesn't
# allow redistributing them, so they are not in the repo: each clone exports them from its
# own Xcode. scripts/apple-skills.sha256 lists the reviewed versions of the adopted ones.
#
#   scripts/check-apple-skills.sh            compare the installed and the exported skills
#                                            with the reviewed versions (after an Xcode update)
#   scripts/check-apple-skills.sh --install  install the adopted skills from this Xcode, if
#                                            they are the reviewed versions
#   scripts/check-apple-skills.sh --manifest DIR
#                                            print the manifest for the skills in DIR
#
# Exit 1 if anything differs, so a changed skill is reviewed before adoption. To adopt one,
# review the export the check keeps in .build/apple-skills-export, then:
#   scripts/check-apple-skills.sh --manifest .build/apple-skills-export \
#       >| scripts/apple-skills.sha256 && scripts/check-apple-skills.sh --install
# A skill's front matter is hashed with its keys sorted: Xcode writes them in no fixed order.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
manifest="$root/scripts/apple-skills.sha256"
installed="$root/.claude/skills"
install=no
adopted=$(awk '{ split($2, p, "/"); print p[1] }' "$manifest" | sort -u)

# normalized FILE — the file with the keys of its front matter (between the first two "---"
# lines) sorted, each key with its value's lines (the indented lines after it) kept in order.
normalized() {
    end=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { print NR; exit }' "$1")
    if [ -z "$end" ]; then
        cat "$1"
        return
    fi
    sed -n "2,$((end - 1))p" "$1" |
        awk 'NR > 1 && !/^[ \t]/ { printf "\n" } { printf "%s\001", $0 } END { printf "\n" }' |
        LC_ALL=C sort | tr -d '\n' | tr '\001' '\n'
    sed -n "$end,\$p" "$1"
}

# listing DIR — the manifest-format checksums of the adopted skills' files under DIR.
listing() {
    (cd "$1" && find $adopted -type f 2>/dev/null | LC_ALL=C sort | while read -r file; do
        printf '%s  %s\n' "$(normalized "$file" | shasum -a 256 | cut -d ' ' -f 1)" "$file"
    done)
}

case "${1:-}" in
"") ;;
--install) install=yes ;;
--manifest)
    listing "${2:?usage: scripts/check-apple-skills.sh --manifest DIR}"
    exit 0
    ;;
*)
    echo "usage: scripts/check-apple-skills.sh [--install | --manifest DIR]" >&2
    exit 2
    ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

xcrun agent skills export --output-dir "$tmp" >/dev/null

# Skills Apple ships that we haven't adopted, listed for awareness.
for dir in "$tmp"/*/; do
    name=$(basename "$dir")
    echo "$adopted" | grep -qx "$name" || echo "not adopted: $name"
done

# Only plain files and folders: the checksums cover nothing else.
# A skill missing from the export is left to the diff below.
odd=$(cd "$tmp" && find $adopted ! -type f ! -type d 2>/dev/null || true)
if [ -n "$odd" ]; then
    echo "Refused, not a plain file in the export: $odd" >&2
    exit 1
fi

# One diff covers changed, added and removed files: "<" is reviewed, ">" is this Xcode's. A
# changed export is kept for review.
if ! listing "$tmp" | diff "$manifest" -; then
    kept="$root/.build/apple-skills-export"
    rm -rf "$kept" && mkdir -p "$root/.build" && cp -R "$tmp" "$kept"
    echo "Adopted Apple skills changed; review the export (.build/apple-skills-export) before" \
        "installing or updating them." >&2
    exit 1
fi

if [ "$install" = yes ]; then
    mkdir -p "$installed"
    for name in $adopted; do
        rm -rf "${installed:?}/$name"
        cp -R "$tmp/$name" "$installed/$name"
    done
    if ! listing "$installed" | diff -q "$manifest" - >/dev/null; then
        echo "The installed skills don't match the reviewed manifest; install again." >&2
        exit 1
    fi
    echo "Installed $(echo "$adopted" | wc -l | tr -d ' ') Apple skill(s) in .claude/skills/."
    exit 0
fi

if [ ! -d "$installed" ]; then
    echo "No Apple skills installed: run scripts/check-apple-skills.sh --install" >&2
    exit 1
fi
if ! listing "$installed" | diff "$manifest" -; then
    echo "The skills in .claude/skills/ differ from the reviewed manifest." >&2
    exit 1
fi
echo "Adopted Apple skills match the reviewed copies."
