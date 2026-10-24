# Chrome Web Store on our engine (task B4: experiments U3 and U4)

Engine under test: the vendored B5 engine (patches 0001-0003, Chromium 156.0.8078.48), probe app `Noche Probe`, hidden (alpha 0, click-through, never frontmost). Extension installed: uBlock Origin Lite, `https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh`, into the probe's own profile only (`~/Library/Application Support/Noche Probe`, wiped at the start of every store run).

## Answers

- U3, what shows the "Switch to Chrome?" banner: not the UA string, not `Sec-CH-UA`, not `navigator.userAgentData`. The banner is present in all four cases, including a first request that carries a `Google Chrome` brand. The trigger is something else (most likely a check inside the closed-source store page that is not satisfied by any header or JS-visible brand). P4 (a Client Hints brand patch) is dropped: it would change nothing.
- U4, does install work without any override: yes. On the stock UA and stock Client Hints (`Sec-CH-UA: "Not:A-Brand";v="8", "Chromium";v="156"`) the "Add to Chrome" button is enabled, Chrome's install sheet appears, and the install completes (extension on disk, button flips to "Remove from Chrome"). The S1 conclusion that install "needed a spoofed brand" was wrong; the banner is cosmetic.
- The stray window is real: every install opened a separate `BrowserNativeWidgetWindow` (1200x1396) plus a post-install dialog window, and made two activation attempts (see below). That is what patch P3 removes (`engine/patches/0004`).

## Table

All runs: same page, profile wiped first, override applied through CDP before the first navigation to the store (blank page loaded first), `Network.enable` on the tab. Header columns are the document request as sent (`Network.requestWillBeSentExtraInfo`).

| Case | Override | `Sec-CH-UA` of the store document request | `navigator.userAgentData.brands` | Banner | Add button | Install |
|---|---|---|---|---|---|---|
| stock | none | `"Not:A-Brand";v="8", "Chromium";v="156"` | Not:A-Brand 8, Chromium 156 | present ("Switch to Chrome?", also an "Install Chrome" button) | enabled | completed |
| ua | UA string with the full version (`Chrome/156.0.8078.48`), no metadata | header absent (no `sec-ch-ua*` at all) | `[]` | present | enabled | completed |
| brand | stock UA string, metadata with brands Not-A.Brand 24, Chromium 156, Google Chrome 156 | `"Not-A.Brand";v="24", "Chromium";v="156", "Google Chrome";v="156"` | all three | present | enabled | completed |
| ua-brand | full-version UA string plus the same metadata | same as brand | all three | present | enabled | completed |

How the cases are defined: CDP `Emulation.setUserAgentOverride` always carries a UA string, so "UA only" means a changed UA string with no `userAgentMetadata` (Chromium then sends no client hints), "brand only" means the stock UA string with metadata, "UA plus brand" both. The stock UA string already says `Chrome/156.0.0.0`; the "full version" string is the only UA-string change that could matter to a page.

## Evidence

Raw probe output per case, home directory scrubbed to `~`, with the lsappinfo frontmost sampling summary at the end:

- `docs/engine/evidence/b4-store-stock.txt`
- `docs/engine/evidence/b4-store-ua.txt`
- `docs/engine/evidence/b4-store-brand.txt`
- `docs/engine/evidence/b4-store-ua-brand.txt`

Each file has the `PROBE` lines: the override, the document request headers, the page state (banner count and text, buttons), the install sheet, the extension on disk, the window snapshots before and after, and the `activate calls blocked` count.

## Danger analysis: activation (done before any install ran)

The post-install path can take focus, and the alpha guard does not stop activation:

