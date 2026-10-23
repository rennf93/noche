# Phase status

Honest state of every gate in the README plan, as of 2026-10-23. "Verified"
means the exact command in the table was executed on this machine
(macOS 27.0.1, arm64, node 22) during this pass and passed. "External-pending"
names exactly the outside resource the gate is waiting on; nothing else is
missing on our side for those rows. Gate 0 (owner sign-off on the feature
matrix) sits outside this table: signed 2026-10-22 (README.md, docs/phase0/).

## Gate table

| Phase | Gate | Status | Proof, or the missing external resource |
|---|---|---|---|
| 1 | 100% line+branch TS coverage over all src logic dirs | verified | `npm run coverage`: 26 files, 359 tests, 100% lines / branches / functions / statements over src/providers, context, settings, security, chat, history, skills, ui, agent (vitest.config.ts include list) |
| 1 | Playwright e2e | verified | `npm run e2e` (wxt build, then playwright test): chromium channel, new headless, `.output/chrome-mv3` loaded via --load-extension; 1 smoke spec, side panel composer renders and the panel-to-background round trips answer. Ran 3/3 green. Not yet wired into .github/workflows/ci.yml (CI has no e2e step yet; clean runners would need `npx playwright install chromium` there) |
| 1 | Injection corpus fails closed | verified | `npx vitest run tests/injection-corpus.test.ts`: 56 tests over the committed 50-page hostile corpus (tests/corpus/pages), every page fails closed end to end |
| 1 | Machine-checked task evals | verified | `npx vitest run tests/task-evals.test.ts`: 30 tests (budgeting, origin labeling, tool round trips, consent denial, slash matching, SKILL.md parsing) |
| 2 | WPT parity | external-pending | Needs WPT harness runs against the shell. No web-platform-tests checkout or harness exists in the repo, and the shell does not run CEF yet (stub mode; shell/README.md "Status of the scaffold pass") |
| 2 | Speedometer 3 within 5% of stock Chromium | external-pending | Needs the CEF toolchain completed (shell/README.md "Not done yet": ObjC++ shim, helper subprocess targets, framework link). A stub with no browser cannot render pages to benchmark |
| 2 | Notarized CI artifacts | external-pending | Needs Apple credentials: a Developer ID Application certificate and a `notarytool` keychain profile. The procedure is written (shell/README.md "Notarization") but has never been executed; local builds are ad-hoc signed only |
| 2 | Rebase drill | external-pending | Needs the CEF toolchain completed. The drill's stacked pass criteria (fetch + sha1 verify, build, launch, then WPT and Speedometer; shell/README.md "Rebase drill") only bite once CEF is actually linked; today's stub build has no browser to rebase |
| 3 | Behavioral parity diff against the reference product on scripted tasks | external-pending | Needs behavioral parity captures against a running instance of the reference product (capture method in the private archive) and the remaining UI surfaces to diff against them |
| 3 | 7-day daily-driver crash-free log | external-pending | Needs a 7-day soak: a build someone actually drives as their daily browser, with its crash log kept for the window |

## Supporting checks from the same pass (2026-10-23)

- `npm run typecheck`: clean, exit 0.
- `npm run size`: 185.3 KB / 200 KB budget, OK.
- `npx playwright install chromium`: Chrome for Testing 156.0.8078.4 (+ headless
  shell, ffmpeg) downloaded from cdn.playwright.dev in under a minute. No
  environment blocker; the e2e gate is runnable on this machine.

## What the e2e slice changed beyond adding the harness

The first real-browser run caught two shipped bugs the unit suite cannot see
(src/entrypoints is DOM glue and sits outside the coverage include list by
design; src/ui/dom.ts is the covered part of that layer):

1. The side panel sent the bare string `CONTEXT_REQUEST` to
   `runtime.sendMessage` instead of `{ type: CONTEXT_REQUEST }`
   (src/entrypoints/sidepanel/main.ts), so the background's type check never
   matched: the one-shot context load always took its catch path, the badge
   title and cached-context chip could never render, and the picker quietly
   papered over the badge text. Fixed to the wrapped shape every other send
   already used.
2. Rail CSS gave five card classes (`.context-chip`, `.slash-menu`,
   `.consent-card`, `.picker-row`, `.ghost-btn`) explicit `display` values that
   defeat the `hidden` attribute, so empty chip / menu / consent / picker boxes
   leaked onto the panel on load. Fixed with a universal
   `[hidden] { display: none !important }` guard in src/ui/tokens.css.

Both fixes are exercised by the new smoke spec (tests/e2e/sidepanel.spec.ts):
badge text + title from the live context round trip, chip stays hidden, typing
enables send.
