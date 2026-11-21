#!/bin/sh
# Refuses a commit that stages a screen capture or stream recording the maintainer hasn't approved.
# A capture is any staged file under .recordings/, docs/media/ or a Fixtures/recorded/
# directory, or with an image, video or stream extension, except synthetic fixtures and the
# app's own assets. It is approved when the staged captures.sha256 has
# "<sha256 of the staged file>  <path>", a line only scripts/approve-capture.sh writes; a
# commit by Claude Code (CLAUDECODE set) may not add one. Run by the pre-commit hook for every
# commit.
set -u
# No globbing: names and lines split on newlines below are data.
set -f
cd "$(git rev-parse --show-toplevel)" || exit 1
nl='
'

needs_approval() {
    # In a case pattern `*` also matches `/`: the capture places come before the exemptions.
    case "$1" in
        .recordings/* | docs/media/* | */Fixtures/recorded/*) return 0 ;;
        Packages/GliffKit/Tests/*/Fixtures/synthetic/* | Glifftop/Assets.xcassets/*) return 1 ;;
    esac
    # Extensions in any case: images and screenshots, video, raw H.264/H.265, decoded frames,
    # Glifftop recordings.
    case "$1" in
        *.[Pp][Nn][Gg] | *.[Jj][Pp][Gg] | *.[Jj][Pp][Ee][Gg] | *.[Hh][Ee][Ii][CcFf] | *.[Gg][Ii][Ff] | \
            *.[Tt][Ii][Ff] | *.[Tt][Ii][Ff][Ff] | *.[Bb][Mm][Pp] | *.[Pp][Dd][Ff] | *.[Ww][Ee][Bb][Pp] | \
            *.[Aa][Vv][Ii][Ff] | *.[Mm][Oo][Vv] | *.[Mm][Pp]4 | *.[Mm]4[Vv] | *.[Ww][Ee][Bb][Mm] | \
            *.[Mm][Kk][Vv] | *.[Aa][Vv][Ii] | *.[Mm][Pp][Gg] | *.[Mm][Pp][Ee][Gg] | *.[Hh][Ee][Vv][Cc] | \
            *.[Hh]26[45] | *.26[45] | *.[Yy][Uu][Vv] | *.[Nn][Vv]12 | *.[Gg][Ll][Ii][Ff][Ff][Rr][Ee][Cc]) return 0 ;;
    esac
    return 1
}

# Plumbing only (cat-file, not show or diff): colour, textconv and diff attributes can't
# change what is read.
approved=$nl$(git cat-file blob :0:captures.sha256 2>/dev/null)$nl

# Claude's commits may not add an approval: every line staged must already be in HEAD.
if [ -n "${CLAUDECODE:-}" ]; then
    committed=$nl$(git cat-file blob HEAD:captures.sha256 2>/dev/null)$nl
    IFS=$nl
    for line in $approved; do
        case "$line" in "#"*) continue ;; esac
        case "$committed" in *"$nl$line$nl"*) continue ;; esac
        echo "check-captures: Claude can't approve captures; captures.sha256 gains lines only" \
            "from the maintainer (scripts/approve-capture.sh)." >&2
        exit 1
    done
    unset IFS
fi
unapproved=
# -z: git otherwise quotes unusual names. A name with a newline is split, and so refused.
names=$(git diff --cached --no-color --name-only -z --diff-filter=d | tr '\0' '\n')
IFS=$nl
for path in $names; do
    needs_approval "$path" || continue
    # Hash only a file the list names: an unlisted one is refused unread.
    case "$approved" in *"  $path$nl"*)
        sum=$(git cat-file blob ":0:$path" | shasum -a 256)
        case "$approved" in *"$nl${sum%% *}  $path$nl"*) continue ;; esac
        ;;
    esac
    unapproved="$unapproved  $path$nl"
done

[ -z "$unapproved" ] && exit 0
{
    echo "check-captures: these staged captures are not approved:"
    printf '%s' "$unapproved"
    echo "Captures stay local (.recordings/) unless the maintainer approves the exact file:"
    echo "  scripts/approve-capture.sh <file>..., then git add captures.sha256"
} >&2
exit 1
