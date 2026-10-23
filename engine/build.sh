#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${NOCHE_ENGINE_ROOT:-/Volumes/K3Trunk/noche-engine}"
MIN_FREE_GB="${NOCHE_ENGINE_MIN_FREE_GB:-40}"

BRANCH="8078"
# NOCHE_ENGINE_CEF_PIN, NOCHE_ENGINE_CEF_DIR, NOCHE_ENGINE_PATCH_DIR and NOCHE_ENGINE_ALLOW_INTERNAL are test-only.
PIN="${NOCHE_ENGINE_CEF_PIN:-426920c33ef22551e0b8f48cf343d623ac25642d}"
PATCH_DIR="${NOCHE_ENGINE_PATCH_DIR:-$REPO/engine/patches}"
GN_DEFINES_VALUE="is_official_build=false symbol_level=0 blink_symbol_level=0 v8_symbol_level=0 proprietary_codecs=true ffmpeg_branding=Chrome"
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

# The build runs from chromium/src/cef, the copy automate-git.py makes of the download.
CEF="${NOCHE_ENGINE_CEF_DIR:-$ROOT/chromium_git/chromium/src/cef}"
SRC="$ROOT/chromium_git/chromium/src"

export PATH="$ROOT/depot_tools:$PATH"
export VPYTHON_VIRTUALENV_ROOT="$ROOT/.vpython-root"
export CIPD_CACHE_DIR="$ROOT/.cipd-cache"
# Keep the toolchain fixed during a build; only checkout updates depot_tools.
[ "$STEP" = "checkout" ] || export DEPOT_TOOLS_UPDATE=0

mkdir -p "$ROOT/logs"
LOG="$ROOT/logs/$STEP-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG") 2>&1
echo "log: $LOG"

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
    caffeinate -is autoninja -C "out/$OUT_CONFIG" cefclient
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
    ;;
esac
