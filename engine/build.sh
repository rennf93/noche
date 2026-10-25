#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${NOCHE_ENGINE_ROOT:-/Volumes/K3Trunk/noche-engine}"
MIN_FREE_GB="${NOCHE_ENGINE_MIN_FREE_GB:-40}"
case "${NOCHE_ENGINE_JOBS:-}" in
  ''|[1-9]|[1-9][0-9]) ;;
  *) echo "NOCHE_ENGINE_JOBS must be a whole number from 1 to 99" >&2; exit 2 ;;
esac

BRANCH="8078"
# NOCHE_ENGINE_CEF_PIN, NOCHE_ENGINE_CEF_DIR, NOCHE_ENGINE_PATCH_DIR and NOCHE_ENGINE_ALLOW_INTERNAL are test-only.
PIN="${NOCHE_ENGINE_CEF_PIN:-426920c33ef22551e0b8f48cf343d623ac25642d}"
PATCH_DIR="${NOCHE_ENGINE_PATCH_DIR:-$REPO/engine/patches}"
GN_DEFINES_VALUE="is_official_build=false disable_fieldtrial_testing_config=true symbol_level=0 blink_symbol_level=0 v8_symbol_level=0 proprietary_codecs=true ffmpeg_branding=Chrome"
OUT_CONFIG="Release_GN_arm64"

STEP="${1:-}"
case "$STEP" in
  checkout|patch|build|distrib) ;;
  *) echo "usage: engine/build.sh checkout|patch|build|distrib" >&2; exit 2 ;;
esac

# Guards run before any log file exists or any tool starts.
if [ ! -d "$ROOT" ]; then
  echo "engine root missing: $ROOT" >&2
  exit 1
fi

# The engine never lives on the internal disk; a stale folder after an unplug resolves to it.
MOUNT="$(df -P "$ROOT" | awk 'NR==2 { print $6 }')"
if [ -z "${NOCHE_ENGINE_ALLOW_INTERNAL:-}" ] && { [ "$MOUNT" = "/" ] || [ "$MOUNT" = "/System/Volumes/Data" ]; }; then
  echo "engine root is on the internal disk: $ROOT" >&2
  exit 1
fi

case "$MIN_FREE_GB" in
  ''|*[!0-9]*) echo "NOCHE_ENGINE_MIN_FREE_GB must be a whole number of GiB" >&2; exit 2 ;;
esac

if [ "$STEP" = "build" ] || [ "$STEP" = "checkout" ]; then
  FREE_GB="$(df -k "$ROOT" | awk 'NR==2 { print int($4 / 1048576) }')"
  if [ "$FREE_GB" -lt "$MIN_FREE_GB" ]; then
    echo "need $MIN_FREE_GB GiB free, have $FREE_GB" >&2
    exit 1
  fi
fi

# ANGLE compiles Metal shaders at build time, and this Xcode ships the Metal toolchain as a separate download.
if [ "$STEP" = "build" ] && ! xcrun metal --version >/dev/null 2>&1; then
  echo "Metal toolchain missing: run xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

# The build runs from chromium/src/cef, the copy automate-git.py makes of the download.
CEF="${NOCHE_ENGINE_CEF_DIR:-$ROOT/chromium_git/chromium/src/cef}"
SRC="$ROOT/chromium_git/chromium/src"

