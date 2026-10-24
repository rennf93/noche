#!/usr/bin/env bash
# usage: app-test.sh <check>...   (hidden, close-last, quit-many, web-insets)
# Builds Noche.app with the self-test hooks (NOCHE_TESTHOOKS=1), serves Tests/fixtures/app on a free localhost port and
# runs `Noche --selftest <check> --selftest-url <url>` once per check by direct exec (never `open`). Prints the app's
# NOCHE_TEST lines and exits 0 only if every check printed "pass", exited 0 and never hit the shutdown watchdog.
# Profile: ~/Library/Application Support/Noche Test (wiped before each check), never the dev profile.
# Controls the app cannot give itself: new Noche*.ips crash reports (diffed per launch after a 3 s settle), the frontmost
# app (lsappinfo every 0.5 s, fails if it is ever Noche) and leftover helpers (polled up to 5 s). The app's own limit is
# 40 s; this script kills the one app PID (TERM, then KILL) 20 s after that.
# A hidden window gets no frames while the screen is locked: a timeout with a locked screen or a loaded CPU is not
# necessarily a code fault (ioreg -n Root -d1 | grep CGSSessionScreenIsLocked).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ $# -gt 0 ] || { echo "usage: app-test.sh <check>..." >&2; exit 2; }
for C in "$@"; do
  [[ "$C" =~ ^[a-z0-9-]+$ ]] || { echo "bad check name: $C" >&2; exit 2; }
done
APP="$ROOT/build/Noche.app"
BIN="$APP/Contents/MacOS/Noche"
PROFILE="$HOME/Library/Application Support/Noche Test"
NOCHE_TESTHOOKS=1 "$ROOT/scripts/build-app.sh" >&2

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT/Tests/fixtures/app" >/dev/null 2>&1 &
SERVER_PID=$!
OUTF="$(mktemp)"
ERRF="$(mktemp)"
APP_PID=""
# Ctrl-C or a kill of this script must not leave the app running: stop the one app PID this script spawned (never a list).
cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    for _ in $(seq 1 50); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$APP_PID" 2>/dev/null && kill -KILL "$APP_PID" 2>/dev/null || true
  fi
  rm -rf "$OUTF" "$ERRF"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
REPORTS="$HOME/Library/Logs/DiagnosticReports"
crash_reports() { ls "$REPORTS" 2>/dev/null | grep '^Noche.*\.ips$' | grep -v '^Noche Probe' | sort || true; }
front_pid() { lsappinfo info -only pid "$(lsappinfo front)" 2>/dev/null | sed -n 's/.*pid = \([0-9]*\).*/\1/p' | head -1; }
# Leftover helpers: PIDs whose command line holds the app's Frameworks path (literal match, not a regex; the awk itself is skipped).
helpers() { ps -axo pid=,command= | awk -v p="$APP/Contents/Frameworks" 'index($0, p) && $2 != "awk" { print $1 }'; }
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done

FAILED=0
for CHECK in "$@"; do
  : > "$OUTF"; : > "$ERRF"
  rm -rf "$PROFILE"
  REPORTS_BEFORE="$(crash_reports)"
  LIMIT=$((40 + ${NOCHE_TEST_SLACK:-20}))
  # The throttling switches keep timers and renderers running in a window nobody sees.
  (cd / && exec "$BIN" --selftest "$CHECK" --selftest-url "http://127.0.0.1:$PORT/" \
      --load-extension="$ROOT/Probes/fixtures/probe-extension" \
      --disable-backgrounding-occluded-windows --disable-renderer-backgrounding \
      --disable-background-timer-throttling --mute-audio >"$OUTF" 2>"$ERRF") &
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
    # APP_PID is this script's own unreaped child, so it cannot have been reused.
    WATCHDOG=1
    kill -TERM "$APP_PID" 2>/dev/null || true  # the one PID, then the same PID hard after 5 s
    for _ in $(seq 1 50); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$APP_PID" 2>/dev/null && kill -KILL "$APP_PID" 2>/dev/null || true
  fi
  set +e; wait "$APP_PID" 2>/dev/null; RC=$?; set -e
  APP_PID=""
  [ "$WATCHDOG" = 1 ] && echo "NOCHE_TEST $CHECK fail watchdog" >> "$OUTF"
  grep '^NOCHE_TEST ' "$OUTF" || echo "NOCHE_TEST $CHECK fail no-output"
  grep -qE "^NOCHE_TEST $CHECK pass( .*)?\$" "$OUTF" || FAILED=1
  if grep -q '^NOCHE shutdown watchdog' "$ERRF"; then FAILED=1; echo "NOCHE_TEST $CHECK fail NOCHE shutdown watchdog fired"; fi
  if [ "$WATCHDOG" = 1 ] || [ "$RC" != 0 ]; then
    FAILED=1; echo "NOCHE_TEST $CHECK fail exit-rc=$RC watchdog=$WATCHDOG"
    grep '^NOCHE' "$ERRF" | head -20 || true
  fi
  echo "NOCHE_TEST $CHECK info frontmost samples=$SAMPLES noche-frontmost=$FRONT unknown=$UNKNOWN"
  [ "$FRONT" = 0 ] || { FAILED=1; echo "NOCHE_TEST $CHECK fail noche-was-frontmost in $FRONT of $SAMPLES samples"; }
  [ "$UNKNOWN" -lt "$SAMPLES" ] || { FAILED=1; echo "NOCHE_TEST $CHECK fail frontmost-unreadable (lsappinfo gave no pid in $SAMPLES samples)"; }
  sleep 3  # crash reports land seconds after the crash
  NEW="$(comm -13 <(printf '%s\n' "$REPORTS_BEFORE") <(crash_reports))"
  if [ -n "$NEW" ]; then FAILED=1; echo "NOCHE_TEST $CHECK fail new-crash-report: $(echo "$NEW" | tr '\n' ',')"; else echo "NOCHE_TEST $CHECK info crash reports: none new"; fi
  LEFT=""
  for _ in $(seq 1 10); do LEFT="$(helpers | tr '\n' ' ')"; [ -z "$LEFT" ] && break; sleep 0.5; done
  if [ -n "$LEFT" ]; then FAILED=1; echo "NOCHE_TEST leftover-helpers fail pids: $LEFT"; fi
done
rm -rf "$PROFILE"
exit "$FAILED"
