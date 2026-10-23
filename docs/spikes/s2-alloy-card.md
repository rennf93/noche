# Spike S2: rounded Alloy card over vibrancy

Pin: CEF 156.0.7 (Chromium 156), macOS arm64, spike target `SpikeAlloyCard` (`Spikes/AlloyCard/main.mm`), built with
`scripts/build-app.sh --product SpikeAlloyCard --app-name "Spike Alloy Card"` (`evidence/s2/build.log`). Evidence lives under
`evidence/s2/`. Logs are the `[S2 <ms>]` lines the spike writes to stderr (`run1.log`, `run2.log`).

Layout under test: a titled, full-size-content, transparent-titlebar `NSWindow` (1100x700, clear background) whose content view is an
`NSVisualEffectView` (material `.sidebar`, behind-window blending, active). A 197 pt sidebar region on the left, and a card view
inset 6 pt top, right and bottom with `cornerRadius 10`, `masksToBounds`, a 1 pt `#2a2a2a` border and a `#1e1e1e` layer background.
The card holds two `NCBrowserView`s (Alloy style, `SetAsChild`) stacked and toggled with `hidden`: tab 0 `https://example.com`,
tab 1 a local long page (`long.html`, 30000 px of white and light-blue stripes, with an in-page `requestAnimationFrame` meter that
reports through `document.title`).

Method notes that apply to every row:
- The binary was started directly from the shell and stopped by its single PID. The spike is driven by a command file
  (`tab N`, `resize W H MS`, `scroll MS`); resize steps are `setFrame:display:` calls at 60 Hz, scroll is `NSEvent` wheel events built
  from `CGEvent` and delivered to the page view inside the process. No system-level input injection and no clicks.
- Captures are `screencapture -R240,100,1100,700` of the spike's own window frame (System Events reported `240, 100, 1100, 700`,
  `frame.txt`), taken with the spike frontmost (`front-a*.txt`). Before each capture the screen was unlocked
  (`lock-state-a*.txt`: the `CGSSessionScreenIsLocked` query printed nothing). The display is 1x, so frames are 1100x700 pixels.
- The window needs `NSWindowCollectionBehaviorMoveToActiveSpace`: without it the window was created on another Space (not
  on screen) and every capture showed only the wallpaper.
- Analysis scripts are `corners.py`, `resize_check.py`, `flash_check.py` in the same folder.
- Page colour here: example.com rendered in its dark scheme (page background `(59, 59, 59)`, `a1-corners.txt`), so the white-page
  check uses tab 1, which is pure white at the top of the page.

