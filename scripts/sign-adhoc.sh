#!/usr/bin/env bash
# usage: sign-adhoc.sh <app>   (ad-hoc, hardened runtime, inside-out; no notarization)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?usage: sign-adhoc.sh <app>}"
FW="$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
sign() { codesign --force --options runtime --timestamp=none -s - "$@"; }

for lib in "$FW"/Libraries/*.dylib; do sign "$lib"; done
sign "$FW"
for h in "$APP"/Contents/Frameworks/*Helper*.app; do
  sign --entitlements "$ROOT/Resources/Entitlements/helper.entitlements" "$h"
done
sign --entitlements "$ROOT/Resources/Entitlements/app.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "signed $APP"
