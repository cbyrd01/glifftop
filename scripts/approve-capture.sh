#!/bin/sh
# The maintainer approves screen captures and recordings for the repo, one exact file at a time: shows
# each file, asks, and on "y" appends "<sha256>  <path>" to captures.sha256 (checked by
# scripts/check-captures.sh at commit). Interactive only: it refuses unless stdin is a terminal.
set -u
if [ ! -t 0 ]; then
    echo "approve-capture: run this yourself, in a terminal; approval is the maintainer's call." >&2
    exit 1
fi
if [ "$#" -eq 0 ]; then
    echo "usage: scripts/approve-capture.sh <file>..." >&2
    exit 2
fi
root=$(git rev-parse --show-toplevel) && root=$(cd "$root" && pwd -P) || exit 1
status=0
for file in "$@"; do
    if [ ! -f "$file" ]; then
        echo "approve-capture: no such file: $file" >&2
        status=1
        continue
    fi
    # The path as git names it (repo-relative, no ./ or ../), or the line never matches.
    dir=$(cd "$(dirname "$file")" && pwd -P)
    case "$dir/" in
        "$root/"*) path=${dir#"$root"}/$(basename "$file") && path=${path#/} ;;
        *)
            echo "approve-capture: not in this repo: $file" >&2
            status=1
            continue
            ;;
    esac
    echo "$path"
    echo "  $(file -b "$file"), $(wc -c <"$file" | tr -d ' ') bytes"
    # Quick Look shows what it can (a stream file gets an icon); closed after the answer.
    qlmanage -p "$file" >/dev/null 2>&1 &
    preview=$!
    printf 'Approve %s for the repo? [y/N] ' "$path"
    read -r answer
    kill "$preview" 2>/dev/null
    case "$answer" in
        y | Y)
            printf '%s  %s\n' "$(shasum -a 256 <"$file" | cut -d' ' -f1)" "$path" >>"$root/captures.sha256"
            echo "  approved; stage captures.sha256 with it."
            ;;
        *) echo "  not approved." ;;
    esac
done
exit "$status"
