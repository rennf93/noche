#!/usr/bin/env bash
# usage: build-app.sh [--product <SwiftPM product>] [--app-name <name>]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT=Noche
NAME=Noche
while [ $# -gt 0 ]; do
  case "$1" in
    --product) PRODUCT="${2:?--product needs a value}"; shift 2 ;;
    --app-name) NAME="${2:?--app-name needs a value}"; shift 2 ;;
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
fi

"$ROOT/scripts/build-cef-wrapper.sh"
cd "$ROOT"
swift build -c release --product "$PRODUCT"
swift build -c release --product NocheHelper
BIN="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$BIN/$PRODUCT" "$APP/Contents/MacOS/$NAME"
sed -e "s|@ID@|$ID|g" -e "s|@EXECUTABLE@|$NAME|g" -e "s|@NAME@|$NAME|g" \
  "$ROOT/Resources/App/Info.plist.template" > "$APP/Contents/Info.plist"
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
