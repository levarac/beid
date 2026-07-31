# Spec — 04 Collection (Home) redesign (Beid iOS)

Status: **APPROVED — cleared for implementation.** All three open items in §5
resolved by PM + user; resolutions recorded in place below (§5 kept as a
record of the decision, not as open questions).
Owner: SubPM a-20260728-012, for PM a-20260727-036.
Scope strategy: model-independent visual reskin (parallel to the Option C
protocol-model work; see §5 of the companion survey for the read-only
constraints this inherits).
Survey: `docs/redesign-collection-survey.md`. Figma: `xf2uFHceIYg0h0gJndUkmI`
node `104:300` ("04 Collection (Home)", clean/populated variant).

## 1. Scope

**IN**: visual reskin of `ios/Beid/Views/CollectionHomeView.swift` (grid +
04b empty state) and `ios/Beid/Views/ProofCardView.swift` to Figma `104:300`,
keeping current behavior (read `coordinator.proofStore.proofs`, tap a card to
`openProof(proof)`, "Sense Event"/CTA starts a scan, account icon opens the
already-shipped Account Sheet). Fixes the pre-existing token violations listed
in the survey §2 that live in the two files this reskin touches anyway.

**OUT (defer)**:
- The two banner-overlay "04 Collection (Home)" variants (`104:1630`,
  `104:1737`) and the competing "01b Home (Grouped List)" (`104:1478`) —
  Option C-gated, see survey §4.
- Any change to `AccountSheetView` itself (already shipped, `docs/specs/account-redesign.md`).
- Any change to `Proof`/`ProofStore` schema, proof-arrival timing, or a
  Verified/Collected merge — see survey §5.
- Producing the `encounter-field-empty` custom asset (DESIGN.md Appendix B)
  — out of scope for this code-only slice; the empty state keeps a
  placeholder icon (§3.2), brought into §12 compliance instead of waiting
  on art.

## 2. Source-of-truth precedence

Decision record > Figma > current code. `DESIGN.md` is the token/value
contract (§0): Figma's pixel values (22 pt card radius, 14 px gutters, the
`#007AFF` blue) are a *layout* reference only, never adopted as values — keep
`DS.Radius.card` (16 pt), `DS.Space.m` (16 pt gutters), and every existing
`DS.Color.*`. Only Figma's *shape* (two-column grid, centered card content,
header title + trailing account affordance, floating bottom CTA) is
authoritative reference.

## 3. Screen spec

### 3.1 `CollectionHomeView.swift` (populated grid, node `104:300`)

- **Title**: `.navigationTitle("Collection")` (was `"My Proofs"`), unchanged
  `.navigationBarTitleDisplayMode(.large)` — matches Figma's 34 pt bold
  header via the existing system large-title chrome, no custom header view
  needed (DESIGN.md §2.10).
- **Account button — RESOLVED (§5.1)**: keep the existing toolbar
  `Image(systemName: "person.crop.circle")` exactly as-is, no filled
  roundel. Already correctly tinted `actionPrimary` via the app-root
  `.tint` (`RootView.swift:26`) — no change at all to this element.
- **New proof-count caption**: a `Text` above the grid reading "{n} proofs
  collected" (pluralized, see §6), `DS.Font.supporting` + `DS.Color.textSecondary`
  — matches Figma's 15 pt regular secondary caption (`104:326`) in size,
  weight, and role.
- **Grid**: unchanged `LazyVGrid`/`BeidGlassGroup`/`DS.Layout.*`/`DS.Space.m`
  structure — Figma's two-column layout is already what the adaptive grid
  produces at this frame width; no column-count or spacing token change.
- **Bottom CTA on the POPULATED grid — RESOLVED (§5.2)**: icon-only
  `BeidPrimaryButton`-style button (no visible label), using an existing
  sensing/scan glyph already established in the app's iconography —
  `"dot.radiowaves.left.and.right"` (the same symbol `SensingView`'s center
  glyph and the current CTA already use, i.e. reuse the existing icon, do
  not invent a new one). Size/hit-target via existing `DS.Size.minHitTarget`
  (44×44 minimum) — no raw Figma pixel value. **MANDATORY**: keep the
  `String(localized:)` "Sense Event" copy and set it as
  `.accessibilityLabel(...)` on the button — VoiceOver still announces
  "Sense Event"; only the visible text is removed. Tint/fill conventions
  (`DS.Color.actionPrimary`, no motif accent — Collection has none per §5)
  unchanged from the current labeled button.
- **Bottom CTA on the 04b EMPTY STATE — EXCEPTION, stays labeled**: per
  DESIGN.md §3's do/don't block (first-run discoverability), the
  empty-state CTA keeps its visible "Sense Event" label — do not make it
  icon-only. This means `CollectionHomeView` needs two visual variants of
  the same bottom CTA depending on `proofStore.proofs.isEmpty` (icon-only
  vs. labeled), both wrapping the same `startScan()` action and the same
  underlying localized string.

