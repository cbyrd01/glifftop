#!/usr/bin/env bash
# Tests scripts/unfinished-tests.sh: from `swift test --verbose` output, it names each Swift
# Testing test that started and never passed, failed or was skipped.
set -uo pipefail
cd "$(dirname "$0")/../.."
fail=0
expect() { case "$2" in *"$3"*) ;; *) echo "FAIL: $1: got: $(echo "$2" | head -5)"; fail=1 ;; esac; }
refute() { case "$2" in *"$3"*) echo "FAIL: $1"; fail=1 ;; esac; }

log=$(printf '%s\n' \
    $'^D\b\b◇ Test echoed() started.' \
    'Test Suite '\''All tests'\'' started at 2026-11-22 03:11:51.566.' \
    $'\e[1;38;5;244m◇\e[0m Test passes() started.' \
    $'\e[1;32m✔\e[0m Test passes() passed after 0.001 seconds.' \
    '◇ Test fails() started.' \
    '✘ Test fails() recorded an issue at A.swift:3:5: Expectation failed' \
    '✘ Test fails() failed after 0.002 seconds with 1 issue.' \
    '◇ Test cases(name:) started.' \
    '◇ Test case passing 1 argument name → "a" (Swift.String) to cases(name:) started.' \
    '✔ Test cases(name:) with 2 test cases passed after 0.004 seconds.' \
    '◇ Test hangs() started.' \
    '◇ Test sameName() started.' \
    '◇ Test sameName() started.' \
    '✔ Test sameName() passed after 0.001 seconds.' \
    '➜ Test needsAHost() skipped: "set GLIFFTOP_LIVE_HOST"' \
    '◇ Test "A display name" started.' \
    '◇ Suite HangingTests started.' \
    '◇ Test run started.' \
    $'◇ Test crlf() started.\r' \
    $'✔ Test crlf() passed after 0.001 seconds.\r' \
    '✘ Test run with 9 tests in 2 suites failed after 600.1 seconds with 1 issue.')
out=$(echo "$log" | scripts/unfinished-tests.sh)
expect "a test that never ended is named" "$out" "✘ Test hangs() never finished"
expect "a display name is named whole" "$out" '✘ Test "A display name" never finished'
expect "of two tests with one name, the one still running is named" "$out" "✘ Test sameName() never finished"
refute "a passed test isn't named" "$out" "passes()"
refute "a failed test isn't named" "$out" "fails()"
refute "a parameterized test that passed isn't named" "$out" "cases("
refute "a skipped test isn't named" "$out" "needsAHost"
refute "suites aren't named" "$out" "HangingTests"
refute "the run isn't named" "$out" "Test run"
refute "a pseudo-terminal's line ends are read" "$out" "crlf"
expect "a start line after script's echoed ^D is read" "$out" "✘ Test echoed() never finished"
expect "one line per unfinished test" "$(echo "$out" | wc -l | tr -d ' ')" "4"

out=$(echo '✔ Test passes() passed after 0.001 seconds.' | scripts/unfinished-tests.sh)
expect "nothing unfinished prints nothing" "[$out]" "[]"

exit $fail
