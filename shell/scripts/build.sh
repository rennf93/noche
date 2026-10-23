#!/usr/bin/env bash
# build.sh: compile the Noche shell into shell/build/Noche.app and bundle the
# phase-1 extension (../.output/chrome-mv3) into it as the default brain.
#
# Usage:
#   scripts/build.sh            build (rebuilds the extension first if missing)
#
# Two modes, chosen by what is vendored:
#   CEF mode  - shell/deps/ contains a fetched CEF distribution (run
#               scripts/fetch-cef.sh). Builds the libcef_dll wrapper, the
#               ObjC++ shim, the helper subprocess executable, links the main
#               binary, and assembles the full app bundle: CEF framework in
#               Contents/Frameworks (versioned layout) plus "Noche Helper.app".
#   Stub mode - no deps/. Swift target builds against cef_bridge_stub.mm; the
#               app runs with the placeholder browser region.
set -euo pipefail

SHELL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "${SHELL_DIR}/.." && pwd)"
APP_DIR="${SHELL_DIR}/build/Noche.app"
CONTENTS="${APP_DIR}/Contents"
BUILD_DIR="${SHELL_DIR}/build"
EXT_SRC="${ROOT_DIR}/.output/chrome-mv3"
MACOS_TARGET="arm64-apple-macos13.0"
APP_BUNDLE_ID="dev.noche.shell"
HELPER_NAME="Noche Helper"

# 1. The extension is the brain this shell bundles. Build it if it is missing.
if [[ ! -f "${EXT_SRC}/manifest.json" ]]; then
  echo "Extension build missing at ${EXT_SRC}, running 'npm run build' ..."
  (cd "${ROOT_DIR}" && npm run build)
fi
if [[ ! -f "${EXT_SRC}/manifest.json" ]]; then
  echo "FATAL: no extension at ${EXT_SRC} after build." >&2
  echo "Resume with: cd ${ROOT_DIR} && npm run build" >&2
  exit 1
fi

# 2. Mode detection: a vendored CEF distribution (fetch-cef.sh output).
CEF_ROOT="$(find "${SHELL_DIR}/deps" -maxdepth 1 -type d -name 'cef_binary_*' 2>/dev/null | head -1 || true)"
CEF_FRAMEWORK_SRC="${CEF_ROOT}/Release/Chromium Embedded Framework.framework"
if [[ -n "${CEF_ROOT}" && -d "${CEF_FRAMEWORK_SRC}" ]]; then
  CEF_MODE=1
else
  CEF_MODE=0
fi

rm -rf "${APP_DIR}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources" "${BUILD_DIR}/cef-build"

# 3. CEF native build: wrapper static lib, shim, helper executable.
SHIM_OBJ=""
WRAPPER_A=""
HELPER_BIN=""