### 3.2 04b empty state (`CollectionHomeView.emptyState`)

No Figma frame exists for this state (survey §4) — DESIGN.md §3's do/don't
block is the spec:

- Icon: reduce `BeidGlyph(systemImage: "tray", ...)` from `size: 64` to
  `size: 32` (the §12 cap) and add a `// TODO(asset): encounter-field-empty`
  comment at the call site — brings the existing placeholder into §12
  compliance without requiring the art asset to exist yet. Keep
  `assetImage: "encounter-field-empty"` as-is (already wired to pick up the
  real asset the moment it's added to `Illustrations.xcassets`).
- Title: keep **"No proofs yet"** (already matches DESIGN.md §3's DO
  exactly, no change).
- Body: change to **"Start sensing at an event to collect your first
  proof."** (DESIGN.md §3's canonical DO wording; current code's "Tap Sense
  Event to start collecting proof of attendance automatically." drifted
  from the ratified copy — align it).
- CTA: no dedicated button inside `emptyState` — the shared bottom-bar
  "Sense Event" CTA (§3.1) already satisfies DESIGN.md §3's "CTA: Sense
  Event" requirement, since it renders regardless of empty/populated state.
  No change needed here beyond §5.2's open question, which applies equally
  to both states.
- Layout cleanup: replace both `Spacer(minLength: 96)` / `Spacer(minLength:
  140)` with plain `Spacer()` (no literal) — removes the two raw-spacing
  lint violations without inventing a new token for values that were
  arbitrary screen-centering numbers to begin with.

### 3.3 `ProofCardView.swift` (card content, node `104:328` pattern)

Adopt Figma's centered layout, replacing the current icon/checkmark/divider/
metric-row content:

- Replace the top row (`BeidGlyph(seal.fill, .accentColor, 52)` +
  trailing checkmark) with a **centered circular avatar** using the
  already-defined, currently-unused `DS.Artwork.proofCardGradient(seed:
  proof.gradientSeed)` (`Tokens.swift:174-192`) as a `Circle().fill(...)`,
  sized via a new `DS.Size` token (§4) rather than Figma's raw 76 pt.
- `proof.eventName`: keep `DS.Font.cardTitle`, change alignment to
  `.center` (was `.leading`) and keep `lineLimit(2)` +
  `minimumScaleFactor(0.86)` — matches Figma's wrapping 2-line centered
  title (e.g. "DevCon Bangkok 2025").
- `proof.date`: change font from `DS.Font.supporting` to `DS.Font.meta`
  (the token documented for "dates, counts, fine print" — a corrected
  token use, not just a Figma-driven change) and center-align. Keep
  `DS.Color.textSecondary`.
- **Remove — RESOLVED (§5.3)** the `Divider()` and `BeidMetricRow("Peers",
  ...)` row — Figma's card shows no peer count and no divider. This drops
  the visible peer count from the grid card; it remains available on
  `ItemDetailView`.
- Keep `.padding(DS.Space.m)`, `.beidSurface(interactive: true,
  cornerRadius: DS.Radius.card)`. Replace the raw `minHeight: 188` with a
  value derived from the new (shorter, icon-less) content stack — exact
  number is an implementation detail, not a spec-level token, since the
  card is now three centered elements instead of five.
- Accessibility label unchanged: "Proof of {eventName}, {date}"
  (DESIGN.md §10) — still accurate with peers removed from the visible
  card face.

## 4. New/changed tokens (design-system)

- **New `DS.Size` token** for the proof-card avatar diameter (e.g.
  `DS.Size.proofCardArtwork`), added to `Tokens.swift` + the token table in
  DESIGN.md §17 in the same PR — replaces Figma's raw 76 pt with a named
  role, per §4's "MUST: New semantic tokens are added by editing
  Tokens.swift *and* the token table in §17 in the same PR."
- **No new color token** — `DS.Artwork.proofCardGradient(seed:)` already
  exists and is the sanctioned source of `Color(hue:)` (DESIGN.md §5); this
  slice starts *using* it, not defining it.
- **No new font/space/radius token** — `DS.Font.meta`, `DS.Font.supporting`,
  `DS.Space.m`, `DS.Radius.card` all already exist and already have the
  right semantics for their new call sites (§3).

## 5. Decisions (resolved by PM + user — record, not open questions)

1. **Account button treatment — RESOLVED: keep the plain SF Symbol icon**,
   no filled roundel. Figma's filled circular gradient avatar button is not
   adopted; the current bare `person.crop.circle` toolbar icon (already
   correctly tinted `actionPrimary`, no color bug) is unchanged.
