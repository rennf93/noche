# Noche app self-tests (M1.1)

M1.1 is the window shell: frameless window, sidebar, toolbar and many tabs on our patched engine. The app checks the shell itself, without a person or a visible window. Recorded run: `docs/app/evidence/m1-1-run.txt`.

## Run

```sh
scripts/app-test.sh <check>...      # one or more of the checks below
scripts/app-test.sh --negative      # each check with its negative-control switch; exits 0 only if every expected-FAIL pair fails
```

`scripts/app-test.sh` builds `Noche.app` with the test hooks (`NOCHE_TESTHOOKS=1`), serves `Tests/fixtures/app` on a free localhost port and runs `Noche --selftest <check> --selftest-url <url>` once per check by direct exec. A check passes only if the app printed `pass`, exited 0 and never hit the shutdown watchdog. The profile is `~/Library/Application Support/Noche Test`, wiped before each check, never the dev profile.

Regression gate (the screen-lock state and load go in the evidence header): `swift test` (the XCTest summary line, "Executed N tests, with 0 failures", is what counts; the Swift Testing line above it reports 0 tests), `scripts/build-app.sh`, `scripts/smoke.sh build/Noche.app fixture` (0), `scripts/smoke.sh build/Noche.app closed-port` (2), `scripts/check-sandbox.sh build/Noche.app` (0), then every check. A plain `scripts/build-app.sh` carries no test code (`strings ... | grep -c NOCHE_TEST` is 0, and `nm build/Noche.app/Contents/MacOS/Noche | grep -c inTransactionHook` is 0). The `nm` proof has a positive control: the same `nm | grep -c inTransactionHook` on a `NOCHE_TESTHOOKS=1 scripts/build-app.sh` build must print at least 1, or a 0 on the plain build proves nothing.

## Hidden-run rules

