#!/usr/bin/env bash
# Tests scripts/gate-step.sh, the gate's step runner, under the gate's own shell options.
set -uo pipefail
cd "$(dirname "$0")/../.."
fail=0
expect() { case "$2" in *"$3"*) ;; *) echo "FAIL: $1: got: $(echo "$2" | head -5)"; fail=1 ;; esac; }
refute() { case "$2" in *"$3"*) echo "FAIL: $1"; fail=1 ;; esac; }

# run CMD... — one step in a fresh gate shell; prints its output, then "rc=N".
run() {
    bash -c 'set -euo pipefail; log=$(mktemp); trap "rm -f \"$log\"" EXIT
        source scripts/gate-step.sh; "$@"' gate "$@" 2>&1
    echo "rc=$?"
}

out=$(run step good true)
expect "a passing step says ok" "$out" "ok    good"
expect "a passing step goes on" "$out" "rc=0"

out=$(run step short bash -c 'echo "x.swift:1:2: error: bad"; exit 3')
expect "a failing step says FAIL" "$out" "FAIL  short"
expect "a failing step ends the gate with 1" "$out" "rc=1"
expect "a short log is shown whole" "$out" "x.swift:1:2: error: bad"
refute "a short log isn't shown twice" "$out" "the last 60 lines"

out=$(run step long bash -c 'echo "✘ Test aTest() recorded an issue"; seq 200; exit 1')
expect "a failure far above the tail is shown" "$out" "✘ Test aTest()"
expect "then the tail" "$out" "--- the last 60 lines:"
expect "the tail's last line" "$out" "200"

out=$(run step detail bash -c 'echo "✘ Test aTest() recorded an issue at a.swift:3:5: Expectation failed: x == 2"
    echo "↳ x == 2 → false"; echo "↳   x → 7"; echo "◇ Test other() started."; seq 200; exit 1')
expect "a failure's values follow it" "$out" "↳   x → 7"
refute "lines after its values don't" "$(echo "$out" | sed '/the last 60 lines/,$d')" "other()"

out=$(run step many bash -c 'for i in $(seq 5000); do echo "f.swift:$i:1: error: e$i"; done; exit 1')
expect "many failures still end with 1" "$out" "rc=1"
expect "many failures still show the tail" "$out" "f.swift:5000:1: error: e5000"
expect "the failures past 40 are counted" "$out" "4960 more"

out=$(run step binary bash -c 'printf "error: a\0b\n"; seq 100; exit 1')
expect "a log with a NUL byte still shows its failure" "$out" "error: a"

out=$(run step noise bash -c 'echo "expected error: fine"; seq 100; exit 1')
refute "only diagnostics count as failures" "$(echo "$out" | sed '/the last 60 lines/,$d')" "expected error"

exit $fail
