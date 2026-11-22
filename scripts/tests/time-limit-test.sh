#!/usr/bin/env bash
# Tests scripts/time-limit.sh: a command that finishes keeps its output and status; one still
# running at the limit is ended, with everything it started, and the script exits 124.
set -uo pipefail
cd "$(dirname "$0")/../.."
fail=0
expect() { case "$2" in *"$3"*) ;; *) echo "FAIL: $1: got: $(echo "$2" | head -5)"; fail=1 ;; esac; }
refute() { case "$2" in *"$3"*) echo "FAIL: $1"; fail=1 ;; esac; }

out=$(scripts/time-limit.sh 5 bash -c 'echo hello; exit 3' 2>&1)
rc=$?
expect "a finished command's output passes through" "$out" "hello"
expect "a finished command's status is kept" "rc=$rc" "rc=3"
refute "a finished command isn't called slow" "$out" "time limit"

start=$SECONDS
out=$(scripts/time-limit.sh 1 bash -c 'echo begun; sleep 30' 2>&1)
rc=$?
expect "a command past the limit exits 124" "rc=$rc" "rc=124"
expect "it says so" "$out" "still running after 1 s"
expect "its output so far is kept" "$out" "begun"
[ $((SECONDS - start)) -lt 15 ] || { echo "FAIL: the limit didn't end it in time"; fail=1; }

# survives NAME [setpgrp] — a perl child that ignores INT and TERM (and, with setpgrp, leaves
# the process group, as swiftpm-testing-helper does); fails if it outlived the limit.
survives() {
    local code="\$SIG{INT} = \$SIG{TERM} = 'IGNORE'; ${2:-} sleep 30; # time-limit-test $1"
    scripts/time-limit.sh 1 bash -c 'perl -e "$1" & wait' bash "$code" >/dev/null 2>&1
    rc=$?
    expect "$1: still ends with 124" "rc=$rc" "rc=124"
    if pgrep -f "time-limit-test $1" >/dev/null; then
        echo "FAIL: $1: it outlived the limit"
        pkill -KILL -f "time-limit-test $1"
        fail=1
    fi
}
survives ignoring
survives leaving 'setpgrp(0, 0);'

# Interrupting time-limit.sh (Ctrl-C in the gate) ends the command too, not only the script.
set -m
scripts/time-limit.sh 100 perl -e 'sleep 30; # time-limit-test interrupted' >/dev/null 2>&1 &
limited=$!
set +m
sleep 1
kill -INT "$limited"
wait "$limited"
rc=$?
expect "an interrupted time limit exits 130" "rc=$rc" "rc=130"
sleep 1
if pgrep -f "time-limit-test interrupted" >/dev/null; then
    echo "FAIL: an interrupted time limit left its command running"
    pkill -KILL -f "time-limit-test interrupted"
    fail=1
fi

out=$(scripts/time-limit.sh 2>&1)
expect "no arguments is a usage error" "$out" "usage:"
out=$(scripts/time-limit.sh soon true 2>&1)
expect "a limit must be whole seconds" "$out" "usage:"

exit $fail
