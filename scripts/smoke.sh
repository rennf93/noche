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

set +e
OUT="$(cd / && "$APP/Contents/MacOS/Noche" --smoke-url "$URL" --smoke-timeout 30)"
CODE=$?
set -e
printf '%s\n' "$OUT" | grep '^NOCHE' || true
exit "$CODE"
