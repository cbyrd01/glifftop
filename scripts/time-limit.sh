#!/usr/bin/env bash
# time-limit.sh SECONDS COMMAND... — runs COMMAND, its output passing through. If it is still
# running after SECONDS, every process under it is interrupted (SIGINT, so SwiftPM stops its
# test helpers), then they and it are killed 5 s later, and this exits 124; otherwise it exits
# with COMMAND's status. Interrupted or terminated itself, it passes the signal on to all of
# them. For gate steps that can hang.
set -uo pipefail
if [ "$#" -lt 2 ] || ! [[ "$1" =~ ^[0-9]+$ ]]; then
    echo "usage: scripts/time-limit.sh SECONDS COMMAND..." >&2
    exit 2
fi
limit=$1
shift
flag=$(mktemp)
trap 'rm -f "$flag"' EXIT

# tree PID — PID and its descendants. A process that left the process group is still found.
tree() {
    local child
    echo "$1"
    for child in $(pgrep -P "$1"); do tree "$child"; done
}

# Job control: COMMAND isn't started with SIGINT ignored, as a background job otherwise is.
set -m
"$@" &
pid=$!
set +m

(
    trap 'kill "$nap" 2>/dev/null; exit 0' TERM
    sleep "$limit" &
    nap=$!
    wait "$nap"
    kill -0 "$pid" 2>/dev/null || exit 0
    echo late >"$flag"
    started=$(tree "$pid")
    # COMMAND itself (`script`, holding the terminal its children write to) is left for the KILL.
    kill -INT $(echo "$started" | sed 1d) 2>/dev/null
    sleep 5
    # The first list too: a process whose parent has gone is no longer in the tree.
    kill -KILL $started $(tree "$pid") 2>/dev/null
) >/dev/null 2>&1 &
watcher=$!

# stop SIGNAL STATUS — this script was interrupted (Ctrl-C) or terminated: so is COMMAND, which
# job control put outside the terminal's process group.
stop() {
    kill "$watcher" 2>/dev/null
    kill "-$1" $(tree "$pid") 2>/dev/null
    exit "$2"
}
trap 'stop INT 130' INT
trap 'stop TERM 143' TERM

wait "$pid"
rc=$?
if [ -s "$flag" ]; then
    # COMMAND has ended; the watcher kills what is left of its tree.
    wait "$watcher"
    echo "time limit: still running after $limit s, so it was ended: $*" >&2
    exit 124
fi
kill "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null
exit "$rc"
