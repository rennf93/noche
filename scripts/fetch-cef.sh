#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="156.0.7+g47dbc1d+chromium-156.0.8078.17"
PLATFORM="macosarm64"
DIST="minimal"
SHA1="038a6ce70a814181f6a507d40155c81e80b328e3"
NAME="cef_binary_${VERSION}_${PLATFORM}_${DIST}"
URL="https://cef-builds.spotifycdn.com/${NAME}.tar.bz2"

# NOCHE_VENDOR is test-only: vendor into another dir so tests never touch the real vendor/.
VENDOR="${NOCHE_VENDOR:-$ROOT/vendor}"
RECEIPT="$VENDOR/CEF-VERSION.txt"

# CEF_DIST: vendor our own engine's distribution dir instead of downloading.
if [ -n "${CEF_DIST:-}" ]; then
  # Check before touching anything: a bad dir must leave the current vendor/cef alone.
  LOCAL_VERSION="$(cat "$CEF_DIST/README.txt" 2>/dev/null | tr -d '\r' | sed -n '/^CEF Version:/{s/^CEF Version:[[:space:]]*//;s/[[:space:]]*$//;p;q;}')" || true
  if [ ! -f "$CEF_DIST/include/cef_app.h" ] || [ ! -d "$CEF_DIST/libcef_dll" ] \
    || [ ! -f "$CEF_DIST/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework" ] \
    || [ -z "$LOCAL_VERSION" ]; then
    echo "not a CEF distribution: $CEF_DIST" >&2
    exit 1
  fi
  LOCAL_PATH="$(cd "$CEF_DIST" && pwd)"
  # An engine rebuild keeps the version string, so the binary itself must match too.
  FINGERPRINT="$(stat -f '%z-%m' "$LOCAL_PATH/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework")"
  if [ -f "$VENDOR/cef/include/cef_app.h" ] && [ -f "$RECEIPT" ] \
    && grep -qxF "source=local" "$RECEIPT" && grep -qxF "path=$LOCAL_PATH" "$RECEIPT" \
    && grep -qxF "cef_version=$LOCAL_VERSION" "$RECEIPT" && grep -qxF "framework=$FINGERPRINT" "$RECEIPT"; then
    echo "CEF already vendored"
    exit 0
  fi
  mkdir -p "$VENDOR"
  TMP="$(mktemp -d "$VENDOR/.fetch.XXXXXX")"
  trap 'rm -rf "$TMP"' EXIT
  # ditto keeps the framework's symlinks and signature intact.
  ditto "$LOCAL_PATH" "$TMP/cef"
  # No receipt while vendor/cef is in flux, so an interrupted run re-vendors next time.
  rm -f "$RECEIPT"
  rm -rf "$VENDOR/cef"
  mv "$TMP/cef" "$VENDOR/cef"
  # Always rewrite the receipt: the wrapper build rebuilds when it is newer than the archive.
  cat > "$RECEIPT" <<EOR
source=local
cef_version=$LOCAL_VERSION
path=$LOCAL_PATH
framework=$FINGERPRINT
fetched=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOR
  echo "CEF vendored at $VENDOR/cef"
  exit 0
fi

if [ -f "$VENDOR/cef/include/cef_app.h" ] && [ -f "$RECEIPT" ] && grep -q "^sha1=$SHA1\$" "$RECEIPT"; then
  echo "CEF already vendored"
  exit 0
fi

mkdir -p "$VENDOR"
TMP="$(mktemp -d "$VENDOR/.fetch.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# CEF_ARCHIVE is test-only: use a local file instead of downloading.
if [ -n "${CEF_ARCHIVE:-}" ]; then
  ARCHIVE="$CEF_ARCHIVE"
else
  ARCHIVE="$TMP/cef.tar.bz2"
  curl -fL --retry 3 -o "$ARCHIVE" "$URL"
fi

ACTUAL="$(shasum -a 1 "$ARCHIVE" | awk '{print $1}')"
if [ "$ACTUAL" != "$SHA1" ]; then
  # Only delete what we downloaded, never a caller-supplied file.
  [ -n "${CEF_ARCHIVE:-}" ] || rm -f "$ARCHIVE"
  echo "sha1 mismatch: expected $SHA1, got $ACTUAL" >&2
  exit 1
fi

tar -xjf "$ARCHIVE" -C "$TMP"
# No receipt while vendor/cef is in flux, so an interrupted run re-vendors next time.
rm -f "$RECEIPT"
rm -rf "$VENDOR/cef"
mv "$TMP/$NAME" "$VENDOR/cef"

cat > "$RECEIPT" <<EOR
source=download
cef_version=$VERSION
platform=$PLATFORM
distribution=$DIST
sha1=$SHA1
fetched=$(date -u +%Y-%m-%dT%H:%M:%SZ)
url=$URL
EOR
echo "CEF vendored at $VENDOR/cef"