| Criterion | Result | Evidence | Notes |
|---|---|---|---|
| A1 corners clean at rest | pass | `a1-rest.png`, `a1-corners.txt`, `a1-zoom-tr.png`, `a1-zoom-br.png`, `a1-rest-white.png`, `a1-corners-white.txt`, `a1-zoom-white-tr.png`, `a1-border-pixels.txt` | Card rect found at x 197..1093, y 6..693 (window 1100x700). With example.com, the four outer corner pixels are vibrancy background, not page: TL (33, 37, 40), TR (32, 35, 42), BL (32, 37, 54), BR (32, 38, 50), against a page colour of (59, 59, 59); the diagonal pixels 1 and 2 in are the same background, the arc starts at 3 px in. With the white tab, the outer, diag1 and diag2 pixels are the same background values and white (255, 255, 255) appears first at diag5 on TL and BL. The border is drawn at x 1093 and y 693 as (37, 37, 37), and on the left at x 197 (`a1-border-pixels.txt`, sampled from `a1-rest-white.png`). Zoomed crops show a clean 10 pt arc on all corners, including under the scrollbar at top right. |
| A2 clean during a 5 s live resize | pass | `a2-resize.mov` (5.9 s), `a2-frames/f001.png` to `f059.png`, `a2-corners.txt`, `a2-contact-sheet.png`, `run1.log` (lines `RESIZE start ... 1100x700 to 800x500 over 4000 ms`, then `RESIZE done`) | Window shrunk from 1100x700 to 800x500 over 4 s while recording. 59 frames extracted at 10 fps; `resize_check.py` located the card in every frame (window sizes 1100x700 down to 800x500 in the output) and found 0 corner violations (`corner violations: 0`; 59 frames x 4 corners all `clean`). 12 of them were inspected visually in `a2-contact-sheet.png` (every fourth frame, 0.4 s apart): rounded on all four corners, no square page corners, no lag of the right or bottom edge. The vibrancy sidebar stays translucent throughout. Limits: the check ran on frames extracted at 10 fps (59 frames) from a recorder that delivers at most about 55 frames per second, so a single-frame corner glitch between samples would be missed; and the test (any of the 3 diagonal pixels with all channels at or above 150) only detects page bleed on the white tab, it would not catch a dark-page corner. Driven by `setFrame:display:` from inside the app, not a mouse drag, so it exercises the same layout path but not the system live-resize loop. |
| A3 no black flash on window show and on tab switch | pass | show: `a3-show.mov`, `a3-flash.txt`, `a3-show-pair.png`; switch: `a3-tabswitch.mov`, `a3-tabswitch-flash.txt`, `a3-tab-sample.png`, `run2.log` (13 `TAB shown` lines) | Show: recording started before launch. At about 0.85 s the window appears with the card at the layer colour (mean (28, 28, 28), `#1e1e1e`) for about 3 frames at 60 fps, then the page (mean (64, 64, 64)) by 0.93 s. Fraction of interior pixels below 10 on every channel: worst 0.000392 over 476 samples, which is the wallpaper before the window exists. Switch: 12 alternating tab switches 0.6 s apart (`tab 1`, `tab 0`, and so on) over a 9 s recording, 552 samples at 60 fps (`a3-tabswitch-flash.txt`); worst black fraction 0, and the card mean only ever shows the two page states (64 and 213) plus two single transition samples (59 and 255). Caveat: the capture is limited to roughly 55 distinct frames per second (A4), so a flash shorter than about 20 ms could be missed. |
| A4 scrolling a long page keeps 60 fps | inconclusive | `a4-scroll.mov`, `a4-frame-times.txt`, `a4-frame-timing.txt`, `a4-page-fps.txt`, `a4-scroll-frame.png`, `run2.log` | No valid smoothness measurement was obtained. `--show-fps-counter` was passed and rendered nothing (`a4-scroll-frame.png`). In-page `requestAnimationFrame` reported `fps=` between 128.1 and 170.1 in 9 samples, worst frame 12.4 ms (`a4-page-fps.txt`); that only shows the page's rAF was not throttled, it is not a presented-frame rate (it is no display refresh rate) and says nothing about what reached the screen. The scroll was synthetic: a 60 Hz timer for 4000 ms (`SCROLL start` to `SCROLL done` in `run2.log`) calling `scrollWheel:` with `CGEvent`-built events directly on the page view, with no window attached (`evwin=0` in the `SCROLL target` log line); the number of events is not logged. The page advanced 720 px per 0.5 s (`a4-page-fps.txt`). Recording frame timing (`a4-frame-timing.txt`) is poor evidence and not favourable: the densest 3 s window holds 167 frames (55.7 frames/s, the recorder's own cap), median inter-frame 16.7 ms, p95 30.0 ms, max 53.3 ms, 77 gaps over 16.7 ms and 4 gaps over 33.3 ms. Not done: reading the display's maximum refresh (`NSScreen.maximumFramesPerSecond`), real wheel events posted to the window, and presented-frame intervals from CEF (CDP tracing). Needs a rerun with those before A4 can pass or fail. |

Findings that bear on the M1 design:
- Rounding technique: `cornerRadius = 10` with `masksToBounds = YES` on the layer of a plain container `NSView` that parents the `NCBrowserView`
  clips the Alloy windowed browser correctly at rest, in resize and when scrolling. No `CAShapeLayer` mask was needed (unlike S1 C6, where the
  Chrome-style path drew through `ViewsCompositorSuperview`). The layer property was set on the container, not on the CEF-created child view; setting it on the child itself was not tested.
- The container layer background (`#1e1e1e`) is what the user sees before the first paint, so there is no black flash on show or on switch.
- Tabs are stacked `NCBrowserView`s toggled with `hidden`; switching shows no black frames.
- The app window must be able to appear on the active Space (`MoveToActiveSpace`) for scripted capture; otherwise it opens off screen when launched from a shell.
- `NCBrowserView close` did not complete here: with the command `quit` both views got `CloseBrowser(false)` but `onClosed` never fired, so the spike had to be stopped with `kill` on its PID. Not investigated (outside this spike's question); worth a check in the real app.
- Wheel events built from `CGEvent` reach the page only with the window-under-pointer fields set, and the event sent to the `RenderWidgetHostViewCocoa` directly; the first attempt (no window fields, `sendEvent:` on the window) did not scroll, and the two changes were not tested separately.

S2 verdict: partial
