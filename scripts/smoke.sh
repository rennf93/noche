#!/usr/bin/env bash
# usage: smoke.sh <app path> <url|fixture>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?usage: smoke.sh <app path> <url|fixture>}"
URL="${2:?usage: smoke.sh <app path> <url|fixture>}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

SERVER_PID=""
if [ "$URL" = fixture ]; then
  PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
  python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT/Tests/fixtures" >/dev/null 2>&1 &
  SERVER_PID=$!
  trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true' EXIT
  URL="http://127.0.0.1:$PORT/smoke.html"
  for _ in $(seq 1 50); do curl -s -o /dev/null "$URL" && break; sleep 0.1; done
fi

if [ "$URL" = closed-port ]; then
  PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  URL="http://127.0.0.1:$PORT/"
fi

TIMEOUT=30
# Outer watchdog: if the app is still alive this long after its own timeout, kill that one PID.
LIMIT=$((TIMEOUT + ${NOCHE_SMOKE_SLACK:-15}))
OUTF="$(mktemp)"
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true; rm -f "$OUTF"' EXIT
(cd / && exec "$APP/Contents/MacOS/Noche" --smoke-url "$URL" --smoke-timeout "$TIMEOUT" >"$OUTF") &
APP_PID=$!
WATCHDOG=0
for _ in $(seq 1 $((LIMIT * 10))); do
  kill -0 "$APP_PID" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$APP_PID" 2>/dev/null; then
  # only kill the PID we started, and only if it is still our binary
  if ps -p "$APP_PID" -o command= | grep -qF "$APP/Contents/MacOS/Noche"; then
    WATCHDOG=1
    kill -KILL "$APP_PID"
  fi
fi
set +e
wait "$APP_PID"
CODE=$?
set -e
if [ "$WATCHDOG" = 1 ]; then
  echo "NOCHE_SMOKE watchdog"
  exit 1
fi
grep '^NOCHE' "$OUTF" || true
exit "$CODE"