if [[ "${CEF_MODE}" -eq 1 ]]; then
  echo "CEF mode (distribution at ${CEF_ROOT})"
  OBJ_DIR="${BUILD_DIR}/cef-build/obj"
  WRAPPER_A="${BUILD_DIR}/cef-build/libcef_dll_wrapper.a"
  BRIDGE_OBJ="${BUILD_DIR}/cef-build/cef_bridge.o"
  HELPER_BIN="${BUILD_DIR}/cef-build/${HELPER_NAME}"

  # Compile flags mirror the distribution's cmake/cef_variables.cmake (macOS
  # block): C++20, no exceptions, no rtti, hidden visibility. -w drops the
  # -Wall/-Wextra noise; there is no -Werror here.
  CXX_FLAGS=(
    -std=c++20 -fno-exceptions -fno-rtti -fno-threadsafe-statics
    -fno-strict-aliasing -fvisibility=hidden -fvisibility-inlines-hidden
    -fobjc-call-cxx-cdtors -fstack-protector -funwind-tables -DNDEBUG -w
    -O2 -arch arm64 -mmacosx-version-min=13.0
    -I"${CEF_ROOT}"
  )
  # Wrapper sources require WRAPPING_CEF_SHARED (checked by every
  # libcef_dll/{ctocpp,cpptoc} header); shim/object files do not.
  WRAPPER_ONLY=(-DWRAPPING_CEF_SHARED)
  # ObjC++ files additionally use ARC (the shim and loader interop with NSView).
  MM_EXTRA=(-fobjc-arc)

  mkdir -p "${OBJ_DIR}"

  # 3a. libcef_dll wrapper static library. Cached: delete shell/build/ to
  #     force a rebuild (e.g. after a CEF re-pin).
  if [[ ! -f "${WRAPPER_A}" ]]; then
    echo "Compiling libcef_dll wrapper (cached until shell/build is wiped) ..."
    (
      cd "${OBJ_DIR}"
      find "${CEF_ROOT}/libcef_dll" \( -name '*.cc' -o -name '*.mm' \) -print0 \
        | xargs -0 -n 16 -P "$(sysctl -n hw.ncpu)" \
            clang++ "${CXX_FLAGS[@]}" "${WRAPPER_ONLY[@]}" -c
      libtool -static -o "${WRAPPER_A}" ./*.o
    )
    echo "  wrapper: ${WRAPPER_A}"
  fi

  # 3b. The ObjC++ shim (real CEF implementation).
  clang++ -ObjC++ "${CXX_FLAGS[@]}" "${MM_EXTRA[@]}" -c \
    "${SHELL_DIR}/Sources/shim/cef_bridge.mm" -o "${BRIDGE_OBJ}"
  SHIM_OBJ="${BRIDGE_OBJ}"

  # 3c. Helper subprocess executable (see Sources/shim/helper_main.mm).
  echo "Compiling helper subprocess executable (${HELPER_NAME}) ..."
  clang++ -ObjC++ "${CXX_FLAGS[@]}" "${MM_EXTRA[@]}" \
    "${SHELL_DIR}/Sources/shim/helper_main.mm" \
    "${WRAPPER_A}" \
    -framework AppKit -framework Cocoa -framework Foundation \
    -framework IOSurface \
    -o "${HELPER_BIN}"
else
  echo "Stub mode (no CEF distribution in shell/deps; run scripts/fetch-cef.sh for the real browser)"
  BRIDGE_OBJ="${BUILD_DIR}/cef-build/cef_bridge_stub.o"
  clang++ -ObjC++ -std=c++20 -arch arm64 -mmacosx-version-min=13.0 -fobjc-arc -w \
    -c "${SHELL_DIR}/Sources/shim/cef_bridge_stub.mm" -o "${BRIDGE_OBJ}"
  SHIM_OBJ="${BRIDGE_OBJ}"
fi

# 4. Compile the Swift target with the shim's C header as the bridge header.
echo "Compiling Swift sources (${MACOS_TARGET}) ..."
SWIFT_LINK=()
if [[ "${CEF_MODE}" -eq 1 ]]; then
  # The wrapper static lib is C++; swiftc must link libc++ for it.
  SWIFT_LINK=("${SHIM_OBJ}" "${WRAPPER_A}" -lc++ -framework IOSurface)
fi
swiftc \
  -O \
  -target "${MACOS_TARGET}" \
  -import-objc-header "${SHELL_DIR}/Sources/shim/cef_bridge.h" \
  "${SHELL_DIR}"/Sources/*.swift \
  "${SWIFT_LINK[@]}" \
  -o "${CONTENTS}/MacOS/Noche"

# 5. App bundle skeleton files.
cp "${SHELL_DIR}/Info.plist" "${CONTENTS}/Info.plist"
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# 6. Bundle the extension as the default brain.
echo "Bundling extension brain from .output/chrome-mv3 ..."
ditto "${EXT_SRC}" "${CONTENTS}/Resources/NocheExtension/chrome-mv3"

# 7. Local fixture page used by the smoke run (see README).
cat > "${CONTENTS}/Resources/fixture.html" <<'EOF'
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>Noche CEF smoke fixture</title></head>
<body>
  <h1>Noche CEF smoke fixture</h1>
  <p>If you can read this, the CEF browser rendered a real page.</p>
</body>
</html>
EOF

# 8. Bundle the CEF receipt when the distribution is vendored.
if [[ -f "${SHELL_DIR}/deps/CEF-VERSION.txt" ]]; then
  cp "${SHELL_DIR}/deps/CEF-VERSION.txt" "${CONTENTS}/Resources/CEF-VERSION.txt"
fi

# 9. CEF mode: assemble the framework (versioned layout per the distribution's
#    cmake/cef_macros.cmake COPY_MAC_FRAMEWORK) and the helper app bundles.
write_helper_plist() {
  # $1 = executable/bundle display name, $2 = bundle-id suffix.
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$1</string>
	<key>CFBundleIdentifier</key>
	<string>${APP_BUNDLE_ID}.helper$2</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$1</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF
}

make_helper_app() {
  # $1 = bundle directory, $2 = executable name, $3 = bundle-id suffix.
  local app_dir="$1" exe_name="$2" id_suffix="$3"
  mkdir -p "${app_dir}/Contents/MacOS"
  cp "${HELPER_BIN}" "${app_dir}/Contents/MacOS/${exe_name}"
  printf 'APPL????' > "${app_dir}/Contents/PkgInfo"
  write_helper_plist "${exe_name}" "${id_suffix}" > "${app_dir}/Contents/Info.plist"
}

if [[ "${CEF_MODE}" -eq 1 ]]; then
  FRAMEWORK_DIR="${CONTENTS}/Frameworks/Chromium Embedded Framework.framework"
  mkdir -p "${FRAMEWORK_DIR}/Versions/A"
  echo "Bundling CEF framework (versioned layout) ..."
  cp -R "${CEF_FRAMEWORK_SRC}/" "${FRAMEWORK_DIR}/Versions/A/"
  ln -sfn "Versions/A/Chromium Embedded Framework" "${FRAMEWORK_DIR}/Chromium Embedded Framework"
  ln -sfn "Versions/A/Libraries" "${FRAMEWORK_DIR}/Libraries"
  ln -sfn "Versions/A/Resources" "${FRAMEWORK_DIR}/Resources"
  ln -sfn "A" "${FRAMEWORK_DIR}/Versions/Current"

  # Per-type helper bundles. libcef composes "<exe> Helper[( TYPE)].app" per
  # subprocess kind (observed at runtime: base + (Alerts); the binary also
  # carries (GPU) and (Renderer) suffix strings). All bundles run the same
  # helper binary; the process type arrives on the command line.
  make_helper_app "${CONTENTS}/Frameworks/${HELPER_NAME}.app" "${HELPER_NAME}" ""
  make_helper_app "${CONTENTS}/Frameworks/${HELPER_NAME} (Alerts).app" "${HELPER_NAME} (Alerts)" ".alerts"
  make_helper_app "${CONTENTS}/Frameworks/${HELPER_NAME} (GPU).app" "${HELPER_NAME} (GPU)" ".gpu"
  make_helper_app "${CONTENTS}/Frameworks/${HELPER_NAME} (Renderer).app" "${HELPER_NAME} (Renderer)" ".renderer"
fi

# 10. Ad-hoc sign, inside-out: framework Libraries dylibs, framework, helper
#     app, then the outer app. Real identity signing and notarization are
#     documented in README.md.
sign() { codesign --force --sign - "$@" >/dev/null; echo "  signed: $1"; }
if [[ "${CEF_MODE}" -eq 1 ]]; then
  for dylib in "${CONTENTS}/Frameworks/Chromium Embedded Framework.framework/Versions/A/Libraries/"*.dylib; do
    sign "${dylib}"
  done
  sign "${CONTENTS}/Frameworks/Chromium Embedded Framework.framework"
  sign "${CONTENTS}/Frameworks/${HELPER_NAME}.app"
  sign "${CONTENTS}/Frameworks/${HELPER_NAME} (Alerts).app"
  sign "${CONTENTS}/Frameworks/${HELPER_NAME} (GPU).app"
  sign "${CONTENTS}/Frameworks/${HELPER_NAME} (Renderer).app"
fi
sign "${APP_DIR}"

echo
echo "Built ${APP_DIR}"
du -sh "${APP_DIR}" | awk '{print "  size: " $1}'
echo "Run it:      open ${APP_DIR}"
echo "Run in CLI:  ${CONTENTS}/MacOS/Noche"
