#!/usr/bin/env bash
# usage: check-sandbox.sh <app path>
# Launches the app on a page that never finishes loading and asserts that one of its own renderer children runs with
# --seatbelt-client (the CEF sandbox). The renderer is found by parent PID, never by name.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?usage: check-sandbox.sh <app path>}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

# A listener that accepts and never answers keeps the page loading, so the app (and its renderer) stays up.
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -c 'import socket,sys,time
s=socket.socket(); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(8)
c=[]
while True:
    c.append(s.accept()[0]); time.sleep(0.01)' "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!
APP_PID=""
cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then kill "$APP_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT
sleep 0.5

(cd / && exec "$APP/Contents/MacOS/Noche" --smoke-url "http://127.0.0.1:$PORT/" --smoke-timeout 30 >/dev/null 2>&1) &
APP_PID=$!

FOUND=""
for _ in $(seq 1 400); do
  kill -0 "$APP_PID" 2>/dev/null || break
  PS_OUT="$(ps -axo ppid=,command=)"
  FOUND="$(printf '%s\n' "$PS_OUT" | awk -v p="$APP_PID" '$1 == p && /--type=renderer/ && /--seatbelt-client/ { print; exit }')"
  [ -n "$FOUND" ] && break
  sleep 0.05
done

if [ -z "$FOUND" ]; then
  echo "sandbox check FAILED: no renderer child of $APP_PID with --seatbelt-client" >&2
  exit 1
fi
echo "sandbox check ok: $(printf '%s' "$FOUND" | grep -o -e '--seatbelt-client=[0-9]*' | head -1)"