- Every launch is hidden (`NCWindowModeHidden`): never `CefWindow::Show`, NSWindow alpha 0, ignores the mouse, floating level, ordered in with `orderWindow:NSWindowAbove relativeTo:0`, never key, never activates the app.
- Direct exec only: never `open`, never osascript, never system-level input. Input is synthesized `NSEvent`s handed to our own window and menu, or CDP.
- The script stops an app only by the one PID it started (TERM, then KILL after the app's own 40 s limit plus 20 s).
- Controls the app cannot give itself: new `Noche*.ips` crash reports (after a 3 s settle), the frontmost app (every 0.5 s, fails if it is ever Noche) and leftover helpers (polled up to 5 s).
- A hidden window gets no frames while the screen is locked, and a loaded CPU can trip the watchdog: a timeout then is not necessarily a code fault. Check `ioreg -n Root -d1 | grep CGSSessionScreenIsLocked` and `uptime`.

## Checks (29)

| Check | What it asserts |
|---|---|
| hidden | one window with one tab, alpha 0, not key, floating level, ignores the mouse, the app never active, no activation attempt and no alpha attempt on our own windows, the page title read through CDP. "Never frontmost" is not asserted by the app: it comes from the script's sampling of the frontmost app |
| window-frame | the first window, a window on the primary screen and one on the second screen (when present) open with the frame asked for, in AppKit global coordinates, within 1 pt and with no `setFrame` repair. See Deviations for Stage Manager |
| close-last | closing the last tab closes the window, the app is still alive 2 s later, a new window has one tab |
| no-window | with no window open, File > New Tab (through the menu key equivalent) and Open Command Bar each open one window with one tab (the second with the address field being edited), and the reopen delegate called directly opens one too |
| quit-many | 15 loaded tabs in 2 windows (10 and 5): the Quit menu action ends with 15 `didCloseTab`, 2 `windowDidClose`, no shutdown watchdog |
| quit-100 | 100 loaded tabs in 2 windows (60 and 40) plus one DevTools, closed 100 ms apart so the quit outlasts a fixed 5 s watchdog: clean exit, 100 `didCloseTab`, 2 `windowDidClose`, the DevTools ended, no watchdog line, no crash report. The app's own limit for it is 90 s |
| web-insets | the page view covers its inset rect, square top corners and rounded bottom corners (mask), and setting the same insets again rebuilds neither the layout nor the mask |
| layout | window, sidebar, traffic lights, rows, card, toolbar buttons, address field, divider, page view and corner mask are within 1 pt of the design geometry in both sidebar states, plus 3 pixel samples (divider, toolbar, selected row) within 3 per channel of the same color through the same pipeline |
| tabs-keys | Cmd+T three times (4 rows, newest active), next and previous tab wrap, Cmd+W closes the selected row and selects the row below, a row click selects, the New Tab row adds a tab, a middle click closes a row; each shortcut acts exactly once. Cmd+1 to Cmd+9 and the tab moves are in `tab-chords` and `move-tab-relaunch` (M1.2) |
| tabs-rapid | 20 Cmd+T then 20 Cmd+W leaves 1 row, 1 engine tab (the first one) and an extension tab count of 1 |
| close-beforeunload | on a page that cancels its beforeunload, Cmd+W with the dialog answered Stay (test hook on the JS dialog callback) keeps the tab and keeps it selected, and a second Cmd+W answered Leave closes it and selects the other tab |
| ext-count | the extension's tab count equals the rows; `tabs.create` adds exactly one row and `tabs.update(active)` moves the selection |
| navigate | Cmd+L selects the URL, a typed host and path and a search load, back (Cmd+[) and forward (the button) work, Cmd+R reloads; row title and address follow |
| blank-link | a real mouse click (through the extension's debugger) on a `target=_blank` link opens one new row right after its opener, active, in the same window |
| long-title | titles of 300 W, Arabic and emoji stay inside their rows (pitch 37), show no ellipsis, have the fade mask with its stop 20 pt from the end, and the rows show the placeholder favicon. The toolbar is not examined |
| load-error | a typed address of a closed port shows the failed host in the row title and the address field, Back returns to the page. The error page itself is not asserted |
| load-error-link | a link on a normal fixture page to a closed port shows the failed host in the row title and address, Cmd+L seeds the field with the failed URL, Back returns to the page and clears the failure |
| menu | the 48 menu lines equal the M1.1 list plus the 11 tab by-number and move items of M1.2 (Move Tab Forward and Backward, Select Tab 1 to 8, Select Last Tab) and the 6 edit actions are nil-targeted |
| sidebar-toggle | Cmd+S hides and shows the sidebar, and the toolbar button hides it again, within the motion limits (see Deviations), with the traffic lights hidden and the show overshoot between 0.3 and 2.5 pt |
| sidebar-scroll | with 40 tabs at window heights 1436 and 800, Shift+Cmd+[ from tab 1 wraps to tab 40 and its row is fully visible, the row pitch stays 37, a row scrolled into view takes the click |
| shortcuts-once | each of 19 shortcuts (reload, force reload, zoom in, out and actual size, Copy URL, back, forward, Cmd+L, address editing, Cmd+S, Cmd+T, next, previous, Cmd+W, Cmd+N, close window, Opt+Cmd+I) acts exactly once with no repeated Chrome command; an unclaimed Cmd+K reaches the page. The exact modifier matching is shown by those counts and by the NOEXACT negative control |
| eval-async | evaluation completions never run inside a CEF callback (a normal reply, and a tab closed while evaluating); closed or closing tabs fail with "tab closed", later and never before the call returns |
| devtools-any-path | DevTools opened through a Chrome command Noche does not intercept (`IDC_DEV_TOOLS_CONSOLE`) is found; after the Quit menu action every DevTools browser ended before shutdown |
| no-zombie-tab | 20 tabs opened and closed in the same turn leave 1 tab and 1 row, and no closed tab is announced or listed again |
| devtools-quit | with DevTools open (Opt+Cmd+I), the Quit menu action ends cleanly and every DevTools browser ended before shutdown (hidden; see Owner checks) |
| devtools-close-tab | closing a tab with DevTools open (Cmd+W) closes the tab and its DevTools, the app is alive 2 s later |
| chromium-restore-relaunch | two-phase: 3 tabs open at quit, then the relaunch on the same profile has exactly 1 engine tab and 1 window (Chromium's own session restore adds none) |
| chromium-restore-crash-relaunch | the same after phase 1 is SIGKILLed with 3 loaded tabs: 1 engine tab and 1 window |
| a11y-labels | tab rows are buttons labelled with the tab title and carry the selected state, the New Tab row, the 4 toolbar buttons (Toggle Sidebar, Back, Forward, Reload) and the 3 window buttons are labelled buttons; also, a row's favicon goes back to the placeholder when the next page has none |

Negative controls (`--negative`): `no-zombie-tab` with `NOCHE_TEST_NO_CLOSED_FILTER=1`, `hidden` with `NOCHE_TEST_NEGATIVE=activate` and `shortcuts-once` with `NOCHE_TEST_NOEXACT=1` must fail; `chromium-restore-relaunch` and `chromium-restore-crash-relaunch` with `NOCHE_TEST_RESTORE_EXPECT=3` must fail; `devtools-quit` with `NOCHE_TEST_DEVTOOLS_LAST=1` is recorded only (the engine crash it targets has not reproduced in a hidden run). A pair counts as failed-as-expected only when the check printed its own `NOCHE_TEST <check> fail` line and the app exited 1 on it: a build failure, crash, timeout or missing binary fails `--negative`. The switches exist only in test-hook builds (`NOCHE_TESTHOOKS=1`; the bridge's declarations and counters follow the same switch), and `scripts/app-test.sh` ends by rebuilding `build/Noche.app` without them.

Tab-switch latency on an unlocked screen is in the evidence file (median 11.9 ms, p90 12.9 ms, limits 16.7 and 33.3 ms).

## Two-phase checks and Chromium session restore (M1.2)

A check whose name ends in `-relaunch` runs twice on one profile: `--selftest <check> --selftest-phase 1` on a wiped profile, then `--selftest-phase 2` on what phase 1 left. Each phase prints its own `NOCHE_TEST <check> pass`, and the check passes only if both did (a failed phase 1 skips phase 2). The crash-report diff, leftover-helper poll, frontmost poll and stderr tail cover both phases. The harness argument is in `SelfTest.swift`, the checks in `SelfTestStore.swift`.

`chromium-restore-relaunch` and `chromium-restore-crash-relaunch`: phase 1 opens 3 fixture tabs and waits for their loads. The first then quits normally (the Quit path closes every tab one by one); the second prints `phase1-ready` and `scripts/app-test.sh` SIGKILLs the one app PID it started, so no shutdown runs. Between the phases the script prints the profile's session files (`NOCHE_TEST <check> info sessions=...`). Phase 2 waits until the engine tab and window counts have held still for 3 s (cap 15 s) after the first load, then counts engine tabs (`NCWindow.tabs`), NSWindows of the process and controllers, before Noche restores anything. It also fails if phase 1 left no profile. `--selftest-phase` with a value other than 1 or 2, or a `-relaunch` check without it, fails with `bad --selftest-phase`.

Result: Chromium's session service did write session files in both variants (normal quit: `Cache/Default/Sessions/Session_*` 7127 bytes and `Sessions_Encrypted/Session_*` 7855 bytes; kill: 6831 and 7295 bytes). Phase 2 then saw exactly 1 engine tab, 1 NSWindow and 1 controller in both. So after a normal quit and after a kill, with a session file on disk, Chromium's own restore adds no tabs or windows in our Chrome-style windows; no startup preference is set and no engine or bridge code changed. (Had it added tabs, the pref is `session.restore_on_startup` = 5, new tab page, from `chrome/common/pref_names.h` and `session_startup_pref.h`, set on the request context before the first browser.) The session file contents were not decoded, so "3 tabs recorded" is not proven, only that a session file existed and was not empty. Negative controls: both checks with `NOCHE_TEST_RESTORE_EXPECT=3` (phase 2 expects 3 tabs) must fail with their own line.

## M1.2 persistence checks

Store checks read the store file through the `sqlite3` CLI (read only), the way `scripts/app-test.sh` does, so what they assert is what is on disk. Every check also gets the script's controls (crash reports, frontmost app, leftover helpers).

| Check | What it asserts |
|---|---|
| persist-relaunch | two-phase. Phase 1: 2 windows (3 and 4 tabs, active tabs 2 and 4, frames set at once before the quit so the debounced save is still pending); the store holds the favicon address of the favicon page and a sidebarWidth for both windows; the `lastActiveAt` of the 7 live tab rows is read back from the store file with sqlite3 (not from an app accessor) and written to a side file. Phase 2: 2 windows with frames within 1 pt, tab urls in order, active tabs 2 and 4, 7 engine tabs equal to the 7 rows (no double restore, no extra NSWindow), no window in full screen, and after a save the `lastActiveAt` values equal phase 1's within 1 s (a restore is not a use of the tab), favicon address and sidebarWidth kept. `scripts/app-test.sh` then prints the phase 2 store's `.schema` and `PRAGMA integrity_check` |
| quit-close-relaunch | with `quitBehavior=close` (`--selftest-setting`, hooks builds only) a relaunch has one window with one blank tab and restores nothing |
| reopen-closed | File > Reopen Closed Tab is Shift+Cmd+T, disabled and inert with an empty closed list; Cmd+W on B of A B C then Shift+Cmd+T brings B back at index 1, active, with its tab id; a blank tab is never recorded; with the list [A, B, C] over the engine strip [A, C, B], Next Tab from A selects B and the Cmd+W successor follows the list |
| reopen-closed-relaunch | two-phase: a tab closed before a quit can be reopened after the relaunch, in its original window at its original index |
| crash-mid-write | two-phase, run at two kill points (the pending debounced save, and inside the write transaction): phase 1 SIGKILLs itself (rc 137), the store passes `PRAGMA integrity_check`, and phase 2 restores one whole snapshot, the previous or the new, never a mix |
| corrupt-store | two-phase: garbage over the store file between the phases; phase 2 quarantines it (`noche.sqlite.corrupt-*`), opens one window with one tab and a fresh real store |
| reopen-identity | Shift+Cmd+T and Cmd+T in one turn, then a popup opened by a page right after a reopen: the reopened row keeps its tab id and address, the other new tabs are not given them |
| frame-storm | 50 `setFrame` calls change the window row only (width 849 in the end): the 3 tab rows stay byte for byte as they were |
| store-unavailable | two variants run by the script: a plain file where the Store directory belongs, and an existing store file inside a Store directory set to mode 555. Each: one window on an in-memory store, `NOCHE store unavailable` on stderr, nothing restored, the file (and in the second variant the file's bytes, the directory listing and the mode) unchanged. The script restores the permissions from its EXIT trap (shown by sending the script SIGTERM while the directory was 555: mode 755 afterwards, rc 130) and before each wipe of the profile |
| tab-chords | with the list [A, B, C] over the engine strip [A, C, B] (a reopen put B back in the middle), Cmd+1, 2, 3 and Cmd+9 each select the tab at that position in the list (Cmd+9 the last). The key event goes to the main menu directly: a hidden window is never key, and the page view takes a key the menu has no item for to the page, redispatching an unhandled one to the menu only in a key window |
| move-tab-relaunch | two-phase: Ctrl+Shift+Page Down moves the active tab one step along the list, Ctrl+Shift+Page Up one step back, and at the ends nothing happens (and nothing a second time); B moves after C, the sidebar rows show [A, C, B] and phase 2 after a relaunch has the same order with B active |

Negative controls added in M1.2 (`--negative`): `persist-relaunch` with `NOCHE_TEST_NOFLUSH=1` and `reopen-closed` with `NOCHE_TEST_NO_CLOSED=1` must fail. `tab-chords`, `move-tab-relaunch` and the unwritable variant have no switch: their RED runs (the list mapping removed locally, the check run on the sources before the fix, a failing run that leaves the directory at 555) are in the M1.2 task 4 report.

## Builder calls and rulings

Calls the design left open:

- Traffic lights are drawn circles in the sidebar and hide with it.
- With no pinned items the tab list starts at y 54, where the pinned grid would.
- The last tab closes the window.
- Google is the default search (`https://www.google.com/search?q=%s`).
- No close button on row hover, as captured.

M1.2 calls adopted from the research note as written:

- The quit popup has two values, "Preserve Tabs and Windows" (the default) and "Close Tabs and Windows" (setting `quitBehavior` = `preserve` or `close`).
- The closed-tab list is kept across a quit; the store keeps the 25 newest live rows of it, older ones are tombstoned.
- Reopen puts the tab back in its original window at its original index; with that window gone it is appended to the front window.
- History is not restored (no back list across a relaunch): a restored tab loads its saved address.
- A blank tab (`about:blank` or no address) is never added to the closed list.
- Incognito windows are never persisted (no incognito code exists yet).
- Warn before quitting is off.

Deviations and rulings that change behavior:

- The sidebar hide motion takes about 130 ms in the reference, with a 15 ms tolerance: the limit is 145 ms. Show has a 125 ms limit. The recorded run has Cmd+S hide at 129 ms and the button hide at 130 ms against 145 ms, and show at 118 ms against 125 ms (a hidden window gets no display-link frames, so the motion is timed from the main thread).
- `tabs-rapid` uses 20 Cmd+W.
- Window frames are AppKit global coordinates (origin bottom-left of the primary screen), converted to CEF's top-left DIPs once, in `NCWindow` (`cefInitialBounds`). An earlier cause "unknown" of a window opening 2320 wide at x 240 was two things: the bridge passed bottom-left y to a top-left API (fixed), and a left-edge band that macOS keeps windows out of. On this Mac that band is the Stage Manager strip (240 pt on the 2560x1440 screen, 112 pt on the second one): a window asked to start inside it is moved to its edge and cut to fit, whoever asks. AppKit's `constrainFrameRect` does not move it, and the WindowManager process owns windows inside that band. This is outside Noche's control, so `window-frame` and the self-test windows start at least 300 pt from a screen's left edge.

- Quitting within a few seconds of the launch can crash the engine's own shutdown (`SharedTabGroupFeedbackController::MaybeShowFeedbackActionInToolbar`, a pending tab-group sync task, seen twice in the final run on `window-frame` and `web-insets`). It is engine code, not Noche's; the self-test harness lets 15 s pass after the launch before a check quits the app. A person quitting right after launch can still hit it.

- The engine disables its own tab commands (select next or by number, move) in a views-hosted window, so they never reach Noche as Chrome commands, and a key the main menu has no item for goes to the page first. Cmd+1 to Cmd+8, Cmd+9 (last tab) and Ctrl+Shift+Page Down and Page Up (Chromium's own chords for moving a tab on Linux and Windows; macOS has none) are therefore Tabs menu items, answered from Noche's list, which is the order of record. The engine's hidden strip is not reordered; the sidebar and the store are the order.

## Owner checks (manual, visible)

Hidden runs can never have a key window or a visible screen, so these need a person:

1. Copy, Paste and Select All through the real menu, in the address field and in a page.
2. Quit with DevTools open, once from Opt+Cmd+I and once from the page's Inspect (the original crash never reproduced hidden).
3. Tab switching feels instant on screen with 20 tabs.
4. The sidebar slide looks right.
5. The bottom corners of the page are visibly rounded.
6. The vibrancy behind the sidebar looks right.
7. Full screen across a relaunch (M1.2): put a window in full screen, quit with Cmd+Q, relaunch: the window comes back in full screen. Hidden runs store and assert the saved value but never enter full screen (a hidden window must not take a Space).
8. A window zoomed with the green light comes back zoomed after a relaunch.
9. Cmd+1 to Cmd+9 select tabs by position and Ctrl+Shift+Page Down and Page Up move the active tab in a real, key window (hidden runs send these keys to the menu directly).
