# Spike S3: media and platform features

Pin: CEF 156.0.7 (Chromium 156), macOS arm64, spike target `SpikeMedia` (`Spikes/Media/main.mm`), built with
`scripts/build-app.sh --product SpikeMedia --app-name "Spike Media"`. Evidence lives under `build/spikes/s3/` (gitignored, local):
`alloy/`, `chrome/`, `alloy-noaudio/` each hold `run.log` (the `[S3 <style> <ms>]` lines), `summary.txt`, `loaded.png`, `pip.png`,
`pmset-unmuted.txt`, `pmset-muted.txt`; plus `build.log`, `screen-lock-state.txt`, `cache-widevine-contents.txt`.

Setup:
- One binary, `--style alloy|chrome --url <media.html url> --out <dir>`. Alloy: `CreateBrowserSync` with `SetAsChild` in a 900x640 `NSWindow`
  (`runtime_style = ALLOY`). Chrome: `CefBrowserView` (`CEF_RUNTIME_STYLE_CHROME`, `CEF_CTT_NONE`) in a `CefWindow`. Fresh cache dir per run.
  Third run `alloy-noaudio` is Alloy with `--no-audio-handler` (explained under M4 and M5).
- Fixtures: `Spikes/fixtures/media.html` (Widevine button, `<video src=clip.webm loop>`, Play and PiP buttons, `contenteditable` holding `recieve`)
  and `Spikes/fixtures/clip.webm`, generated locally (4 s, 320x180 testsrc, VP9, 440 Hz sine, Opus):
  `ffmpeg -f lavfi -i testsrc=duration=4:size=320x180:rate=15 -f lavfi -i sine=frequency=440:duration=4 -c:v libvpx-vp9 -b:v 100k -c:a libopus -shortest clip.webm`.
  Served by `python3 -m http.server 60838 --bind 127.0.0.1` (single PID stopped after the runs).
- All clicks are CDP `Input.dispatchMouseEvent` (move, press, release), which gives a real user gesture; the right-click is `button:"right"`.
  The context menu is swallowed (`RunContextMenu` returns true and cancels) so no native menu loop stays open. No system dialog appeared.
- Screen lock: `screen-lock-state.txt` holds `0` (count of `CGSSessionScreenIsLocked` in `ioreg`), so the screen was unlocked.
  Screenshots are window-only (`screencapture -l <windowNumber>`). The PiP window is its own window, so `pip.png` shows the main window
  ("Playing in picture-in-picture" placeholder in the video); the PiP window itself is evidenced by the `WINDOWLIST` lines in `run.log`.

