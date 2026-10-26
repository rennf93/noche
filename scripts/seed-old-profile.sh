#!/usr/bin/env bash
# usage: seed-old-profile.sh <scratch-root>
# Makes the seeded old-engine profile for the profile-upgrade check (E11): builds this commit's probe against the pre-patch engine
# (3659, patches 0001 to 0006) in a scratch git worktree, runs profile-upgrade once with NOCHE_PROBE_ROOT=<scratch-root> so the profile is
# written by the old engine, then removes the worktree. Afterwards run, on the current engine:
#   NOCHE_PROBE_ROOT=<copy of scratch-root> NOCHE_TABS_API=1 NOCHE_ACTIONS_API=1 scripts/probe-engine.sh profile-upgrade
# Never touches ~/Library/Application Support/Noche*. Env: OLD_CEF_DIST overrides the old distrib path.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ $# -eq 1 ] || { echo "usage: seed-old-profile.sh <scratch-root>" >&2; exit 2; }
SCRATCH="$1"
case "$SCRATCH" in "$HOME/Library/Application Support/"*) echo "refusing a real profile root: $SCRATCH" >&2; exit 2 ;; esac
[ ! -e "$SCRATCH" ] || [ -z "$(ls -A "$SCRATCH")" ] || { echo "scratch root is not empty: $SCRATCH" >&2; exit 2; }
OLD="${OLD_CEF_DIST:-/Volumes/K3Trunk/noche-engine/distrib/cef_binary_156.0.14-noche.3659+g18b1359+chromium-156.0.8078.48_macosarm64_minimal}"
[ -d "$OLD" ] || { echo "old distrib missing: $OLD" >&2; exit 2; }
WT="$(dirname "$ROOT")/scratch-old-$$"
cleanup() { git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"; git -C "$ROOT" worktree prune; }
trap cleanup EXIT
git -C "$ROOT" worktree add --detach "$WT" HEAD >&2
(cd "$WT" && CEF_DIST="$OLD" scripts/fetch-cef.sh >&2 && grep '^cef_version=' vendor/CEF-VERSION.txt >&2)
mkdir -p "$SCRATCH"
(cd "$WT" && NOCHE_PROBE_ROOT="$SCRATCH" NOCHE_TABS_API=1 NOCHE_ACTIONS_API=1 scripts/probe-engine.sh profile-upgrade)
echo "seeded old-engine profile at $SCRATCH"