2. **Bottom CTA on the populated grid — RESOLVED: icon-only**, no visible
   text. Reuse the existing `"dot.radiowaves.left.and.right"` sensing/scan
   glyph (already used by `SensingView` and the current labeled CTA) rather
   than inventing a new icon. Size/shape via `DS.Size`/`DS.Space` tokens,
   never a raw Figma pixel value. The localized "Sense Event" string is
   **kept and set as `.accessibilityLabel`** — VoiceOver still announces it;
   only the visible label is removed. **Exception**: the 04b empty-state CTA
   keeps its visible label per DESIGN.md §3 (first-run discoverability) —
   not icon-only.
3. **Dropping the "Peers" count from the grid card — RESOLVED: yes.**
   Figma's card shows no peer-verified count at all (§3.3); it stays
   reachable via `ItemDetailView`. DESIGN.md §10's `ProofCardView` entry
   already documents "States: default only... keeps the card dense," which
   this aligns with.

## 6. Localization (per `AGENTS.md`)

New/changed user-facing strings, all authored in English first, machine-
drafted `needs_review` for `ja`/`zh-Hans`/`es`/`fr` in the same PR:

- **"Collection"** — literal-key `.navigationTitle`, one-off (replaces "My
  Proofs"). No comment needed (unambiguous noun).
- **"{n} proofs collected"** — plural variant (String Catalog `plural`
  keyed on the count), not manual branching. Explicit key recommended (interpolated
  value): `String(localized: "collection.count", defaultValue: "^[\(n) proofs](inflect: true) collected", comment: "Count of proofs currently in the user's collection, shown above the grid on the Collection Home screen.")`
  — exact ICU/String-Catalog plural authoring left to implementation; `ja`/
  `zh-Hans` need only the `other` variant filled (no plural forms), `en`/
  `es`/`fr` need `one`/`other`.
- **"Start sensing at an event to collect your first proof."** — literal
  key, replaces the drifted current empty-state body. No comment needed
  (plain declarative sentence, matches DESIGN.md §3's own wording verbatim).
- Account button (§5.1, unchanged): no new string, same "Account"
  accessibility label already in place.
- Bottom CTA (§5.2, icon-only): **no new key** — the existing
  `String(localized:)` "Sense Event" stays exactly as-is in code and moves
  from the button's visible label to its `.accessibilityLabel`. Existing
  translations (all locales) carry over unchanged since the key/string is
  identical, only its call site changes.
- **No key removed** — "My Proofs", "Tap Sense Event to start collecting
  proof of attendance automatically.", and "Peers" become orphaned/unused
  now that §5.3 drops the peers row; String Catalogs tolerate unused keys
  (they simply stop being extracted), noted as a PR cleanup item rather
  than a blocking requirement.

## 7. Acceptance criteria

- clean build = BUILD SUCCEEDED.
- `scripts/lint.sh` = 0 violations; every `ProofCardView.swift` /
  `CollectionHomeView.swift` entry in `lint/baseline.template.json`
  (survey §2's list) is gone, and the template is regenerated to shrink
  (§16's "may only be regenerated to shrink after a migration lands").
- Visual matches Figma `104:300`'s *layout* (two-column centered cards,
  header title + count caption, floating bottom CTA) using `DS.*` token
  *values* throughout — confirmed via `get_design_context` → `DS.*`
  mapping, not pixel-matching Figma's raw colors/radii (§2).
- New `DS.Size` token (§4) documented in `DESIGN.md §17` (+ a note on
  `ProofCardView`'s §10 entry that it now uses `DS.Artwork.proofCardGradient`).
- `#Preview` for both `CollectionHomeView` (empty + populated, light + dark
  — 4 variants, matching the existing 4) and `ProofCardView` (light + dark).
- Behavior unchanged: tapping a card still opens `ItemDetailView` via
  `openProof(proof)`; the account icon still opens the unmodified
  `AccountSheetView`; `startScan()` unchanged.
- No `Proof`/`ProofStore` schema change; no proof-arrival-timing or
  Verified/Collected-merge assumption introduced (survey §5).
- New/changed copy localized (`ja`/`zh-Hans`/`es`/`fr` `needs_review`) per
  §6, including a correctly authored plural variant for the count string.
- UI tests still pass (`-testLanguage en -testRegion US`); update any
  assertion that reads "My Proofs", the empty-state body text, or the
  removed "Peers" row.
- PR-sized; no `.xcodeproj` hand-edits; PR description notes all three §5
  resolved decisions explicitly.
- Icon-only bottom CTA (populated grid) has a real `.accessibilityLabel`
  reading the localized "Sense Event" string — verified via VoiceOver
  inspection or an accessibility audit, not just visual review.

## 8. Branch note

Base on `main` (current HEAD, after PRs #67/#68/#69 merged) or a fresh
branch from `origin/main` — decide at implementation time, independent of
any in-flight Option C branch work.
