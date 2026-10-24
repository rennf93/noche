#!/usr/bin/env bash
# usage: probe-engine.sh <check>...   (store-stock, store-ua, store-brand, store-ua-brand, install-no-window (live Chrome Web Store, task B4), ext-loaded, tabs-one, tabs-20, ext-create, ext-activate, switch-latency, rss-20, blank-link, per-tab-client, close-non-last, close-last, close-callbacks, window-normal, cmd-enabled, bubbles, download-restart-1, download-restart-2 (run 1 then 2, same profile), download-tab-close, ctx-ext-items, zoom-scope, chrome-pages)
# Builds Probes/EngineProbe (NOCHE_PROBES=1), runs it once per check by direct exec, prints its PROBE lines,
# exits 0 only if every check printed "pass", exited 0, did not hit the watchdog and left no helpers behind.
# Profile: ~/Library/Application Support/Noche Probe (store checks: Noche Probe Store, emptied every run). Check names are [a-z0-9-]+.
# Watchdogs (probe's own, in main.mm / the script's outer limit that kills the one app PID): store checks 150 s / 170 s,
# rss-20* and tabs-bare-wait 150 s / 140 s (the outer one fires first and reports "watchdog"), every other check 40 s / 60 s.
# Controls the probe cannot give itself: new Noche Probe*.ips (diffed per launch after a 3 s settle), the frontmost app
# (lsappinfo every 0.5 s, fails if it is ever the probe) and leftover helpers (polled up to 5 s, PIDs printed).
# switch-latency needs frames; it orders its alpha-0 window in without activating. The tab checks need NOCHE_TABS_API=1 (new engine).
# NOCHE_PROBE_VISIBLE=1 makes the probe window opaque on screen: it needs the owner's approval each time and is never on by default.
# Surfaces checks (M1.4/M1.5 research): 90 s probe watchdog / 110 s outer. The script serves Probes/fixtures/pages next to index.html and starts
# Probes/fixtures/slow_server.py (200 MB at about 2 MB/s, Range-capable) for the download checks: NOCHE_PROBE_SLOW_URL, downloads land in a temp
# NOCHE_PROBE_DL_DIR that is deleted on exit. Run with NOCHE_TABS_API=1 NOCHE_ACTIONS_API=1 like the tab checks.
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
cp "$ROOT"/Probes/fixtures/pages/*.html "$SITE/"
DL_DIR="$(mktemp -d)"
SLOW_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 "$ROOT/Probes/fixtures/slow_server.py" "$SLOW_PORT" >/dev/null 2>&1 &
SLOW_PID=$!
export NOCHE_PROBE_SLOW_URL="http://127.0.0.1:$SLOW_PORT/big.bin" NOCHE_PROBE_DL_DIR="$DL_DIR"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SITE" >/dev/null 2>&1 &
SERVER_PID=$!
OUTF="$(mktemp)"
APP_PID=""
# Ctrl-C or a kill of this script must not leave the probe running: stop the one app PID this script spawned (never a list).
cleanup() {
  kill "$SERVER_PID" "$SLOW_PID" 2>/dev/null || true
  case "$DL_DIR" in /var/folders/*|/tmp/*|/private/*) rm -rf "$DL_DIR" ;; esac
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    for _ in $(seq 1 50); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$APP_PID" 2>/dev/null && kill -KILL "$APP_PID" 2>/dev/null || true
  fi
  rm -rf "$SITE" "$OUTF"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
REPORTS="$HOME/Library/Logs/DiagnosticReports"
crash_reports() { ls "$REPORTS" 2>/dev/null | grep '^Noche Probe.*\.ips$' | sort || true; }
front_pid() { lsappinfo info -only pid "$(lsappinfo front)" 2>/dev/null | sed -n 's/.*pid = \([0-9]*\).*/\1/p' | head -1; }
# Leftover helpers: PIDs whose command line holds the probe's Frameworks path (literal match, not a regex; the awk itself is skipped).
helpers() { ps -axo pid=,command= | awk -v p="$APP/Contents/Frameworks" 'index($0, p) && $2 != "awk" { print $1 }'; }
EXT_DIR="$HOME/Library/Application Support/Noche Probe/Default/Extensions"
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done

