# Noche shell (phase 2 scaffold)

The macOS app that will become the actual Noche browser: a thin AppKit chrome
(window + tab strip) around a CEF (Chromium Embedded Framework) browser, with
the phase-1 extension bundled as the default brain. Plain `swiftc` on purpose:
no SwiftPM, no xcodeproj, the sources are few and the CEF link step stays in a
readable script.

Current status is at the bottom ("Status of the scaffold pass"), including what
was actually executed and what the next slice is.

## Layout

```
shell/
  Info.plist                  minimal app bundle manifest (committed)
  Sources/
    main.swift                NSApplication bootstrap + CEF subprocess gate
    AppDelegate.swift         window construction, menus, CEF bootstrap
    TabStripView.swift        tab-strip placeholder (draws two static tabs)
    BrowserViewStub.swift     CEF browser region placeholder + mount seam
    CefReceipt.swift          reads the vendored-CEF receipt from Resources
    CefBridge.swift           Swift wrapper around the noche_* C API
    shim/
      cef_bridge.h            the noche_* C API (Swift bridge header)
      cef_bridge.mm           real CEF implementation (compiled in CEF mode)
      cef_bridge_stub.mm      no-op fallback (compiled in stub mode)
      helper_main.mm          helper subprocess main (Noche Helper binaries)
  scripts/
    fetch-cef.sh              download CEF macosarm64 into deps/ (gitignored)
    build.sh                  wrapper build + shim + helpers + app assembly
  deps/                       CEF binary distribution (gitignored)
  build/                      Noche.app output + cached wrapper lib (gitignored)
```

## Prerequisites

- Xcode with the full SDK (`xcode-select -p` points at Xcode.app; `swiftc --version` works).
- Node + npm for the extension brain (`npm run build` in the repo root).
- Network access to `cef-builds.spotifycdn.com` for the first fetch only.

## Build and run

```sh
# 1. Vendor CEF (macOS arm64 minimal distribution, ~135 MB download, ~340 MB
#    on disk). Skips itself if already vendored. Verifies sha1 against the
#    value pinned from the builds index.
shell/scripts/fetch-cef.sh

# 2. Build the extension brain if needed and assemble the app.
#    CEF mode (deps vendored): builds the libcef_dll wrapper static library
#    (cached under shell/build/cef-build; wipe shell/build to force), compiles
#    Sources/shim/cef_bridge.mm + helper_main.mm, links the Swift target with
#    -import-objc-header Sources/shim/cef_bridge.h, assembles Noche.app with
#    the CEF framework (versioned layout) and four Noche Helper*.app bundles,
#    and signs inside-out (Libraries dylibs, framework, helpers, app).
#    Stub mode (no deps): compiles cef_bridge_stub.mm; the app runs with the
#    placeholder browser region.
shell/scripts/build.sh

# 3. Run.
open shell/build/Noche.app
# or from a terminal (logs inline):
shell/build/Noche.app/Contents/MacOS/Noche
```

Environment switches for smoke runs (read by the app at startup):

- `NOCHE_URL` - URL to load; defaults to the bundled `fixture.html`
  (`Contents/Resources/fixture.html`, written by build.sh).
- `NOCHE_SMOKE_HOOK` - path of a file the shim writes on `OnLoadEnd` with
  `<page title>\t<url>`; the render-verification hook for scripted runs.
- `NOCHE_CEF_IPC_TIMEOUT` - when set, passed to CEF children as
  `--ipc-connection-timeout` so stalled children stay alive for sampling
  instead of self-terminating at 15 s (debug aid, see Status below).

CEF cache/profile lives in `~/Library/Application Support/Noche/CEF`; the CEF
log is `~/Library/Application Support/Noche/cef.log`.

`build.sh` does not require the CEF download: without `shell/deps/` it builds
and runs in stub mode (the browser region shows "CEF not vendored yet"). With
deps vendored, the stub reports the vendored CEF version.

## Rebase drill (phase-2 gate)

Moving onto a new CEF stable is a deliberate, recorded event, never a silent
pin bump:

