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

Run the app with `scripts/run.sh`, not `open build/Noche.app`: it copies the bundle to `~/Applications/Noche Dev/` first, because macOS asks for Documents access on every ad-hoc build launched from under `~/Documents`.