FAILED=0
for CHECK in "$@"; do
  : > "$OUTF"
  # Guard against the store-install pollution (B4) coming back: only the store checks may install, in their own profile.
  if [[ "$CHECK" != store-* && "$CHECK" != install-no-window ]] && [ -n "$(ls -A "$EXT_DIR" 2>/dev/null)" ]; then
    echo "PROBE $CHECK fail profile-polluted: $EXT_DIR holds $(ls -A "$EXT_DIR" | tr '\n' ' ')"
    FAILED=1; continue
  fi
  REPORTS_BEFORE="$(crash_reports)"
  LIMIT=$((40 + ${NOCHE_PROBE_SLACK:-20}))
  [[ "$CHECK" == rss-20* || "$CHECK" == tabs-bare-wait ]] && LIMIT=$((120 + ${NOCHE_PROBE_SLACK:-20}))
  [[ "$CHECK" =~ ^(cmd-enabled|bubbles|download-.*|ctx-ext-items|zoom-scope|chrome-pages)$ ]] && LIMIT=$((90 + ${NOCHE_PROBE_SLACK:-20}))
  # Web Store checks (store-*, install-no-window) load a live page and wait for an install: 150 s probe watchdog.
  [[ "$CHECK" == store-* || "$CHECK" == install-no-window ]] && LIMIT=$((150 + ${NOCHE_PROBE_SLACK:-20}))
  # Outer watchdog: if the app outlives its own 40s timeout, kill that one PID (see smoke.sh).
  (cd / && exec "$BIN" --probe="$CHECK" --url="http://127.0.0.1:$PORT/" \
      --load-extension="$ROOT/Probes/fixtures/probe-extension" --enable-logging=stderr >"$OUTF") &
  APP_PID=$!
  WATCHDOG=0; SAMPLES=0; FRONT=0; UNKNOWN=0; TICK=0
  for _ in $(seq 1 $((LIMIT * 10))); do
    kill -0 "$APP_PID" 2>/dev/null || break
    if [ $((TICK % 5)) = 0 ]; then
      SAMPLES=$((SAMPLES + 1)); FP="$(front_pid)"
      if [ -z "$FP" ]; then UNKNOWN=$((UNKNOWN + 1)); elif [ "$FP" = "$APP_PID" ]; then FRONT=$((FRONT + 1)); fi
    fi
    TICK=$((TICK + 1))
    sleep 0.1
  done
  if kill -0 "$APP_PID" 2>/dev/null; then
    # APP_PID is this script's own unreaped child, so it cannot have been reused: no command-line guard that could skip the kill.
    WATCHDOG=1
    kill -TERM "$APP_PID" 2>/dev/null || true  # the one PID, then the same PID hard after 5s
    for _ in $(seq 1 50); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$APP_PID" 2>/dev/null && kill -KILL "$APP_PID" 2>/dev/null || true
  fi
  set +e; wait "$APP_PID" 2>/dev/null; RC=$?; set -e
  APP_PID=""
  [ "$WATCHDOG" = 1 ] && echo "PROBE $CHECK fail watchdog" >> "$OUTF"
  grep '^PROBE ' "$OUTF" || echo "PROBE $CHECK fail no-output"
  grep -qxE "PROBE $CHECK pass( .*)?" "$OUTF" || FAILED=1
  if [ "$WATCHDOG" = 1 ] || [ "$RC" != 0 ]; then FAILED=1; echo "PROBE $CHECK fail exit-rc=$RC watchdog=$WATCHDOG"; fi
  echo "PROBE $CHECK info frontmost samples=$SAMPLES probe-frontmost=$FRONT unknown=$UNKNOWN"
  [ "$FRONT" = 0 ] || { FAILED=1; echo "PROBE $CHECK fail probe-was-frontmost in $FRONT of $SAMPLES samples"; }
  [ "$UNKNOWN" -lt "$SAMPLES" ] || { FAILED=1; echo "PROBE $CHECK fail frontmost-unreadable (lsappinfo gave no pid in $SAMPLES samples)"; }
  sleep 3  # crash reports land seconds after the crash; the probe's own listing at verdict time is too early
  NEW="$(comm -13 <(printf '%s\n' "$REPORTS_BEFORE") <(crash_reports))"
  if [ -n "$NEW" ]; then FAILED=1; echo "PROBE $CHECK fail new-crash-report: $(echo "$NEW" | tr '\n' ',')"; else echo "PROBE $CHECK info crash reports: none new"; fi
  LEFT=""
  for _ in $(seq 1 10); do LEFT="$(helpers | tr '\n' ' ')"; [ -z "$LEFT" ] && break; sleep 0.5; done
  if [ -n "$LEFT" ]; then FAILED=1; echo "PROBE leftover-helpers fail pids: $LEFT"; fi
done
exit "$FAILED"
