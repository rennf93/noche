# Engine

Noche runs on CEF 8078 (Chromium 156.0.8078.48) built from source, not the downloaded binary. The M0 spike verdict (`docs/spikes/README.md`): the stock distribution leaves gaps for extensions across many tabs (no extension toolbar actions, `chrome.tabs.query` sees one tab), and closing them takes patches to CEF and Chromium, which needs a source build.

## Pins

- CEF branch `8078`, commit `426920c33ef22551e0b8f48cf343d623ac25642d`
- arm64, Release only (Debug would need about 150 GB; the volume has 140 GiB)

## Root

Everything lives under `NOCHE_ENGINE_ROOT` (default `/Volumes/K3Trunk/noche-engine`): `chromium_git`, `depot_tools`, `automate`, `distrib`, `logs`, and the vpython and CIPD caches. Nothing lands on the internal disk. If the root is missing, every command exits 1 with `engine root missing: <path>`. Override with `NOCHE_ENGINE_ROOT=/other/path`, which must be on an external volume: the scripts refuse the internal disk (`engine root is on the internal disk: <path>`).

`build` refuses to start with less than 40 GiB free (`NOCHE_ENGINE_MIN_FREE_GB`).

## Commands

Run in order, each logs to `$NOCHE_ENGINE_ROOT/logs/<step>-<UTC timestamp>.log`:

1. `engine/build.sh checkout` - fetch Chromium and CEF at the pins with CEF's `automate-git.py` (no build, no distribution).
2. `engine/build.sh patch` - reset local branch `noche` in `chromium/src/cef` to the pinned commit and `git am` every `engine/patches/*.patch` in name order. Safe to repeat; a failing patch aborts, restores the pinned commit and exits 1.
3. `engine/build.sh build` - `tools/gclient_hook.py` (applies CEF's Chromium patches, then `gn gen`), then `autoninja -C out/Release_GN_arm64 cefclient`. A repeat after a finished build does no compile work.
4. `engine/build.sh distrib` - `make_distrib.py` minimal, arm64, no docs, no symbols, no archive. Output: `$NOCHE_ENGINE_ROOT/distrib/cef_binary_<version>_macosarm64_minimal`.

`engine/test.sh` checks the guards and the patch step without touching the checkout.

## GN defines

- `is_official_build=false`: skips the official-build link and optimization cost.
- `symbol_level=0 blink_symbol_level=0 v8_symbol_level=0`: no debug symbols, which keeps the output small and the link fast.
- `proprietary_codecs=true ffmpeg_branding=Chrome`: H.264 and AAC playback. Distributing a build with these needs a licensing decision before any public binary.

## Baseline numbers

(Filled in after the first full build.)
