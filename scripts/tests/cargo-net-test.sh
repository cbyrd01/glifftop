#!/bin/sh
# Tests scripts/cargo-net.sh's Cargo version guard with stub cargo and sfw on PATH: a Cargo
# older than 1.100 (which ignores the crate cooldown) is refused before sfw runs.
set -u
cd "$(dirname "$0")/../.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
printf '#!/bin/sh\necho "STUB SFW RAN: $*"\n' >"$T/sfw"
chmod +x "$T/sfw"
for v in 1.97.0 1.100.0 2.0.0; do
    mkdir "$T/$v"
    printf '#!/bin/sh\necho "cargo %s (stub)"\n' "$v" >"$T/$v/cargo"
    chmod +x "$T/$v/cargo"
done
run() { PATH="$T/$1:$T:/usr/bin:/bin" scripts/cargo-net.sh fetch 2>&1; }

case $(run 1.97.0) in *"STUB SFW RAN"*) echo "FAIL: ran sfw with cargo 1.97"; fail=1 ;; esac
case $(run 1.100.0) in *"STUB SFW RAN: cargo --config"*) ;; *) echo "FAIL: refused cargo 1.100"; fail=1 ;; esac
case $(run 2.0.0) in *"STUB SFW RAN"*) ;; *) echo "FAIL: refused cargo 2.0"; fail=1 ;; esac
[ "$fail" -eq 0 ] && echo "cargo-net: all cases passed"
exit "$fail"
