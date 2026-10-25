#!/usr/bin/env bash
# usage: app-test.sh <check>...   (a11y-labels quit-100 quit-early window-frame no-window close-beforeunload chromium-restore-relaunch chromium-restore-crash-relaunch persist-relaunch quit-close-relaunch quit-close-dirty-relaunch window-close-cancel reopen-closed reopen-closed-relaunch crash-mid-write corrupt-store reopen-identity frame-storm store-unavailable tab-chords move-tab-relaunch history-record cb-layout cb-open cb-motion cb-go cb-escape cb-arrows cb-inline cb-switch-tab cb-outside cb-nonet cb-nonet-default cb-history hidden close-last quit-many web-insets layout tabs-keys tabs-rapid ext-count navigate blank-link long-title load-error menu-diff menu-disabled menu-actions sidebar-toggle sidebar-scroll shortcuts-once eval-async devtools-any-path no-zombie-tab devtools-quit devtools-close-tab load-error-link focus-return newtab-surface ctx-page ctx-tab ctx-sidebar find zoom find-selection find-restart find-nav find-engine find-escape find-escape-page find-escape-guards zoom-engine)
# Builds Noche.app with the self-test hooks (NOCHE_TESTHOOKS=1), serves Tests/fixtures/app on a free localhost port and
# runs `Noche --selftest <check> --selftest-url <url>` once per check by direct exec (never `open`). Prints the app's
# NOCHE_TEST lines and exits 0 only if every check printed "pass", exited 0 and never hit the shutdown watchdog.
# Profile: ~/Library/Application Support/Noche Test (wiped before each check), never the dev profile.
# Two-phase checks (names ending in -relaunch): phase 1 runs with `--selftest-phase 1` on the wiped profile, phase 2 with
# `--selftest-phase 2` on the same profile; each phase must print its own `NOCHE_TEST <check> pass` (the crash variant `-crash-relaunch`: phase 1 prints `info phase1-ready` and this script SIGKILLs the one app PID) and every control below covers both.
# cb-history is two-phase by name (a typed visit through the command bar, then the relaunch shows it as a row); cb-nonet passes `--selftest-setting suggestRemote=1` and `--selftest-suggest-url` (the fixture's suggest.json) and counts requests in the fixture server's access log (NOCHE_TEST_SERVER_LOG).
# Store checks: quit-close-relaunch passes `--selftest-setting quitBehavior=close` in phase 1; crash-mid-write runs both
# NOCHE_TEST_KILL_AT variants (pending, in-transaction): phase 1 SIGKILLs itself (rc 137 expected), then `sqlite3 <store> "PRAGMA integrity_check"`
# must print ok before phase 2; persist-relaunch prints the phase 2 store's `.schema` and `PRAGMA integrity_check`; corrupt-store overwrites the store file with garbage between its phases.
# store-unavailable runs two variants: `file` (a plain file where the Store directory belongs) and `unwritable` (an existing store file in a
# Store directory set to mode 555; the permissions are restored by the EXIT trap whatever happens, and before each wipe of the profile).
# Controls the app cannot give itself: new Noche*.ips crash reports (diffed per launch after a 3 s settle), the frontmost
# app (lsappinfo every 0.5 s, fails if it is ever Noche) and leftover helpers (polled up to 5 s). The app's own limit is
# 40 s (90 s for quit-100); this script kills the one app PID (TERM, then KILL) 20 s after that.
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
  PAIRS="${NOCHE_NEG_PAIRS:-no-zombie-tab NOCHE_TEST_NO_CLOSED_FILTER=1 expect-fail;hidden NOCHE_TEST_NEGATIVE=activate expect-fail;hidden NOCHE_TEST_NEGATIVE=alpha expect-fail;chromium-restore-relaunch NOCHE_TEST_RESTORE_EXPECT=1 expect-fail;chromium-restore-crash-relaunch NOCHE_TEST_RESTORE_EXPECT=1 expect-fail;persist-relaunch NOCHE_TEST_NOFLUSH=1 expect-fail;reopen-closed NOCHE_TEST_NO_CLOSED=1 expect-fail;quit-close-dirty-relaunch NOCHE_TEST_NO_QUIT_CLEAR=1 expect-fail;window-close-cancel NOCHE_TEST_STICKY_CLOSING=1 expect-fail;tab-chords NOCHE_TEST_NO_LIST_ORDER=1 expect-fail;move-tab-relaunch NOCHE_TEST_NO_MOVE=1 expect-fail;history-record NOCHE_TEST_NO_RECORD=1 expect-fail;shortcuts-once NOCHE_TEST_NOEXACT=1 expect-fail;focus-return NOCHE_TEST_NO_FOCUS=1 expect-fail;newtab-surface NOCHE_TEST_NO_HIDE=1 expect-fail;focus-return NOCHE_TEST_NO_AMBIGUOUS_GUARD=1 expect-fail;newtab-surface NOCHE_TEST_NO_UNHIDE=1 expect-fail;cb-layout NOCHE_TEST_BAR_LAYOUT=1 expect-fail;cb-open NOCHE_TEST_BAR_NOFOCUS=1 expect-fail;cb-motion NOCHE_TEST_BAR_NOMOTION=1 expect-fail;cb-go NOCHE_TEST_BAR_NOGO=1 expect-fail;cb-go NOCHE_TEST_BAR_ROUTE=1 expect-fail;cb-escape NOCHE_TEST_BAR_ESC=1 expect-fail;cb-escape NOCHE_TEST_NO_FOCUS=1 expect-fail;cb-arrows NOCHE_TEST_BAR_NOARROWS=1 expect-fail;cb-inline NOCHE_TEST_BAR_INLINE=1 expect-fail;cb-switch-tab NOCHE_TEST_BAR_DUPTAB=1 expect-fail;cb-outside NOCHE_TEST_BAR_NOOUTSIDE=1 expect-fail;cb-nonet NOCHE_TEST_NO_DEBOUNCE=1 expect-fail;cb-history NOCHE_TEST_NO_RECORD=1 expect-fail;cb-open NOCHE_TEST_BAR_NOFOCUSLOC=1 expect-fail;cb-inline NOCHE_TEST_BAR_STALEDELETE=1 expect-fail;history-record NOCHE_TEST_TYPED_STICKY=1 expect-fail;cb-nonet NOCHE_TEST_HOST_SWAP=1 expect-fail;cb-nonet NOCHE_TEST_HOST_SWAP_UNGUARDED=1 expect-fail;cb-nonet NOCHE_TEST_REMOTE_IGNORE_OFF=1 expect-fail;cb-nonet-default NOCHE_TEST_REMOTE_IGNORE_OFF=1 expect-fail;menu-diff NOCHE_TEST_MENU_DRIFT=1 expect-fail;menu-disabled NOCHE_TEST_MENU_NODISABLE=1 expect-fail;menu-actions NOCHE_TEST_NO_DUPLICATE=1 expect-fail;menu-actions NOCHE_TEST_NO_FULLURL=1 expect-fail;shortcuts-once NOCHE_TEST_NO_CLOSEALL=1 expect-fail;shortcuts-once NOCHE_TEST_NO_SHIFTMAP=1 expect-fail;shortcuts-once NOCHE_TEST_NO_EXACTFIRST=1 expect-fail;shortcuts-once NOCHE_TEST_NO_PREEMPT=1 expect-fail;menu-diff NOCHE_TEST_MENU_SELECTOR=1 expect-fail;menu-actions NOCHE_TEST_NO_SHARE=1 expect-fail;menu-actions NOCHE_TEST_NO_DIAG=1 expect-fail;ctx-page NOCHE_TEST_CTX_NOENABLE=1 expect-fail;ctx-page NOCHE_TEST_CTX_NOCHOOSE=1 expect-fail;ctx-page NOCHE_TEST_CTX_NOEXT=1 expect-fail;ctx-page NOCHE_TEST_CTX_NOCANCEL=1 expect-fail;ctx-tab NOCHE_TEST_CTX_TABORDER=1 expect-fail;ctx-tab NOCHE_TEST_CTX_TABENABLE=1 expect-fail;ctx-sidebar NOCHE_TEST_CTX_NOREOPEN=1 expect-fail;ctx-sidebar NOCHE_TEST_CTX_CLOSEALLBLANK=1 expect-fail;find NOCHE_TEST_FIND_NOSTEP=1 expect-fail;find NOCHE_TEST_FIND_NOCLEAR=1 expect-fail;find-selection NOCHE_TEST_FIND_NOSELECT=1 expect-fail;find NOCHE_TEST_FIND_PREVFWD=1 expect-fail;find-restart NOCHE_TEST_FIND_STALE=1 expect-fail;find-nav NOCHE_TEST_FIND_NONAV=1 expect-fail;find-engine NOCHE_TEST_FIND_NOCLOSECMD=1 expect-fail;zoom-engine NOCHE_TEST_ZOOM_NOFOLLOW=1 expect-fail;find-escape NOCHE_TEST_NO_PREEMPT=1 expect-fail;find-escape NOCHE_TEST_ESC_ALWAYS=1 expect-fail;find-escape-page NOCHE_TEST_ESC_ALWAYS=1 expect-fail;find-escape-guards NOCHE_TEST_ESC_ALWAYS=1 expect-fail;find NOCHE_TEST_FIND_NOLEAVESTOP=1 expect-fail;find-restart NOCHE_TEST_FIND_NOFLOOR=1 expect-fail;menu-disabled NOCHE_TEST_FIND_NTENABLED=1 expect-fail;zoom NOCHE_TEST_ZOOM_NOPILL=1 expect-fail;zoom NOCHE_TEST_ZOOM_WINDOW=1 expect-fail;devtools-quit NOCHE_TEST_DEVTOOLS_LAST=1 record}"
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
PROFILE="$HOME/Library/Application Support/Noche Test"
[ -n "$HOME" ] && [ -n "$PROFILE" ] && [[ "$PROFILE" == */"Noche Test" ]] || { echo "refusing to run: bad PROFILE '$PROFILE'" >&2; exit 2; }
APP="$ROOT/build/Noche.app"
BIN="$APP/Contents/MacOS/Noche"
NOCHE_TESTHOOKS=1 "$ROOT/scripts/build-app.sh" >&2

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
# The server's access log is the independent record of the requests cb-nonet counts (the app reads it through NOCHE_TEST_SERVER_LOG).
SERVER_LOG="$(mktemp)"
export NOCHE_TEST_SERVER_LOG="$SERVER_LOG"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT/Tests/fixtures/app" >/dev/null 2>"$SERVER_LOG" &
SERVER_PID=$!
OUTF="$(mktemp)"
ERRF="$(mktemp)"
APP_PID=""
# Ctrl-C or a kill of this script must not leave the app running: stop the one app PID this script spawned (never a list).
# The unwritable variant of store-unavailable leaves the Store directory at 555 while the app runs; the EXIT trap restores it. A SIGKILL of
# this script skips the trap and leaves 555 until the next run's pre-wipe chmod (before its rm -rf of the profile).
cleanup() {
  [ -n "${PROFILE:-}" ] && [ -d "$PROFILE/Store" ] && { chmod -R u+rwx "$PROFILE/Store" 2>/dev/null || true; }
  kill "$SERVER_PID" 2>/dev/null || true
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    for _ in $(seq 1 50); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$APP_PID" 2>/dev/null && kill -KILL "$APP_PID" 2>/dev/null || true
  fi
  rm -rf "$OUTF" "$ERRF" "$SERVER_LOG"
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
  # Checks ending in -relaunch (and crash-mid-write, corrupt-store) run twice on one profile (phase 1, then 2); each phase must print its own pass line.
  PHASES=""; case "$CHECK" in *-relaunch|crash-mid-write|corrupt-store|cb-history) PHASES="1 2" ;; esac
  # crash-mid-write runs once per kill point, store-unavailable once per variant.
  KILLS="${NOCHE_TEST_KILL_AT:-none}"; [ "$CHECK" != crash-mid-write ] || KILLS="pending in-transaction"
  [ "$CHECK" != store-unavailable ] || KILLS="file unwritable"  # the variants share the loop variable
  for KILL_AT in $KILLS; do
  for PHASE in ${PHASES:-none}; do
    [ "$PHASE" != none ] || PHASE=""
    : > "$OUTF"; : > "$ERRF"
    # Only phase 1 (or a one-phase check) starts from a wiped profile: phase 2 relaunches on what phase 1 left.
    if [ -z "$PHASE" ] || [ "$PHASE" = 1 ]; then [ -n "$PROFILE" ] && chmod -R u+rwx "$PROFILE" 2>/dev/null || true; rm -rf "$PROFILE"; fi
    # corrupt-store: garbage over the store file (the WAL files stay), then phase 2 must quarantine it and start with one window.
    if [ "$CHECK" = corrupt-store ] && [ "$PHASE" = 2 ]; then
      [ -f "$PROFILE/Store/noche.sqlite" ] || { FAILED=1; echo "NOCHE_TEST $CHECK fail no store file left by phase 1"; break; }
      # Fold the WAL into the file first: pages still in the WAL would shadow the garbage and the store would open fine.
      sqlite3 "$PROFILE/Store/noche.sqlite" "PRAGMA wal_checkpoint(TRUNCATE)" >/dev/null 2>&1 || true
      head -c 8192 /dev/urandom > "$PROFILE/Store/noche.sqlite"
    fi
    # store-unavailable: a plain file where the Store directory belongs; the app must run on an in-memory store and leave it alone.
    if [ "$CHECK" = store-unavailable ] && [ "$KILL_AT" = file ]; then
      mkdir -p "$PROFILE"; printf 'not a directory: sentinel bytes' > "$PROFILE/Store"; SENTINEL="$(shasum "$PROFILE/Store")"
    fi
    # unwritable: a real store file (one table, closed cleanly so no WAL is left) in a read-only directory.
    if [ "$CHECK" = store-unavailable ] && [ "$KILL_AT" = unwritable ]; then
      mkdir -p "$PROFILE/Store"; sqlite3 "$PROFILE/Store/noche.sqlite" "CREATE TABLE sentinel(a); INSERT INTO sentinel VALUES ('kept')"
      SENTINEL="$(shasum "$PROFILE/Store/noche.sqlite")"; LISTING="$(ls -a "$PROFILE/Store")"; chmod 555 "$PROFILE/Store"
    fi
    EXTRA=(); [ "$CHECK" != quit-close-relaunch ] && [ "$CHECK" != quit-close-dirty-relaunch ] || [ "$PHASE" != 1 ] || EXTRA=(--selftest-setting quitBehavior=close)
    # cb-nonet: remote suggestions on, pointed at the fixture server (no self-test touches the network).
    [ "$CHECK" != cb-nonet-default ] || EXTRA=(--selftest-suggest-url "http://127.0.0.1:$PORT/suggest.json?q=%s")
    [ "$CHECK" != cb-nonet ] || EXTRA=(--selftest-setting suggestRemote=1 --selftest-suggest-url "http://127.0.0.1:$PORT/suggest.json?q=%s")
    SELFKILL=0; [ "$CHECK" != crash-mid-write ] || [ "$PHASE" != 1 ] || SELFKILL=1
    REPORTS_BEFORE="$(crash_reports)"
    BASE=40; [ "$CHECK" = quit-100 ] && BASE=90  # the app's own limit, see SelfTest.limit
    LIMIT=$((BASE + ${NOCHE_TEST_SLACK:-20}))
    # The throttling switches keep timers and renderers running in a window nobody sees.
    (cd / && { [ "$CHECK" != crash-mid-write ] || [ "$KILL_AT" = none ] || export NOCHE_TEST_KILL_AT="$KILL_AT"; } && exec "$BIN" --selftest "$CHECK" --selftest-url "http://127.0.0.1:$PORT/" ${PHASE:+--selftest-phase $PHASE} ${EXTRA[@]+"${EXTRA[@]}"} \
        --load-extension="$ROOT/Probes/fixtures/probe-extension" \
        --disable-backgrounding-occluded-windows --disable-renderer-backgrounding \
        --disable-background-timer-throttling --mute-audio >"$OUTF" 2>"$ERRF") &
    APP_PID=$!
    KILLED=0
    WATCHDOG=0; SAMPLES=0; FRONT=0; UNKNOWN=0; TICK=0
    for _ in $(seq 1 $((LIMIT * 10))); do
      kill -0 "$APP_PID" 2>/dev/null || break
      # The crash variant: phase 1 prints phase1-ready, then this script SIGKILLs the one app PID it started (no quit, no cleanup).
      if [ "$PHASE" = 1 ] && [[ "$CHECK" == *-crash-relaunch ]] && grep -q "^NOCHE_TEST $CHECK info phase1-ready" "$OUTF"; then
        sleep 2; kill -KILL "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; KILLED=1; break
      fi
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
    if [ "$CHECK" = store-unavailable ] && [ "$KILL_AT" = unwritable ]; then
      MODE="$(stat -f %Lp "$PROFILE/Store")"; chmod -R u+rwx "$PROFILE/Store"
      [ "$MODE" = 555 ] || { FAILED=1; echo "NOCHE_TEST $CHECK fail the Store directory mode changed to $MODE"; }
      [ "$(shasum "$PROFILE/Store/noche.sqlite" 2>/dev/null)" = "$SENTINEL" ] || { FAILED=1; echo "NOCHE_TEST $CHECK fail the existing store file changed"; }
      [ "$(ls -a "$PROFILE/Store")" = "$LISTING" ] || { FAILED=1; echo "NOCHE_TEST $CHECK fail the Store directory listing changed: $(ls -a "$PROFILE/Store" | tr '\n' ' ')"; }
      echo "NOCHE_TEST $CHECK info variant=unwritable mode-after-run=$MODE file and listing unchanged"
    fi
    if [ "$CHECK" = store-unavailable ]; then
      [ "$KILL_AT" != file ] || [ "$(shasum "$PROFILE/Store" 2>/dev/null)" = "$SENTINEL" ] || { FAILED=1; echo "NOCHE_TEST $CHECK fail the file at the store path changed"; }
      grep -q '^NOCHE store unavailable: ' "$ERRF" || { FAILED=1; echo "NOCHE_TEST $CHECK fail no 'NOCHE store unavailable' line on stderr"; }
    fi
    # crash-mid-write phase 1: the app SIGKILLs itself from the test hook (rc 137), then the file must pass integrity_check.
    if [ "$SELFKILL" = 1 ]; then
      KILLED=1
      [ "$RC" = 137 ] || { FAILED=1; echo "NOCHE_TEST $CHECK fail app was not SIGKILLed by its kill hook (kill-at=$KILL_AT rc=$RC)"; }
      IC="$(sqlite3 "$PROFILE/Store/noche.sqlite" "PRAGMA integrity_check" 2>&1 || true)"
      echo "NOCHE_TEST $CHECK info kill-at=$KILL_AT integrity_check=$IC"
      [ "$IC" = ok ] || { FAILED=1; echo "NOCHE_TEST $CHECK fail integrity_check after kill-at=$KILL_AT: $IC"; }
    fi
    [ "$WATCHDOG" = 1 ] && echo "NOCHE_TEST $CHECK fail watchdog" >> "$OUTF"
    grep '^NOCHE_TEST ' "$OUTF" || echo "NOCHE_TEST $CHECK fail no-output"
    if [ "$KILLED" = 1 ]; then
      grep -q "^NOCHE_TEST $CHECK info phase1-ready" "$OUTF" || FAILED=1
    else
      grep -qE "^NOCHE_TEST $CHECK pass( .*)?\$" "$OUTF" || FAILED=1
    fi
    if grep -q '^NOCHE shutdown watchdog' "$ERRF"; then FAILED=1; echo "NOCHE_TEST $CHECK fail NOCHE shutdown watchdog fired"; fi
    if grep -q '^NOCHE devtools still open' "$ERRF"; then FAILED=1; echo "NOCHE_TEST $CHECK fail $(grep -m1 '^NOCHE devtools still open' "$ERRF")"; fi
    if [ "$WATCHDOG" = 1 ] || { [ "$RC" != 0 ] && [ "$KILLED" = 0 ]; }; then
      FAILED=1; echo "NOCHE_TEST $CHECK fail exit-rc=$RC watchdog=$WATCHDOG"
      grep '^NOCHE' "$ERRF" | head -20 || true
      echo "--- last stderr lines:"; tail -15 "$ERRF" || true
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
    # What Chromium left for the relaunch (positive control: a session must exist for "no restore" to mean anything).
    if [ "$PHASE" = 1 ]; then
      # The gate: the newest unencrypted session file must name the 3 fixture URLs, or "Chromium does not restore" proves nothing.
      case "$CHECK" in chromium-restore-relaunch|chromium-restore-crash-relaunch)
        NEWEST="$(ls -t "$PROFILE"/Cache/Default/Sessions/Session_* 2>/dev/null | head -1 || true)"
        SESSION_URLS=0; [ -z "$NEWEST" ] || SESSION_URLS="$(strings "$NEWEST" | grep -o "http://127.0.0.1:$PORT/" | wc -l | tr -d ' ')" || SESSION_URLS=0
        echo "NOCHE_TEST $CHECK info session-file=${NEWEST##*/} fixture-urls=$SESSION_URLS"
        [ "$SESSION_URLS" -ge 3 ] || { FAILED=1; echo "NOCHE_TEST $CHECK fail session file has $SESSION_URLS of the 3 fixture URLs (${NEWEST:-no session file})"; } ;;
      esac
      echo "NOCHE_TEST $CHECK info sessions=$(cd "$PROFILE" 2>/dev/null && find . \( -iname 'Session*' -o -iname 'Current *' -o -iname 'Last *' -o -iname 'Tabs_*' \) -exec ls -ldT {} + 2>/dev/null | awk '{print $5 ":" $NF}' | tr '\n' ' ')"
    fi
    # persist-relaunch phase 2: the store file the relaunch ran on, as the sqlite3 CLI reads it (evidence: schema and integrity).
    if [ "$CHECK" = persist-relaunch ] && [ "$PHASE" = 2 ]; then
      sqlite3 -readonly "$PROFILE/Store/noche.sqlite" ".schema" | sed 's/^/NOCHE_TEST persist-relaunch info schema| /'
      echo "NOCHE_TEST persist-relaunch info integrity_check=$(sqlite3 -readonly "$PROFILE/Store/noche.sqlite" "PRAGMA integrity_check" 2>&1 || true)"
    fi
    # A phase 1 without its pass (or phase1-ready) line leaves nothing for phase 2 to check.
    if [ "$KILLED" = 1 ]; then grep -q "^NOCHE_TEST $CHECK info phase1-ready" "$OUTF" || break
    else grep -qE "^NOCHE_TEST $CHECK pass( .*)?\$" "$OUTF" || break; fi
  done
  done
done
rm -rf "$PROFILE"
# The app left on disk is the plain one (no test hooks), unless --negative asked to keep the hook build between runs.
if [ "${NOCHE_APPTEST_KEEP_HOOKS:-}" != 1 ]; then
  env -u NOCHE_TESTHOOKS "$ROOT/scripts/build-app.sh" >&2 || { echo "NOCHE_TEST plain-rebuild fail"; FAILED=1; }
fi
exit "$FAILED"