```sh
# 1. Resolve and fetch the latest stable macosarm64 distribution.
CEF_CHANNEL=latest shell/scripts/fetch-cef.sh

# 2. Read the resolved version + sha1 out of the receipt.
cat shell/deps/CEF-VERSION.txt

# 3. Update the pin in shell/scripts/fetch-cef.sh:
#    DEFAULT_VERSION and DEFAULT_SHA1 (and DEFAULT_SIZE) get the values above.

# 4. Rebuild everything and smoke-run.
cd <repo root> && npm run build && shell/scripts/build.sh
open shell/build/Noche.app

# 5. Delete the previous distribution from shell/deps/ so only the new pin
#    remains, then commit the pin bump with the drill results.
```

Today the drill's pass criteria are: fetch succeeds with sha1 verified, the app
builds and launches with CEF initialized, and the smoke hook fires (page
rendered). As phase-2 gates land they stack onto this procedure:
WPT parity run, Speedometer 3 within 5% of stock Chromium, then the commit.

To fetch one specific version instead of latest:

```sh
CEF_VERSION='156.0.7+g47dbc1d+chromium-156.0.8078.17' shell/scripts/fetch-cef.sh
```

(ad-hoc versions have no pinned sha1, so verification is skipped and the
receipt records `sha1=unverified`; use `CEF_CHANNEL=latest` for drills so the
sha1 comes from the index.)

## Rebase drill log

One entry per executed drill: from-version, to-version, outcome, elapsed.
An entry never changes the pin by itself; a kept bump is a separate commit.

- 2026-10-23, `156.0.7+g47dbc1d+chromium-156.0.8078.17` -> `156.0.7+g47dbc1d+chromium-156.0.8078.17`
  (no bump available), outcome: mechanics pass, render gate blocked
  (pre-existing), elapsed ~7 min. Queried the builds index live: the pin is
  the strict newest stable macosarm64 minimal (first of all 454 stable
  entries; no newer 156.x patch exists; the beta channel's newest is also
  156.0.7), so the drill ran as an identity drill at the newest stable.
  Passed: cold re-fetch after deleting `deps/` (fresh 134,827,440-byte
  download, `sha1 OK: 038a6ce70a814181f6a507d40155c81e80b328e3`, 20 s) and a
  full rebuild from a wiped `shell/build` (wrapper recompiled, 330 MB app,
  41 s). Failed: the render gate. With `NOCHE_SMOKE_HOOK` set the hook file
  stayed absent at 60 s while `CefInitialize` succeeded and three utility
  children printed the handshake failure from the status section below
  (`child_thread_impl.cc:931 Terminating current process after 15 seconds
  with no connection`). A control run on the same pin before the drill failed
  identically, so this is the known utility-process blocker, not a regression
  of a bump. No pin change resulted, so there was nothing to revert. The
  drill's pass criteria stay unmet until the utility-process handshake is
  unblocked (resume pointers in the status section).

## Notarization

Local dev builds are ad-hoc signed (`codesign --force --deep --sign -`). For
distributable artifacts:

```sh
# 1. Sign with hardened runtime. Sign inside-out: the CEF framework's
#    Libraries dylibs, the framework, each Noche Helper*.app, then the app
#    (build.sh already applies this order with an ad-hoc identity).
codesign --force --options runtime \
  --entitlements shell/packaging/noche.entitlements \
  --sign "Developer ID Application: <NAME> (<TEAMID>)" \
  shell/build/Noche.app

# 2. Zip and submit to the notary service.
ditto -c -k --keepParent shell/build/Noche.app Noche.zip
xcrun notarytool submit Noche.zip --keychain-profile noche-notary --wait

# 3. Staple and verify.
xcrun stapler staple shell/build/Noche.app
spctl -a -t exec -vv shell/build/Noche.app
```

`noche-notary` is a keychain profile created once with
`xcrun notarytool store-credentials`. The entitlements file does not exist yet
because nothing consumes it; when the CEF frameworks are linked it must carry
at minimum (standard for Chromium/CEF apps):

- `com.apple.security.cs.allow-jit`
- `com.apple.security.cs.allow-unsigned-executable-memory`
- `com.apple.security.cs.disable-library-validation`

## Status of the CEF integration pass (2026-10-23)

Executed and verified in this pass, on arm64 / macOS 27.0.1 / Xcode Swift 6.4,
against CEF `156.0.7+g47dbc1d+chromium-156.0.8078.17` (minimal, macosarm64):

