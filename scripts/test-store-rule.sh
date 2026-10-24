#!/usr/bin/env bash
# Offline proof that the install-no-window rule fails on the recorded stock run (stray Chrome window present) and
# passes on a clean synthetic run. No probe launch.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
clang++ -std=c++20 -o "$T/t" "$ROOT/Probes/store-rule-test/store_rule_test.cc"
"$T/t" "$ROOT/docs/engine/evidence/b4-store-stock.txt" fail
# clean run: same evidence with the stray window and its guard lines removed
sed -e '/class=BrowserNativeWidgetWindow/d' -e 's/BrowserNativeWidgetWindow{[^}]*} //' "$ROOT/docs/engine/evidence/b4-store-stock.txt" > "$T/clean.txt"
"$T/t" "$T/clean.txt" pass
# a missing evidence file is an error, not the expected failure
if "$T/t" "$T/does-not-exist.txt" fail 2>/dev/null; then echo "store-rule: missing file passed" >&2; exit 1; fi
echo "store-rule: ok"
