# Noche

Noche is an open-source macOS browser written in Swift on Chromium through CEF, with AI built in through hummin. Licensed under MIT.

Status: M1.1 is done (window, sidebar, toolbar and many tabs on the patched engine). Self-tests and evidence are in `docs/app/`.

## Build

```sh
scripts/fetch-cef.sh
scripts/build-cef-wrapper.sh
scripts/build-app.sh
scripts/smoke.sh build/Noche.app fixture
scripts/run.sh
```

`CEF_DIST=<distribution dir> scripts/fetch-cef.sh` vendors our own engine build (see `engine/`) instead of the download.

The app needs our engine's tab API, which the stock download lacks: CI runs `swift test` always and the wrapper, app build, smoke and sandbox steps only when the repo variable `NOCHE_ENGINE_URL` (a tar.bz2 of the engine distribution) is set.

`swift test` covers NocheCore only and needs no CEF, vendor/ or build/. `scripts/build-app.sh` opts the app, helper and bridge targets in
(`NOCHE_APP=1`); the throwaway spike targets exist only with `NOCHE_SPIKES=1` (set by `build-app.sh --product Spike...`).

The CEF sandbox is on by default; `NOCHE_NO_SANDBOX=1 scripts/build-app.sh` opts out, and the script prints which mode it built.
`scripts/check-sandbox.sh build/Noche.app` asserts the renderer runs with `--seatbelt-client`.

The mock keychain (`use-mock-keychain`) is for dev builds only: `scripts/build-app.sh` writes `NocheDevBuild` into Info.plist, and
`scripts/build-app.sh --release` leaves it out, so a release build uses the real keychain.

Run the app with `scripts/run.sh`, not `open build/Noche.app`: it copies the bundle to `~/Applications/Noche Dev/` first, because macOS asks for Documents access on every ad-hoc build launched from under `~/Documents`.

## Engine

Noche's engine is CEF 156 built from source on an external volume; see [engine/README.md](engine/README.md).

App self-tests (`scripts/app-test.sh hidden close-last quit-many`) build Noche.app with `NOCHE_TESTHOOKS=1` and drive it hidden through `--selftest <check>`; see the header of that script.

Engine probes (`scripts/probe-engine.sh <check>...`) build and run `Probes/EngineProbe` against the vendored CEF; see the header of that script.
