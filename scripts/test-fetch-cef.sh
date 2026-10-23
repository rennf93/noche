#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH="$HERE/fetch-cef.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL $1" >&2; exit 1; }
ok() { echo "ok $1"; }
run() { set +e; OUT="$("$@" 2>&1)"; RC=$?; set -e; }
# snapshot <dir>: names, sizes and contents, to prove a tree is byte-identical
snap() { (cd "$1" && find . -type f -o -type l | sort | xargs -I{} cksum "{}" 2>/dev/null; find . | sort); }

# every test runs against a temp vendor dir, never the real vendor/
export NOCHE_VENDOR="$TMP/vendor"
FAKE="$TMP/fake"
mkdir -p "$FAKE/include" "$FAKE/Release"
: > "$FAKE/include/cef_app.h"
printf 'Chromium Embedded Framework (CEF) Standard Distribution\n\nCEF Version:      9.9.9+gabc+chromium-9.9.9.9\n' > "$FAKE/README.txt"

# local_vendors
run env CEF_DIST="$FAKE" "$FETCH"
[ "$RC" -eq 0 ] || fail "local_vendors: exit $RC: $OUT"
[ -f "$NOCHE_VENDOR/cef/include/cef_app.h" ] || fail "local_vendors: header missing"
R="$NOCHE_VENDOR/CEF-VERSION.txt"
grep -q '^source=local$' "$R" || fail "local_vendors: source"
grep -q '^cef_version=9.9.9+gabc+chromium-9.9.9.9$' "$R" || fail "local_vendors: version"
grep -q "^path=$FAKE\$" "$R" || fail "local_vendors: path"
grep -q '^fetched=' "$R" || fail "local_vendors: fetched"
ok local_vendors

# local_skip: the receipt mtime drives the wrapper rebuild, so a skip must not touch it
M1="$(stat -f %m "$R")"
sleep 1.1
run env CEF_DIST="$FAKE" "$FETCH"
[ "$RC" -eq 0 ] || fail "local_skip: exit $RC: $OUT"
[ "$OUT" = "CEF already vendored" ] || fail "local_skip: $OUT"
[ "$(stat -f %m "$R")" = "$M1" ] || fail "local_skip: receipt touched"
# a different version re-vendors and rewrites the receipt
sed -i '' 's/9\.9\.9\.9/8.8.8.8/' "$FAKE/README.txt"
run env CEF_DIST="$FAKE" "$FETCH"
[ "$RC" -eq 0 ] && [ "$OUT" != "CEF already vendored" ] || fail "local_skip: version change skipped: $OUT"
grep -q 'chromium-8.8.8.8$' "$R" || fail "local_skip: receipt not rewritten"
ok local_skip

# local_bad_dir
S1="$(snap "$NOCHE_VENDOR")"
run env CEF_DIST=/nonexistent "$FETCH"
[ "$RC" -eq 1 ] || fail "local_bad_dir: exit $RC: $OUT"
[ "$OUT" = "not a CEF distribution: /nonexistent" ] || fail "local_bad_dir: $OUT"
[ "$(snap "$NOCHE_VENDOR")" = "$S1" ] || fail "local_bad_dir: vendor changed"
ok local_bad_dir

# switch_back: no CEF_DIST goes to the download path (stubbed with a junk archive)
printf 'junk' > "$TMP/junk.tar.bz2"
run env CEF_ARCHIVE="$TMP/junk.tar.bz2" "$FETCH"
[ "$RC" -eq 1 ] || fail "switch_back: exit $RC: $OUT"
case "$OUT" in "sha1 mismatch"*) ;; *) fail "switch_back: $OUT" ;; esac
[ "$(snap "$NOCHE_VENDOR")" = "$S1" ] || fail "switch_back: vendor changed"
ok switch_back

# download_mismatch: fresh vendor dir, the existing download-path check
rm -rf "$NOCHE_VENDOR"
run env CEF_ARCHIVE="$TMP/junk.tar.bz2" "$FETCH"
[ "$RC" -eq 1 ] || fail "download_mismatch: exit $RC"
case "$OUT" in "sha1 mismatch"*) ;; *) fail "download_mismatch: $OUT" ;; esac
ok download_mismatch
