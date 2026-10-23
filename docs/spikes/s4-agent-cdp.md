# Spike S4: agent loop over the DevTools protocol

Pin: CEF 156.0.7 (Chromium 156), macOS arm64, Alloy-style browser, spike target `SpikeAgentCDP` (`Spikes/AgentCDP/main.mm`), built with
`scripts/build-app.sh --product SpikeAgentCDP --app-name "Spike Agent CDP"`. Evidence (text files only; images and recordings are not committed) lives under `evidence/s4/`.

Setup:
- `CefBrowserHost::CreateBrowserSync` with `SetAsChild` on a 900x640 pt view, `runtime_style = ALLOY`, one `CefDevToolsMessageObserver`
  registered in `OnAfterCreated`. Every request goes out through `CefBrowserHost::SendDevToolsMessage` (JSON with our own `id`), every
  response and event comes back through `OnDevToolsMessage`. The checks run on a worker thread; each send hops to the main (UI) thread.
- Fixtures: `Spikes/fixtures/agent.html` (input with `aria-label="Name field"`, button "Go" setting `document.title` to `clicked:<value>`,
  an iframe whose `src` comes from `?frame=`) and `Spikes/fixtures/frame.html` (button that sets its own text to `frame-clicked`).
  Two `python3 -m http.server` instances: agent page at `127.0.0.1:60808`, frame at `localhost:60818` (ports in `servers.txt`).
  Deviation from "two ports on 127.0.0.1": two ports on the same host are same-site in Chromium and would not be out-of-process, so the
  frame uses the host name `localhost` (a different site) on its own port. D4 confirms the frame arrives as its own `iframe` target.
- Screen lock: `screen-lock-state.txt` shows `CGSSessionScreenIsLocked` absent (grep count 0), so the screen was unlocked; the page reported
  `visibilityState = visible`, so D3 is a screenshot of a visible page (a hidden or locked-screen page may differ and was not tested).
- Raw request and response log: `cdp.log` (lines starting `>` are sent, `<` received, `#` are spike notes; payloads over 40000 chars are
  truncated, which only affects the screenshot data). Run output: `run.log`, `summary.txt`.

