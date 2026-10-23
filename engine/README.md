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

Unpatched build of the pins above, 2026-10-23, on an Apple M2 Pro (12 cores, 32 GB) with the root on an external USB SSD.

- Checkout: about 17 minutes; `chromium_git` is 32 GB.
- Build: about 86,760 steps, 9,364 seconds of build time in total over four runs. The first stopped after 60 seconds on the missing Metal toolchain (now a preflight check), and two were stopped to free the machine. Each restart resumed where the previous run stopped.
- `out/Release_GN_arm64`: 9.1 GB. Re-running `build` after a finished build: 21 seconds, `ninja: no work to do`.
- `distrib`: 51 seconds; the minimal distribution is 711 MB (`cef_binary_156.0.8+g426920c+chromium-156.0.8078.48_macosarm64_minimal`).
- Free space on the root volume: 103 GiB before the build, 94 GiB after the distribution.
- A full build uses every core for hours. Run it when the machine is free, or stop it with SIGINT to the `siso` process and run `build` again later.

Noche on this engine passes the M0 checks: `docs/engine/evidence/task3-m0-checks.txt`.
