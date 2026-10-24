# Noche app self-tests (M1.1)

M1.1 is the window shell: frameless window, sidebar, toolbar and many tabs on our patched engine. The app checks the shell itself, without a person or a visible window. Recorded run: `docs/app/evidence/m1-1-run.txt`.

## Run

```sh
scripts/app-test.sh <check>...      # one or more of the checks below
scripts/app-test.sh --negative      # each check with its negative-control switch; exits 0 only if every expected-FAIL pair fails
```

`scripts/app-test.sh` builds `Noche.app` with the test hooks (`NOCHE_TESTHOOKS=1`), serves `Tests/fixtures/app` on a free localhost port and runs `Noche --selftest <check> --selftest-url <url>` once per check by direct exec. A check passes only if the app printed `pass`, exited 0 and never hit the shutdown watchdog. The profile is `~/Library/Application Support/Noche Test`, wiped before each check, never the dev profile.

Regression gate: `swift test`, `scripts/build-app.sh`, `scripts/smoke.sh build/Noche.app fixture` (0), `scripts/smoke.sh build/Noche.app closed-port` (2), `scripts/check-sandbox.sh build/Noche.app` (0), then every check. A plain `scripts/build-app.sh` carries no test code (`strings ... | grep -c NOCHE_TEST` is 0).

## Hidden-run rules

- Every launch is hidden (`NCWindowModeHidden`): never `CefWindow::Show`, NSWindow alpha 0, ignores the mouse, floating level, ordered in with `orderWindow:NSWindowAbove relativeTo:0`, never key, never activates the app.
- Direct exec only: never `open`, never osascript, never system-level input. Input is synthesized `NSEvent`s handed to our own window and menu, or CDP.
- The script stops an app only by the one PID it started (TERM, then KILL after the app's own 40 s limit plus 20 s).
- Controls the app cannot give itself: new `Noche*.ips` crash reports (after a 3 s settle), the frontmost app (every 0.5 s, fails if it is ever Noche) and leftover helpers (polled up to 5 s).
- A hidden window gets no frames while the screen is locked, and a loaded CPU can trip the watchdog: a timeout then is not necessarily a code fault. Check `ioreg -n Root -d1 | grep CGSSessionScreenIsLocked` and `uptime`.

## Checks (22)

| Check | What it proves |
|---|---|
| hidden | the window never becomes key, never activates the app, is never frontmost |
| close-last | closing the last tab closes the window, the app stays alive, a new window has one tab |
| quit-many | quitting with 10 loaded tabs ends cleanly, no watchdog |
| web-insets | the page view covers its bounds, square top and rounded bottom corners |
| layout | window, sidebar card, toolbar and rows match the design geometry |
| tabs-keys | tab shortcuts (new, close, next, previous, by number) act on the right tab |
| tabs-rapid | rapid open and close (20 Cmd+W) leaves a consistent tab list |
| ext-count | the extension tab count equals the rows; tabs.create and tabs.update act on the rows |
| navigate | the address field navigates and the row title and address follow |
| blank-link | a link with a blank target opens a new tab |
| long-title | a long title truncates in the row and the toolbar |
| load-error | a failed load shows the error page and the host in address and row |
| load-error-link | a link from the error page works |
| menu | the 36 menu lines equal the M1.1 list and the 6 edit actions are nil-targeted |
| sidebar-toggle | Cmd+S hides and shows the sidebar within the motion limits |
| sidebar-scroll | the tab list scrolls and a changed selection scrolls its row into view |
| shortcuts-once | each shortcut fires exactly once, with exact modifier matching |
| eval-async | async eval completions arrive |
| devtools-any-path | DevTools opened any way is found and tracked |
| no-zombie-tab | closed tabs vanish from the tab list at once |
| devtools-quit | quitting with DevTools open ends cleanly (hidden; see Owner checks) |
| devtools-close-tab | closing a tab with DevTools open ends cleanly |

Negative controls (`--negative`): `no-zombie-tab` with `NOCHE_TEST_NO_CLOSED_FILTER=1`, `hidden` with `NOCHE_TEST_NEGATIVE=activate` and `shortcuts-once` with `NOCHE_TEST_NOEXACT=1` must fail; `devtools-quit` with `NOCHE_TEST_DEVTOOLS_LAST=1` is recorded only (the engine crash it targets has not reproduced in a hidden run). The switches exist only in test-hook builds.

Tab-switch latency on an unlocked screen is in the evidence file (median 11.9 ms, p90 12.9 ms, limits 16.7 and 33.3 ms).

## Builder calls and rulings

Calls the design left open:

- Traffic lights are drawn circles in the sidebar and hide with it.
- With no pinned items the tab list starts at y 54, where the pinned grid would.
- The last tab closes the window.
- Google is the default search (`https://www.google.com/search?q=%s`).
- No close button on row hover, as captured.

Deviations and rulings that change behavior:

- The sidebar hide motion takes 125 ms against the reference's about 130 ms, within the design's 15 ms tolerance.
- `tabs-rapid` uses 20 Cmd+W.
- The window opens 2320 wide at x 240 whatever bounds are requested (cause unknown); the checks set 2368x1436 explicitly.

## Owner checks (manual, visible)

Hidden runs can never have a key window or a visible screen, so these need a person:

1. Copy, Paste and Select All through the real menu, in the address field and in a page.
2. Quit with DevTools open, once from Opt+Cmd+I and once from the page's Inspect (the original crash never reproduced hidden).
3. Tab switching feels instant on screen with 20 tabs.
4. The sidebar slide looks right.