| Check | Result | Evidence | Notes |
|---|---|---|---|
| D1 `Accessibility.getFullAXTree` returns input and button with roles and names | pass | `summary.txt`, `d1-ax-nodes.plist`, `cdp.log` | 10 nodes returned. Input found as role `textbox`, name `Name field`; button as role `button`, name `Go`. `Accessibility.enable` was sent first. The tree covers the main frame only (the iframe's button is not in it; read the iframe through its own session). |
| D2 click input, `Input.insertText("hello")`, click button gives title `clicked:hello` | pass | `summary.txt`, `cdp.log`, `run.log` (`TITLE clicked:hello`) | Element centers come from `DOM.getDocument`, `DOM.querySelector`, `DOM.getBoxModel` (average of the 4 content-quad points): input (144.0, 37.0), button (289.4, 37.0). A click is `mouseMoved`, `mousePressed`, `mouseReleased` (left, clickCount 1). Input value read back as `hello`; `document.title` read back as `clicked:hello`, and CEF's `OnTitleChange` also reported it. |
| D3 `Page.captureScreenshot` PNG size matches the view in device pixels | pass | `d3.png`, `summary.txt` | PNG is 900x640 (6454 bytes); view is 900x640 pt at backing scale 1.0 (expected 900x640); page `innerWidth x innerHeight` 900x640, devicePixelRatio 1. Only a scale-1.0 display was available, so a Retina scale was not tested; the screenshot is page-viewport sized, so the expectation there is view points times scale (not tested). Page visible, screen unlocked. |
| D4 cross-origin iframe reached via `Target.setAutoAttach` (flatten) and clicked | pass | `cdp.log` (search `attachedToTarget`), `summary.txt`, `run.log` | `Target.setAutoAttach {autoAttach:true, waitForDebuggerOnStart:false, flatten:true}` on the browser connection, then `Page.reload`. `Target.attachedToTarget` arrived with `targetInfo.type = "iframe"`, `url` `http://localhost:60818/frame.html` for the pre-reload frame and a fresh iframe session after the reload (empty url at attach time). Messages carrying a top-level `"sessionId"` were accepted by `SendDevToolsMessage` and routed to the iframe (`Runtime.evaluate`, `DOM.getDocument`, `DOM.querySelector`, `DOM.getBoxModel` on that session all returned). Button text before: `frame-button`; the button center in frame coordinates was (90, 30), the iframe's content origin in the page (21, 71), so the page-level click point was (111.0, 101.0). The click was dispatched as `Input.dispatchMouseEvent` on the parent (no sessionId); Chromium routed it to the iframe and the text became `frame-clicked` (read through the iframe session). The iframe-session fallback was never needed. |
| D5 time each call, median of 10 | pass | `d5-timings.tsv` (all 10 raw values per method), `run.log` | Round trip from `SendDevToolsMessage` to the observer callback, on the UI thread clock, ms: see the table below. |

D5 medians (from `d5-timings.tsv`):

| Method | Median ms |
|---|---|
| `Accessibility.getFullAXTree` | 0.30 |
| `Runtime.evaluate` (main page) | 0.08 |
| `DOM.getBoxModel` | 0.08 |
| `Input.dispatchMouseEvent` (mouseMoved) | 5.84 |
| `Input.insertText` | 0.10 |
| `Page.captureScreenshot` (PNG, 900x640) | 17.55 |
| `Runtime.evaluate` (iframe session) | 0.11 |

Timing caveats: tiny fixture page; `getFullAXTree` on a real page will be much larger and slower. `dispatchMouseEvent` waits for the input event to be acked by the renderer (in the raw values, 3 of the 10 samples are under 1 ms and the rest 5.0 to 6.6 ms).

## Method sequence for M2

All messages are `SendDevToolsMessage` JSON `{"id":N,"method":...,"params":{...}}`, with `"sessionId":"<id>"` added at top level to address an iframe target.

- Setup (once per browser): register `AddDevToolsMessageObserver` (in `OnAfterCreated`; keep the returned `CefRegistration`), then `Accessibility.enable`. No debug port or DevTools window is needed.
- Read: `Accessibility.getFullAXTree` (no params); nodes carry `role.value`, `name.value`, `ignored`, `backendDOMNodeId`, `frameId`. Page text/state: `Runtime.evaluate {expression, returnByValue:true}`.
- Locate an element: `DOM.getDocument {depth:0}`, then `DOM.querySelector {nodeId: root.nodeId, selector}`, then `DOM.getBoxModel {nodeId}`; click point is the average of the 4 points in `model.content`. Re-run `DOM.getDocument` after any navigation (node ids reset).
- Click: `Input.dispatchMouseEvent {type:"mouseMoved",x,y}`, then `{type:"mousePressed",x,y,button:"left",buttons:1,clickCount:1}`, then `{type:"mouseReleased",x,y,button:"left",buttons:0,clickCount:1}`. Coordinates are CSS px relative to the viewport.
- Type: click the field to focus it, then `Input.insertText {text}`. (`Input.dispatchKeyEvent` was not exercised.)
- Screenshot: `Page.captureScreenshot {format:"png"}`; the result `data` is base64 PNG sized viewport times device scale factor.
- Iframe access: `Target.setAutoAttach {autoAttach:true, waitForDebuggerOnStart:false, flatten:true}` before the frame exists (or reload after); take `params.sessionId` from `Target.attachedToTarget` events with `targetInfo.type == "iframe"`; then send any method with that `sessionId` (`Runtime.evaluate`, `DOM.*`). To click inside it, compute the point as iframe origin in the parent page (`getBoundingClientRect` of the `<iframe>` element plus its border) plus the in-frame box center, and dispatch the three mouse events on the parent session (no `sessionId`).
- Responses are matched by `id`; events (no `id`) arrive through the same observer callback and must be kept for the `attachedToTarget` lookup.

## Findings and concerns

- Closing the browser did not complete in this harness: `CloseBrowser(false)` (also `true`, also with the observer released, with the window ordered out or closed, with auto-attach turned off, and with no CDP use at all) reaches `DoClose` and `OnBeforeClose` never fires. The same harness is a plain `SetAsChild` view in a titled `NSWindow`; the cause was not found. The spike therefore quits with `exit(0)` after a 3 s grace period (verified no helper process remained). M0 shell code that depends on `onClosed` firing should be re-checked.
- Same-site frames are not out-of-process: the second fixture port alone is not enough, a different host name is needed.
- The CEF observer callback is the only channel for responses and events; it runs on the UI thread, so an agent runtime must hand results to its own thread.

S4 verdict: all pass
