# Noche

Noche is an open-source macOS browser written in Swift on Chromium through CEF, with AI built in through hummin. Licensed under MIT.

## Build

```sh
scripts/fetch-cef.sh
scripts/build-cef-wrapper.sh
scripts/build-app.sh
scripts/smoke.sh build/Noche.app fixture
scripts/run.sh
```

`swift test` covers NocheCore only and needs no CEF, vendor/ or build/. `scripts/build-app.sh` opts the app, helper and bridge targets in
(`NOCHE_APP=1`); the throwaway spike targets exist only with `NOCHE_SPIKES=1` (set by `build-app.sh --product Spike...`).

The CEF sandbox is on by default; `NOCHE_NO_SANDBOX=1 scripts/build-app.sh` opts out, and the script prints which mode it built.
`scripts/check-sandbox.sh build/Noche.app` asserts the renderer runs with `--seatbelt-client`.

The mock keychain (`use-mock-keychain`) is for dev builds only: `scripts/build-app.sh` writes `NocheDevBuild` into Info.plist, and
`scripts/build-app.sh --release` leaves it out, so a release build uses the real keychain.

Run the app with `scripts/run.sh`, not `open build/Noche.app`: it copies the bundle to `~/Applications/Noche Dev/` first, because macOS asks for Documents access on every ad-hoc build launched from under `~/Documents`.

## Engine

Noche's engine is CEF 156 built from source on an external volume; see [engine/README.md](engine/README.md).
