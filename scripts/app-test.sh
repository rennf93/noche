#!/usr/bin/env bash
# usage: app-test.sh <check>...   (window-frame hidden close-last quit-many web-insets layout tabs-keys tabs-rapid ext-count navigate blank-link long-title load-error menu sidebar-toggle sidebar-scroll shortcuts-once eval-async devtools-any-path no-zombie-tab devtools-quit devtools-close-tab load-error-link)
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
# --negative: run each check with its negative-control switch and expect it to FAIL (exit 0 only when all expected-FAIL ones do).
# devtools-quit with NOCHE_TEST_DEVTOOLS_LAST=1 is recorded only: the engine crash it targets has not reproduced in a hidden run.
if [ "${1:-}" = "--negative" ]; then
  BAD=0
  # An expected FAIL counts only when the check itself printed `NOCHE_TEST <check> fail <detail>` and the app exited 1 on its own
  # verdict: a build failure, crash, timeout, missing binary or crash report is a failure of --negative, not the expected one.
  # The lines this script adds itself (watchdog, no-output, exit-rc=, frontmost, crash report, helpers) are not the check's own.
  SCRIPT_LINES='^NOCHE_TEST [a-z0-9-]+ fail (watchdog|no-output|exit-rc=|NOCHE shutdown watchdog|NOCHE devtools|noche-was-frontmost|frontmost-unreadable|new-crash-report)'
  # NOCHE_NEG_PAIRS (";" separated "check VAR=1 expect-fail|record") replaces the list, to test this gate itself.
  PAIRS="${NOCHE_NEG_PAIRS:-no-zombie-tab NOCHE_TEST_NO_CLOSED_FILTER=1 expect-fail;hidden NOCHE_TEST_NEGATIVE=activate expect-fail;shortcuts-once NOCHE_TEST_NOEXACT=1 expect-fail;devtools-quit NOCHE_TEST_DEVTOOLS_LAST=1 record}"
  IFS=';' read -ra PAIR_LIST <<< "$PAIRS"
  for PAIR in "${PAIR_LIST[@]}"; do
    set -- $PAIR
    NEG_OUT="$(mktemp)"
    if env "$2" NOCHE_APPTEST_KEEP_HOOKS=1 "$0" "$1" >"$NEG_OUT" 2>/dev/null; then RES=pass; else RES=fail; fi
    OWN="$(grep -E "^NOCHE_TEST $1 fail " "$NEG_OUT" | grep -vE "$SCRIPT_LINES" | head -1 || true)"
    OTHER="$(grep -E "$SCRIPT_LINES" "$NEG_OUT" | grep -vE "^NOCHE_TEST $1 fail exit-rc=1 watchdog=0\$" | head -1 || true)"
    rm -f "$NEG_OUT"
    case "$3" in
      expect-fail)
        if [ "$RES" = pass ]; then echo "NEGATIVE $1 with $2: PASSED, the check cannot fail"; BAD=1
        elif [ -z "$OWN" ]; then echo "NEGATIVE $1 with $2: failed WITHOUT the check's own fail line (build failure, crash or timeout?)"; BAD=1
        elif [ -n "$OTHER" ]; then echo "NEGATIVE $1 with $2: the check failed, but the run also hit: $OTHER"; BAD=1
        else echo "NEGATIVE $1 with $2: failed as expected: $OWN"; fi ;;
      *) echo "NEGATIVE $1 with $2: $RES (recorded, not asserted)" ;;
    esac
  done
  # The app left on disk is the plain one.
  env -u NOCHE_TESTHOOKS "$ROOT/scripts/build-app.sh" >&2 || { echo "NEGATIVE plain rebuild failed"; BAD=1; }
  exit "$BAD"
fi
[ $# -gt 0 ] || { echo "usage: app-test.sh <check>... | --negative" >&2; exit 2; }
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
  if grep -q '^NOCHE devtools still open' "$ERRF"; then FAILED=1; echo "NOCHE_TEST $CHECK fail $(grep -m1 '^NOCHE devtools still open' "$ERRF")"; fi
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
# The app left on disk is the plain one (no test hooks), unless --negative asked to keep the hook build between runs.
if [ "${NOCHE_APPTEST_KEEP_HOOKS:-}" != 1 ]; then
  env -u NOCHE_TESTHOOKS "$ROOT/scripts/build-app.sh" >&2 || { echo "NOCHE_TEST plain-rebuild fail"; FAILED=1; }
fi
exit "$FAILED"
