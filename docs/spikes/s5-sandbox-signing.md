# Spike S5: sandbox and hardened-runtime signing

Pin: CEF 156.0.7 (Chromium 156), macOS arm64. Evidence under `build/spikes/s5/` (gitignored, local). The screen was locked, so no
screenshots; checks use process arguments and exit codes only. Apps were launched by `scripts/smoke.sh` or by running the binary directly.

| Criterion | Result | Evidence | Notes |
|---|---|---|---|
| Sandbox on, smoke passes | pass | `smoke-sandbox.txt`, `build-sandbox.log` | `NOCHE_SANDBOX=1 scripts/build-app.sh`; `scripts/smoke.sh build/Noche.app fixture` exits 0, `NOCHE_SMOKE load_end status=200`. The flag adds `-DNOCHE_SANDBOX=1` to the CEF-facing targets via `Package.swift` and sets `no_sandbox = false`. |
| Every helper logs `Initialize` returned true | pass | `sandbox-run.err`, `signed-sandbox-run.err` | One `NOCHE-HELPER pid=N sandbox-initialize=1` line per helper process (6 per run), none with 0. |
| Renderer shows `--seatbelt-client` with flag, not without | pass | `sandbox-ps.txt`, `nosandbox-ps.txt` | With flag: renderer `--seatbelt-client=62`, GPU `--seatbelt-client=29`. Without: renderer and GPU show `--no-sandbox` and no seatbelt argument. PIDs were found with `pgrep -f 'build/Noche.app.*--type=renderer'` because all helper variants run from the executable named `Noche Helper`, so `pgrep -f 'Helper (Renderer)'` does not match our processes (it matched another app's helpers, which were not touched). |
| Hardened runtime ad-hoc signing, `codesign --verify --deep --strict` | pass | `sandbox-signed-verify.txt`, `sandbox-signed-codesign-dv.txt`, `sandbox-signed-entitlements.txt` (same three with the `nosandbox-signed-` prefix for the no-flag build) | `scripts/sign-adhoc.sh build/Noche.app` exits 0, verify exits 0, `codesign -dv` shows `flags=0x10002(adhoc,runtime)`. Helper entitlements confirmed (allow-jit, allow-unsigned-executable-memory, disable-library-validation). Signing order: framework dylibs, framework, 4 helpers, app. |
| Smoke after signing | pass, both builds | `sandbox-signed-smoke-fixture.txt`, `nosandbox-signed-smoke-fixture.txt`, `*-smoke-closed-port.txt` (each ends with an `exit=` line) | `fixture` exits 0 signed with and without the flag. Signed sandbox build still shows `--seatbelt-client` on renderer and GPU (`signed-sandbox-ps.txt`; earlier unsigned smoke output is in `smoke-sandbox.txt` and `smoke-nosandbox.txt`). `closed-port` exits 2 (load failure), the same non-zero it gives for any failed load. |
| Notarization | skipped | none | Owner has no Developer ID (design section 13 item 2). Ad-hoc signed apps are for local use only. |

Findings for M1:
- The sandbox works with the shipped framework and the helper call order (sandbox init, then `LoadInHelper`); it can be on by default. The flag can be dropped and the default flipped when M1 wants it.
- The framework must be signed with `codesign --force` in place as shipped (flat layout); `--deep --strict` verifies.
- Not tested: a Developer ID signature, notarization, Gatekeeper assessment (`spctl`), and behavior of the sandbox with extensions or GPU-heavy pages.

S5 verdict: all pass