# A tree that was not reset by `patch` builds without the series; refuse it.
if [ "$STEP" = "build" ]; then
  shopt -s nullglob
  PATCHES=("$PATCH_DIR"/*.patch)
  shopt -u nullglob
  BRANCH_NOW="$(git -C "$CEF" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  COMMITS="$(git -C "$CEF" rev-list --count "$PIN..HEAD" 2>/dev/null || echo -1)"
  if [ "$BRANCH_NOW" != "noche" ] || [ "$COMMITS" != "${#PATCHES[@]}" ]; then
    echo "cef tree does not match engine/patches: run engine/build.sh patch first" >&2
    exit 1
  fi
fi

export PATH="$ROOT/depot_tools:$PATH"
export VPYTHON_VIRTUALENV_ROOT="$ROOT/.vpython-root"
export CIPD_CACHE_DIR="$ROOT/.cipd-cache"
# Keep the toolchain fixed during a build; only checkout updates depot_tools.
[ "$STEP" = "checkout" ] || export DEPOT_TOOLS_UPDATE=0

mkdir -p "$ROOT/logs"
LOG="$ROOT/logs/$STEP-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG") 2>&1
echo "log: $LOG"

# CEF's patcher applies cef/patch/patches to Chromium in place and cannot re-apply a patch whose old form is
# still there. For each Chromium-side patch file the series adds or changes, put its files back to the Chromium
# checkout state unless it applies forward (not applied yet) or backward (already applied in this form).
restore_stale_chromium_files() {
  [ -d "$SRC/.git" ] || return 0
  local f p files
  while IFS= read -r f; do
    p="$CEF/$f"
    git -C "$SRC" apply -p0 --check "$p" >/dev/null 2>&1 && continue
    git -C "$SRC" apply -p0 --check -R "$p" >/dev/null 2>&1 && continue
    files="$(sed -n 's/^diff --git \([^ ]*\) .*/\1/p' "$p")"
    echo "restoring Chromium files of $f"
    # shellcheck disable=SC2086
    git -C "$SRC" checkout -q -- $files
  done < <(git diff --name-only --diff-filter=AM "$PIN" HEAD -- patch/patches)
}

patch_series() {
  [ -d "$CEF/.git" ] || { echo "cef checkout missing: $CEF"; exit 1; }
  cd "$CEF"
  # Fixed committer identity and date so a re-run reproduces the same commits.
  export GIT_COMMITTER_NAME="Noche Engine" GIT_COMMITTER_EMAIL="engine@noche.invalid"
  # An interrupted run can leave a half-done am; clear it (rm covers an empty stray dir).
  git am --abort >/dev/null 2>&1 || true
  rm -rf .git/rebase-apply
  git checkout -q -f -B noche "$PIN"
  local p
  for p in "$PATCH_DIR"/*.patch; do
    [ -e "$p" ] || break
    if ! git -c core.hooksPath=/dev/null -c commit.gpgsign=false am -q --3way --committer-date-is-author-date "$p"; then
      git am --abort || true
      git reset -q --hard "$PIN"
      echo "patch failed: $(basename "$p")"
      exit 1
    fi
  done
  restore_stale_chromium_files
  echo "patched: $(git rev-parse --short HEAD)"
}

case "$STEP" in
  checkout)
    caffeinate -is python3 "$ROOT/automate/automate-git.py" \
      --download-dir="$ROOT/chromium_git" \
      --depot-tools-dir="$ROOT/depot_tools" \
      --branch="$BRANCH" \
      --checkout="$PIN" \
      --no-chromium-history --no-build --no-distrib --arm64-build
    ;;
  patch)
    patch_series
    ;;
  build)
    # gclient_hook.py runs patcher.py (applies cef/patch/patches to Chromium), then gn gen.
    cd "$CEF"
    GN_DEFINES="$GN_DEFINES_VALUE" GN_OUT_CONFIGS="$OUT_CONFIG" caffeinate -is python3 tools/gclient_hook.py
    cd "$SRC"
    # NOCHE_ENGINE_JOBS caps the parallel compile jobs (siso -local_jobs) so the Mac stays usable during a build.
    caffeinate -is autoninja ${NOCHE_ENGINE_JOBS:+-j "$NOCHE_ENGINE_JOBS"} -C "out/$OUT_CONFIG" cefclient
    ;;
  distrib)
    # make_distrib.py takes the framework from the cefclient app in out/Release_GN_arm64.
    cd "$CEF/tools"
    # Not the log: tee bumps its mtime on every output line.
    MARKER="$ROOT/logs/.distrib-start"
    touch "$MARKER"
    caffeinate -is python3 make_distrib.py --output-dir="$ROOT/distrib" \
      --ninja-build --arm64-build --minimal \
      --no-docs --no-symbols --no-archive
    # Strict make_distrib still exits 0 on a missing build; check the output.
    # Only a dir created by this run counts (make_distrib.py:90-91 recreates it), so an older distrib cannot pass.
    DIST="$(find "$ROOT/distrib" -maxdepth 1 -name 'cef_binary_*_macosarm64_minimal' -newer "$MARKER" 2>/dev/null | head -1)"
    rm -f "$MARKER"
    if [ -z "$DIST" ] || [ ! -f "$DIST/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework" ]; then
      echo "distrib incomplete: ${DIST:-$ROOT/distrib}"
      exit 1
    fi
    echo "distrib: $DIST"
    ;;
esac
