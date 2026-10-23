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
FW="Release/Chromium Embedded Framework.framework"
mkdir -p "$FAKE/include" "$FAKE/libcef_dll" "$FAKE/$FW"
: > "$FAKE/$FW/Chromium Embedded Framework"
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
# an existing dir that is not a distribution
mkdir "$TMP/notdist"
run env CEF_DIST="$TMP/notdist" "$FETCH"
[ "$RC" -eq 1 ] || fail "local_bad_dir: notdist exit $RC: $OUT"
[ "$OUT" = "not a CEF distribution: $TMP/notdist" ] || fail "local_bad_dir: notdist $OUT"
[ "$(snap "$NOCHE_VENDOR")" = "$S1" ] || fail "local_bad_dir: notdist vendor changed"
ok local_bad_dir

# local_thin_dir: header plus README alone must not replace a good vendor
THIN="$TMP/thin"
mkdir -p "$THIN/include"
: > "$THIN/include/cef_app.h"
printf 'CEF Version: 2.2\n' > "$THIN/README.txt"
run env CEF_DIST="$THIN" "$FETCH"
[ "$RC" -eq 1 ] || fail "local_thin_dir: exit $RC: $OUT"
[ "$OUT" = "not a CEF distribution: $THIN" ] || fail "local_thin_dir: $OUT"
[ "$(snap "$NOCHE_VENDOR")" = "$S1" ] || fail "local_thin_dir: vendor changed"
mkdir -p "$THIN/libcef_dll"
run env CEF_DIST="$THIN" "$FETCH"
[ "$RC" -eq 1 ] || fail "local_thin_dir: no framework exit $RC: $OUT"
[ "$(snap "$NOCHE_VENDOR")" = "$S1" ] || fail "local_thin_dir: no framework vendor changed"
ok local_thin_dir

# local_crlf_version: CR and tabs are not part of the version
CRLF="$TMP/crlf"
cp -R "$FAKE" "$CRLF"
printf 'CEF Version:\t3.3\r\n' > "$CRLF/README.txt"
run env CEF_DIST="$CRLF" "$FETCH"
[ "$RC" -eq 0 ] || fail "local_crlf_version: exit $RC: $OUT"
grep -qx 'cef_version=3.3' "$R" || fail "local_crlf_version: $(grep cef_version "$R" | od -c | head -3)"
ok local_crlf_version

# local_path_change: same version, other dist dir
P2="$TMP/fake2"
cp -R "$FAKE" "$P2"
printf 'CEF Version: 3.3\n' > "$P2/README.txt"
run env CEF_DIST="$P2" "$FETCH"
[ "$RC" -eq 0 ] && [ "$OUT" != "CEF already vendored" ] || fail "local_path_change: $OUT"
grep -qxF "path=$P2" "$R" || fail "local_path_change: receipt path"
ok local_path_change

# local_needs_source: matching path and version but a download receipt is not a local vendor
sed -i '' 's/^source=local$/source=download/' "$R"
run env CEF_DIST="$P2" "$FETCH"
[ "$RC" -eq 0 ] && [ "$OUT" != "CEF already vendored" ] || fail "local_needs_source: $OUT"
grep -qx 'source=local' "$R" || fail "local_needs_source: receipt"
ok local_needs_source

# switch_back: no CEF_DIST goes to the download path (stubbed with a junk archive)
printf 'junk' > "$TMP/junk.tar.bz2"
S1="$(snap "$NOCHE_VENDOR")"
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

# download_old_receipt: a pre-source receipt with the pinned sha1 still counts as vendored
OLD="$TMP/oldvendor"
mkdir -p "$OLD/cef/include"
: > "$OLD/cef/include/cef_app.h"
PIN="$(sed -n 's/^SHA1="\(.*\)"$/\1/p' "$FETCH")"
printf 'cef_version=x\nplatform=macosarm64\ndistribution=minimal\nsha1=%s\nfetched=2026-01-01T00:00:00Z\nurl=u\n' "$PIN" > "$OLD/CEF-VERSION.txt"
M1="$(stat -f %m "$OLD/CEF-VERSION.txt")"
sleep 1.1
run env NOCHE_VENDOR="$OLD" CEF_ARCHIVE="$TMP/junk.tar.bz2" "$FETCH"
[ "$RC" -eq 0 ] && [ "$OUT" = "CEF already vendored" ] || fail "download_old_receipt: $RC $OUT"
[ "$(stat -f %m "$OLD/CEF-VERSION.txt")" = "$M1" ] || fail "download_old_receipt: receipt touched"
ok download_old_receipt
