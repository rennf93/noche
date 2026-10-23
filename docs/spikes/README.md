# M0 spike verdict

Pin for all five spikes: CEF 156.0.7 (Chromium 156), macOS arm64. Each row below takes its verdict and finding from the linked doc;
every number is quoted from that doc.

Evidence location: the small text evidence (txt, tsv, log) the docs cite is committed under [evidence/](evidence/), one folder per spike
(`evidence/s1` to `s5`), together with the clean check output (`evidence/step2-clean-check.txt`) and `evidence/verdict-df.txt`. Screenshots,
recordings, and listings that could hold personal data (profile, dictionary and extension cache listings) were not committed; the home
directory name in the committed files is replaced by `USER`. The full set originally lived in `build/spikes/s1` to `s5` (gitignored).

| Spike | Verdict | Finding that matters most | Doc |
|---|---|---|---|
| S1 extensions in Chrome style next to our own chrome | partial | CEF allows only one Chrome-style browser view per window (19 refusals of "Cannot add multiple Chrome style BrowserViews"), so many tabs means one Chrome view plus Alloy views, or one Chrome-style window per tab; in the hybrid layout extension content scripts and request blocking work in Alloy tabs but `chrome.tabs.query` sees only the Chrome-style tab, and there is no CEF API for extension toolbar actions | [s1-chrome-style.md](s1-chrome-style.md) |
| S2 rounded Alloy card over vibrancy | partial | `cornerRadius = 10` with `masksToBounds = YES` on a plain container `NSView` parenting the Alloy browser view rounds the card cleanly at rest, in a live resize (0 corner violations in 59 frames) and on tab switch with no black flash; scroll smoothness (A4) is inconclusive | [s2-alloy-card.md](s2-alloy-card.md) |
| S3 media and platform features | partial | Widevine `requestMediaKeySystemAccess` fails in both runtime styles with the minimal CEF distribution; PiP, spellcheck suggestions and `SetAudioMuted` work in both; the audio-playing callback (`CefAudioHandler`) fires in Alloy only | [s3-media.md](s3-media.md) |
| S4 agent loop over the DevTools protocol | all pass | Accessibility tree, input, screenshot and cross-origin iframe control all work through `SendDevToolsMessage` with no debug port; medians range from 0.08 ms to 17.55 ms per call (`Page.captureScreenshot`) | [s4-agent-cdp.md](s4-agent-cdp.md) |
| S5 sandbox and hardened-runtime signing | all pass | The sandbox works with the shipped framework (renderer `--seatbelt-client=62`, GPU `--seatbelt-client=29`) and ad-hoc hardened-runtime signing verifies with `codesign --verify --deep --strict`; notarization was skipped (no Developer ID) | [s5-sandbox-signing.md](s5-sandbox-signing.md) |

## Decision per design section 13 item 1

Decision rule (approved design, section 13, paraphrased with the product name removed): the reference product's exact look, many tabs running fast, and Chrome Web Store extensions
are ranked equally by the owner, so no trade-off is pre-approved. If Spike 1 shows CEF can host many tabs with extensions (including
toolbar icons and popups, implemented by Noche if CEF has no API) beside Noche's own chrome, M1 proceeds on CEF. Anything less: stop and
bring the owner measured numbers (what failed, disk and build time for the alternative) for the route that keeps all three, a Chromium
build that owns its extension system. The switch is the owner's call, because it changes the cost of the whole project.

S1 is `partial`, not `all pass`, so M1 does not start on CEF by default. No option below has been acted on; the owner chooses.

### What S1 showed (each item cites the S1 doc line)

Failed or partial:
- C4, 20 Chrome-style browser views in one window: fail as written (line 22). CEF logs 19 times `Cannot add multiple Chrome style BrowserViews`
  and only tab 0 gets a browser. Two alternatives pass. Hybrid (1 Chrome view plus 19 Alloy views): switch latency median 9.7 ms (range
  9.3 to 10.0), RSS 2658.1 MB then 2628.3 MB for 20 loaded tabs in 25 processes. Window per tab (one frameless Chrome-style `CefWindow`
  per tab): switch latency median 25.8 ms (range 22.9 to 42.8), RSS 3411.5 MB then 3434.9 MB in 25 processes. One tab: 554.3 MB in 6
  processes. The RSS samples were taken with the screen locked (pages hidden), and a re-run for this fix round is `needs owner` (unlock
  needed), so treat RSS as roughly 2.6 to 3.4 GB for 20 live tabs.
- C4b, extension APIs across tabs: content scripts and request blocking work in Alloy tabs, but `chrome.tabs.query({})` returned count 1,
  only the Chrome-style tab (line 23). `chrome.tabs.sendMessage` and `activeTab` against an Alloy tab were not tested.
