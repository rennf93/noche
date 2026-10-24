#!/bin/bash
# Builds the native filter engine (Native/noche_adblock) and copies the archive to build/adblock/libnoche_adblock.a.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$PATH:$HOME/.cargo/bin"
cd "$ROOT/Native/noche_adblock"
nice -n 10 cargo build --release --target aarch64-apple-darwin -j 4
mkdir -p "$ROOT/build/adblock"
cp target/aarch64-apple-darwin/release/libnoche_adblock.a "$ROOT/build/adblock/libnoche_adblock.a"
