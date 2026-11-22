# shellcheck shell=bash
# step NAME COMMAND... — runs one gate step quietly, its output in "$log" (set by the caller).
# On failure it prints the output and ends the gate with 1. A long log gets its failure lines
# (Swift Testing's ✘, compiler and cargo errors) first, since parallel test output can push
# them far above the tail. One awk reads the whole log, so neither a huge log nor binary
# bytes in it stop the gate early.
step() {
    local name=$1 start=$SECONDS
    shift
    if "$@" >"$log" 2>&1; then
        printf 'ok    %-18s %3ds\n' "$name" $((SECONDS - start))
        return
    fi
    printf 'FAIL  %-18s %3ds\n' "$name" $((SECONDS - start))
    if [ "$(wc -l <"$log")" -gt 60 ]; then
        sed 's/\x1b\[[0-9;]*m//g' "$log" | LC_ALL=C awk '
            /✘/ || /^error:/ || /: error:/ { if (++n <= 40) print }
            END { if (n > 40) print "(" n - 40 " more)" }'
        echo "--- the last 60 lines:"
    fi
    sed 's/\x1b\[[0-9;]*m//g' "$log" | tail -60
    exit 1
}
