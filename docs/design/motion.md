# Motion design: premium, exact-parity, and cheap to run

Requirement (owner, 2026-10-22): Noche ships a premium commercial grade of animation and
polish. Motion is part of the exact-parity mandate: surfaces must not only look like the
reference product's at rest, they must move like it. The owner suggested HyperFrames; that
framework renders video from HTML and so serves this project in two ways: as the
motion-rules reference (its animation domain encodes professional durations, easings
and scene blueprints we mirror in UI terms) and later as the tool for Noche's launch
video. Live UI motion uses the same underlying stack HyperFrames drives, bundled in
the extension.

## Stack (lightweight mandate, 2026-10-22)

The owner requires the build to be as lightweight as possible, so the motion stack
is native-first and costs zero runtime kilobytes by default:

- **CSS transitions and keyframes** for micro-interactions (hover, focus, presses)
  and most entrances: no JS on the hot path, no runtime.
- **WAAPI** for anything needing JS-driven sequencing; composited transform and
  opacity only.
- **A hand-rolled spring utility** (under 1KB) for overshoot motion where
  cubic-bezier overshoot is not enough.
- **View Transitions API** for page-level swaps where available.
- GSAP and a Lottie runtime are NOT bundled. Comparable premium browsers ship Lottie, but matching that
  motion quality means authoring equivalent original animations natively, not
  shipping their runtime class of dependency. If a future surface genuinely needs
  timeline orchestration beyond WAAPI, that decision comes back to the owner with
  the byte cost attached. A total-size budget is enforced in CI
  (scripts/size-budget.mjs); ratchet it down, never up.

## Motion tokens (v0, refine against captures at pixel-zoom)

- Instant: 0 to 60ms - hover states, button presses, toggles.
- Quick: 120 to 200ms - chips appearing, menu items, tooltips, icon swaps.
- Standard: 200 to 320ms - rail dock/undock, card entrances, panel switches.
- Slow: 320 to 500ms - first-run reveals, hero moments, onboarding.
- Easings: ease-out family for entrances (material-style decelerate), ease-in-out
  for moves between two visible states, spring (slight overshoot, stiffness high,
  damping near critical) for the chat rail and composer focus. No linear motion
  except continuous loops.
- Stagger: 30 to 50ms between siblings, capped so a full set resolves within 350ms.

## Per-surface specs (targets; each lands with its surface at its gate)

- Chat rail: spring dock from right (about 280ms, slight overshoot), content
  crossfade 180ms, composer grows to multiline on focus over 160ms, send button
  morphs to stop while streaming.
- Streaming responses: text reveals in phrase-sized chunks with 60ms fades, thinking
  indicator as a subtle three-dot pulse; never per-character jitter.
- Suggestion cards: stagger-in 40ms apart, hover lifts 2px with shadow bloom.
- New tab Supertab card: entrance fade plus 12px rise at 320ms; chips stagger below.
- Tab actions in sidebar: close collapses height and fades 180ms; group open chevron
  rotates 150ms with children stagger 30ms.
- Context menu and dropdowns: scale 0.96 to 1 with 8px origin-toward-cursor, 140ms.
- Theme switches: crossfade the whole UI over 240ms, never instant flips.

## Rules that make it premium AND fast

- Transform and opacity only on the animation path; everything else (filter blur
  excepted for small areas) goes through composited layers.
- 60fps budget: no animation frame over 8ms of main-thread work; GSAP timelines
  paused when their surface is hidden (service worker friendly).
- `prefers-reduced-motion`: all entrances become simple fades under 100ms, springs
  become ease-out, loops pause. Non-negotiable accessibility floor.
- Every animated surface ships a motion-parity review next to its visual-parity
  review: side-by-side at normal speed and at quarter speed against the
  private reference capture.
- No animation without a token: durations and easings come from the tokens file,
  never ad-hoc numbers in components.
