#!/usr/bin/env bash
# usage: probe-engine.sh <check>...   (store-stock, store-ua, store-brand, store-ua-brand, install-no-window (live Chrome Web Store, task B4), ext-loaded, tabs-one, tabs-20, ext-create, ext-activate, switch-latency, rss-20, blank-link, per-tab-client, close-non-last, close-last, close-callbacks, window-normal, cmd-enabled, bubbles, download-restart-1, download-restart-2 (run 1 then 2, same profile), download-tab-close, download-tab-close-start, download-restart-crash-1/2, download-control-cancel-1/2, download-control-rejected, download-control-noprofile, ctx-ext-items, zoom-scope, chrome-pages, zoom-no-bubble)
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
# Probes/fixtures/slow_server.py (/big.bin 200 MB and /mid.bin 24 MB of a deterministic pattern at about 2 MB/s, Range-capable) for the
# download checks: NOCHE_PROBE_SLOW_URL, NOCHE_PROBE_MID_URL, NOCHE_PROBE_SLOW_LOG (one line per request with its Range header), downloads land in a
# temp NOCHE_PROBE_DL_DIR that is deleted on exit. download-restart-crash-1 is killed with SIGKILL by this script (it prints ready-to-kill first).
# Patch 0008 checks need the new engine API for SetDownloadHandler: NOCHE_DOWNLOAD_API=1 (without it they print the missing API as a failed assertion). Run with NOCHE_TABS_API=1 NOCHE_ACTIONS_API=1 like the tab checks.
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
SLOW_LOG="$(mktemp)"
python3 "$ROOT/Probes/fixtures/slow_server.py" "$SLOW_PORT" "$SLOW_LOG" >/dev/null 2>&1 &
SLOW_PID=$!
export NOCHE_PROBE_SLOW_URL="http://127.0.0.1:$SLOW_PORT/big.bin" NOCHE_PROBE_MID_URL="http://127.0.0.1:$SLOW_PORT/mid.bin" NOCHE_PROBE_SLOW_LOG="$SLOW_LOG" NOCHE_PROBE_DL_DIR="$DL_DIR"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SITE" >/dev/null 2>&1 &
SERVER_PID=$!
OUTF="$(mktemp)"
HIST_COPY="$(mktemp)"
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
  rm -rf "$SITE" "$OUTF" "$SLOW_LOG" "$HIST_COPY"
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

