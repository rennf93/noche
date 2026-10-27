#!/usr/bin/env bash
# usage: app-test.sh <check>...   (a11y-labels quit-100 quit-early quit-with-context-menu quit-menu-late quit-menu-stuck window-frame no-window close-beforeunload chromium-restore-relaunch chromium-restore-crash-relaunch persist-relaunch quit-close-relaunch quit-close-dirty-relaunch window-close-cancel reopen-closed reopen-closed-relaunch crash-mid-write corrupt-store reopen-identity frame-storm store-unavailable tab-chords move-tab-relaunch history-record cb-layout cb-open cb-motion cb-go cb-escape cb-arrows cb-inline cb-switch-tab cb-outside cb-nonet cb-nonet-default cb-history hidden close-last quit-many web-insets layout tabs-keys tabs-rapid ext-count navigate blank-link long-title load-error menu-diff menu-disabled menu-actions sidebar-toggle sidebar-scroll shortcuts-once eval-async devtools-any-path no-zombie-tab devtools-quit devtools-close-tab load-error-link focus-return newtab-surface ctx-page ctx-tab ctx-sidebar find zoom find-selection find-restart find-nav find-engine find-escape find-escape-page find-escape-guards zoom-engine pw-on bridge-dl bridge-perm dl-list dl-controls dl-tab-close dl-quit-relaunch dl-ring perm-prompt perm-remember perm-remember-relaunch perm-no-bubble perm-dismiss perm-guards perm-forget perm-iframe title-throttle title-flush history-window bm-add bm-bar bm-open bm-manager bm-suggest bm-all-tabs cb-readpath cb-reopen perm-origins perm-dismiss-id window-front quit-gap-close-relaunch quit-gap-tab-relaunch history-cap title-window-close window-recency dl-remove-relaunch bm-bar-relaunch history-dock dl-restored-cancel-relaunch dl-restored-silent-relaunch dl-cancel-slow bm-dupes bm-menu-lazy dl-clear-write dl-reuse dl-file-missing dl-rows bm-remove-undo cb-reopen-late dl-file-stats cb-reopen-reqlate bm-undo-valid sidebar-geometry sidebar-columns sidebar-scale min-width min-width-relaunch pin-toggle pin-dormant pin-reset pin-launch pin-launch-held reopen-container pin-reveal discard-click discard-policy discard-hang discard-media)
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
  PAIRS="${NOCHE_NEG_PAIRS:-no-zombie-tab NOCHE_TEST_NO_CLOSED_FILTER=1 expect-fail;hidden NOCHE_TEST_NEGATIVE=activate expect-fail;hidden NOCHE_TEST_NEGATIVE=alpha expect-fail;chromium-restore-relaunch NOCHE_TEST_RESTORE_EXPECT=1 expect-fail;chromium-restore-crash-relaunch NOCHE_TEST_RESTORE_EXPECT=1 expect-fail;persist-relaunch NOCHE_TEST_NOFLUSH=1 expect-fail;reopen-closed NOCHE_TEST_NO_CLOSED=1 expect-fail;quit-close-dirty-relaunch NOCHE_TEST_NO_QUIT_CLEAR=1 expect-fail;window-close-cancel NOCHE_TEST_STICKY_CLOSING=1 expect-fail;tab-chords NOCHE_TEST_NO_LIST_ORDER=1 expect-fail;move-tab-relaunch NOCHE_TEST_NO_MOVE=1 expect-fail;history-record NOCHE_TEST_NO_RECORD=1 expect-fail;shortcuts-once NOCHE_TEST_NOEXACT=1 expect-fail;focus-return NOCHE_TEST_NO_FOCUS=1 expect-fail;newtab-surface NOCHE_TEST_NO_HIDE=1 expect-fail;focus-return NOCHE_TEST_NO_AMBIGUOUS_GUARD=1 expect-fail;newtab-surface NOCHE_TEST_NO_UNHIDE=1 expect-fail;cb-layout NOCHE_TEST_BAR_LAYOUT=1 expect-fail;cb-open NOCHE_TEST_BAR_NOFOCUS=1 expect-fail;cb-motion NOCHE_TEST_BAR_NOMOTION=1 expect-fail;cb-go NOCHE_TEST_BAR_NOGO=1 expect-fail;cb-go NOCHE_TEST_BAR_ROUTE=1 expect-fail;cb-escape NOCHE_TEST_BAR_ESC=1 expect-fail;cb-escape NOCHE_TEST_NO_FOCUS=1 expect-fail;cb-arrows NOCHE_TEST_BAR_NOARROWS=1 expect-fail;cb-inline NOCHE_TEST_BAR_INLINE=1 expect-fail;cb-switch-tab NOCHE_TEST_BAR_DUPTAB=1 expect-fail;cb-outside NOCHE_TEST_BAR_NOOUTSIDE=1 expect-fail;cb-nonet NOCHE_TEST_NO_DEBOUNCE=1 expect-fail;cb-history NOCHE_TEST_NO_RECORD=1 expect-fail;cb-open NOCHE_TEST_BAR_NOFOCUSLOC=1 expect-fail;cb-inline NOCHE_TEST_BAR_STALEDELETE=1 expect-fail;history-record NOCHE_TEST_TYPED_STICKY=1 expect-fail;cb-nonet NOCHE_TEST_HOST_SWAP=1 expect-fail;cb-nonet NOCHE_TEST_HOST_SWAP_UNGUARDED=1 expect-fail;cb-nonet NOCHE_TEST_REMOTE_IGNORE_OFF=1 expect-fail;cb-nonet-default NOCHE_TEST_REMOTE_IGNORE_OFF=1 expect-fail;menu-diff NOCHE_TEST_MENU_DRIFT=1 expect-fail;menu-disabled NOCHE_TEST_MENU_NODISABLE=1 expect-fail;menu-actions NOCHE_TEST_NO_DUPLICATE=1 expect-fail;menu-actions NOCHE_TEST_NO_FULLURL=1 expect-fail;shortcuts-once NOCHE_TEST_NO_CLOSEALL=1 expect-fail;shortcuts-once NOCHE_TEST_NO_SHIFTMAP=1 expect-fail;shortcuts-once NOCHE_TEST_NO_EXACTFIRST=1 expect-fail;shortcuts-once NOCHE_TEST_NO_PREEMPT=1 expect-fail;menu-diff NOCHE_TEST_MENU_SELECTOR=1 expect-fail;menu-actions NOCHE_TEST_NO_SHARE=1 expect-fail;menu-actions NOCHE_TEST_NO_DIAG=1 expect-fail;ctx-page NOCHE_TEST_CTX_NOENABLE=1 expect-fail;ctx-page NOCHE_TEST_CTX_NOCHOOSE=1 expect-fail;ctx-page NOCHE_TEST_CTX_NOEXT=1 expect-fail;ctx-page NOCHE_TEST_CTX_NOCANCEL=1 expect-fail;ctx-tab NOCHE_TEST_CTX_TABORDER=1 expect-fail;ctx-tab NOCHE_TEST_CTX_TABENABLE=1 expect-fail;ctx-sidebar NOCHE_TEST_CTX_NOREOPEN=1 expect-fail;ctx-sidebar NOCHE_TEST_CTX_CLOSEALLBLANK=1 expect-fail;find NOCHE_TEST_FIND_NOSTEP=1 expect-fail;find NOCHE_TEST_FIND_NOCLEAR=1 expect-fail;find-selection NOCHE_TEST_FIND_NOSELECT=1 expect-fail;find NOCHE_TEST_FIND_PREVFWD=1 expect-fail;find-restart NOCHE_TEST_FIND_STALE=1 expect-fail;find-nav NOCHE_TEST_FIND_NONAV=1 expect-fail;find-engine NOCHE_TEST_FIND_NOCLOSECMD=1 expect-fail;zoom-engine NOCHE_TEST_ZOOM_NOFOLLOW=1 expect-fail;find-escape NOCHE_TEST_NO_PREEMPT=1 expect-fail;find-escape NOCHE_TEST_ESC_ALWAYS=1 expect-fail;find-escape-page NOCHE_TEST_ESC_ALWAYS=1 expect-fail;find-escape-guards NOCHE_TEST_ESC_ALWAYS=1 expect-fail;find-escape-guards NOCHE_TEST_FS_CLAIM=1 expect-fail;find NOCHE_TEST_FIND_NOLEAVESTOP=1 expect-fail;find-restart NOCHE_TEST_FIND_NOFLOOR=1 expect-fail;menu-disabled NOCHE_TEST_FIND_NTENABLED=1 expect-fail;zoom NOCHE_TEST_ZOOM_NOPILL=1 expect-fail;zoom NOCHE_TEST_ZOOM_WINDOW=1 expect-fail;find NOCHE_TEST_FIND_NOREMEMBER=1 expect-fail;find NOCHE_TEST_FIND_FIXEDWIDTH=1 expect-fail;shortcuts-once NOCHE_TEST_NO_FSKEY=1 expect-fail;cb-escape NOCHE_TEST_BAR_ESCPREFILL=1 expect-fail;cb-inline NOCHE_TEST_BAR_IME=1 expect-fail;a11y-labels NOCHE_TEST_A11Y_NOADDRESS=1 expect-fail;bridge-dl NOCHE_TEST_DL_DROP=1 expect-fail;bridge-perm NOCHE_TEST_PERM_MASK=1 expect-fail;bridge-perm NOCHE_TEST_PERM_DISMISS=1 expect-fail;dl-list NOCHE_TEST_DL_NOOPEN=1 expect-fail;dl-controls NOCHE_TEST_DL_NOCANCEL=1 expect-fail;dl-tab-close NOCHE_TEST_DL_NOPROFILE=1 expect-fail;dl-tab-close NOCHE_TEST_STRAY_SERVER=1 expect-fail;dl-quit-relaunch NOCHE_TEST_DL_NOPAUSE=1 expect-fail;dl-ring NOCHE_TEST_DL_NORING=1 expect-fail;perm-prompt NOCHE_TEST_PERM_NOCARD=1 expect-fail;perm-prompt NOCHE_TEST_PERM_ALLOWDENY=1 expect-fail;perm-remember NOCHE_TEST_PERM_NOSTORE=1 expect-fail;perm-remember NOCHE_TEST_PERM_NOLOOKUP=1 expect-fail;perm-remember-relaunch NOCHE_TEST_PERM_NOLOOKUP=1 expect-fail;perm-no-bubble NOCHE_TEST_PERM_BUBBLE=1 expect-fail;perm-dismiss NOCHE_TEST_PERM_DISMISSSTORES=1 expect-fail;perm-guards NOCHE_TEST_PERM_MEDIA0=1 expect-fail;perm-guards NOCHE_TEST_PERM_NOGUARD=1 expect-fail;perm-guards NOCHE_TEST_PERM_NOCLOSE=1 expect-fail;perm-guards NOCHE_TEST_PERM_NODISMISSCB=1 expect-fail;perm-no-bubble NOCHE_TEST_PERM_BLIND=1 expect-fail;perm-forget NOCHE_TEST_PERM_KEEPEMBARGO=1 expect-fail;perm-forget NOCHE_TEST_PERM_NOPTZ=1 expect-fail;pw-on NOCHE_TEST_PW_NOSAVE=1 expect-fail;title-throttle NOCHE_TEST_NO_TITLE_THROTTLE=1 expect-fail;history-window NOCHE_TEST_HIST_NOSEARCH=1 expect-fail;history-window NOCHE_TEST_HIST_NODELETE=1 expect-fail;history-window NOCHE_TEST_HIST_NOOPEN=1 expect-fail;history-window NOCHE_TEST_HIST_OLDEST=1 expect-fail;history-window NOCHE_TEST_HIST_NOFLOAT=1 expect-fail;history-window NOCHE_TEST_HIST_NOKEY=1 expect-fail;title-flush NOCHE_TEST_NO_TITLE_FLUSH=1 expect-fail;shortcuts-once NOCHE_TEST_HIST_NOCMD=1 expect-fail;bm-add NOCHE_TEST_BM_NOADD=1 expect-fail;bm-bar NOCHE_TEST_BM_NOBAR=1 expect-fail;bm-open NOCHE_TEST_BM_FOREGROUND=1 expect-fail;bm-open NOCHE_TEST_BM_NOLOAD=1 expect-fail;bm-manager NOCHE_TEST_BM_NORENAME=1 expect-fail;bm-manager NOCHE_TEST_BM_NODELETE=1 expect-fail;bm-manager NOCHE_TEST_BM_NOOPEN=1 expect-fail;bm-manager NOCHE_TEST_BM_NOKEY=1 expect-fail;bm-manager NOCHE_TEST_BM_NOFLOAT=1 expect-fail;bm-suggest NOCHE_TEST_BM_NOSUGGEST=1 expect-fail;cb-readpath NOCHE_TEST_BM_STALECACHE=1 expect-fail;cb-readpath NOCHE_TEST_RANK_STALE=1 expect-fail;bm-all-tabs NOCHE_TEST_BM_NOSAVE=1 expect-fail;bm-open NOCHE_TEST_BM_NOSCHEME=1 expect-fail;bm-add NOCHE_TEST_BM_NOREFOCUS=1 expect-fail;bm-bar NOCHE_TEST_BM_NOBARSHIFT=1 expect-fail;history-window NOCHE_TEST_HIST_NOLIVE=1 expect-fail;history-cap NOCHE_TEST_HIST_NOFOOTER=1 expect-fail;history-cap NOCHE_TEST_HIST_NOKEEP=1 expect-fail;title-flush NOCHE_TEST_TITLE_WRONGPAGE=1 expect-fail;title-window-close NOCHE_TEST_NO_TITLE_FLUSH=1 expect-fail;window-recency NOCHE_TEST_WIN_NOREC=1 expect-fail;dl-remove-relaunch NOCHE_TEST_DL_NOREMOVE=1 expect-fail;dl-remove-relaunch NOCHE_TEST_DL_CLEARALL=1 expect-fail;dl-remove-relaunch NOCHE_TEST_DL_NOKEEP=1 expect-fail;bm-bar NOCHE_TEST_BM_NOPUSH=1 expect-fail;bm-bar NOCHE_TEST_BM_NOTOGGLE=1 expect-fail;bm-bar NOCHE_TEST_BM_NOMARK=1 expect-fail;bm-bar-relaunch NOCHE_TEST_BM_NOREAD=1 expect-fail;bm-manager NOCHE_TEST_BM_ORPHAN=1 expect-fail;bm-manager NOCHE_TEST_BM_NOUNDO=1 expect-fail;bm-manager NOCHE_TEST_BM_NOKEEPSEL=1 expect-fail;bm-manager NOCHE_TEST_BM_NOKEEPEDIT=1 expect-fail;bm-manager NOCHE_TEST_BM_NOCLEAR=1 expect-fail;bm-manager NOCHE_TEST_BM_NOEDIT=1 expect-fail;bm-manager NOCHE_TEST_BM_NOMANAGE=1 expect-fail;history-dock NOCHE_TEST_HIST_NOWAKE=1 expect-fail;dl-remove-relaunch NOCHE_TEST_DL_NOPROFILE=1 expect-fail;dl-restored-cancel-relaunch NOCHE_TEST_DL_NOCANCEL=1 expect-fail;dl-restored-cancel-relaunch NOCHE_TEST_DL_SKIPENGINE=1 expect-fail;dl-restored-silent-relaunch NOCHE_TEST_DL_NOGIVEUP=1 expect-fail;bm-manager NOCHE_TEST_BM_SHOWRELOAD=1 expect-fail;bm-manager NOCHE_TEST_BM_LOSEUNDO=1 expect-fail;dl-cancel-slow NOCHE_TEST_DL_GIVEUPLIVE=1 expect-fail;dl-cancel-slow NOCHE_TEST_DL_KEEPKEY=1 expect-fail;dl-restored-cancel-relaunch NOCHE_TEST_DL_NOKEEP=1 expect-fail;dl-restored-silent-relaunch NOCHE_TEST_DL_NOKEEP=1 expect-fail;cb-reopen NOCHE_TEST_BAR_NOKEEPKEYS=1 expect-fail;perm-origins NOCHE_TEST_PERM_EMBEDALLOW=1 expect-fail;perm-origins NOCHE_TEST_PERM_GUARDKINDS=1 expect-fail;perm-origins NOCHE_TEST_PERM_BLOCKLABEL=1 expect-fail;perm-dismiss-id NOCHE_TEST_PERM_DISMISSFIRST=1 expect-fail;perm-dismiss-id NOCHE_TEST_PERM_MEDIAID0=1 expect-fail;window-front NOCHE_TEST_NOFRONT=1 expect-fail;quit-gap-close-relaunch NOCHE_TEST_QUIT_EARLY=1 expect-fail;quit-gap-tab-relaunch NOCHE_TEST_QUIT_EARLY=1 expect-fail;bm-dupes NOCHE_TEST_BM_ONEDUP=1 expect-fail;bm-dupes NOCHE_TEST_BM_DUPTABS=1 expect-fail;bm-menu-lazy NOCHE_TEST_BM_EAGER=1 expect-fail;dl-clear-write NOCHE_TEST_DL_WRITEEACH=1 expect-fail;dl-clear-write NOCHE_TEST_DL_NOTRIM=1 expect-fail;dl-clear-write NOCHE_TEST_DL_HIDEFAIL=1 expect-fail;dl-reuse NOCHE_TEST_DL_KEEPKEY=1 expect-fail;dl-file-missing NOCHE_TEST_DL_NOFILECHECK=1 expect-fail;dl-rows NOCHE_TEST_DL_RELOADALL=1 expect-fail;dl-rows NOCHE_TEST_DL_NOCOALESCE=1 expect-fail;bm-remove-undo NOCHE_TEST_BM_NOCARDUNDO=1 expect-fail;cb-reopen-late NOCHE_TEST_BAR_NOGOTFOCUS=1 expect-fail;cb-reopen-late NOCHE_TEST_FOCUS_NOREFUSE=1 expect-fail;dl-file-stats NOCHE_TEST_DL_STATALL=1 expect-fail;sidebar-toggle NOCHE_TEST_SB_ONEFRAME=1 expect-fail;cb-reopen-reqlate NOCHE_TEST_FOCUS_ANYREPORT=1 expect-fail;bm-undo-valid NOCHE_TEST_BM_UNDOSTALE=1 expect-fail;quit-with-context-menu NOCHE_TEST_QUIT_KEEPMENU=1 expect-fail;quit-menu-late NOCHE_TEST_QUIT_NOWAIT=1 expect-fail;quit-menu-stuck NOCHE_TEST_QUIT_SILENT=1 expect-fail;devtools-quit NOCHE_TEST_DEVTOOLS_LAST=1 record;sidebar-geometry NOCHE_TEST_SB_GEOMETRY=1 expect-fail;sidebar-columns NOCHE_TEST_SB_FIXEDWIDTH=1 expect-fail;sidebar-scale NOCHE_TEST_SB_UNVIRTUAL=1 expect-fail;min-width NOCHE_TEST_MINWIDTH_OFF=1 expect-fail;min-width-relaunch NOCHE_TEST_MINWIDTH_RESTORE=1 expect-fail;pin-toggle NOCHE_TEST_PIN_NOOP=1 expect-fail;pin-dormant NOCHE_TEST_PIN_CLOSE=1 expect-fail;pin-dormant NOCHE_TEST_PIN_NOBLANK=1 expect-fail;pin-dormant NOCHE_TEST_PIN_NOSOON=1 expect-fail;pin-dormant NOCHE_TEST_PIN_NOREVIVE=1 expect-fail;pin-reset NOCHE_TEST_PIN_NORESET=1 expect-fail;pin-reset NOCHE_TEST_PIN_GLYPH=1 expect-fail;pin-launch NOCHE_TEST_PIN_ALLLIVE=1 expect-fail;pin-launch NOCHE_TEST_RESTORE_FLAT=1 expect-fail;pin-launch NOCHE_TEST_PIN_NOICON=1 expect-fail;pin-launch-held NOCHE_TEST_FALLBACK_BARE=1 expect-fail;reopen-container NOCHE_TEST_REOPEN_FLAT=1 expect-fail;pin-reveal NOCHE_TEST_SB_NOREVEAL=1 expect-fail;sidebar-geometry NOCHE_TEST_SB_BARDRAW=1 expect-fail;discard-click NOCHE_TEST_DISCARD_WAKE=1 expect-fail;discard-click NOCHE_TEST_DISCARD_NODIM=1 expect-fail;discard-policy NOCHE_TEST_DISCARD_ACTIVE=1 expect-fail;discard-policy NOCHE_TEST_DISCARD_LOADING=1 expect-fail;discard-policy NOCHE_TEST_DISCARD_MEDIA=1 expect-fail;discard-click NOCHE_TEST_DISCARD_NORESET=1 expect-fail;discard-hang NOCHE_TEST_DISCARD_NOTIMEOUT=1 expect-fail;discard-hang NOCHE_TEST_DISCARD_NOGUARD=1 expect-fail;discard-media NOCHE_TEST_DISCARD_NOSHADOW=1 expect-fail;discard-media NOCHE_TEST_DISCARD_NOSAME=1 expect-fail;discard-media NOCHE_TEST_DISCARD_NOATTACH=1 expect-fail}"
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
  PHASES=""; case "$CHECK" in *-relaunch|crash-mid-write|corrupt-store|cb-history|pin-launch|pin-launch-held) PHASES="1 2" ;; esac
  case "$CHECK" in dl-restored-cancel-relaunch|dl-restored-silent-relaunch) PHASES="1 2 3" ;; esac  # the third launch shows the removed row stays hidden
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
      # Exit code 2 is content::RESULT_CODE_HUNG: Chromium's teardown watchdog (_exit after a shutdown over 10 s, seen under heavy load). The line says so,
      # with the load and the engine's own stderr line, so a rare occurrence names its cause. rc 1 (the check's own verdict) keeps the bare line the --negative gate filters on.
      WHY=""
      if [ "$RC" = 2 ]; then WHY=" (RESULT_CODE_HUNG, engine shutdown over 10 s; load $(uptime | sed 's/.*averages*: //'); stderr: $(grep -m1 -i 'teardown watchdog' "$ERRF" || echo none))"; fi
      FAILED=1; echo "NOCHE_TEST $CHECK fail exit-rc=$RC watchdog=$WATCHDOG$WHY"
      grep '^NOCHE' "$ERRF" | head -20 || true
      echo "--- last stderr lines:"; tail -15 "$ERRF" || true
    fi
    grep '^NOCHE shutdown: ' "$ERRF" | sed "s/^/NOCHE_TEST $CHECK info stderr| /" || true
    echo "NOCHE_TEST $CHECK info frontmost samples=$SAMPLES noche-frontmost=$FRONT unknown=$UNKNOWN"
    [ "$FRONT" = 0 ] || { FAILED=1; echo "NOCHE_TEST $CHECK fail noche-was-frontmost in $FRONT of $SAMPLES samples"; }
    [ "$UNKNOWN" -lt "$SAMPLES" ] || { FAILED=1; echo "NOCHE_TEST $CHECK fail frontmost-unreadable (lsappinfo gave no pid in $SAMPLES samples)"; }
    sleep 3  # crash reports land seconds after the crash
    NEW="$(comm -13 <(printf '%s\n' "$REPORTS_BEFORE") <(crash_reports))"
    if [ -n "$NEW" ]; then FAILED=1; echo "NOCHE_TEST $CHECK fail new-crash-report: $(echo "$NEW" | tr '\n' ',')"; else echo "NOCHE_TEST $CHECK info crash reports: none new"; fi
    LEFT=""
    for _ in $(seq 1 10); do LEFT="$(helpers | tr '\n' ' ')"; [ -z "$LEFT" ] && break; sleep 0.5; done
    if [ -n "$LEFT" ]; then FAILED=1; echo "NOCHE_TEST leftover-helpers fail pids: $LEFT"; fi
    # Fixture servers the app started (it prints each PID): none may outlive the app. A stray one is reported and stopped by its one verified PID.
    for SPID in $(grep -E "^NOCHE_TEST $CHECK info slow-server-pid [0-9]+\$" "$OUTF" | awk '{print $5}'); do
      for _ in $(seq 1 20); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.1; done
      if kill -0 "$SPID" 2>/dev/null; then
        FAILED=1; echo "NOCHE_TEST $CHECK fail stray-server pid $SPID outlived the app"
        # Only the fixture server's own command line (its bytes(range(251)) pattern) is killed: a reused PID of another python3 is left alone.
        case "$(ps -p "$SPID" -o command= 2>/dev/null)" in *'bytes(range(251))'*) kill "$SPID" 2>/dev/null || true ;; esac
      fi
    done
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
