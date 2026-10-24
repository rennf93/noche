#!/usr/bin/env bash
# usage: probe-engine.sh <check>...   (ext-loaded, tabs-one, tabs-20, ext-create, ext-activate, switch-latency, rss-20, blank-link, per-tab-client, close-non-last, close-last)
# Builds Probes/EngineProbe (NOCHE_PROBES=1), runs it once per check by direct exec, prints its PROBE lines,
# exits 0 only if every check printed "pass", exited 0, did not hit the watchdog and left no helpers behind.
# Profile: ~/Library/Application Support/Noche Probe. Check names are [a-z0-9-]+.
# rss-20 waits a minute between samples, so it gets a 120s probe watchdog (set in main.mm) and a longer outer limit.
# switch-latency needs frames; it orders its alpha-0 window in without activating. The tab checks need NOCHE_TABS_API=1 (new engine).
# NOCHE_PROBE_VISIBLE=1 makes the probe window opaque on screen: it needs the owner's approval each time and is never on by default.
# Test-only: NOCHE_PROBE_STUB_BIN=<exe> skips the build and runs that binary instead of the probe app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ $# -gt 0 ] || { echo "usage: probe-engine.sh <check>..." >&2; exit 2; }

for C in "$@"; do
  [[ "$C" =~ ^[a-z0-9-]+$ ]] || { echo "bad check name: $C" >&2; exit 2; }
done
APP="$ROOT/build/Noche Probe.app"
BIN="$APP/Contents/MacOS/Noche Probe"
if [ -n "${NOCHE_PROBE_STUB_BIN:-}" ]; then BIN="$NOCHE_PROBE_STUB_BIN"
else NOCHE_PROBES=1 "$ROOT/scripts/build-app.sh" --product EngineProbe --app-name "Noche Probe" >&2; fi

SITE="$(mktemp -d)"
echo '<!doctype html><title>probe</title><p>probe page' > "$SITE/index.html"
# u10: NOCHE_PROBE_MEASURE=pagestatic puts the in-page visibility/rAF recorder in the page (same script as kPageJS in main.mm).
[ "${NOCHE_PROBE_MEASURE:-}" = pagestatic ] && echo "<script>(()=>{window.__sw=[];document.addEventListener('visibilitychange',()=>{if(document.visibilityState!=='visible')return;const v=performance.timeOrigin+performance.now();requestAnimationFrame(()=>{window.__sw.push([v,performance.timeOrigin+performance.now()])});});})()</script>" >> "$SITE/index.html"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SITE" >/dev/null 2>&1 &
SERVER_PID=$!
OUTF="$(mktemp)"
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$SITE" "$OUTF"' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done

FAILED=0
for CHECK in "$@"; do
  : > "$OUTF"
  LIMIT=$((40 + ${NOCHE_PROBE_SLACK:-20}))
  [[ "$CHECK" == rss-20* || "$CHECK" == tabs-bare-wait ]] && LIMIT=$((120 + ${NOCHE_PROBE_SLACK:-20}))
  # Outer watchdog: if the app outlives its own 40s timeout, kill that one PID (see smoke.sh).
  (cd / && exec "$BIN" --probe="$CHECK" --url="http://127.0.0.1:$PORT/" \
      --load-extension="$ROOT/Probes/fixtures/probe-extension" --enable-logging=stderr >"$OUTF") &
  APP_PID=$!
  WATCHDOG=0
  for _ in $(seq 1 $((LIMIT * 10))); do
    kill -0 "$APP_PID" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$APP_PID" 2>/dev/null; then
    if ps -p "$APP_PID" -o command= | grep -qF "$BIN"; then
      WATCHDOG=1
      kill -TERM "$APP_PID"  # the one verified PID, then the same PID hard after 5s
      for _ in $(seq 1 50); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
      kill -0 "$APP_PID" 2>/dev/null && kill -KILL "$APP_PID"
    fi
  fi
  set +e; wait "$APP_PID" 2>/dev/null; RC=$?; set -e
  [ "$WATCHDOG" = 1 ] && echo "PROBE $CHECK fail watchdog" >> "$OUTF"
  grep '^PROBE ' "$OUTF" || echo "PROBE $CHECK fail no-output"
  grep -qxE "PROBE $CHECK pass( .*)?" "$OUTF" || FAILED=1
  if [ "$WATCHDOG" = 1 ] || [ "$RC" != 0 ]; then FAILED=1; echo "PROBE $CHECK fail exit-rc=$RC watchdog=$WATCHDOG"; fi
  sleep 1  # let helpers exit
  LEFT="$( (pgrep -f "$APP/Contents/Frameworks" || true) | wc -l | tr -d ' ')"
  if [ "$LEFT" != 0 ]; then FAILED=1; echo "PROBE leftover-helpers fail $LEFT"; fi
done
exit "$FAILED"
