#!/usr/bin/env bash
# usage: run.sh [app path]   (NOCHE_RUN_NO_OPEN=1 copies without launching)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/build/Noche.app}"
[ -d "$APP" ] || { echo "app missing: $APP, run scripts/build-app.sh" >&2; exit 1; }

DEST_DIR="$HOME/Applications/Noche Dev"
DEST="$DEST_DIR/$(basename "$APP")"
mkdir -p "$DEST_DIR"
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "installed $DEST"
[ -n "${NOCHE_RUN_NO_OPEN:-}" ] || open "$DEST"
