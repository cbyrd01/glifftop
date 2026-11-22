#!/usr/bin/env bash
# unfinished-tests.sh < LOG — reads `swift test --verbose` output and prints
# "✘ Test NAME never finished" for each Swift Testing test that started and never passed or
# failed: after a time limit, the tests a hang is stuck in. Tests sharing a name are counted.
# `script`'s echo of the ^D it sends (stdin at its end) and its \r line ends are dropped.
set -euo pipefail
sed '1s/^\^D\x08\x08//; s/\x1b\[[0-9;]*m//g; s/\r$//' | LC_ALL=C awk '
    /^◇ Test (case|run) / { next }
    /^(✔|✘) Test run / { next }
    /^◇ Test .* started\.$/ {
        name = $0
        sub(/^◇ Test /, "", name)
        sub(/ started\.$/, "", name)
        started[name]++
        next
    }
    /^(✔|✘) Test .* (passed|failed) after / {
        name = $0
        sub(/^[^ ]+ Test /, "", name)
        sub(/ (with [0-9]+ test cases? )?(passed|failed) after .*$/, "", name)
        ended[name]++
    }
    END {
        for (name in started)
            for (i = ended[name]; i < started[name]; i++) print "✘ Test " name " never finished"
    }' | sort