1. `ExtensionInstallUIDesktop::OnInstallSuccess` calls `FindOrCreateVisibleBrowser` (`chrome/browser/ui/extensions/extension_install_ui_desktop.cc:72-79`, call at :119-150).
2. That builds `chrome::ScopedTabbedBrowserDisplayer` (`chrome/browser/ui/scoped_tabbed_browser_displayer.cc:14-21`), which creates a normal Browser when `FindTabbedBrowser` finds none. A CEF-hosted Browser is `TYPE_POPUP` (`cef/libcef/browser/chrome/chrome_browser_host_impl.cc:426-428`) and `FindTabbedBrowser` accepts only `TYPE_NORMAL` (`profile_browser_collection.cc:27-50`), so a new window is always created.
3. Its destructor calls `browser_->GetWindow()->Show()` (`scoped_tabbed_browser_displayer.cc:35`) (or `Restore()` first, :31-33).
4. `BrowserView::Show` (`chrome/browser/ui/views/frame/browser_view.cc:1659-1704`) either activates an already visible widget (:1682-1686) or calls `browser_widget_->Show()` (:1700).
5. On macOS that ends in `NativeWidgetNSWindowBridge::SetVisibilityState(kShowAndActivateWindow)`, which runs `[NSApp activateIgnoringOtherApps:YES]` (`components/remote_cocoa/app_shim/native_widget_ns_window_bridge.mm:1075-1083`) and then `makeKeyAndOrderFront:`.

So yes: an unguarded install steals focus. The probe therefore got an activation guard before any install (main.mm `InstallActivationGuard`): `-[NSApplication activateIgnoringOtherApps:]`, `-[NSApplication activate]` and `-[NSRunningApplication activateWithOptions:]` are counted no-ops, install sheets get alpha 0 and click-through before `beginSheet:completionHandler:` (they are separate windows, outside the ordering swizzles), and a 5 ms timer zeroes any window alpha that slipped through. The store checks refuse to navigate if the guard is not installed. Result in every run that installed: `activate calls blocked=2` (the new Browser window's Show, and the post-install dialog window), `appActive=0` at the end, the owner's frontmost app never changed (sampled every 0.5 s through the whole run, the probe's ASN never the front one).

## What did not work as the plan said

- CDP `Input.dispatchMouseEvent` (move, press, release) returned `ok` but had no effect on the page in the hidden, inactive window: neither on the cookie consent button nor on "Add to Chrome". The page's own `click()` on the same button, run through CDP `Runtime.evaluate` with `userGesture: true`, worked both times and Chrome accepted it as the user gesture the install call needs. All installs here were started that way.
- The install confirmation is a views dialog shown as a sheet of the probe window. Accessibility did not expose it (the walk returned one `AXUnknown` node), a posted Return key did nothing, and a posted mouse click at the bottom right of the sheet (in-process `NSEvent` into the sheet window, never the window server) pressed "Add extension". No macOS system dialog appeared or was touched.
- The first launch of the series failed on the cookie consent page (the probe profile is wiped each run, so the consent page appears every time). Later launches click "Reject all" through the page. Three launches then aborted at navigation: a DevTools reply callback sent `Page.navigate` synchronously and CEF's observer list CHECKs on reentrancy (`base/observer_list.h:192`). The probe now posts every CDP send. Neither was an engine bug.
- Every install run ends with exit code 134 after the `pass` line: the stray Chrome window's Browser is still alive at `CefShutdown` (`chrome_browser_host_impl.cc:576` `DCHECK failed: !GetWebContents()`). It is handled by the probe's crash handler (no crash report, no dialog) and is expected to go away with P3, which creates no extra Browser.

## Launches

Experiments used 8 of 8: 1 failed consent step, 3 aborted at navigation (probe bug), 4 valid cases (stock, ua, brand, ua-brand).

## P3 and P4

P3 is written (not built): `engine/patches/0004-views-extension-installs-stay-in-the-window.patch`, a Chromium patch `chrome_browser_ui_extension_install_in_view.patch` for `extension_install_ui_desktop.cc`. In `FindOrCreateVisibleBrowser`, when no tabbed Browser exists, use the most recently active CEF-hosted Browser of the profile (not DevTools, with an active tab) instead of creating and showing a Chrome window. No new API.

P4 is dropped (U3: the brand is not the trigger).

The probe check `install-no-window` (same flow as `store-stock`, plus: browser-window count and tab count equal before and after, and the installed extension's service worker answers through `chrome.runtime.getContexts`) runs after the build.
