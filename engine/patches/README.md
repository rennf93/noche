# Patches

Noche's engine patches are `git format-patch` output against the pinned CEF commit (see `engine/README.md`). `engine/build.sh patch` applies them with `git am --3way` in name order, so prefix names with a number (`0001-...`).

Changes to Chromium itself go in as new files under CEF's `patch/patches/` plus an entry in `patch/patch.cfg`, all inside a Noche patch. CEF's own patcher then applies them during `build`.

To regenerate a series: commit on the `noche` branch in `chromium/src/cef`, then `git format-patch <pinned commit>`.

`engine/build.sh patch` resets `src/cef` with `checkout -f -B noche`, which loses uncommitted edits, so commit on `noche` and run `git format-patch` before re-running `patch`.

CEF's patcher applies `cef/patch/patches/*.patch` to Chromium in place, and `engine/build.sh patch` only resets `src/cef`, so Chromium keeps those edits. Before dropping or editing a Chromium-side patch, revert it in Chromium with CEF's `tools/patch_updater.py` (its `--revert` option, optionally limited with `--patch <name>`), from `chromium/src/cef`: `python3 tools/patch_updater.py --revert --patch <name>`.

`engine/build.sh patch` also restores (git checkout) the Chromium files of any Chromium-side patch file the series adds or changes that applies neither forward nor backward to the current Chromium tree, so an amended patch re-applies over its old form. A patch already applied in its new form is left alone. `engine/test.sh` covers this with a fixture.

The series is experimental-API only. The CEF-side parts of popups-as-tabs engage only when `CEF_API_IS_ADDED(CEF_EXPERIMENTAL)`, but the Chromium-side hunks (tabs allowed in a views-hosted Browser, window type reported as normal, installs anchored to the CEF window) apply to every views-hosted Chrome style Browser regardless of `CEF_API_VERSION`. Do not ship the series to a client that pins a stable API version.

0006 closes the teardown window: from the moment the last tab's WebContents is gone (before `OnBeforeClose` and `OnBrowserDestroyed`), `GetTabs`, `GetActiveTab` and `GetTabCount` report only live tabs, and `AddTab` and the extension action calls refuse. Probe check: `close-callbacks`.

0007 stops the zoom bubble in views-hosted browsers: `ZoomViewController::UpdateBubbleVisibility` returns early when the Browser is a CEF views-hosted Browser (`cef_delegate()->IsViewsHosted()`), so zoom steps no longer order a bubble window in at the top-left of the window. Zoom itself is untouched (per-host levels, `GetZoomLevel`, the zoom commands all work). The change is a Chromium-side patch file (`chrome_browser_ui_zoom_bubble.patch`) listed in `patch/patch.cfg`. Probe check: `zoom-no-bubble`.
