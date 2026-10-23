#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/build.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL $1" >&2; exit 1; }
ok() { echo "ok $1"; }

# run <args...>: sets OUT and RC without tripping set -e
run() { set +e; OUT="$("$@" 2>&1)"; RC=$?; set -e; }

# root_missing
for cmd in checkout patch build distrib; do
  run env NOCHE_ENGINE_ROOT=/Volumes/NoSuchVolume/x "$BUILD" "$cmd"
  [ "$RC" -eq 1 ] || fail "root_missing $cmd: exit $RC"
  [ "$OUT" = "engine root missing: /Volumes/NoSuchVolume/x" ] || fail "root_missing $cmd: $OUT"
done
ok root_missing

# low_disk: nothing may be created under the root
ROOT="$TMP/root"
mkdir -p "$ROOT"
run env NOCHE_ENGINE_ROOT="$ROOT" NOCHE_ENGINE_MIN_FREE_GB=100000 "$BUILD" build
[ "$RC" -eq 1 ] || fail "low_disk: exit $RC"
case "$OUT" in "need 100000 GiB free, have "*) ;; *) fail "low_disk: $OUT" ;; esac
[ -z "$(ls -A "$ROOT")" ] || fail "low_disk: root not empty: $(ls -A "$ROOT")"
ok low_disk

# throwaway CEF repo with one base commit
CEF="$TMP/cef"
git init -q "$CEF"
G=(git -C "$CEF" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t.invalid -c commit.gpgsign=false)
printf 'one\n' > "$CEF/a.txt"
"${G[@]}" add a.txt
"${G[@]}" commit -q -m base
BASE="$(git -C "$CEF" rev-parse HEAD)"
printf 'one\ntwo\n' > "$CEF/a.txt"
"${G[@]}" commit -q -am change
mkdir "$TMP/good"
"${G[@]}" format-patch -q -1 -o "$TMP/good"
git -C "$CEF" checkout -q --detach "$BASE"

# the real engine/patches is not touched: tests point at their own series
export NOCHE_ENGINE_ROOT="$ROOT" NOCHE_ENGINE_CEF_DIR="$CEF" NOCHE_ENGINE_CEF_PIN="$BASE"

# patch_idempotent
export NOCHE_ENGINE_PATCH_DIR="$TMP/good"
run "$BUILD" patch
[ "$RC" -eq 0 ] || fail "patch_idempotent: first run exit $RC: $OUT"
H1="$(git -C "$CEF" rev-parse HEAD)"
D1="$(git -C "$CEF" diff "$BASE")"
run "$BUILD" patch
[ "$RC" -eq 0 ] || fail "patch_idempotent: second run exit $RC: $OUT"
[ "$H1" != "$BASE" ] || fail "patch_idempotent: patch not applied"
[ "$(git -C "$CEF" rev-parse HEAD)" = "$H1" ] || fail "patch_idempotent: HEAD moved"
[ "$(git -C "$CEF" diff "$BASE")" = "$D1" ] || fail "patch_idempotent: diff changed"
grep -q two "$CEF/a.txt" || fail "patch_idempotent: content"
ok patch_idempotent

# patch_fails_loud: second patch conflicts with the first
mkdir "$TMP/bad"
cp "$TMP/good/"*.patch "$TMP/bad/0001-good.patch"
sed 's/^+two$/+three/; s/^ one$/ uno/; s/^-one$/-uno/' "$TMP/good/"*.patch > "$TMP/bad/0002-bad.patch"
export NOCHE_ENGINE_PATCH_DIR="$TMP/bad"
run "$BUILD" patch
[ "$RC" -eq 1 ] || fail "patch_fails_loud: exit $RC: $OUT"
case "$OUT" in *"patch failed: 0002-bad.patch"*) ;; *) fail "patch_fails_loud: $OUT" ;; esac
[ "$(git -C "$CEF" rev-parse HEAD)" = "$BASE" ] || fail "patch_fails_loud: not on base"
[ -z "$(git -C "$CEF" status --porcelain)" ] || fail "patch_fails_loud: dirty tree"
[ ! -d "$CEF/.git/rebase-apply" ] || fail "patch_fails_loud: am left running"
ok patch_fails_loud

# distrib_incomplete: a stub make_distrib that writes an empty distribution
mkdir -p "$TMP/stubcef/tools"
printf 'import os,sys\nd=[a for a in sys.argv if a.startswith("--output-dir=")][0].split("=",1)[1]\nos.makedirs(d+"/cef_binary_1_macosarm64_minimal")\n' > "$TMP/stubcef/tools/make_distrib.py"
run env NOCHE_ENGINE_ROOT="$ROOT" NOCHE_ENGINE_CEF_DIR="$TMP/stubcef" "$BUILD" distrib
[ "$RC" -eq 1 ] || fail "distrib_incomplete: exit $RC: $OUT"
case "$OUT" in *"distrib incomplete: $ROOT/distrib/cef_binary_1_macosarm64_minimal"*) ;; *) fail "distrib_incomplete: $OUT" ;; esac
ok distrib_incomplete

# usage
unset NOCHE_ENGINE_ROOT
for args in "" "bogus"; do
  # shellcheck disable=SC2086
  run "$BUILD" $args
  [ "$RC" -eq 2 ] || fail "usage '$args': exit $RC"
  [ "$OUT" = "usage: engine/build.sh checkout|patch|build|distrib" ] || fail "usage '$args': $OUT"
done
ok usage
