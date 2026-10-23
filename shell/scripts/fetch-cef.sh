#!/usr/bin/env bash
# fetch-cef.sh: download the CEF macOS arm64 binary distribution into shell/deps/.
#
# Usage:
#   scripts/fetch-cef.sh              download the pinned default version
#   CEF_VERSION=<v> scripts/fetch-cef.sh
#                                     download a specific version, e.g. during a
#                                     rebase drill (see README.md)
#   CEF_CHANNEL=latest scripts/fetch-cef.sh
#                                     resolve the newest stable from the builds
#                                     index instead of using the pin
#
# The download lands in shell/deps/ (gitignored). A CEF-VERSION.txt receipt
# records what was fetched and its sha1 so CI and the rebase drill can diff.
set -euo pipefail

SHELL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS_DIR="${SHELL_DIR}/deps"
INDEX_URL="https://cef-builds.spotifycdn.com/index.json"
ARTIFACT_BASE="https://cef-builds.spotifycdn.com"

# Pinned default: latest stable macosarm64 at the time this pin was written
# (resolved from the builds index on 2026-10-23). Re-pin deliberately, never
# silently: a version bump is a rebase drill, see README.md.
DEFAULT_VERSION="156.0.7+g47dbc1d+chromium-156.0.8078.17"
DEFAULT_SHA1="038a6ce70a814181f6a507d40155c81e80b328e3"
DEFAULT_SIZE="134827440"

mkdir -p "${DEPS_DIR}"

version="${DEFAULT_VERSION}"
sha1="${DEFAULT_SHA1}"
size="${DEFAULT_SIZE}"

if [[ "${CEF_CHANNEL:-}" == "latest" || "${CEF_VERSION:-}" == "latest" ]]; then
  echo "Resolving latest stable macosarm64 from ${INDEX_URL} ..."
  index="$(mktemp)"
  curl -fsSL --retry 3 -o "${index}" "${INDEX_URL}"
  resolved="$(python3 - "${index}" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for v in data["macosarm64"]["versions"]:
    if v.get("channel") != "stable":
        continue
    for f_ in v["files"]:
        if f_["type"] == "minimal":
            print(v["cef_version"])
            print(f_["sha1"])
            print(f_["size"])
            sys.exit(0)
sys.exit(1)
PY
)"
  version="$(sed -n 1p <<<"${resolved}")"
  sha1="$(sed -n 2p <<<"${resolved}")"
  size="$(sed -n 3p <<<"${resolved}")"
  rm -f "${index}"
elif [[ -n "${CEF_VERSION:-}" && "${CEF_VERSION}" != "${DEFAULT_VERSION}" ]]; then
  version="${CEF_VERSION}"
  # sha1 unknown for ad-hoc versions; verification is skipped and the receipt
  # records that. For a formal rebase drill resolve the sha1 from the index.
  sha1="unverified"
  size="unknown"
fi

artifact="cef_binary_${version}_macosarm64_minimal.tar.bz2"
url="${ARTIFACT_BASE}/${artifact}"
tarball="${DEPS_DIR}/${artifact}"
receipt="${DEPS_DIR}/CEF-VERSION.txt"
extracted="${DEPS_DIR}/cef_binary_${version}_macosarm64_minimal"

if [[ -d "${extracted}" && -f "${receipt}" ]]; then
  echo "CEF ${version} already present at ${extracted}"
  echo "Delete ${DEPS_DIR} to force a re-fetch."
  exit 0
fi

echo "Downloading ${url}"
echo "  size: ${size} bytes"
curl -fL --retry 3 --progress-bar -o "${tarball}" "${url}"

if [[ "${sha1}" != "unverified" ]]; then
  echo "Verifying sha1 ..."
  actual="$(shasum -a 1 "${tarball}" | awk '{print $1}')"
  if [[ "${actual}" != "${sha1}" ]]; then
    echo "FATAL: sha1 mismatch: got ${actual}, expected ${sha1}" >&2
    rm -f "${tarball}"
    exit 1
  fi
  echo "  sha1 OK: ${sha1}"
fi

echo "Extracting into ${DEPS_DIR} ..."
tar -xjf "${tarball}" -C "${DEPS_DIR}"
rm -f "${tarball}"

cat > "${receipt}" <<EOF
cef_version=${version}
platform=macosarm64
distribution=minimal
sha1=${sha1}
fetched=$(date -u +%Y-%m-%dT%H:%M:%SZ)
url=${url}
EOF

echo "Done. Receipt: ${receipt}"
echo "CEF root: ${extracted}"
