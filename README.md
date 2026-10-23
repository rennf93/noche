# Noche

Noche ("night") is an open-source, local-first, AI-native browser layer. The AI layer (chat with
tabs, chat with
page, inline writing, skills) is built portable first, as a Chromium extension with an
optional native host, and defaults to a user-owned model endpoint
(`http://localhost:9991`, a local fleet running North at 262K context). Any
OpenAI-compatible endpoint works. Commercial cloud browsers cannot ship "your
hardware as the brain"; this project can.

The AI layer is plug-and-play, the way hummin does it: one provider abstraction where
local fleet endpoints, existing subscriptions, and keyed cloud APIs are all just config
entries (base URL, wire protocol, auth, model catalog), hot-swappable per conversation.
See [docs/design/provider-layer.md](docs/design/provider-layer.md).

Aesthetics are a hard requirement, not an inspiration: Noche's UI matches a premium
commercial-grade reference standard, surface by surface, verified by side-by-side
pixel-zoom comparison against the private reference capture set. See [docs/design/aesthetics-parity.md](docs/design/aesthetics-parity.md).
Motion is part of that: premium animation with a native-first,
zero-runtime stack (CSS, WAAPI, a sub-1KB spring utility; no animation libraries
bundled), governed by motion tokens. See
[docs/design/motion.md](docs/design/motion.md). Lightweight is enforced, not
claimed: a total bundle-size budget gate runs in CI (scripts/size-budget.mjs).

Built in gated phases: every gate is a written definition of done, tracked per
gate in [docs/phase-status.md](docs/phase-status.md) as verified (with the
exact command that proves it) or external-pending (naming the missing outside
resource). Headless gates (typecheck, coverage, corpus, evals, size budget) run
in CI on clean runners (.github/workflows/ci.yml); the e2e gate currently runs
via `npm run e2e` until wired into CI. Later phases may scaffold ahead of an
earlier gate, so this list is the plan and the status doc is the truth:
- **Phase 0, ground truth**: clean-room study of the reference product (facts and
  formats only, never copied assets), docs sweep, and a feature matrix mapping every
  feature to an implementation route (extension | native-host | fork-only) or the cut
  list. Gate 0: the owner signs off on the matrix. Status: **signed 2026-10-22** with
  the recommended slate; 37 features routed after the two live-UI passes
  (docs/phase0/), 12 of 13 load-bearing bundle findings independently verified.
- **Phase 1, the AI layer as a portable extension**: WXT + TypeScript, Manifest V3.
  Chat-with-tabs, chat-with-page, inline field editing with accept/reject diffs, skills
  (YAML manifests, zod-validated tools, consent gate on every side effect), streaming
  model client with fleet defaults. Gates: 100% line+branch TS coverage, Playwright e2e,
  an injection corpus (hostile pages must fail closed), machine-checked task evals.
  Status: **all four gates verified 2026-10-23** (359 tests at 100% line+branch,
  chromium e2e smoke over the built extension, 56 corpus tests over 50 hostile
  pages, 30 task evals; docs/phase-status.md). Shipped so far: newtab override,
  side panel chat rail, skills slash menu with a git-hosted registry format,
  local history store, multi-model picker, page-agent core. Inline field editing
  is still open scope.
- **Phase 2, browser shell**: CEF-based macOS app bundling the extension, real tab strip,
  site isolation and Chrome Web Store compatibility inherited from Chromium. Gates: WPT
  parity, Speedometer 3 within 5% of stock Chromium, notarized CI artifacts, a rebase
  drill. Status: **scaffold pass done, no gate landed**. A plain-swiftc stub app
  assembles and launches and CEF 156.0.7 was vendored once with sha1 verified
  (shell/README.md); every gate is external-pending: WPT and Speedometer need the
  CEF toolchain completed, notarization needs Apple Developer ID credentials, the
  rebase drill needs a CEF-linked build.
- **Phase 3, parity push and differentiators**: history-aware local chat, consent-gated
  agent-mode page actions, git-based shareable skills, multi-model picker. Gates:
  behavioral parity diff against the reference product on scripted tasks, a 7-day daily-driver crash-free
  log. Status: **not started as a phase; groundwork landed early** (history store +
  keyword search, consent-gated page-agent core, registry-format skills, multi-model
  picker). Both gates unrun: the parity diff needs captures against a running reference instance,
  the crash-free log needs a 7-day soak.

Security stance: web page content is untrusted input to a model with tool access. Origin
labeling on every context chunk, a capability firewall (untrusted content never solely
triggers a side-effecting tool), per-site consent for tab data, and a public injection
corpus that must fail closed on every page.

License: MIT. Phase 0 sources and dossiers live under `docs/phase0/`.
