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
# root_internal: an existing dir on the internal disk is refused, with no logs dir created
for cmd in checkout patch build distrib; do
  run env NOCHE_ENGINE_ROOT="$TMP/root" "$BUILD" "$cmd"
  [ "$RC" -eq 1 ] || fail "root_internal $cmd: exit $RC: $OUT"
  [ "$OUT" = "engine root is on the internal disk: $TMP/root" ] || fail "root_internal $cmd: $OUT"
  [ ! -e "$TMP/root/logs" ] || fail "root_internal $cmd: logs dir created"
done
ok root_internal

# NOCHE_ENGINE_ALLOW_INTERNAL is test-only: the fixtures live in a temp dir on the internal disk.
export NOCHE_ENGINE_ALLOW_INTERNAL=1

# min_free_invalid: bad input must not switch the guard off
for v in abc -1 1.5; do
  for cmd in checkout build; do
    run env NOCHE_ENGINE_ROOT="$ROOT" NOCHE_ENGINE_MIN_FREE_GB="$v" "$BUILD" "$cmd"
    [ "$RC" -eq 2 ] || fail "min_free_invalid $v $cmd: exit $RC: $OUT"
    [ "$OUT" = "NOCHE_ENGINE_MIN_FREE_GB must be a whole number of GiB" ] || fail "min_free_invalid $v $cmd: $OUT"
  done
done
run env NOCHE_ENGINE_ROOT="$ROOT" NOCHE_ENGINE_MIN_FREE_GB=100000 "$BUILD" checkout
[ "$RC" -eq 1 ] || fail "low_disk checkout: exit $RC"
ok min_free_invalid

run env NOCHE_ENGINE_ROOT="$ROOT" NOCHE_ENGINE_MIN_FREE_GB=100000 "$BUILD" build
[ "$RC" -eq 1 ] || fail "low_disk: exit $RC"
case "$OUT" in "need 100000 GiB free, have "*) ;; *) fail "low_disk: $OUT" ;; esac
[ -z "$(ls -A "$ROOT")" ] || fail "low_disk: root not empty: $(ls -A "$ROOT")"
ok low_disk

# metal_missing: a build without Xcode's Metal toolchain stops before any log
mkdir -p "$TMP/stubbin" && printf '#!/bin/sh\nexit 1\n' > "$TMP/stubbin/xcrun" && chmod +x "$TMP/stubbin/xcrun"
run env PATH="$TMP/stubbin:$PATH" NOCHE_ENGINE_ROOT="$ROOT" NOCHE_ENGINE_MIN_FREE_GB=0 "$BUILD" build
[ "$RC" -eq 1 ] || fail "metal_missing: exit $RC: $OUT"
[ "$OUT" = "Metal toolchain missing: run xcodebuild -downloadComponent MetalToolchain" ] || fail "metal_missing: $OUT"
[ -z "$(ls -A "$ROOT")" ] || fail "metal_missing: root not empty: $(ls -A "$ROOT")"
ok metal_missing

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

# patch_after_interrupt: a stray rebase-apply dir must not fail the run
mkdir "$CEF/.git/rebase-apply"
export NOCHE_ENGINE_PATCH_DIR="$TMP/good"
run "$BUILD" patch
[ "$RC" -eq 0 ] || fail "patch_after_interrupt: exit $RC: $OUT"
[ "$(git -C "$CEF" rev-parse HEAD)" = "$H1" ] || fail "patch_after_interrupt: HEAD differs"
ok patch_after_interrupt

# distrib_incomplete: a stub make_distrib that writes an empty distribution
mkdir -p "$TMP/stubcef/tools"
printf 'import os,sys\nd=[a for a in sys.argv if a.startswith("--output-dir=")][0].split("=",1)[1]\nos.makedirs(d+"/cef_binary_1_macosarm64_minimal")\n' > "$TMP/stubcef/tools/make_distrib.py"
run env NOCHE_ENGINE_ROOT="$ROOT" NOCHE_ENGINE_CEF_DIR="$TMP/stubcef" "$BUILD" distrib
[ "$RC" -eq 1 ] || fail "distrib_incomplete: exit $RC: $OUT"
case "$OUT" in *"distrib incomplete: $ROOT/distrib/cef_binary_1_macosarm64_minimal"*) ;; *) fail "distrib_incomplete: $OUT" ;; esac
ok distrib_incomplete

# distrib_ok: a complete distribution written before the run ends (output continues after) passes
mkdir -p "$TMP/okcef/tools"
cat > "$TMP/okcef/tools/make_distrib.py" <<'PY'
import os, sys, time
d = [a for a in sys.argv if a.startswith("--output-dir=")][0].split("=", 1)[1]
f = d + "/cef_binary_1_macosarm64_minimal/Release/Chromium Embedded Framework.framework"
os.makedirs(f)
open(f + "/Chromium Embedded Framework", "w").write("x")
time.sleep(1)
print("done")
PY
rm -rf "$ROOT/distrib"
run env NOCHE_ENGINE_ROOT="$ROOT" NOCHE_ENGINE_CEF_DIR="$TMP/okcef" "$BUILD" distrib
[ "$RC" -eq 0 ] || fail "distrib_ok: exit $RC: $OUT"
ok distrib_ok

# distrib_stale: a complete distribution from an earlier run must not pass for a run that wrote nothing
rm -rf "$ROOT/distrib" && mkdir -p "$ROOT/distrib/cef_binary_0_macosarm64_minimal/Release/Chromium Embedded Framework.framework"
touch "$ROOT/distrib/cef_binary_0_macosarm64_minimal/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework"
touch -t 200001010000 "$ROOT/distrib/cef_binary_0_macosarm64_minimal"
printf 'pass\n' > "$TMP/stubcef/tools/make_distrib.py"
run env NOCHE_ENGINE_ROOT="$ROOT" NOCHE_ENGINE_CEF_DIR="$TMP/stubcef" "$BUILD" distrib
[ "$RC" -eq 1 ] || fail "distrib_stale: exit $RC: $OUT"
case "$OUT" in *"distrib incomplete: $ROOT/distrib"*) ;; *) fail "distrib_stale: $OUT" ;; esac
ok distrib_stale

# usage
unset NOCHE_ENGINE_ROOT
for args in "" "bogus"; do
  # shellcheck disable=SC2086
  run "$BUILD" $args
  [ "$RC" -eq 2 ] || fail "usage '$args': exit $RC"
  [ "$OUT" = "usage: engine/build.sh checkout|patch|build|distrib" ] || fail "usage '$args': $OUT"
done
ok usage
