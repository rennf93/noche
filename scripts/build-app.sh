#!/usr/bin/env bash
# usage: build-app.sh [--product <SwiftPM product>] [--app-name <name>] [--release]
# NOCHE_TESTHOOKS=1 (read by Package.swift, inherited from the environment) compiles the self-test harness into the app.
# Sandbox is on by default; NOCHE_NO_SANDBOX=1 opts out. --release omits the dev-only NocheDevBuild plist key.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT=Noche
NAME=Noche
RELEASE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --product) PRODUCT="${2:?--product needs a value}"; shift 2 ;;
    --app-name) NAME="${2:?--app-name needs a value}"; shift 2 ;;
    --release) RELEASE=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

FRAMEWORK="$ROOT/vendor/cef/Release/Chromium Embedded Framework.framework"
if [ ! -d "$FRAMEWORK" ]; then
  echo "vendor/cef missing, run scripts/fetch-cef.sh" >&2
  exit 1
fi

if [ "$PRODUCT" = Noche ]; then
  ID=dev.noche.browser
else
  ID="dev.noche.spike.$(echo "$PRODUCT" | tr '[:upper:]' '[:lower:]')"
  # spike engines predate the sandbox default and run unsandboxed
  export NOCHE_SPIKES=1 NOCHE_NO_SANDBOX=1
fi
export NOCHE_APP=1
if [ "${NOCHE_NO_SANDBOX:-}" = 1 ]; then echo "sandbox: off (NOCHE_NO_SANDBOX=1)"; else echo "sandbox: on"; fi

"$ROOT/scripts/build-cef-wrapper.sh"
cd "$ROOT"
BIN="$(swift build -c release --show-bin-path)"
# SwiftPM does not track the wrapper archive, so a rebuilt wrapper needs a forced relink.
for b in "$PRODUCT" NocheHelper; do
  [ ! "$ROOT/build/cef/libcef_dll_wrapper.a" -nt "$BIN/$b" ] || rm -f "$BIN/$b"
done
swift build -c release --product "$PRODUCT"
swift build -c release --product NocheHelper

APP="$ROOT/build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$BIN/$PRODUCT" "$APP/Contents/MacOS/$NAME"
sed -e "s|@ID@|$ID|g" -e "s|@EXECUTABLE@|$NAME|g" -e "s|@NAME@|$NAME|g" \
  "$ROOT/Resources/App/Info.plist.template" > "$APP/Contents/Info.plist"
# Dev builds only: lets NCApp use a mock keychain (see MessagePump.mm). --release leaves the key out.
if [ "$RELEASE" = 1 ]; then
  /usr/libexec/PlistBuddy -c "Delete :NocheDevBuild" "$APP/Contents/Info.plist" 2>/dev/null || true
else
  PB=/usr/libexec/PlistBuddy
  $PB -c "Set :NocheDevBuild true" "$APP/Contents/Info.plist" 2>/dev/null \
    || $PB -c "Add :NocheDevBuild bool true" "$APP/Contents/Info.plist"
fi
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Chromium Embedded Framework.framework"

# helper suffix : bundle id suffix
for variant in ":" " (Alerts):.alerts" " (GPU):.gpu" " (Renderer):.renderer"; do
  suffix="${variant%%:*}"; idsuffix="${variant#*:}"
  hname="$NAME Helper$suffix"
  hdir="$APP/Contents/Frameworks/$hname.app/Contents"
  mkdir -p "$hdir/MacOS"
  cp "$BIN/NocheHelper" "$hdir/MacOS/$hname"
  sed -e "s|@ID@|$ID.helper$idsuffix|g" -e "s|@NAME@|$hname|g" \
    "$ROOT/Resources/Helper/Info.plist.template" > "$hdir/Info.plist"
done
echo "built $APP"
