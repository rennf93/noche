#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CEF="$ROOT/vendor/cef"
OUT="$ROOT/build/cef"
LIB="$OUT/libcef_dll_wrapper.a"

if [ ! -d "$CEF/include" ]; then
  echo "vendor/cef missing, run scripts/fetch-cef.sh" >&2
  exit 1
fi

if [ -f "$LIB" ] && [ "$LIB" -nt "$ROOT/vendor/CEF-VERSION.txt" ]; then
  echo "wrapper up to date"
  exit 0
fi

rm -rf "$OUT/obj"
mkdir -p "$OUT/obj"

export CEF_FLAGS="-std=c++20 -fno-exceptions -fno-rtti -fno-threadsafe-statics -fno-strict-aliasing -fvisibility=hidden -fvisibility-inlines-hidden -fobjc-call-cxx-cdtors -fstack-protector -funwind-tables -arch arm64 -mmacosx-version-min=14.0 -I $CEF -DWRAPPING_CEF_SHARED -O2 -DNDEBUG -w"

# Object names embed the relative path so same-named files in different dirs cannot collide.
# shortcut: paths with spaces break CEF_FLAGS word splitting, fine for this repo location.
find "$CEF/libcef_dll" \( -name '*.cc' -o -name '*.mm' \) -print0 |
  xargs -0 -P "$(sysctl -n hw.ncpu)" -I{} bash -c '
    src="$1"; rel="${src#"$2/libcef_dll/"}"; obj="$3/obj/$(echo "${rel%.*}" | tr / _).o"
    lang=""; [ "${src##*.}" = mm ] && lang="-x objective-c++"
    clang++ $CEF_FLAGS $lang -c "$src" -o "$obj"' _ {} "$CEF" "$OUT"

libtool -static -o "$LIB" "$OUT"/obj/*.o
echo "built $LIB"
