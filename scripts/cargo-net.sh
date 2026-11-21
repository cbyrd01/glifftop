#!/bin/sh
# The one way this repo's cargo reaches the network: under Socket Firewall Free (sfw, pinned
# in mise.toml), which blocks known-malicious crates. .cargo/config.toml sets
# net.offline = true, so every other cargo command uses only what this has downloaded.
#
#   scripts/cargo-net.sh fetch --locked        download the crates Cargo.lock pins
#   scripts/cargo-net.sh update -p minicbor    change Cargo.lock (cooldown still applies)
#
# Runs in tools/fake-server, so relative paths in the arguments start there.
# sfw sees only downloads: a crate already in ~/.cargo/registry is never checked.
set -eu
command -v sfw >/dev/null || { echo "cargo-net: sfw not found; run mise install" >&2; exit 1; }

cd "$(dirname "$0")/../tools/fake-server"

# A Cargo older than 1.100 only warns about the 7-day cooldown and resolves anyway, e.g. when
# ~/.cargo/bin (rustup stable) comes before mise on PATH.
version=$(cargo --version | awk '{ print $2 }')
minor=$(echo "$version" | cut -d. -f2)
if [ "${version%%.*}" -eq 1 ] && [ "$minor" -lt 100 ]; then
    echo "cargo-net: cargo $version ignores the crate cooldown; need 1.100+ (mise's rust)" >&2
    exit 1
fi

exec sfw cargo --config net.offline=false "$@"
