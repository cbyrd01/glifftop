#!/bin/sh
# Reports upstream gliff releases newer than the version tools/fake-server pins, so the maintainer can
# decide whether and when to adopt one (see "Watching upstream" in CLAUDE.md). One read-only
# `gh release list`; it never changes the pin.
#
#   scripts/check-upstream.sh            one summary line, plus each newer release
#   scripts/check-upstream.sh --quiet    print only news: a newer release, or a pin it can't
#                                        place; silent if gh is offline (for a session hook)
#
# It compares versions: the gliff-proto version Cargo.lock resolved for the pinned rev, with
# upstream's release tags. We only pin release commits, so that version names the pin.
# Needs gh (GitHub CLI), signed in.
set -eu
cd "$(dirname "$0")/.."
case ${1:-} in
'' | --quiet) ;;
*) echo "usage: scripts/check-upstream.sh [--quiet]" >&2 && exit 2 ;;
esac

# The pinned commit's gliff-proto version, as Cargo resolved it.
version=$(awk '/^name = "gliff-proto"$/ { getline; gsub(/version = |"/, ""); print; exit }' \
    tools/fake-server/Cargo.lock)
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-.+)?$' ||
    { echo "check-upstream: no gliff-proto version in tools/fake-server/Cargo.lock" >&2; exit 1; }
command -v gh >/dev/null || { echo "check-upstream: gh not found (GitHub CLI)" >&2; exit 1; }

fetch() { gh release list -R omacom/gliff --exclude-drafts --limit 100 --json tagName,publishedAt,isPrerelease; }
# Into a variable, not a pipe, so a gh failure (offline, signed out) stops the script here.
if [ "${1:-}" = --quiet ]; then
    releases=$(fetch 2>/dev/null) || exit 0
else
    releases=$(fetch)
fi
printf '%s' "$releases" | /usr/bin/python3 -I -c '
import json, re, sys

def version(tag):
    """A sortable key for a tag like v0.4.3 or v0.5.0-rc.1, or None if it is neither. A
    pre-release sorts just below its release; suffixes are not compared with each other."""
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)(-.+)?", tag)
    if match is None:
        return None
    major, minor, patch, suffix = match.groups()
    return (int(major), int(minor), int(patch), 0 if suffix else 1)

pinned_tag, quiet = "v" + sys.argv[1], sys.argv[2] == "--quiet"
releases = json.load(sys.stdin)  # newest first
pinned = next((r for r in releases if r["tagName"] == pinned_tag), None)
if pinned is None:
    print(f"upstream: no upstream release {pinned_tag} among the latest; check by hand: "
          "https://github.com/omacom/gliff/releases")
    sys.exit(0)
# Newer by version number, not date: a backport to an older line is not news.
newer = [r for r in releases if (version(r["tagName"]) or ()) > version(pinned_tag)]
if not newer:
    if not quiet:
        print(f"upstream: up to date with {pinned_tag}")
    sys.exit(0)
plural = "s" if len(newer) > 1 else ""
print(f"upstream: {len(newer)} release{plural} newer than pinned {pinned_tag}:")
for r in newer:
    tag, date = r["tagName"], r["publishedAt"][:10]
    pre = " pre-release" if r["isPrerelease"] else ""
    print(f"  {tag} ({date}){pre} https://github.com/omacom/gliff/releases/tag/{tag}")
' "$version" "${1:-}"
