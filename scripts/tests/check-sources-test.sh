#!/bin/sh
# Tests scripts/check-sources.sh's no-print and one-subsystem rules on throwaway Swift files.
set -u
cd "$(dirname "$0")/../.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
check() {  # NAME EXPECT(flag|pass) SWIFT-LINE
    printf '%s\n' "$3" >"$T/Sample.swift"
    if scripts/check-sources.sh "$T/Sample.swift" >/dev/null 2>&1; then got=pass; else got=flag; fi
    [ "$got" = "$2" ] || { echo "FAIL: $1: expected $2, got $got"; fail=1; }
}
check "plain print" flag 'print(x)'
check "print after a URL string" flag 'let u = URL(string: "https://example.com")!; print(u)'
check "print in a comment" pass 'let x = 1  // print(x)'
check "print inside a string" pass 'let s = "call print(x) to debug"'
check "escaped quote, then print" flag 'let s = "a \"quoted\" //"; print(s)'
check "Logger call" pass 'logger.debug("https://x")'
check "the app's subsystem" pass 'let l = Logger(subsystem: "io.github.cbyrd01.Glifftop", category: "x")'
check "another subsystem" flag 'let l = Logger(subsystem: "me.example.Glifftop", category: "x")'
check "a subsystem constant, another" flag 'static let subsystem = "me.example.Glifftop"'
check "a subsystem constant, the app's" pass 'static let subsystem = "io.github.cbyrd01.Glifftop"'
[ "$fail" -eq 0 ] && echo "check-sources: all cases passed"
exit "$fail"
