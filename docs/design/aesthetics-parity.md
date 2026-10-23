# Aesthetics: exact parity with the reference standard

Requirement (owner, 2026-10-22): Noche's aesthetics have to be the exact same as a
named premium commercial browser's (the reference product). This is a hard
visual-parity requirement, not an inspiration. Every user-facing surface we ship
must match the reference equivalent visually: layout, spacing, shape, typography
weight, color, and interaction states. Match the look with our own implementation;
nothing is copied from the reference product's assets (clean-room applies to pixels
as well as code and text).

## Correction that shaped this doc

An earlier live pass wrongly concluded the reference product has no persistent URL
bar. The owner's screenshot disproved it: a persistent, slim, single-row toolbar
with a pill URL bar. The error came from a vision-tool description that called the
URL pill a "title label". That lesson is rule 2 below.

## Reference capture set

Clean captures (neutral pages only, no personal content) live in the PRIVATE
archive outside this repository (toolbar with URL pill, chat rail, new tab card,
owner toolbar crop, plus settings and context-menu captures). New captures get
added to that archive as surfaces are built; the archive is owner-private and
never published.

## Chrome layout spec (from the reference set, v0)

- Light theme: white toolbar band, no divider line or a hairline at most; traffic
  lights at far left on the toolbar background; ghost-style icon cluster next
  (sidebar toggle, back, forward, reload); the URL pill floats as an autonomous
  rounded element (light gray fill around #F2F2F2 in light theme, favicon plus
  domain-only text inside); right side carries the extension icon cluster and a
  labeled chat pill as the terminal item.
- Dark theme: page backgrounds #0d0d0d to #1a1a1a, toolbar surfaces #1e1e1e to
  #252525 per capture estimates.
- Tabs: top strip or sidebar modes plus an auto-hide state; the sidebar layout is
  pinned grid, chevron groups, individual rows, New Tab row, bottom bar.
- Chat rail: right-docked, roughly 20% of window width, page-scoped context chip
  with favicon and domain, composer with plus (attach), camera (capture tool),
  mic, and a circular send button.
- New tab: centered translucent card roughly 40% of window width, slightly below
  middle, camera button inside, suggestion chips below.

Color values are capture estimates, replaced by pixel-picked tokens in Phase 1
into a tokens file the UI consumes (src/ui/tokens.css).

## Working method (how parity is enforced)

0. Motion is part of parity: movement style is matched too, per
   [motion.md](motion.md); every animated surface gets a quarter-speed
   side-by-side next to its still comparison.
1. A surface is never "done" from code review alone: it ships next to its
   reference capture in a side-by-side, and the comparison is done at pixel zoom
   (spacing, radius, weight, color) before any gate passes.
2. Vision-tool descriptions are leads, not facts: every structural claim about
   the reference UI is checked against an actual capture, and where possible
   against the owner's screen, before it lands in a spec.
3. Both themes are parity targets (the reference ships Automatic, Light, Dark).
4. The Phase 1 gate list gains a visual parity item per shipped surface: new tab
   card, chat rail, settings surfaces; Phase 2 adds toolbar, tab strip, and
   omnibox pill.
