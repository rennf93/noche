# Patches

Noche's engine patches are `git format-patch` output against the pinned CEF commit (see `engine/README.md`). `engine/build.sh patch` applies them with `git am --3way` in name order, so prefix names with a number (`0001-...`).

Changes to Chromium itself go in as new files under CEF's `patch/patches/` plus an entry in `patch/patch.cfg`, all inside a Noche patch. CEF's own patcher then applies them during `build`.

To regenerate a series: commit on the `noche` branch in `chromium/src/cef`, then `git format-patch <pinned commit>`.
