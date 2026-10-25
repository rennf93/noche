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

## Checks (28, plus the M1.2, M1.3 and M1.4 tables below)

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
| sidebar-toggle | Cmd+S hides and shows the sidebar, and the toolbar button hides it again, within the motion limits (see Deviations), with the traffic lights hidden and the show overshoot between 0.3 and 2.5 pt |
| sidebar-scroll | with 40 tabs at window heights 1436 and 800, Shift+Cmd+[ from tab 1 wraps to tab 40 and its row is fully visible, the row pitch stays 37, a row scrolled into view takes the click |
| shortcuts-once | each of 35 rows (shortcuts acting once, plus resolution rows) holds with no repeated Chrome command: reload, force reload, zoom in, out and actual size, Copy URL, back, forward, Cmd+L, address editing, Cmd+S, Cmd+T, next, previous, Cmd+W, and (M1.4 task 2, from the menu table) Copy URL as Markdown (a page titled `a\b] c` at an address ending `/q)x` puts `[a\\b\] c](.../q%29x)` on the pasteboard), Print, Inspect Elements, JavaScript Console, Show History and Downloads (each a new tab at its `chrome://` page, closed again), Close All Tabs (3 tabs become one blank tab), then Cmd+N, close window and Opt+Cmd+I; an unclaimed Cmd+K reaches the page (it used to fall to AppKit's loose matching, which fires Close All Tabs). The exact modifier matching is shown by those counts and by the NOEXACT negative control. Print, Inspect Elements and JavaScript Console are counted but not run (`BrowserWindowController.suppressChrome`: a hidden run must not raise a print or DevTools window), and the engine-claimed chords go through `NSApp.sendEvent` like a real press: Opt+Shift+Cmd+C copies the Markdown link once and Opt+Cmd+C runs Inspect Elements once, with no DevTools window created (see "Claimed chords"); Cmd+C is not claimed (no Noche action, and the page gets the keydown through AppKit's fall-through); shifted punctuation resolves through `ShortcutMenu.item(for:)` for Cmd+: (Shift+Cmd+;), Cmd+;, Cmd++, Ctrl++, Ctrl+Shift+', Ctrl+Shift+[, Shift+Cmd+] and Shift+Cmd+[ (on a machine whose layout AppKit rewrites, the live key is typed) |
| focus-return | an AppKit text field takes first responder (its field editor), then `focusActiveContent` makes the page's own view the first responder again; the same again with a DevTools window open, with no activation or alpha guard counted during the call; with the candidate count forced to 2 (`NOCHE_TEST_PAGE_VIEWS`) the responder stays on the field and one ambiguous-focus line is counted (the line itself goes to stderr, which the script does not capture); the NO_FOCUS and NO_AMBIGUOUS_GUARD negative controls fail it |
| newtab-surface | `webContentHidden` YES removes the page view from view while the window keeps one tab and a JS evaluation in that hidden tab still returns; NO shows the view again at the exact previous rect with the corner mask; hiding then activating or opening another tab shows the page again (bridge rule: any active-tab switch clears the flag; the caller sets it again) and JS works in both tabs; the NO_HIDE and NO_UNHIDE negative controls fail it |
| eval-async | evaluation completions never run inside a CEF callback (a normal reply, and a tab closed while evaluating); closed or closing tabs fail with "tab closed", later and never before the call returns |
| devtools-any-path | DevTools opened through a Chrome command Noche does not intercept (`IDC_DEV_TOOLS_CONSOLE`) is found; after the Quit menu action every DevTools browser ended before shutdown |
| no-zombie-tab | 20 tabs opened and closed in the same turn leave 1 tab and 1 row, and no closed tab is announced or listed again |
| devtools-quit | with DevTools open (Opt+Cmd+I), the Quit menu action ends cleanly and every DevTools browser ended before shutdown (hidden; see Owner checks) |
| devtools-close-tab | closing a tab with DevTools open (Cmd+W) closes the tab and its DevTools, the app is alive 2 s later |
| chromium-restore-relaunch | two-phase: 3 tabs open at quit, then the relaunch on the same profile has exactly 1 engine tab and 1 window (Chromium's own session restore adds none) |
| chromium-restore-crash-relaunch | the same after phase 1 is SIGKILLed with 3 loaded tabs: 1 engine tab and 1 window |
| a11y-labels | tab rows are buttons labelled with the tab title and carry the selected state, the New Tab row, the 4 toolbar buttons (Toggle Sidebar, Back, Forward, Reload) and the 3 window buttons are labelled buttons; also, a row's favicon goes back to the placeholder when the next page has none |

Negative controls (`--negative`): `no-zombie-tab` with `NOCHE_TEST_NO_CLOSED_FILTER=1`, `hidden` with `NOCHE_TEST_NEGATIVE=activate` and `shortcuts-once` with `NOCHE_TEST_NOEXACT=1` must fail; `chromium-restore-relaunch` and `chromium-restore-crash-relaunch` with `NOCHE_TEST_RESTORE_EXPECT=1` must fail (3 is the default the checks expect); `devtools-quit` with `NOCHE_TEST_DEVTOOLS_LAST=1` is recorded only (the engine crash it targets has not reproduced in a hidden run). A pair counts as failed-as-expected only when the check printed its own `NOCHE_TEST <check> fail` line and the app exited 1 on it: a build failure, crash, timeout or missing binary fails `--negative`. The switches exist only in test-hook builds (`NOCHE_TESTHOOKS=1`; the bridge's declarations and counters follow the same switch), and `scripts/app-test.sh` ends by rebuilding `build/Noche.app` without them.

Tab-switch latency on an unlocked screen is in the evidence file (median 11.9 ms, p90 12.9 ms, limits 16.7 and 33.3 ms).

## Two-phase checks and Chromium session restore (M1.2)

A check whose name ends in `-relaunch` runs twice on one profile: `--selftest <check> --selftest-phase 1` on a wiped profile, then `--selftest-phase 2` on what phase 1 left. Each phase prints its own `NOCHE_TEST <check> pass`, and the check passes only if both did (a failed phase 1 skips phase 2). The crash-report diff, leftover-helper poll, frontmost poll and stderr tail cover both phases. The harness argument is in `SelfTest.swift`, the checks in `SelfTestStore.swift`.

`chromium-restore-relaunch` and `chromium-restore-crash-relaunch`: phase 1 opens 3 fixture tabs and waits for their loads. The first then quits normally (the Quit path closes every tab one by one); the second prints `phase1-ready` and `scripts/app-test.sh` SIGKILLs the one app PID it started, so no shutdown runs. Between the phases the script prints the profile's session files (`NOCHE_TEST <check> info sessions=...`). Phase 2 waits until the engine tab and window counts have held still for 3 s (cap 15 s) after the first load, then counts engine tabs (`NCWindow.tabs`), NSWindows of the process and controllers, before Noche restores anything. It also fails if phase 1 left no profile. `--selftest-phase` with a value other than 1 or 2, or a `-relaunch` check without it, fails with `bad --selftest-phase`.

Result: Chromium's session service did write session files in both variants (normal quit: `Cache/Default/Sessions/Session_*` 7127 bytes and `Sessions_Encrypted/Session_*` 7855 bytes; kill: 6831 and 7295 bytes). Phase 2 then saw exactly 1 engine tab, 1 NSWindow and 1 controller in both. So after a normal quit and after a kill, with a session file on disk, Chromium's own restore adds no tabs or windows in our Chrome-style windows; no startup preference is set and no engine or bridge code changed. (Had it added tabs, the pref is `session.restore_on_startup` = 5, new tab page, from `chrome/common/pref_names.h` and `session_startup_pref.h`, set on the request context before the first browser.) Since M1.2 Task 3, between the phases `scripts/app-test.sh` runs `strings` on the newest unencrypted `Sessions/Session_*` and requires the 3 fixture URLs, and phase 2 expects 3 tabs because Noche restores them itself (a Chromium restore on top would give 6). Negative controls: both checks with `NOCHE_TEST_RESTORE_EXPECT=1` must fail with their own line.

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
| quit-close-dirty-relaunch | two-phase, `quitBehavior=close`: a navigation dirties the window and the quit starts at once with the tab closes 2.5 s apart (`NOCHE_TEST_SLOW_CLOSE_MS`), so the debounced save fires during the shutdown; phase 2 has one blank window and restores nothing (a late save used to bring the window back). Negative pair: `NOCHE_TEST_NO_QUIT_CLEAR=1` |
| window-close-cancel | after a window close is cancelled (the flag `close()` sets is set, then the cancellation reaches the controller; this engine's window close raises no beforeunload dialog, so it is delivered to the delegate directly) a Cmd+W on another tab is recorded as a closed tab and Shift+Cmd+T puts it back. Negative pair: `NOCHE_TEST_STICKY_CLOSING=1` |
| tab-chords | with the list [A, B, C] over the engine strip [A, C, B] (a reopen put B back in the middle), Cmd+1, 2, 3 and Cmd+9 each select the tab at that position in the list (Cmd+9 the last). The key event goes to the main menu directly: a hidden window is never key, and the page view takes a key the menu has no item for to the page, redispatching an unhandled one to the menu only in a key window |
| move-tab-relaunch | two-phase: Ctrl+Shift+Page Down moves the active tab one step along the list, Ctrl+Shift+Page Up one step back, and at the ends nothing happens (and nothing a second time); B moves after C, the sidebar rows show [A, C, B] and phase 2 after a relaunch has the same order with B active |
| history-record | M1.3: the startup fixture load becomes one `page` row (1 visit, 0 typed) with the page's own title (it arrives with a later update); `about:`, `data:` and `file:` loads are never stored; a load typed through the address entry counts as typed (`typedCount` 1) and gets its title; an aborted typed load (error -3, delivered as the bridge does) leaves no mark, so the next link visit is recorded with `typedCount` 0 (NOCHE_TEST_TYPED_STICKY); the NO_RECORD negative control fails it |

Negative controls added in M1.2 (`--negative`): `persist-relaunch` with `NOCHE_TEST_NOFLUSH=1` and `reopen-closed` with `NOCHE_TEST_NO_CLOSED=1` must fail. `tab-chords` with `NOCHE_TEST_NO_LIST_ORDER=1` and `move-tab-relaunch` with `NOCHE_TEST_NO_MOVE=1` must fail too. The unwritable variant has no switch; the RED runs (including the lastActiveAt run on the 03c37ed sources and the trap demonstration) are under "RED proofs" in `docs/app/evidence/m1-2-run.txt`.

## M1.3 command bar checks

The command bar (File > Open Command Bar, Cmd+L, a click on the toolbar's address area) is one view with two placements: the New Tab card (always shown on a blank tab, over a hidden page surface and `NewTabPageView`) and the overlay a loaded page gets. Typing goes through the field editor's `insertText`, special keys are key events handed to the first responder, clicks are mouse events sent through `NSApp` (so the click-outside monitor sees them). Geometry is compared with the note's tables from formulas written out in the check, not from `CommandBarLayout`.

| Check | What it asserts |
|---|---|
| cb-layout | the `commandBar` frame within 1 pt of the research note's tables 1a (card) and 1c (overlay) at 2200x1436, for the overlay with 0, 1 and 6 rows and the New Tab card with its 3 starter rows, 1 row and 6 rows (a card never has 0 rows), each with the sidebar hidden, and the full set shown too where listed in the check; fill #282828, border #3e4042 and the selected row #464747 within 3 per channel of the same color through the same pipeline (`cacheDisplay`); the NOCHE_TEST_BAR_LAYOUT negative control fails it |
| cb-open | Cmd+L on a loaded page opens the overlay with the page's address (`https://` dropped, a trailing "/" dropped, other schemes kept) fully selected, the field editor (not the page view) is first responder and takes typing; two Escapes close it and the page view is first responder again; the Chrome command `IDC_FOCUS_LOCATION`, delivered to Noche's delegate the way the bridge's `OnChromeCommand` does, is answered YES and opens the bar (NOCHE_TEST_BAR_NOFOCUSLOC leaves it unanswered, and a NO from the delegate fails the check on its own line); when the engine itself can execute it on the tab it must reach the bar too, otherwise the engine's `CanExecuteChromeCommand` answer is only an info line (a hidden run cannot raise the accelerator through the engine; that stays an owner check); Cmd+T shows the focused card (placement New Tab, no overlay) over a hidden page surface that stays hidden for 1 s (ruling R14: the engine's later active-tab report must not clear it), Escape on the empty card unfocuses it and Cmd+L focuses it again; the NOCHE_TEST_BAR_NOFOCUS negative control fails it |
| cb-motion | the overlay height from Cmd+L: at least 4 frames, each within 2 pt of the cubic ease-out fit (41 to 107 pt in 107 ms), monotonic, none above 107, the final frame 107; Escape twice closes within the same run-loop turn; the NOCHE_TEST_BAR_NOMOTION negative control fails it |
| cb-go | typed `127.0.0.1:<port>/b.html` plus Return loads it (row title updates, the typed visit is a history page row with `typedCount` 1), `two words` plus Return loads the self-test search URL, and Return gives the page typing back; typed `javascript:` and `data:` text searches and never navigates; stored rows with `javascript:`, `data:` and `ftp:` URLs load nothing and run nothing (title and URL unchanged); the NOCHE_TEST_BAR_NOGO and NOCHE_TEST_BAR_ROUTE negative controls fail it |
| cb-escape | loaded page: Escape clears the text and the rows with the bar still open, a second Escape closes it and the page view is first responder (the NOCHE_TEST_NO_FOCUS bridge control fails that); New Tab: Escape clears to the 3 starter rows, a second Escape unfocuses the card and the page surface stays hidden; the NOCHE_TEST_BAR_ESC negative control fails it |
| cb-arrows | 3 stored pages and a typed prefix: the inline remainder is selected, Down twice selects row 3 and the field text follows it, Down past the end does not wrap, Up returns to the typed text with the remainder selected, Tab accepts the remainder (caret at the end), a second Tab moves down, Return runs the selected row; the NOCHE_TEST_BAR_NOARROWS negative control fails it |
| cb-inline | typing `weather` completes to a stored page's URL with the remainder selected, Backspace deletes the completion and nothing completes again (also after a second Backspace), typing again completes, case stays as typed, no completion with a space or for a title-only match; a Backspace on an empty field does not skip the next completion (NOCHE_TEST_BAR_STALEDELETE); the NOCHE_TEST_BAR_INLINE negative control fails it |
| cb-switch-tab | with tabs A and B and a blank New Tab, typing a prefix of A's title and Return on its row makes A active with the same number of engine tabs, sidebar rows and list items (no duplicate), the blank tab stays and the page surface is visible again; the NOCHE_TEST_BAR_DUPTAB negative control fails it |
| cb-outside | a click on the card keeps the bar open; a click on the sidebar toggle closes it, the monitor hands the event back untouched, and the toggle takes its click (a hidden window never delivers synthesized mouse events by itself, so the check delivers it to the target); the NOCHE_TEST_BAR_NOOUTSIDE negative control fails it |
| cb-nonet | with `suggestRemote` 1 and `--selftest-suggest-url` pointing at the fixture's `suggest.json` (the script passes both): 7 keystrokes in one turn send at most 2 requests and 14 spaced keystrokes at most 3, never closer than 100 ms, every request to 127.0.0.1 (the host assertion in `RemoteSuggest` counts any other as foreign), the fixture server's access log (`NOCHE_TEST_SERVER_LOG`, written by the script) counts the same as the app; URL-like text, text with no letter and 1 character send none; the answer shows as query rows; with the setting 0 nothing is sent; every request is built against the configured endpoint's host and refused otherwise (NOCHE_TEST_HOST_SWAP and NOCHE_TEST_HOST_SWAP_UNGUARDED); the NOCHE_TEST_REMOTE_IGNORE_OFF and NOCHE_TEST_NO_DEBOUNCE negative controls fail it |
| cb-nonet-default | with an endpoint configured but no `suggestRemote` setting at all (the default), typing sends nothing (app counter and the fixture server's log); the NOCHE_TEST_REMOTE_IGNORE_OFF negative control fails it |
| cb-history | two-phase: phase 1 navigates by typing through the bar (a typed page row with its title in the store); phase 2 (relaunch) types a title prefix and the stored page is a suggestion row; the NOCHE_TEST_NO_RECORD negative control fails phase 1 |

The M1.1 checks that typed into the address field (`navigate`, `load-error`, `load-error-link`, `shortcuts-once`, `no-window`) now type into the command bar's field editor; the toolbar address is display only (a click on it opens the bar).

Negative controls added in M1.3 (`--negative`): `history-record` NOCHE_TEST_NO_RECORD, `cb-layout` NOCHE_TEST_BAR_LAYOUT, `cb-open` NOCHE_TEST_BAR_NOFOCUS, `cb-motion` NOCHE_TEST_BAR_NOMOTION, `cb-go` NOCHE_TEST_BAR_NOGO and NOCHE_TEST_BAR_ROUTE, `cb-escape` NOCHE_TEST_BAR_ESC and NOCHE_TEST_NO_FOCUS, `cb-arrows` NOCHE_TEST_BAR_NOARROWS, `cb-inline` NOCHE_TEST_BAR_INLINE, `cb-switch-tab` NOCHE_TEST_BAR_DUPTAB, `cb-outside` NOCHE_TEST_BAR_NOOUTSIDE, `cb-nonet` NOCHE_TEST_NO_DEBOUNCE, NOCHE_TEST_HOST_SWAP, NOCHE_TEST_HOST_SWAP_UNGUARDED and NOCHE_TEST_REMOTE_IGNORE_OFF, `cb-nonet-default` NOCHE_TEST_REMOTE_IGNORE_OFF, `cb-open` NOCHE_TEST_BAR_NOFOCUSLOC, `cb-inline` NOCHE_TEST_BAR_STALEDELETE, `history-record` NOCHE_TEST_TYPED_STICKY, `cb-history` NOCHE_TEST_NO_RECORD. Each must fail on its own `NOCHE_TEST <check> fail` line.

## M1.4 menu checks

The menu bar is `MenuTable.bar` (`Sources/Noche/MenuTable.swift`, the only place items are defined); keys and modifiers come from NocheCore's `ShortcutDefaults` by id (`table` for the Settings rows, `fixed` for system items and the key commands that have no menu item). `Tests/fixtures/app/menu-expected.txt` is the transcription of live-ui.md section 9 the checks compare with.

| Check | What it asserts |
|---|---|
| menu-diff | the live bar, walked recursively after each menu validated itself, equals `menu-expected.txt` line for line (`<menu path>|<title>|<key>|<modifiers>|<enabled in a one-tab window>`, separators as `---`, the 11 key commands as `command` lines): 166 lines. Rows AppKit adds itself (Window tiling rows, the window list, the Help search field) carry no Noche mark and are the skipped system rows. `r` means nil-targeted (the responder chain decides; not asserted). Also: every item without an action names a milestone; every nil-targeted (`r`) row has the hand-listed standard selector and no target; Task Manager (`e`) is enabled exactly when the engine can execute `IDC_TASK_MANAGER` (recorded as an info line). The dump maps the owner's Spanish-layout glyphs back to US keys and the ellipsis to three dots. Negative pairs: `NOCHE_TEST_MENU_DRIFT=1` drops History > Show History..., `NOCHE_TEST_MENU_SELECTOR=1` gives Copy the Paste action |
| menu-disabled | every disabled item that has a key equivalent (32 in a one-tab window: later-milestone items, Go Back and Forward, Reopen Closed Tab) is fired through the menu key route: no action counted, no Chrome command logged, no tab or window changed; the positive control Cmd+R then reloads once. Negative pair: `NOCHE_TEST_MENU_NODISABLE=1` makes `ShortcutMenu` act on a disabled item |
| menu-actions | the items with no shortcut: Tabs > Duplicate (a second tab, same address, new one active, one action), View > Show Full URL (the toolbar address shows the whole URL, then the host again, with its checkmark), View > Appearance (Dark, Light, Automatic set `NSApp.appearance`, with checkmarks). File > Share... makes an `NSSharingServicePicker` whose one item is the tab's URL and does not show it (hidden run); Help > Copy Diagnostics puts three lines on the pasteboard, checked against `Resources/App/Info.plist.template`, `vendor/CEF-VERSION.txt` (cef_version) and `sw_vers`; Window > Task Manager is executed for real when the engine can (recorded: CanExecute true, executed once, the `Task Manager` NativeWidgetMacNSWindow appeared; the window is closed again), else it must be disabled. Negative pairs: `NOCHE_TEST_NO_DUPLICATE=1`, `NOCHE_TEST_NO_FULLURL=1`, `NOCHE_TEST_NO_SHARE=1`, `NOCHE_TEST_NO_DIAG=1` |

Superseded: the M1.1 `menu` check (the 48-line M1.1 list) is replaced by `menu-diff`; its nil-targeted edit assertion lives on in the `r` rows. The Tabs items M1.2 added (Cmd+1 to Cmd+9, Ctrl+Shift+Page Down and Up) are not in section 9, so they are no longer menu items: they are `MenuTable.commands`, matched by `ShortcutMenu` with the same exact matching, and `tab-chords`, `move-tab-relaunch` and `tabs-keys` still pass unchanged.

Negative controls added in M1.4 task 2 (`--negative`): `menu-diff` NOCHE_TEST_MENU_DRIFT, `menu-disabled` NOCHE_TEST_MENU_NODISABLE, `menu-actions` NOCHE_TEST_NO_DUPLICATE and NOCHE_TEST_NO_FULLURL, `shortcuts-once` NOCHE_TEST_NO_CLOSEALL (Close All Tabs does nothing), NOCHE_TEST_NO_SHIFTMAP (no shifted-punctuation matching) and NOCHE_TEST_NO_PREEMPT (the engine's accelerators run first), `menu-diff` NOCHE_TEST_MENU_SELECTOR, `menu-actions` NOCHE_TEST_NO_SHARE and NOCHE_TEST_NO_DIAG.

Items present and disabled until their feature exists (`docs` requirement; the milestone is in the table row and `menu-diff` fails on a disabled item without one):

| Item (menu) | Arrives |
|---|---|
| Check for Updates..., Settings... (Noche) | M1.8 |
| New Incognito Window (File) | M1.7 (profile incognito) |
| Import from Another Browser... (Noche) | M1.10 (passwords and autofill import) |
| Move to Window (Tabs), Merge All Windows (Window) | M1.6 (cross-window tab moves) |
| New Tab in Group, Clean Up Tabs (File); Show Tabs in Sidebar (View); Search Tabs..., Pin, New Group with Tab, Move to Group, Rename..., Change Icon... (Tabs) | M1.6 |
| Chat..., Focus Chat (File) | M2 |
| Find..., Find Next, Find Previous, Use Selection for Find (Edit > Find) | M1.4 task 4 (the find bar) |
| AutoFill > Contact..., Passwords..., Credit Card... (Edit) | M1.10 |
| Open Split Pane, Focus Next Split Pane, Focus Previous Split Pane (View) | M1.10 |
| Show Bookmarks Bar > Always, On New Tab Only, Never, Toggle Bookmarks Bar (View); Bookmark This Page, Manage Bookmarks, Bookmarks Bar, Other Bookmarks (Bookmarks) | M1.5 |
| Move to Profile (Tabs) | M1.7 |
| Add Extension..., Manage Extensions..., Pin Extensions... (Extensions) | M1.9 |

Working now, once listed as later: File > Share..., Window > Task Manager and Help > Copy Diagnostics (see menu-actions); nothing stays "unscheduled".

Omitted on purpose (no Noche counterpart, see the header of `menu-expected.txt`): Invite, the plan label, Upgrade Plan, Sign Out, Chat with Support, Video Tour, Status, Record Performance Issue, the per-profile Window items, the installed-extension list and the Recent Bookmarks entries. Move to Group, Move to Profile, Move to Window and Bookmarks Bar are dynamic submenus in the reference: here single disabled items. History > Show History... opens `chrome://history` and Window > Downloads opens `chrome://downloads` in a new tab until M1.5.

Claimed chords (ruling M6a): Chromium's Mac accelerator table handles some chords before the page and its own commands never reach Noche (no `OnChromeCommand`, no CEF key callback), so they would run the engine's action instead of the menu item. `NCWindow` claims only these, with a local event monitor on its own windows (it runs in `NSApplication.sendEvent` ahead of the window, the same point Chromium handles them) and hands them to the main menu on the next turn: Opt+Cmd+C (Chromium: Inspect; Noche: Inspect Elements), Opt+Shift+Cmd+C (observed: opens DevTools; Noche: Copy URL as Markdown, proven), and, from Chromium's Mac accelerator table as I know it and not proven here: Cmd+, (Settings page), Shift+Cmd+N (incognito window), Cmd+D (bookmark bubble), Opt+Cmd+B (bookmark manager), Shift+Cmd+B (bookmark bar), Shift+Cmd+A (Search Tabs). The engine source was not read (off limits to this job), so the list is derived from Chromium's published accelerator table plus the two observations; extend `preemptKey:` in `NCWindow.mm` if a visible run finds another chord where the engine acts instead of the menu. Cmd+C, V, X, A, R, L, K, F and the rest stay with the page and the engine.

Menu calls: Focus Previous Split Pane is Ctrl+Shift+[ (section 1 maps the N-tilde glyph to "[", as for Previous Tab). Window > Arrange in Front runs `NSApp.arrangeInFront` through an app action because AppKit retitles the system selector "Bring All to Front"; Enter Full Screen and Emoji & Symbols have no key shown (the reference's Fn+F and Fn+E come from macOS); Appearance Light uses system colors until light is captured; Show Full URL is per app run (the Settings of M1.8 will persist it).

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
- Reopen peeks the closed list and takes the tab off it only once it is back in a window (a crash in between loses nothing). It puts the tab back in its original window at its original index; with that window gone it is appended to the front window.
- History is not restored (no back list across a relaunch): a restored tab loads its saved address.
- A blank tab (`about:blank` or no address) is never added to the closed list.
- Incognito windows are never persisted (no incognito code exists yet).
- Warn before quitting is off.

M1.3 command bar calls (every CALL item of the research note, adopted as written unless a line says otherwise):

- Deep-URL display (note section 2): the bar shows the page address with `https://` and a trailing "/" dropped and keeps path and query. Other schemes (`http://`, `file://`, `about:`) are kept as they are, so Return on the untouched text loads the same page (a stripped `http://` would turn into `https://`).
- Arrows, Tab, Cmd+Return, click outside (note section 2): Down and Up move the selection without wrapping, the field text follows the selected row (its address without scheme, or the query), Up back to the first row shows the typed text with the inline remainder selected; Tab accepts the remainder (caret at the end), without one it acts like Down; Cmd+Return opens the row in a new tab; a click outside the card closes the overlay (on a New Tab card it only takes the focus out of the field) and the click still reaches its target.
- Escape (note section 2): the first Escape with any text, an untouched prefilled address included, clears the text and the rows; on an empty bar an overlay closes (instantly) and the New Tab card gives up focus. Whether the reference clears or closes on an untouched prefilled address needs a capture.
- Cmd+L on a New Tab focuses the card and selects its text; Cmd+T shows a New Tab with its card focused.
- Open-tab row (note section 3a): "Title - host" with a trailing "Switch to Tab" pill; Return activates that tab (never a load, never a duplicate) and the blank New Tab it was opened from stays.
- Frecency weights, tier order, six-row cap and the history slot kept for a page (note section 4, Task 1): builder numbers.
- Overlay geometry with the sidebar hidden: left edge = card x + 106, right edge fixed at 264.5 from the window edge; top corners square (the window edge clips them) and no top border line; the card keeps its top (H/2 - 78) when it grows; rows appearing while typing are not animated; closing is instant; the overlay input is 13 pt and the New Tab card's 14 pt.
- Chip "Add tabs or files" 142x28, centered on the footer row; mic and chip are inert (no AI, no voice in M1.3); the send circle shows with no rows, the "Go" pill with rows.
- The 3 starter rows of the empty New Tab card ("Summarize my open tabs", "What changed on this page?", "Plan my week", SF Symbols `bubble.left`, `sparkles`, `list.bullet`) are inert: clicking one copies its text into the input and nothing is sent. The owner can veto them (the empty card would then be 107 pt high).
- New Tab surface: the page surface is hidden (`webContentHidden`, set only after the bridge reports the tab active, ruling R14) under a behind-window vibrancy view and a static grain disc (a radial gradient with a fixed speckle) instead of the reference's video orb.
- Remote query suggestions are off by default (`suggestRemote` 0), on when the owner sets it to 1 (Settings arrive in M1.8; tests use `--selftest-setting`). The endpoint follows the default search engine (Google `suggestqueries.google.com ... client=firefox`, DuckDuckGo `duckduckgo.com/ac/`; any other engine sends nothing); ephemeral session with no cookies, cache, credentials or referrer; 100 ms debounce, 500 ms timeout, the last 20 answers cached in memory; never for URL-like text, text with no letter or under 2 characters.
- The built-in site list (`Resources/App/Sites.json`, copied into the bundle by `scripts/build-app.sh`) is a hand-written original file of about 380 `{name, host}` rows in rough popularity order.
- Rows join title and host with " - " (a plain hyphen with spaces) where the reference uses a long dash.
- History records only http and https main-frame loads that end with status 200 to 399; a load from the bar (or the address entry) counts as typed; every navigation from a stored row re-checks the scheme allowlist.

Deviations and rulings that change behavior:

- The sidebar hide motion takes about 130 ms in the reference, with a 15 ms tolerance: the limit is 145 ms. Show has a 125 ms limit. The recorded run has Cmd+S hide at 129 ms and the button hide at 130 ms against 145 ms, and show at 118 ms against 125 ms (a hidden window gets no display-link frames, so the motion is timed from the main thread).
- `tabs-rapid` uses 20 Cmd+W.
- Window frames are AppKit global coordinates (origin bottom-left of the primary screen), converted to CEF's top-left DIPs once, in `NCWindow` (`cefInitialBounds`). An earlier cause "unknown" of a window opening 2320 wide at x 240 was two things: the bridge passed bottom-left y to a top-left API (fixed), and a left-edge band that macOS keeps windows out of. On this Mac that band is the Stage Manager strip (240 pt on the 2560x1440 screen, 112 pt on the second one): a window asked to start inside it is moved to its edge and cut to fit, whoever asks. AppKit's `constrainFrameRect` does not move it, and the WindowManager process owns windows inside that band. This is outside Noche's control, so `window-frame` and the self-test windows start at least 300 pt from a screen's left edge.

- Quitting within a few seconds of the launch can crash the engine's own shutdown (`SharedTabGroupFeedbackController::MaybeShowFeedbackActionInToolbar`, a pending tab-group sync task, seen twice in the final run on `window-frame` and `web-insets`). It is engine code, not Noche's; the self-test harness lets 15 s pass after the launch before a check quits the app. A person quitting right after launch can still hit it.

- The engine disables its own tab commands (select next or by number, move) in a views-hosted window, so they never reach Noche as Chrome commands (engine source: `chrome/browser/ui/browser_command_controller.cc` lines 1985 to 2003 enable them only when `supports_tabs`, the window's `kFeatureTabStrip`, is true), and a key the main menu has no item for goes to the page first. Cmd+1 to Cmd+8, Cmd+9 (last tab) and Ctrl+Shift+Page Down and Page Up (Chromium's own chords for moving a tab on Linux and Windows; macOS has none) are therefore Tabs menu items, answered from Noche's list, which is the order of record. The engine's hidden strip is not reordered; the sidebar and the store are the order.

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
10. Cmd+L with the page focused, in a real key window, opens the command bar through the engine accelerator (hidden runs deliver `IDC_FOCUS_LOCATION` to Noche's delegate directly), and Cmd+Return on a bar row opens it in a new tab.
11. Real key window (M1.4): Opt+Shift+Cmd+C copies the Markdown link and opens no DevTools window; Shift+Cmd+N, Cmd+D and Cmd+, open nothing; Cmd+P shows the print preview; Opt+Cmd+C and Opt+Cmd+J open DevTools in inspect and console mode; File > Share... shows the system picker at the toolbar; Window > Task Manager shows Chromium's task manager (hidden runs only record that its window appears).