Working end to end:

- `scripts/build.sh` CEF mode: builds the `libcef_dll` wrapper static library
  (211 sources, `clang++ -std=c++20 -fno-rtti -fno-exceptions -DWRAPPING_CEF_SHARED`,
  cached at `build/cef-build/libcef_dll_wrapper.a`), compiles the ObjC++ shim
  and the helper executable, links the Swift target via
  `-import-objc-header Sources/shim/cef_bridge.h` (`-lc++ -framework IOSurface`
  for the wrapper), assembles `Noche.app` (327 MB) with the CEF framework in
  the versioned layout from the distribution's `cmake/cef_macros.cmake`, four
  helper bundles (`Noche Helper.app`, `Noche Helper (Alerts|GPU|Renderer).app`;
  the per-type names match what libcef composes at runtime - the `(Alerts)`
  one is requested verbatim in child command lines), and signs inside-out.
  Stub mode still builds and compiles (verified with a direct clang++ pass on
  `cef_bridge_stub.mm`).
- The app launches, `noche_cef_execute_process` returns -1 (browser path),
  `CefInitialize` succeeds, the window opens, and the GPU helper process
  launches, loads the framework via `CefScopedLibraryLoader::LoadInHelper`,
  applies its seatbelt (`--seatbelt-client=N` in its args) and CONNECTS.

NOT working (blocked, precise state):

- The browser's utility subprocesses (network + storage + notifications) are
  launched with correct command lines and bundles, apply their sandbox, load
  the framework, and then never complete the mojo channel handshake: each
  prints `content/child/child_thread_impl.cc:931 Terminating current process
  after 15 seconds with no connection.` and self-terminates. Because browser
  startup waits on the network service, `OnContextInitialized` never fires,
  so `CreateBrowser`/`OnAfterCreated` never run and no page renders yet (the
  smoke hook stays absent). Sampled the child main thread at +4 s: it sits in
  `cef_execute_process` internals pumping an NSRunLoop - a Chromium child
  waiting for its mojo invitation/ping that the browser side never completes
  (GPU children complete the same handshake fine, which is the puzzling
  asymmetry).

Tried and ruled out this pass (all with the same result):

- `CefSettings.no_sandbox = 1` vs default sandbox on with
  `CefScopedSandboxContext::Initialize` in `helper_main.mm` (both configs).
- Single `Noche Helper.app` vs the full per-type bundle set (no change).
- Children with `--v=1 --enable-logging=stderr` (propagated via
  `CefApp::OnBeforeChildProcessLaunch`, verified present in child args): the
  children log NOTHING before the terminating line.
- `--ipc-connection-timeout=180`: children stay alive (sandboxed, idle) for
  minutes but the handshake never completes.
- Chromium source check (`content/child/child_thread_impl.cc`, main): the
  timeout fires only after `ChildThreadImpl::Init` ran, i.e. the child got
  past rendezvous-invitation recovery; what is missing is the browser side
  completing/pinging the channel for utility-type children.

Resume pointers for the next session (in order of suspicion):

1. Build the OFFICIAL cefclient/cefsimple from this same distribution
   (cmake out of `shell/deps/cef_binary_*/`) and run it on this machine. If
   it reproduces, the blocker is environmental (machine/OS/CEF 156 bug) and
   belongs upstream; if it works, diff its app bundle against ours
   (`ls -laR` both, plus `codesign -dv` each) - the delta is the bug.
2. The main binary links the wrapper and loads the framework at runtime, and
   the main executable is Swift/ARC - compare how the browser-side
   `ChildProcessLauncher` behaves with a plain C++ host binary for the main
   process (minimal repro: strip our AppKit layer, keep the shim).
3. Check Console.app for `AMFI`/`sandbox`/`RunningBoard` denials scoped to
   the helper processes at launch time.

Not done yet (next slices, in order):

1. Unblock the utility-process handshake above; only then does the page
   render and the smoke hook fire.
2. Real tab strip backed by a tab model, wired to browser lifetime.
3. Rebase drill automation: the manual procedure above stays the source of
   truth until the gates (WPT, Speedometer) exist.