# Copy of the History database (with journal/WAL) queried with sqlite3; prints the query result on one line.
hist_query() {
  local hd="$HOME/Library/Application Support/Noche Probe/Default" hc f
  hc="$(mktemp -d)"
  for f in History History-journal History-wal History-shm; do if [ -f "$hd/$f" ]; then cp "$hd/$f" "$hc/$f"; fi; done
  sqlite3 -separator '|' "$hc/History" "$1" 2>&1 | tr '\n' ' '
  rm -rf "$hc"
}
FAILED=0
for CHECK in "$@"; do
  : > "$OUTF"
  # Download checks start from an empty download directory, except a -2 check, which continues its -1 check.
  [[ "$CHECK" == download-* && "$CHECK" != *-2 ]] && rm -rf "${DL_DIR:?}"/* 2>/dev/null
  # Guard against the store-install pollution (B4) coming back: only the store checks may install, in their own profile.
  if [[ "$CHECK" != store-* && "$CHECK" != install-no-window ]] && [ -n "$(ls -A "$EXT_DIR" 2>/dev/null)" ]; then
    echo "PROBE $CHECK fail profile-polluted: $EXT_DIR holds $(ls -A "$EXT_DIR" | tr '\n' ' ')"
    FAILED=1; continue
  fi
  REPORTS_BEFORE="$(crash_reports)"
  # probe.log is rewritten by every launch (freopen "w" in main.mm); remove it first so a launch that dies before that cannot show an old launch's lines.
  rm -f "$HOME/Library/Application Support/Noche Probe/probe.log"
  HIST_MAX0=0
  [[ "$CHECK" == download-control-rejected ]] && HIST_MAX0="$(hist_query 'select coalesce(max(id),0) from downloads' | tr -d ' ')"
  LIMIT=$((40 + ${NOCHE_PROBE_SLACK:-20}))
  [[ "$CHECK" == rss-20* || "$CHECK" == tabs-bare-wait ]] && LIMIT=$((120 + ${NOCHE_PROBE_SLACK:-20}))
  [[ "$CHECK" =~ ^(cmd-enabled|bubbles|download-.*|ctx-ext-items|zoom-scope|chrome-pages|zoom-no-bubble)$ ]] && LIMIT=$((90 + ${NOCHE_PROBE_SLACK:-20}))
  # Web Store checks (store-*, install-no-window) load a live page and wait for an install: 150 s probe watchdog.
  [[ "$CHECK" == store-* || "$CHECK" == install-no-window ]] && LIMIT=$((150 + ${NOCHE_PROBE_SLACK:-20}))
  # Outer watchdog: if the app outlives its own 40s timeout, kill that one PID (see smoke.sh).
  (cd / && exec "$BIN" --probe="$CHECK" --url="http://127.0.0.1:$PORT/" \
      --load-extension="$ROOT/Probes/fixtures/probe-extension" --enable-logging=stderr >"$OUTF") &
  APP_PID=$!
  WATCHDOG=0; SAMPLES=0; FRONT=0; UNKNOWN=0; TICK=0; KILLED=0
  for _ in $(seq 1 $((LIMIT * 10))); do
    kill -0 "$APP_PID" 2>/dev/null || break
    # download-restart-crash-1 asks the harness to kill -9 it (no shutdown code runs) once it printed ready-to-kill.
    if [[ "$CHECK" == download-restart-crash-1 && "$KILLED" = 0 ]] && grep -q "info ready-to-kill" "$OUTF"; then
      KILLED=1; kill -KILL "$APP_PID" 2>/dev/null || true
    fi
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
  [ "$KILLED" = 1 ] && echo "PROBE $CHECK pass killed with SIGKILL by the harness after ready-to-kill" >> "$OUTF" && RC=0
  grep '^PROBE ' "$OUTF" || echo "PROBE $CHECK fail no-output"
  grep -qxE "PROBE $CHECK pass( .*)?" "$OUTF" || FAILED=1
  if [ "$WATCHDOG" = 1 ] || [ "$RC" != 0 ]; then FAILED=1; echo "PROBE $CHECK fail exit-rc=$RC watchdog=$WATCHDOG"; fi
  # Independent witness for download-control-rejected: a rejected download (no WebContents) is cancelled by CEF's item->Cancel(true) at
  # creation, which leaves a History row with state 2 (cancelled) and interrupt reason 40 (USER_CANCELED) for every new file:///etc/hosts item.
  if [[ "$CHECK" == download-control-rejected ]]; then
    Q="from downloads d join downloads_url_chains u on u.id=d.id where u.url='file:///etc/hosts' and d.id>$HIST_MAX0"
    TOTAL="$(hist_query "select count(*) $Q" | tr -d ' ')"; GOOD="$(hist_query "select count(*) $Q and d.state=2 and d.interrupt_reason=40" | tr -d ' ')"
    if [ "${TOTAL:-0}" -gt 0 ] 2>/dev/null && [ "$TOTAL" = "$GOOD" ]; then
      echo "PROBE $CHECK info assert history-rows-cancelled-by-cancel-true PASS: $TOTAL new History row(s) for the rejected URL, all state 2 reason 40 (USER_CANCELED)"
    else
      FAILED=1; echo "PROBE $CHECK fail history-rows-cancelled-by-cancel-true: new History rows for the rejected URL: $TOTAL, cancelled with reason 40: $GOOD (want all)"
    fi
  fi
  # An exit code other than 0 (pass) or 1 (a failed check) is the engine or the OS ending the process: show how it ended.
  if [ "$RC" != 0 ] && [ "$RC" != 1 ] && [ "$WATCHDOG" = 0 ]; then
    # Exit code 2 is content::RESULT_CODE_HUNG: chrome/browser/shutdown_watchdog_mac.cc _exit()s with it when engine shutdown takes over 10 s
    # (it logs "Teardown watchdog expired"). Seen only under heavy machine load; it is a real failure, shutdown was too slow.
    if grep -q "Teardown watchdog expired" "$HOME/Library/Application Support/Noche Probe/probe.log" 2>/dev/null; then
      echo "PROBE $CHECK fail engine shutdown watchdog fired (exit code $RC = RESULT_CODE_HUNG, shutdown took over 10 s)"
    fi
    echo "PROBE $CHECK info unexpected exit code $RC (1-minute load $(uptime | sed 's/.*load averages*: *//' | awk '{print $1}')); probe.log tail: $(tail -n 6 "$HOME/Library/Application Support/Noche Probe/probe.log" | cut -c1-200 | tr '\n' '|')"
  fi
  # Independent witness between launches: what the History database holds for the downloads. The app is gone, so copy the database
  # together with its journal/WAL files into a temp dir (a copy of History alone misses rows that only exist in the journal) and
  # print the files that were copied, so a stale snapshot would be visible.
  if [[ "$CHECK" =~ ^download-.*-[12]$ ]] && command -v sqlite3 >/dev/null; then
    HD="$HOME/Library/Application Support/Noche Probe/Default"
    HC="$(mktemp -d)"
    for F in History History-journal History-wal History-shm; do [ -f "$HD/$F" ] && cp "$HD/$F" "$HC/$F"; done
    echo "PROBE $CHECK info History files copied: $(cd "$HC" && ls -l | awk 'NR>1 {print $9 ":" $5}' | tr '\n' ' ')"
    echo "PROBE $CHECK info History downloads (id|state|interrupt_reason|received_bytes|etag, newest 3; state 1=complete 2=cancelled 3=interrupted, 0=in progress): $(sqlite3 -separator '|' "$HC/History" 'select id,state,interrupt_reason,received_bytes,etag from downloads order by id desc limit 3' 2>&1 | tr '\n' ' ')"
    rm -rf "$HC"
    # download-restart-crash-1: History has NO row for the killed download even with its WAL copied (measured 2026-10-25: the row for id N
    # first appeared in History when launch 2 handled the restored item). In-progress downloads are persisted in the in-progress download DB
    # (leveldb under shared_proto_db) until a History row is written, so only launch 2 can show what crash recovery restored.
  fi
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
