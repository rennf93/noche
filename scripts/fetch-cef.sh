#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="156.0.7+g47dbc1d+chromium-156.0.8078.17"
PLATFORM="macosarm64"
DIST="minimal"
SHA1="038a6ce70a814181f6a507d40155c81e80b328e3"
NAME="cef_binary_${VERSION}_${PLATFORM}_${DIST}"
URL="https://cef-builds.spotifycdn.com/${NAME}.tar.bz2"

VENDOR="$ROOT/vendor"
RECEIPT="$VENDOR/CEF-VERSION.txt"

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
rm -rf "$VENDOR/cef"
mv "$TMP/$NAME" "$VENDOR/cef"

cat > "$RECEIPT" <<EOR
cef_version=$VERSION
platform=$PLATFORM
distribution=$DIST
sha1=$SHA1
fetched=$(date -u +%Y-%m-%dT%H:%M:%SZ)
url=$URL
EOR
echo "CEF vendored at $VENDOR/cef"