| Check | Alloy result | Chrome result | Evidence | Notes |
|---|---|---|---|---|
| M1 Widevine `requestMediaKeySystemAccess` | fail | fail | `alloy/run.log`, `chrome/run.log`, `cache-widevine-contents.txt`, `chrome/crx-cache-metadata.json` | Both: `ERR NotSupportedError: Unsupported keySystem or supportedConfigurations.` (config: `initDataTypes ['cenc','webm']`, `video/webm; codecs="vp9"`, no robustness). No Widevine CDM is shipped in the minimal distribution. The component updater ran (a `component_crx_cache` entry for app id `ceofaddefefcbblgcgnibnonglccbfja` appeared, 136340 bytes) but it is not the Widevine component, and `WidevineCdm/` in the cache dir stayed empty in both styles. No CDM was fetched within the run (about 1 s after load and the check waited for the result, no longer wait for the CDM was tried). Widevine would need the CDM supplied by the app (not tested). |
| M2 Picture in Picture opens from a real click | pass | pass | `alloy/run.log`, `chrome/run.log` (`RESULT M2`, `WINDOWLIST`), `pip.png` in each dir | `video.requestPictureInPicture()` resolved `OK 512x288`; `document.pictureInPictureElement` is `v`; `document.pictureInPictureEnabled` true. A separate window titled `Picture in Picture`, 512x288, layer 3, on screen, appeared in the CGWindow list of the process in both styles. Only the button click triggered it (CDP mouse events). Not tested: dragging or closing the PiP window, document PiP, PiP of audible-only content. |
| M3 right-click on `recieve` gives dictionary suggestions | pass | pass | `alloy/run.log`, `chrome/run.log` (`CTXMENU`) | Both: `misspelled=recieve editable=1 GetDictionarySuggestions=1 count=2 [receive,relieve,]`. Menu item count 14 (Alloy) and 15 (Chrome). `IsSpellCheckEnabled()` returned 0 in both although misspelling and suggestions were reported; no spellcheck setting was changed. The macOS system spellchecker supplied the words (no `Dictionaries` download needed). |
| M4 callback reporting that audio is playing | pass | fail | `alloy/run.log`, `chrome/run.log`, `alloy-noaudio/run.log` (`RESULT M4`, `AUDIO`) | The only such callback in `vendor/cef/include` is `CefAudioHandler::OnAudioStreamStarted` (also `OnAudioStreamPacket`, `OnAudioStreamStopped`, `OnAudioStreamError`); there is no tab-audible or audio-state-changed callback (grep for audible only finds a content setting). Alloy: after the Play click `OnAudioStreamStarted rate=44100 channels=2 frames_per_buffer=1024` fired, 92 packets and 94208 frames in 2 s, RMS 0.0866 (the 440 Hz tone). Chrome style: the handler was returned from `GetAudioHandler()` the same way, the video played (`currentTime` 2.15) and the stream was open on the device (see M5), but no `AUDIO` line ever appeared (`started=0`). So in Chrome style CEF gives no audio-playing signal here. `alloy-noaudio` (handler withheld) shows M4 fail by construction; it exists only for M5. |
| M5 `SetAudioMuted(true)` silences it | partial (flag only, with the handler installed) | pass | `alloy/run.log`, `chrome/run.log`, `alloy-noaudio/run.log` (`RESULT M5`), `*/pmset-unmuted.txt`, `*/pmset-muted.txt` | `IsAudioMuted()` returned 1 after `SetAudioMuted(true)` in all runs, and the video kept playing (`paused=false`; `currentTime` moved, the 4 s clip loops). Silence evidence is device level: `pmset -g assertions` lists a `coreaudiod` resource `audio-out BuiltInHeadphoneOutputDevice` while a stream reaches the output device. Chrome style: present before mute, gone after (`coreaudiod_audio-out unmuted=1 muted=0`). Alloy without audio handler: same (`unmuted=1 muted=0`), result pass. Alloy with the handler installed (`alloy/`): the page's audio never reaches the output device (`audio-out` absent both before and after, a `Capturing` assertion instead) because CEF diverts it to the handler, and the `OnAudioStreamPacket` tap is before the mute stage (RMS 0.0866 unmuted, 0.0861 muted), so the mute cannot be shown there and the verdict is inconclusive. Caveats: this proves the output stream detaches, not what the speakers emit; it relies on no other app playing audio at that moment (not isolated; the `pmset` files list all assertions); nobody listened. |

Findings that bear on the design:
- Widevine playback needs the CDM supplied by us; the minimal CEF build plus the component updater did not provide it in these runs.
- PiP, spellcheck suggestions and `SetAudioMuted` work in both runtime styles without extra setup.
- The only audio-state hook is `CefAudioHandler`, and it fires in Alloy only. Installing it in Alloy re-routes the page audio through the handler (nothing reaches the speakers unless the app plays the PCM itself), so using it as a tab-audible indicator costs playback. In Chrome style a tab speaker indicator would need another source (for example CDP or the page), not tested.
- `OnBeforeClose` fired in Chrome style this time (`chrome/run.log`) but not in Alloy (`DoClose` only); the spike exits explicitly after a 3 s grace period in both.

S3 verdict: partial
