# noche_adblock

A thin C-ABI wrapper (Rust static library) over the `adblock` crate (adblock-rust), used by Noche's content blocking.

- Our wrapper code is MIT, like the rest of the repo.
- The `adblock` crate is MPL-2.0 and is used unmodified as a dependency (pinned in Cargo.toml and Cargo.lock).
- Filter lists are downloaded at runtime from their owners and are never committed to this repo.
- The C header is `Sources/CNocheAdblock/include/noche_adblock.h`.

Build with `scripts/build-adblock.sh`, which writes `build/adblock/libnoche_adblock.a`.
