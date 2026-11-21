#!/bin/sh
# PostToolUse (Edit|Write|MultiEdit): format, lint and source-check an edited .swift file.
# Exit 2 with the violations on stderr so Claude sees and fixes them.
. "$(dirname "$0")/lib.sh"

# Most edits aren't Swift: skip the JSON parse unless the payload could name a .swift file.
case "$payload" in *'.swift"'*) ;; *) exit 0 ;; esac
eval "$(fields cwd tool_input.file_path)"
file=$tool_input_file_path
case "$file" in
    *.swift) ;;
    *) exit 0 ;;
esac
[ -f "$file" ] || exit 0
cd_project || exit 0
# Only the project's own files: a scratch file elsewhere isn't held to its rules.
case "$file" in "$PWD"/*) ;; *) exit 0 ;; esac

swift format format --in-place "$file" >/dev/null 2>&1
failed=false
if ! lint=$(swift format lint --strict "$file" 2>&1) || [ -n "$lint" ]; then
    failed=true
fi
sources=
if [ -x scripts/check-sources.sh ] && ! sources=$(scripts/check-sources.sh "$file" 2>&1); then
    failed=true
fi

if $failed; then
    printf '%s\n' "$lint" "$sources" | grep . >&2 || echo "$file: a source check failed." >&2
    exit 2
fi