- C5, extension toolbar action from our own button: partial (line 24). No extension, action or popup entry point exists in the CEF headers.
  A popup page in an `NSPopover` renders blank and the browser stops answering CDP; the same page in a small frameless Chrome-style
  `CefWindow` child window renders and `chrome.*` works in it. That popup resolves "current tab" from its own window (shows "not a
  website") and `popup.html?tabId=` is not honoured. The popup's own slider was not clicked.
- C2, install and run: pass in the test harness, with caveats (lines 20 and 28). The install was proven under a spoofed UA brand (the
  "Switch to Chrome" banner stayed anyway), and the ad check ran in a modified network harness (host-resolver map plus
  `--ignore-certificate-errors` plus a local dummy script), so it does not show behavior against the real ad host or that install works
  without the brand override. Installing also opens a full visible Chrome browser window that the app has to hide or close, and
  `orderOut:` on it was not verified as a lasting fix.

What works:
- C1 page renders with no toolbar, tab strip or omnibox (line 19); C3 AppKit sidebar works as a sibling of the Views content view, not a
  child (line 21); C6 rounded card works with a `CAShapeLayer` mask on the Chrome-style path (line 25).
- Hybrid layout: one Chrome-style view plus Alloy views in one window; `ad:blocked` in Alloy tab 20 (lines 22 and 23).
- Content scripts and request blocking run in Alloy tabs (line 23); `chrome.tabs` sees only the Chrome-style tab (line 23).
- Extension popups work only in a side window (line 24, line 32).

### Alternative route: a Chromium build that owns its extension system

Figures as Chromium's own documentation states them, fetched 2026-10-23 from
https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md:
- Git cache size: "It mirrors every repo it fetches (~30 GB for Chromium) and is shared by all checkouts on the machine".
- Checkout time: "Expect the command to take 30 minutes on even a fast connection, and many hours on slower ones." (This is `fetch --git-cache chromium`.)
- Total disk for a checkout plus build output: the page gives no figure (a search of the page for GB, disk, hour and minutes finds only
  the two sentences above).
- Build time: the page gives no figure for a full build. It only says "Full rebuilds are about the same speed in Debug and Release, but
  linking is a lot faster in Release builds" and points to ccache. Nothing here is measured on this machine.

The sibling page https://chromium.googlesource.com/chromium/src/+/main/docs/get_the_code.md only links to the per-platform pages and
has no disk or time figure.

This machine's free disk, from `df -h /` (saved in `evidence/verdict-df.txt`): size 460Gi, used 13Gi, available 28Gi,
capacity 31%. The documented git cache alone (~30 GB) is larger than the 28Gi available, before any source checkout or build output.

### Options (no recommendation acted on; the owner chooses)

1. Proceed on CEF with the hybrid layout and accept the extension limits. Cost: `chrome.tabs` only knows the Chrome-style tab (one
   active tab at a time), extension toolbar actions are popups in a side window that resolve the current tab from that window, the
   install flow was only shown to work under a UA brand override (install without it was not tested) and opens a Chrome window to hide, and only one Chrome-style view per window is allowed.
   Gain: many tabs at a median 9.7 ms switch with Noche's own chrome intact, and no new build infrastructure.
2. Proceed on CEF and implement the missing extension pieces in Noche. What that would take per the S1 findings: build the toolbar icon
   and popup host ourselves (side window, since `NSPopover` renders blank), feed popups the right current tab (the popup does not honour
   `popup.html?tabId=`), bridge tab enumeration for Alloy tabs (`chrome.tabs.query` does not list them; `sendMessage` and `activeTab`
   against an Alloy tab are untested), and suppress the install flow's Chrome window. Whether `chrome.tabs` can be made to see Alloy tabs
   at all is not shown by S1; it is a risk, not a measured cost.
3. Switch to a Chromium build that owns its extension system. The design expects it to keep all three, because the build would own its extension system; no spike tested this. The
   documented cost is a ~30 GB git cache, 30 minutes or more of checkout time, and an undocumented (not measured here) build time, on a
   machine with 28Gi free. It changes the cost of the whole project, which is why it is the owner's call.

### Other findings that bear on M1

- S2: round the Alloy card with `cornerRadius = 10` plus `masksToBounds = YES` on a plain container `NSView` that parents the Alloy
  browser view; no `CAShapeLayer` mask needed (the mask is only for the Chrome-style path, S1 C6). Container layer colour `#1e1e1e` avoids a
  black flash. Needs `NSWindowCollectionBehaviorMoveToActiveSpace` for scripted capture. A4 (60 fps scroll) is inconclusive and needs a
  rerun. `CloseBrowser` never reached `OnBeforeClose` here (also noted in S4); re-check in the real app.
- S3: Widevine fails in the minimal build (single check, no extended wait, supplying a CDM ourselves untested). A tab-audible indicator
  via `CefAudioHandler` works in Alloy only and diverts the page audio to the handler. PiP, spellcheck suggestions and `SetAudioMuted` work in both styles.
- S4: the CDP method sequence for the agent loop is in `s4-agent-cdp.md` under "Method sequence for M2" (observer registration,
  `Accessibility.enable`, `Accessibility.getFullAXTree`, `DOM.getDocument` then `querySelector` then `getBoxModel` for click points,
  three `Input.dispatchMouseEvent` calls, `Input.insertText`, `Page.captureScreenshot`, `Target.setAutoAttach` with flatten for iframes).
  Observer callbacks arrive on the UI thread.
- S5: the sandbox can be on by default (the flag can be dropped); ad-hoc hardened-runtime signing passes with `codesign --verify --deep
  --strict`; notarization is not possible without a Developer ID. Not tested: Developer ID, `spctl`, sandbox with extensions or GPU-heavy pages.

## Full clean check (Step 2)

Command: `rm -rf build .build && scripts/build-cef-wrapper.sh && swift test && scripts/build-app.sh && scripts/smoke.sh build/Noche.app fixture`.
Result: 5 tests, 0 failures; build-app succeeded; `NOCHE_SMOKE load_end status=200 title=Noche Smoke Fixture`; `exit=0`. Output:
`evidence/step2-variant-wrapper-first.txt`. The first attempt without the
wrapper step failed and is kept as `evidence/step2-clean-check.txt`.
M1 item: `swift test` cannot run on a wiped tree without the wrapper step (`build/cef/libcef_dll_wrapper.a` is linked by Package.swift).
