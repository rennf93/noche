#!/usr/bin/env bash
# usage: probe-engine.sh <check>...   (ext-loaded, tabs-one, tabs-many-baseline)
# Builds Probes/EngineProbe (NOCHE_PROBES=1), runs it once per check by direct exec, prints its PROBE lines,
# exits 0 only if every check printed "pass". Profile: ~/Library/Application Support/Noche Probe.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ $# -gt 0 ] || { echo "usage: probe-engine.sh <check>..." >&2; exit 2; }

NOCHE_PROBES=1 "$ROOT/scripts/build-app.sh" --product EngineProbe --app-name "Noche Probe" >&2
APP="$ROOT/build/Noche Probe.app"

SITE="$(mktemp -d)"
echo '<!doctype html><title>probe</title><p>probe page' > "$SITE/index.html"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SITE" >/dev/null 2>&1 &
SERVER_PID=$!
OUTF="$(mktemp)"
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$SITE" "$OUTF"' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done

LIMIT=$((40 + ${NOCHE_PROBE_SLACK:-20}))
FAILED=0
for CHECK in "$@"; do
  : > "$OUTF"
  # Outer watchdog: if the app outlives its own 40s timeout, kill that one PID (see smoke.sh).
  (cd / && exec "$APP/Contents/MacOS/Noche Probe" --probe="$CHECK" --url="http://127.0.0.1:$PORT/" \
      --load-extension="$ROOT/Probes/fixtures/probe-extension" --enable-logging=stderr >"$OUTF") &
  APP_PID=$!
  WATCHDOG=0
  for _ in $(seq 1 $((LIMIT * 10))); do
    kill -0 "$APP_PID" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$APP_PID" 2>/dev/null; then
    if ps -p "$APP_PID" -o command= | grep -qF "$APP/Contents/MacOS/Noche Probe"; then
      WATCHDOG=1
      kill -KILL "$APP_PID"
    fi
  fi
  wait "$APP_PID" 2>/dev/null || true
  [ "$WATCHDOG" = 1 ] && echo "PROBE $CHECK fail watchdog" >> "$OUTF"
  grep '^PROBE ' "$OUTF" || echo "PROBE $CHECK fail no-output"
  grep -q "^PROBE $CHECK pass" "$OUTF" || FAILED=1
done
exit "$FAILED"
