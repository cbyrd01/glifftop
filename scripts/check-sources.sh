#!/bin/sh
# Source rules swift-format can't express. Usage: scripts/check-sources.sh [file.swift ...]
# With no arguments, checks every .swift file in Glifftop/, glifftop-askpass/,
# Packages/GliffKit/{Sources,Tests}
# and tools/encode-fixtures/{Sources,Tests}
# (run it from the repo root). Fails on:
#   - print(, debugPrint(, dump( or NSLog( outside Tests/, in code rather than comments
#     (log through os.Logger);
#   - a subsystem other than io.github.cbyrd01.Glifftop (`subsystem: "…"` or `subsystem = "…"`);
#   - a file over 400 lines;
#   - a swift-format-ignore directive without a reason in a plain // comment on the line above
#     (swift-format rejects any text after the rule names, so the reason can't share its line;
#     a /// doc comment or // MARK: is not a reason).
set -eu

# swift_files [FILE...] — the given .swift files, or every one in the checked folders,
# NUL-separated so paths with spaces survive.
swift_files() {
    if [ $# -eq 0 ]; then
        find Glifftop glifftop-askpass Packages/GliffKit/Sources Packages/GliffKit/Tests \
            tools/encode-fixtures/Sources tools/encode-fixtures/Tests -name '*.swift' -print0
    else
        for f; do
            case "$f" in *.swift) printf '%s\0' "$f" ;; esac
        done
    fi
}

if [ $# -eq 0 ] && ! { [ -d Glifftop ] && [ -d Packages/GliffKit ]; }; then
    echo "check-sources: Glifftop/ or Packages/GliffKit/ not found; run from the repo root." >&2
    exit 1
fi

# xargs -r: no files, no check. Any violation makes xargs exit non-zero; report it as 1.
swift_files "$@" | xargs -0 -r awk '
function report(message) { printf "%s:%d: %s\n", FILENAME, FNR, message; failed = 1 }
function explains(line) {
    return line ~ /^[ \t]*\/\/[ \t]*[^ \t]/ && line !~ /^[ \t]*\/\/\// &&
        line !~ /^[ \t]*\/\/[ \t]*MARK:/ && line !~ /swift-format-ignore/
}
FNR == 1 { previous = "" }
# Code only: blank out string literals (so "https://..." is not taken for a comment), then cut
# the comment.
{ code = $0; gsub(/"([^"\\]|\\.)*"/, "\"\"", code); sub(/\/\/.*/, "", code) }
FILENAME !~ /(^|\/)Tests\// &&
    code ~ /(^|[^A-Za-z0-9_.]|Swift\.)(print|debugPrint|dump|NSLog)[ \t]*\(/ {
    report("use os.Logger, not print(, debugPrint(, dump( or NSLog(")
}
# One subsystem, so the bug template'"'"'s log predicate finds every module'"'"'s logs.
match($0, /subsystem(:|[ \t]*=)[ \t]*"[^"]*"/) {
    name = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", name); sub(/"$/, "", name)
    if (name != "io.github.cbyrd01.Glifftop") report("log under the subsystem io.github.cbyrd01.Glifftop")
}
/swift-format-ignore/ && !explains(previous) {
    report("explain this swift-format-ignore in a plain // comment on the line above")
}
{ previous = $0; lines[FILENAME] = FNR }
END {
    for (file in lines) {
        if (lines[file] > 400) { printf "%s: %d lines; split it (limit 400)\n", file, lines[file]; failed = 1 }
    }
    exit failed
}
' || exit 1
