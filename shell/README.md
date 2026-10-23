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
#    the CEF framework copied flat and verbatim from the distribution (no
#    Versions/ layout, no re-signing; see the layout-rules comment in
#    build.sh step 9) and four Noche Helper*.app bundles. Stub mode (no
#    deps): compiles cef_bridge_stub.mm; the app runs with the placeholder
#    browser region.
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
- `NOCHE_CACHE_ROOT` - overrides the cache root passed to CefInitialize; an
  empty value disables the on-disk cache entirely (cefclient's default).
- `NOCHE_NO_UA_OVERRIDE` - when set, skips the `user_agent_product` override
  so CEF settings match cefclient defaults exactly.
- `NOCHE_NO_CHILD_FLAGS` - when set, `OnBeforeChildProcessLaunch` stops
  appending `--enable-logging=stderr --v=1` so children launch with the exact
  command lines cefclient would produce.

The last three are cefclient-equivalence switches used while isolating the
utility-process stall; see the Status section for the bisection record.

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
  unblocked (resume pointers in the status section). Resolved later the same
  day: the stall was the missing CEF/NSApplication message-pump integration
  in the host shell, not a bump issue; the render gate now passes (see the
  status section).

## Notarization

Local dev builds carry no codesign seal at all: every Mach-O in the bundle
(main binary, helper binaries, framework dylibs) keeps the ad-hoc linker
signature applied at link time, which is exactly the signing state of the
official prebuilt cefclient bundle and verified sufficient on arm64 (a full
`codesign --force --sign -` pass over the bundle was one of the suspects
investigated during the utility-process stall; it is no longer applied - see
the layout-rules comment in build.sh step 9). For distributable artifacts,
sign inside-out with hardened runtime:

```sh
# 1. Sign with hardened runtime. Sign inside-out: the CEF framework's
#    Libraries dylibs, the framework, each Noche Helper*.app, then the app
#    (build.sh applies no signing locally; the distribution order matters).
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

## Status of the CEF integration pass (2026-10-23, render gate passes)

Executed and verified in this pass, on arm64 / macOS 27.0.1 / Xcode Swift 6.4,
against CEF `156.0.7+g47dbc1d+chromium-156.0.8078.17` (minimal, macosarm64).

The render gate that blocked the morning rebase drill now passes. Smoke run
(`NOCHE_SMOKE_HOOK` set exactly as documented, nothing else): the hook file
fires at ~5 s with `Noche CEF smoke fixture	<fixture url>`, the shim logs
`OnLoadEnd status=200 title="Noche CEF smoke fixture"`, five helper processes
(gpu, renderer, network, storage, notifications) stay up for the full 35 s
observation with zero `child_thread_impl.cc` handshake failures, then the app
is killed cleanly.

Working end to end:

- `scripts/build.sh` CEF mode: wrapper static library (cached), ObjC++ shim,
  helper executable, Swift target, app assembly with the framework copied
  FLAT and verbatim from the distribution and NO codesign pass (see below),
  four helper bundles. Stub mode unchanged.
- `CefInitialize`, browser creation (`OnAfterCreated`), real page load and
  render (`OnLoadEnd`), and the smoke hook, on both `file://` fixture pages
  and the default startup flow.

What was wrong, with the evidence trail (root cause last; it was not the
bundle layout):

1. Forensic diff vs the working prebuilt cefclient bundle (read-only
   reference at /tmp/cef-bisect, same CEF build; libcef shasum identical):
   the reference ships the framework FLAT (dylib at the framework root, no
   `Versions/`, no symlinks) and carries NO codesign seal anywhere - every
   Mach-O is linker-signed, no sealed resources. Our bundle re-wrapped the
   framework into `Versions/A` + symlinks and sealed everything with
   `codesign --force --sign -`. Helper Info.plists also lacked
   CFBundleDisplayName / CFBundleSignature / LSEnvironment /
   LSFileQuarantineEnabled / NSSupportsAutomaticGraphicsSwitching and used a
   boolean LSUIElement. build.sh now reproduces the reference layout exactly
   (flat copy, no signing, plist key parity; naming stays Noche).
2. Rebuilding with the reference layout did NOT fix the stall (same three
   utilities dying at the 15 s watchdog). The layout parity is kept - it
   removes the unexplained deltas - but the search moved to the host.
3. CefSettings bisection (empty cache path, no user_agent_product, children
   launched with cefclient's exact command lines via the NOCHE_* equivalence
   switches documented above): no change. Settings ruled out.
4. Executable bisection with minimal hosts placed INSIDE Noche.app (each host
   gets matching `<name> Helper.app` clones, because CEF composes the helper
   name as `<main executable basename> Helper[ (TYPE)].app` - hosts named
   anything else fail to spawn children at all with launch error 1003):
   - minhost (plain C++/ObjC, raw CEF calls, `CefRunMessageLoop`): all
     children connect. Bundle, helpers, wrapper, signing all exonerated.
   - minhost2 (same but driving our shim `cef_bridge.mm` verbatim): all
     children connect. Shim exonerated.
   - minhost3 (same shim, but `[NSApp run]` owns the loop and CEF is
     initialized from `applicationDidFinishLaunching`, exactly like the Swift
     shell): REPRODUCES the stall 1:1 - three utilities starve, GPU lives.
5. Root cause: the Swift shell never integrated CEF's message pump with
   NSApplication. With NSApp owning the main loop and
   `settings.external_message_pump` unset, CEF expects its own
   `CefRunMessageLoop` - nobody services CEF's UI-thread task queue, so
   browser-side work that completes child mojo channels never runs. GPU and
   (once a browser exists) renderer children complete their handshake on
   other threads and survive; the network/storage/notifications utilities
   sit in `EnsureConnectivity` until the 15 s watchdog kills them, and
   `OnContextInitialized` never fires, which is why no browser could be
   created before. The fix in `cef_bridge.mm`: `external_message_pump = 1`
   plus `OnScheduleMessagePumpWork` arming a repeating 2 ms heartbeat timer
   on the main run loop that calls `CefDoMessageLoopWork()` (a schedule-only
   one-shot timer variant was tried first and was NOT sufficient - minhost3
   still starved its utilities with it; continuous servicing matches
   `CefRunMessageLoop` semantics and does connect them).

Probe artifacts (`minhost*.mm` live under gitignored `shell/build/`; rebuild
with the clang++ line from build.sh step 3c plus `build/cef-build/
cef_bridge.o` and the wrapper archive) are wiped by every rebuild - the
recipes above are the durable record.

Next slices, in order:

1. Real tab strip backed by a tab model, wired to browser lifetime.
2. Refine the pump: replace the fixed 2 ms heartbeat with cefclient's
   run-loop-source scheme if profiling shows idle CPU cost.
3. Rebase drill automation: the manual procedure above stays the source of
   truth until the gates (WPT, Speedometer) exist; the render gate part of
   the drill now passes.
