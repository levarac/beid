# Beid Design System Contract

This document is the design contract for all beid UI. It is written for two
audiences at once: human designers and AI coding agents. It covers all SwiftUI
UI in `ios/Beid/`, previews, empty states, in-app artwork, and the review
criteria applied to UI PRs.

**Rule language.** Rules use RFC-style keywords:

- **MUST** / **MUST NOT** — hard requirement; violating PRs are rejected.
- **FORBIDDEN** — a concrete, greppable pattern that must not appear.
- **SHOULD** — default; deviation needs a stated reason in the PR.
- **MAY** — explicitly allowed.

**Proposal tags.** Brand-defining values start as
`PROPOSAL — Ken ratification pending` and lose the tag when ratified. On
2026-07-10 Ken ratified the palette direction, the tone thesis, all four
motifs, and the locale set (see §C decision log). Remaining `PROPOSAL` tags
mark the values still genuinely undecided (type ramp choice, exact secondary
hex values, CTA sentence-case grandfathering). Structural and enforcement
rules carry no tag and are not pending.

---

## 0. Source of Truth

DESIGN.md documents **rules**; repo artifacts hold **values**.

| Artifact | Canonical for |
| --- | --- |
| `ios/Beid/DesignSystem/Tokens.swift` | The `DS` namespace: all color/space/radius/size/font/motion tokens and artwork generators |
| `ios/Beid/DesignSystem/Colors.xcassets` | Adaptive (light + dark) color values |
| `.swiftlint.yml` (repo root) | Enforcement rules for banned raw values |
| DESIGN.md (this file) | Semantics, usage rules, tone, review criteria |
| Figma "Minimal v4" board | Visual *reference* for screen layouts (01–09), not a value source |

Note on the Figma board: the mock (branded "SenseProof", an earlier name)
anchors a light minimal look with a blue, Bluetooth-centric accent. This
document's palette (§5) deviates from that blue deliberately; Ken resolved
the tension **against** blue on 2026-07-10 (deep ink + quiet teal + violet
seal adopted). Layout and flow in the Figma are authoritative reference;
its colors are not tokens.

- MUST: When this document and `Tokens.swift` disagree on a value, the code
  is right and this document has drifted — fix the document, and treat the
  drift as a bug.
- MUST: Token excerpts in this document are illustrative; never copy values
  from prose into code.
- FORBIDDEN: Raw color/font/spacing/radius/duration values anywhere in
  `ios/Beid/**` outside `ios/Beid/DesignSystem/`.

## 1. Product Design Thesis

Ratified (Ken, 2026-07-10) — thesis wording adopted as-is.

> Beid is a quiet field instrument for remembering who was really there.
> It senses, verifies, and seals encounters at real-world events. It should
> feel precise, calm, physical, and slightly ceremonial — like a good
> measuring tool that occasionally performs a small ritual when something
> real is captured.

Beid MUST NOT feel like:

- a crypto dashboard or wallet chrome (no balances, gas, jargon-forward UI),
- a social feed (no engagement loops, badges-as-gamification, streaks),
- a generic event app (no confetti-by-default, no marketing gradients),
- a leaderboard.

Wallet is optional (`OnboardingMode.guestFirst` exists). The UI MUST read
fully coherent to a user who never connects a wallet.

## 2. Non-Negotiables

Rules 1–4 are lint-backed for their *common surface forms*
(`.swiftlint.yml` catches the direct call-site patterns — roughly the 80%
case); values reached through expressions, wrappers, or indirection are
review-level (§16 lists the known long tail). Rules 5–12 are review-level
checks against running UI, previews, or PR metadata — auditable, but not
by grep alone.

1. MUST: All colors in Views come from `DS.Color.*`. FORBIDDEN: `Color(red:`,
   `Color(hue:`, `Color(hex:`, `Color.white/.black/.blue/...`, shorthand
   member colors in `.tint(.blue)` / `.foregroundStyle(.orange)` / `.fill(.green)`,
   and `#RRGGBB` literals — anywhere outside `DesignSystem/`.
2. MUST: All fonts in Views come from `DS.Font.*`. FORBIDDEN: `Font.system(`,
   `.font(.title3...)` shorthand, `.font(.custom(` outside `DesignSystem/`.
3. MUST: Spacing and padding use `DS.Space.*`. Numeric literals other than
   `0` and `1` (hairlines) in spacing/padding are FORBIDDEN outside
   `DesignSystem/`.
4. MUST: Corner radii use `DS.Radius.*`.
5. MUST: Every interactive element has a hit region ≥ 44×44 pt
   (`DS.Size.minHitTarget`).
6. MUST: All text uses Dynamic Type-compatible fonts (every `DS.Font.*` role
   is built on text styles, not fixed sizes).
7. MUST: Every screen renders correctly in light and dark mode; all
   `DS.Color.*` tokens are adaptive asset colors.
8. MUST: Icon-only buttons have `.accessibilityLabel`.
9. MUST: State is never conveyed by color alone (verified/warning states pair
   color with a symbol and/or text).
10. MUST: Standard SwiftUI containers first — `NavigationStack`, `TabView`,
    `.sheet`, `.fullScreenCover`, `.alert`, `.confirmationDialog` — before
    any custom chrome.
11. FORBIDDEN: Decorative `Image(systemName:)` larger than 32 pt (see §12).
12. MUST: Any deviation from this document links a decision record in the PR
    (`DesignException: <link or rationale>`).

## 3. Tone and Manner

Adjectives don't constrain agents; named motifs do. Each motif names a
recurring visual idea, where it applies, and what it must not decay into.

Ratified (Ken, 2026-07-10) — all four motif names and definitions adopted
as-is.

| Motif | Meaning | UI use | Avoid |
| --- | --- | --- | --- |
| **Encounter Field** | Nearby people sensed over time | `SensingView` pulse rings, proximity/sensing states, scan-flow backgrounds | Radar/sonar clichés, sci-fi neon, spinning sweeps |
| **Proof Seal** | An encounter became durable | `ProofCollectedView` seal moment, `VerifiedView` resolve, proof card artwork | Generic checkmark-only success, confetti |
| **Ledger Trace** | A verifiable record exists behind this artifact | Metadata rows in `ItemDetailView`, address row in `AccountSheetView`, monospaced identifiers | Blockchain jargon, wallet chrome, explorer-link prominence |
| **Event Artifact** | A proof is a collectible memory of a real event | `ProofCardView` cards, `CollectionHomeView` grid, event recap | NFT-marketplace aesthetics, price/rarity framing |

Concrete do/don't pair (the empty state of `CollectionHomeView`):

```
DO:
Empty state uses Encounter Field artwork (custom asset, once it exists),
title "No proofs yet",
body "Start sensing at an event to collect your first proof.",
CTA "Sense Event",
background DS.Color.surfaceCanvas.

DON'T:
Image(systemName: "tray") at 48 pt,           // the current scaffold does this
generic title "No data",
system blue accent,
or any wallet/crypto iconography.
```

Voice registers by moment:

- **Sensing** (`SensingView`, `VerifyingView`): calm, factual, present tense.
  "Sensing automatically." No exclamation marks.
- **Ceremony** (`VerifiedView`, `ProofCollectedView`): short, declarative,
  slightly formal. "Proof collected." One quiet moment of weight, not a
  celebration.
- **Recovery** (`SignalLostView`, `BluetoothOffView`): plain instructions,
  no blame, always a way forward.

## 4. Token Architecture

Three tiers:

1. **Primitive values** — hex components in `Colors.xcassets`, numeric
   constants in `Tokens.swift`. Never referenced directly by Views.
2. **Semantic tokens** — the `DS.*` namespace (`DS.Color.signalActive`,
   `DS.Space.m`, `DS.Size.minHitTarget`, `DS.Font.sectionTitle`,
   `DS.Motion.proofResolve`, `DS.Artwork.proofCardGradient(seed:)`). This
   is the only tier Views may use.
3. **Component conventions** — per-component token bindings documented in
   §10 (e.g. proof cards use `DS.Radius.card`).

Rules:

- MUST: New semantic tokens are added by editing `Tokens.swift` (+ a colorset
  in `Colors.xcassets` for colors) *and* the token table in §17 in the same PR.
- MUST: Token names describe role, not appearance (`signalActive`, not
  `tealAccent`).
- SHOULD: Prefer reusing an existing semantic token over adding a near-
  duplicate; introduce a new one only when the *role* is genuinely new.
- MAY: Introduce a DTCG `tokens.json` upstream source later if design-tool
  sync becomes real; until then Swift + xcassets are canonical.

## 5. Color

Direction ratified (Ken, 2026-07-10): deep ink background + quiet teal
(`#18C7A7` family) + violet proof seal — the Figma Minimal v4 blue is
resolved **against**. Exact secondary hex values (surfaces, text, hairline,
`actionPrimary`, dark variants) remain
`PROPOSAL — Ken ratification pending`; roles and structure are not pending.

| Token | Light | Dark | Role | Allowed use | Forbidden use |
| --- | --- | --- | --- | --- | --- |
| `DS.Color.surfaceCanvas` | `#F7F4EE` | `#111315` | Root background | Screen roots, scroll backgrounds | Buttons, icons |
| `DS.Color.surfaceRaised` | `#FFFFFF` | `#1B1E20` | Cards, sheets | Proof cards, event cards, sheet surfaces | Full-screen backgrounds |
| `DS.Color.textPrimary` | `#1A1C1E` | `#ECEDEE` | Primary text | Titles, body | Decorative fills |
| `DS.Color.textSecondary` | `#5C6165` | `#9BA1A6` | Supporting text | Subtitles, metadata | Primary CTAs |
| `DS.Color.actionPrimary` | `#2A2E33` | `#E8EAEC` | Neutral primary action | CTA tint on screens with no motif accent; app-level accent | Motif moments (sensing/ceremony/recovery) |
| `DS.Color.signalActive` | `#18C7A7` | `#62E8D0` | Live sensing signal | Sensing pulse, verifying progress, one key accent per scan screen | Body text, large fills |
| `DS.Color.signalWarning` | `#C7841A` | `#E8B562` | Degraded/lost signal | `SignalLostView`, `BluetoothOffView` accents | Errors that aren't signal-related |
| `DS.Color.proofSeal` | `#6E5AEF` | `#9D8CFF` | Sealed proof artifacts | Seal artwork, seal/verified moments, proof accents | Generic links, nav tint |
| `DS.Color.labelOnWarning` | `#1A1C1E` | `#111315` | CTA label on `signalWarning` fill | Prominent-button labels on recovery screens | Anything except labels sitting on a `signalWarning` fill |
| `DS.Color.labelOnSeal` | `#FFFFFF` | `#111315` | CTA label on `proofSeal` fill | Prominent-button labels at ceremony moments | Anything except labels sitting on a `proofSeal` fill |
| `DS.Color.strokeHairline` | `#E3DFD6` | `#2A2E31` | Hairlines | Dividers, card strokes | Text |
| `DS.Color.statusCaution` | `#B23A2E` | `#E2897C` | Non-signal caution/error state | Declined/timed-out/failed wallet-signature status (`ItemDetailView`, `ProofCollectedView` signature controls) | BLE signal issues (use `signalWarning` instead) |
| `DS.Color.statusOn` | `#1E7E34` | `#30D158` | Binary on/off status, "on" | Bluetooth-active badge (`AccountSheetView`) | BLE signal quality (use `signalWarning`), wallet-signature status (use `statusCaution`), sensing-screen accent (use `signalActive`) |
| `DS.Color.statusOff` | `#6B7075` | `#83898F` | Binary on/off status, "off" | Bluetooth-off badge (`AccountSheetView`) | Same as `statusOn`'s forbidden uses — this pair is for a neutral toggle state only, not an alarm |

Rules:

- MUST: Every color is an adaptive asset colorset (light + dark) exposed
  through `DS.Color.*`. High-contrast variants SHOULD be added to the same
  colorsets when the palette is ratified.
- MUST: Exactly **one** motif accent per screen, mapped by moment:
  `signalActive` on sensing screens (`SensingView`, `EventFoundView`,
  `VerifyingView`), `proofSeal` at ceremony moments (`VerifiedView`,
  `ProofCollectedView`, proof artwork), `signalWarning` on recovery screens
  (`SignalLostView`, `BluetoothOffView`). Screens outside these moments
  (onboarding, home, account) have **no** motif accent — their CTAs and
  controls tint with `DS.Color.actionPrimary`.
- MUST NOT: System default blue as an *implicit fallback* — every tintable
  control gets an explicit `DS.Color.*` tint, and at migration the
  app-level accent is set to `actionPrimary`. FORBIDDEN: `.tint(.blue)`
  (the current scaffold's pattern; it is migration debt, not precedent).
- MAY: System semantic colors (`.primary`, `.secondary`, `Color(.systemRed)`)
  inside `DesignSystem/` as implementation details of a token — never
  directly in Views.
- MUST: Prominent CTA labels never rely on the button style's default
  white. Label pairing per fill (see `BeidPrimaryButton`):
  `actionPrimary` → `surfaceCanvas` (fill inversion), `proofSeal` →
  `labelOnSeal`, `signalWarning` → `labelOnWarning`. `signalActive` is a
  sanctioned CTA tint per the §10 accent map but no sensing screen has a
  primary CTA today — whoever introduces one MUST add its on-fill label
  token first (ink-style measures ~8:1/12:1; the inversion default fails
  at ~2:1). Any fill hex change (including ratifying this PROPOSAL
  palette) MUST re-check ≥4.5:1 label-on-fill contrast in both modes.
- The per-proof generated gradient is a *data-driven* artwork generator,
  not a token: `DS.Artwork.proofCardGradient(seed:)` in `Tokens.swift` is
  its canonical home and the only sanctioned source of `Color(hue:)`.
  `ProofCardView`'s current local copy of the same math is scaffold debt;
  the phase-2 migration replaces it with the `DS.Artwork` call.

## 6. Typography

`PROPOSAL — Ken ratification pending` (ramp choice: system SF Pro + SF Mono
for ledger traces; no custom brand font in this phase)

Ramp (all Dynamic Type text styles, defined in `DS.Font`):

| Token | Style | Role | Constraint |
| --- | --- | --- | --- |
| `DS.Font.screenTitle` | `.largeTitle` bold | Screen title | Max one per screen |
| `DS.Font.ceremonyTitle` | `.title` bold | "Verified", "Proof Collected" | Ceremony moments only |
| `DS.Font.sectionTitle` | `.title3` semibold | State/section titles | |
| `DS.Font.cardTitle` | `.subheadline` semibold | Card titles | `lineLimit(1)` + truncation on cards |
| `DS.Font.body` | `.body` | Body copy | |
| `DS.Font.supporting` | `.subheadline` | Supporting copy | Pair with `textSecondary` |
| `DS.Font.meta` | `.caption` | Dates, counts | |
| `DS.Font.ledgerMono` | `.footnote` monospaced | Addresses, hashes, proof IDs | Ledger Trace motif only |
| `DS.Font.cta` | `.headline` | Primary CTA labels | Label color per §5's CTA-label rule (never the style default white) |

Rules:

- MUST: All fonts support Dynamic Type (text styles, never fixed point sizes).
- MUST: Layouts survive AX3 text sizes: multiline text wraps, never clipped;
  fixed-height containers around text are FORBIDDEN.
- SHOULD: Long event names truncate with `lineLimit` on cards, wrap on
  detail screens.
- FORBIDDEN: `.font(.system(size: N))` — the current scaffold uses this for
  oversized SF Symbols; it disappears with the §12 migration.

## 7. Spacing, Layout, Safe Areas

4 pt base scale in `DS.Space`: `xs 4 / s 8 / m 16 / l 24 / xl 32 / xxl 48`,
plus `DS.Space.pageMargin` (32) for full-width content and bottom CTAs.

- MUST: All padding/spacing values come from `DS.Space.*` (exceptions: `0`, `1`).
- MUST: On state screens in compact width, full-width primary CTAs sit at
  the bottom with horizontal padding `DS.Space.pageMargin` (the pattern in
  `WelcomeView`, `SignalLostView`, `ProofCollectedView`). Sheets, regular-
  width layouts, and secondary actions MAY deviate with a stated reason.
- MUST: Respect safe areas; content never hides behind home indicator or
  notch. Keyboard avoidance uses standard SwiftUI behavior.
- SHOULD: Grid layouts use `DS.Space.m` (16) gutters (the
  `CollectionHomeView` `LazyVGrid` pattern).
- SHOULD: Vertical rhythm inside a state screen (icon → title → body → CTA)
  uses `DS.Space.l` (24) as the default stack spacing.

## 8. Shape, Material, Elevation

Radii in `DS.Radius`: `control 12 / card 16 / seal 28 / pill 999`. All
rounded rectangles use `style: .continuous`.

- MUST: Proof cards and event cards use `DS.Radius.card`.
- MUST: Seal/ceremony surfaces use `DS.Radius.seal`.
- SHOULD: Elevation via material or `surfaceRaised` + hairline stroke, not
  heavy drop shadows. Beid surfaces are matte and physical, not floaty.
- Materials: the deployment target is iOS 17, so iOS 26 Liquid Glass APIs
  (e.g. `glassEffect`) are usable only behind availability gates
  (`if #available(iOS 26, *)`), never unguarded. Standard SwiftUI
  controls/navigation adopt the new system appearance automatically when
  the app is rebuilt with the iOS 26 SDK — prefer that free adoption. For
  pre-26 fallback and overlay chrome, use system materials
  (`.ultraThinMaterial` etc.).
- MUST: Custom `glassEffect` use requires explicit design approval
  (a `DesignException` link). Glass is a functional layer for controls and
  navigation, not content decoration — proof/ceremony artwork is content
  and does not get glass by default. No glass-on-glass nesting.
- FORBIDDEN: Faking glass with arbitrary blur rectangles.

### 8a. Liquid Glass materials (design-approved surface, DesignException: this section)

Beid expresses Liquid Glass through the quiet-field-instrument register, not
against it: glass is restrained, matte-adjacent, and reserved for chrome —
never a decorative flourish layered onto content or artwork.

- **The one sanctioned mechanism**: `View.beidSurface(interactive:cornerRadius:fallback:)`
  in `ios/Beid/DesignSystem.swift`. On iOS 26+ it applies `.glassEffect`
  (regular, `.interactive()` only when the surface is genuinely tappable);
  below iOS 26 it falls back to a system `Material` plus a
  `DS.Color.strokeHairline` stroke. This modifier owns the entire surface
  fill — call sites MUST NOT pair it with a separate
  `.background(material:)`/`.background(color:)`. (A real instance of this
  bug shipped in the original `beidGlass` helper: `BeidPanel` and
  `ProofCardView` both painted `.background(.regularMaterial, in: …)`
  *underneath* `.glassEffect(...)`, stacking two materials on iOS 26 — the
  exact glass-on-glass nesting this document forbids. Fixed by folding the
  fallback material into `beidSurface` itself, so glass and material are
  mutually exclusive by construction, not by call-site discipline.)
- **Where glass applies** (functional chrome, per the existing §8 rule):
  `BeidGlyph` (icon roundels), `BeidPanel` (metadata/status card
  backgrounds), `ProofCardView` (interactive grid cards — `interactive:
  true`, since tapping opens the detail screen), `BeidPrimaryButton`
  (`.buttonStyle(.glassProminent)`) and `BeidSecondaryButton`
  (`.buttonStyle(.glass)`), `BeidBulletRow`'s icon roundel.
- **Where glass does not apply**: `DS.Color.surfaceCanvas` screen
  backgrounds (a root background is structural, not a floating control —
  glassing it would remove the "matte and physical" ground everything else
  sits on); proof/ceremony artwork (`DS.Artwork.proofCardGradient`, seal
  moments) — content, per the existing §8 rule, not chrome; `AccountSheetView`'s
  `List` rows (§2.10: standard containers first; a system `List` already
  gets the platform's own Liquid Glass row treatment on iOS 26 for free —
  wrapping rows in `beidSurface` on top of that would itself be
  glass-on-glass); the `WalletConnectPairingView` QR code surface and the
  `EventCodeEntryView` text-field container, which stay `surfaceRaised` +
  hairline — a scan target and a text-entry field are read, not tapped as
  chrome, so matte legibility wins over glass.
- **Grouping**: `BeidGlassGroup` (also in `DesignSystem.swift`) wraps
  `GlassEffectContainer` on iOS 26+ (plain passthrough below it). Use it
  around any cluster of `beidSurface`-backed views that sit close together
  on one screen, so iOS 26 can blend/merge them in one render pass instead
  of compositing each independently — `BeidScreen` wraps its whole
  content+footer stack (covers every state-screen pattern: glyph header +
  panel + CTA), `CollectionHomeView` wraps the proof-card grid,
  `ItemDetailView` wraps its three stacked panels. Do not wrap views that
  are far apart or on different screens; that defeats the container's
  purpose per the upstream guidance.
- **Deployment target**: stays iOS 17 (`ios/project.yml`); every Liquid
  Glass call site is gated behind `#available(iOS 26, *)` with a real
  fallback, never unguarded. Ken's "ふんだんに" (generously) directive is
  read as *thorough adoption of the sanctioned surface pattern across every
  eligible chrome element*, not as raising the minimum OS — beid's existing
  users on iOS 17–25 get an equivalent matte-material look (the pre-26
  fallback path in `beidSurface` now draws its hairline stroke from
  `DS.Color.strokeHairline` instead of the previous `.separator.opacity`,
  a deliberate token-correctness fix, not a value-preserving no-op); iOS 26
  users get glass. No `DesignException` is
  needed for staying on iOS 17; raising the deployment target is a
  business decision (device-support cutoff) outside this design pass's
  scope.

## 9. Motion and Haptics

Motion is spring-first and interruptible. Springs are parameterized by
damping and response (`DS.Motion`), not fixed-duration curves.

| Token | Value | Use |
| --- | --- | --- |
| `DS.Motion.fast` | spring, response 0.25, damping 1.0 | Press feedback, small state flips |
| `DS.Motion.standard` | spring, response 0.35, damping 1.0 | Default transitions |
| `DS.Motion.entrance` | spring, response 0.5, damping 0.85 | Content entering (event card in `EventFoundView`) |
| `DS.Motion.proofResolve` | spring, response 0.6, damping 0.8 | Proof seal ceremony |
| `DS.Motion.sensingPulsePeriod` | 1.8 s | One radar pulse cycle in `SensingView` |

Rules:

- MUST: Default to critically damped (damping 1.0). Overshoot (damping < 1)
  is reserved for moments that carry momentum or ceremony: `entrance` and
  `proofResolve`.
- MUST: Animations are interruptible — never lock out input during a
  transition; animate from the current (presentation) value.
- MUST: Honor Reduce Motion — replace slides/springs with opacity
  cross-fades; the `SensingView` pulse loop degrades to a static state with
  a subtle opacity breathe or none at all.
- SHOULD: Haptics only at meaningful commits: event found (light), proof
  sealed (success). FORBIDDEN: haptics on every phase change of
  `ScanPhase`.
- FORBIDDEN: `repeatForever` animations on screens other than `SensingView`
  (ambient motion is the Encounter Field motif's privilege, nobody else's).

## 10. Component Inventory

Real components in this codebase. Each entry is the contract for reuse.

### Component: ProofCardView

- Purpose: One collected proof in the `CollectionHomeView` grid.
- Use when: Rendering a `Proof` in a collection context.
- Don't use when: Event-level summaries, onboarding illustrations, detail
  hero (that is `ItemDetailView`'s header).
- API: `ProofCardView(proof: Proof)`.
- Required tokens: `DS.Radius.card`, `DS.Font.cardTitle`, `DS.Font.meta`,
  `DS.Color.textSecondary`, `DS.Size.proofCardArtwork`. Artwork:
  `DS.Artwork.proofCardGradient(seed:)` (§5), rendered as a centered
  circular avatar — adopted as of the 04 Collection Home redesign
  (`docs/specs/collection-redesign.md`); no longer scaffold debt.
- States: default only. No "collected" checkmark or peer-count row on the
  card face as of the 04 redesign — peers-verified stays visible on
  `ItemDetailView` only. Per-proof wallet-signature states
  (`notRequested` / `connecting` / `awaitingApproval` / `signed` /
  `deferred` / `rejected` / `failed`) exist as of 2026-07-12 but are
  surfaced in `ItemDetailView` and `ProofCollectedView`, not on the grid
  card itself — keeps the card dense and avoids a second status affordance.
  Revisit if a future design pass wants a compact card-level signature
  badge; it MUST pair color with a symbol per §2.9.
- Accessibility: entire card one element; label "Proof of {eventName},
  {date}".

### Component: ProofSignatureControlsView

- Purpose: Wallet-signing status + action for one `Proof` — reads live
  `signatureState` from `AppCoordinator.proofStore` (never a point-in-time
  snapshot, since a sign attempt mutates state while this view is on
  screen).
- Use when: A screen needs to show/offer proof signing. Currently
  `ItemDetailView` (Screen 08, persistent) and `ProofCollectedView`
  (Screen 07, ceremony moment) — chosen because 08 is the durable place a
  user manages a proof over time, and 07 is the moment signing is most
  top-of-mind right after collection.
- Don't use when: `ProofCardView` (grid density) or `VerifiedView` (no
  `Proof` exists yet at that point in the flow).
- API: `ProofSignatureControlsView(proofId: UUID)`, requires
  `AppCoordinator` in the environment.
- Required tokens: `DS.Color.actionPrimary` (sign/connect CTA tint — no
  motif accent per the Primary CTA button rule, §10), `DS.Color.proofSeal`
  (signed status), `DS.Color.statusCaution` (deferred/rejected/failed
  status), `DS.Font.ledgerMono` (signer address).
- Rules: state is never color alone (§2.9) — every non-default status pairs
  its color with distinct status text. When no wallet is connected, shows a
  "Connect Wallet" path instead of hiding the feature outright.

### Component: ScanFlowView (phase container)

- Purpose: Full-screen cover hosting the sensing flow, switching on
  `SensingCoordinator.phase` (`ScanPhase`: idle/sensing → eventFound →
  verifying → verified → collected, with signalLost branch).
- Use when: The single entry point to sensing; presented via
  `fullScreenCover` from `RootView`.
- Don't use when: Anything else — there is exactly one scan flow.
- Rules: phase transitions animate with `DS.Motion.standard`; a trailing
  close (X) button is always reachable in the toolbar; each phase view owns
  its content but not its chrome.

### Component: Sensing pulse (in SensingView)

- Purpose: The Encounter Field ambient indicator while scanning.
- Required tokens: `DS.Color.signalActive`, `DS.Motion.sensingPulsePeriod`.
- Rules: the only permitted `repeatForever` animation; MUST degrade under
  Reduce Motion (§9); center symbol needs `.accessibilityHidden(true)` with
  the state conveyed by the title text.

### Component: BeidStatusPill

- Purpose: Dot + label status indicator, e.g. "Sensing automatically" atop
  `SensingView`.
- Use when: A screen needs a compact, glanceable state readout that is not
  a navigable control.
- Don't use when: The status is interactive (use a button/toggle) or needs
  more than a dot + one line of text (use `BeidBulletRow` or a bespoke row
  instead).
- API: `BeidStatusPill(state:)`, `state: BeidStatusPill.State` —
  `.sensingAutomatically` / `.sensingPaused`.
- Required tokens: `DS.Space.m` (horizontal padding), `DS.Space.s`
  (vertical padding and the dot-label gap), `DS.Size.statusDot`,
  `DS.Radius.pill` (via `beidSurface`), `DS.Font.supporting`,
  `DS.Color.textSecondary` (label, both states), `DS.Color.signalActive` /
  `DS.Color.signalWarning` (dot).
- States: `.sensingAutomatically` (active, `signalActive` dot) /
  `.sensingPaused` (warning, `signalWarning` dot; defined for future reuse,
  not yet rendered anywhere). Label color never changes with state — only
  the dot does, and the label text itself names the state, so color is
  never the only signal (§2.9).
- Accessibility: dot is `.accessibilityHidden(true)` (decorative — state is
  named by the label text); label is a plain `Text`, not merged into a
  combined accessibility element, so it stays independently queryable by
  its string.

### Component: BeidBulletRow

- Purpose: One benefit/permission bullet — an icon roundel plus a title, and
  optionally a second, smaller supporting sentence.
- Use when: A state screen needs a short list of benefit/permission bullets
  (`BluetoothPermissionView`'s three Bluetooth benefits).
- Don't use when: The row needs numbering/sequence (use
  `BeidNumberedStepList` instead) or is itself a full panel/card.
- API: `BeidBulletRow(systemImage: String, title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil)`.
  Omit `subtitle` for a title-only row.
- Required tokens: `DS.Space.s`/`DS.Space.xs` stack spacing, `DS.Font.cardTitle`
  (title), `DS.Font.meta` + `DS.Color.textSecondary` (subtitle),
  `BeidDesign.Radius.control` + `BeidDesign.Size.bulletIcon` (icon roundel).
  Icon tint follows ambient `.tint()` (no motif accent on onboarding screens
  → `actionPrimary`; §5 accent map elsewhere).
- Accessibility: icon roundel is `.accessibilityHidden(true)` (decorative;
  the title/subtitle text already carries the meaning).

### Component: BeidNumberedStepList

- Purpose: Sequential numbered instructions in a bordered card — one filled
  index badge + one line per step.
- Use when: A recovery/setup screen needs an ordered short sequence
  (`BluetoothOffView`'s "Open Settings / Tap Bluetooth / Switch it on").
- Don't use when: The list isn't ordered (use `BeidBulletRow` instead) or
  has more than a handful of steps (this is not a scrolling list).
- API: `BeidNumberedStepList(steps: [LocalizedStringKey], labelColor: Color = DS.Color.surfaceCanvas)`.
- Required tokens: `DS.Space.m`/`DS.Space.s`/`DS.Space.xs` spacing,
  `DS.Font.meta` (badge number) + `DS.Font.body` (step text),
  `BeidDesign.Radius.card` + `BeidDesign.Size.stepBadge` (badge), hairline
  `Divider()` between rows.
- Rules: the badge fill follows ambient `.tint()` so it always matches the
  hosting screen's single motif accent (§5) — `labelColor` MUST be that
  tint's on-fill pairing token (e.g. `signalWarning` fill → `labelOnWarning`
  label, the same rule `BeidPrimaryButton` follows). Never hardcode a
  specific `DS.Color` for the badge fill; that would fight whatever tint the
  screen sets.
- Accessibility: badge + step text read as one line per row; no separate
  accessibility grouping needed since nothing is interactive.

### Component: State screen (pattern shared by 01/02/03/06c/06d/07)

- Purpose: Icon/artwork → title → supporting text → optional bottom CTA.
  Used by `WelcomeView`, `BluetoothPermissionView`, `BluetoothOffView`,
  `VerifiedView`, `SignalLostView`, `ProofCollectedView`.
- Required tokens: `DS.Space.l` stack spacing, `DS.Space.pageMargin`
  margins, `DS.Font.sectionTitle`/`ceremonyTitle` + `DS.Font.supporting`,
  bottom CTA with `DS.Font.cta`.
- Rules: SHOULD be extracted into a shared `StateScreen` container when the
  UI worker migrates views (phase 2); until then new state screens match the
  required slots and tokens above (not pixel-copying existing views).

### Component: Detail meta row (detailRow in ItemDetailView)

- Purpose: Ledger Trace metadata (`Method`, `Peers verified`, `Status`).
- Required tokens: `DS.Font.supporting`, `DS.Color.textSecondary` label,
  `DS.Font.ledgerMono` for identifiers/addresses when they appear.
- Rules: status values pair text with color (`Verified` +
  `DS.Color.proofSeal`), never color alone.

### Pattern: Primary CTA button

- Purpose: The one main action per screen ("Get Started", "Sense Event",
  "Try Again", "Done"). A convention, not a reusable component (yet).
- Rules: `.borderedProminent`, label `DS.Font.cta`, full width inside
  `DS.Space.pageMargin` (compact-width state screens, §7). Tint follows the
  §5 accent map exactly: `signalActive` on sensing screens, `proofSeal` at
  ceremony, `signalWarning` on recovery screens, `DS.Color.actionPrimary`
  everywhere else. There is no "default" tint — an unspecified tint is a
  §5 violation, not a fallback. Label color follows §5's CTA-label pairing
  rule (never the style default white). Max one per screen.

## 11. Screen Patterns

The app's navigation shape (all real, from `ios/Beid/Navigation/`):

- **Root switch**: `RootView` switches on `AppScreen`
  (welcome / walletConnect / bluetoothPermission / bluetoothOff / home).
  Onboarding order depends on `OnboardingMode` (walletFirst | guestFirst).
  MUST: both orders stay coherent; no screen may assume a wallet exists.
- **Onboarding screens (01–03)**: state-screen pattern (§10), one CTA,
  benefits as short icon bullets (`BluetoothPermissionView`). Permission
  requests explain value *before* the system prompt.
- **Collection home (04)**: `NavigationStack` + adaptive `LazyVGrid` of
  `ProofCardView`; account entry top-trailing; "Sense Event" CTA in the
  bottom bar. Empty state (04b) follows the §3 do/don't.
- **Scan flow (05–07)**: `fullScreenCover` — sensing is a modal session with
  a clear exit (a trailing close (X) button). Phase progression is linear;
  `SignalLostView` (06d) is the recovery branch and MUST always offer "Try
  Again".
- **Detail (08)**: push via `navigationDestination(item:)` from the grid.
- **Account (09)**: `.sheet` with `List` + inline title; wallet
  connect/disconnect lives here in guest-first mode. Destructive actions
  (`Disconnect Wallet`) use `role: .destructive` and MUST confirm via
  `.confirmationDialog` once real wallets exist.
- Loading: indeterminate work shows calm progress (`VerifyingView`'s
  circular progress with peer count), never blocking spinners without copy.
- Errors: recovery screens state what happened, why, and one action —
  the `SignalLostView` formula.

**Planned surfaces (Figma MTG comments, 2026-07 — not yet designed).**
Organizer-side comments on the Minimal v4 board name surfaces that do not
exist in this codebase yet: an organizer mode (主催者モード), organizer-set
verification thresholds, a manual event-code check-in as a rescue path when
sensing fails, and richer pre-check-in status transitions before the scan
flow. Agents MUST NOT improvise these; when they land, they are designed
against this contract (the event-code rescue path, for example, is a
Recovery-register screen per §3, not a new visual language).

## 12. Iconography and Illustration

Policy split:

| SF Symbols (keep) | Custom assets (required) |
| --- | --- |
| System actions: close, back, share, settings, person/account | Proof seals, encounter/sensing artwork, empty states |
| Toolbar and tab affordances | Ceremony moments (`ProofCollectedView` seal) |
| Small inline symbols beside text (≤ 32 pt) | Any brand moment currently faked by an oversized SF Symbol |

- FORBIDDEN: Decorative `Image(systemName:)` larger than 32 pt. Current
  violations are migration debt, explicitly *not* precedent:
  `WelcomeView` ("checkmark.seal.fill" 72 pt), `ProofCollectedView`
  ("seal.fill" 48 pt), `VerifiedView` ("checkmark.circle.fill" 64 pt),
  `SignalLostView` ("exclamationmark.triangle.fill" 56 pt),
  `BluetoothOffView`, `BluetoothPermissionView`, `WalletConnectView`.
  `CollectionHomeView`'s empty-state icon was brought into compliance
  (32 pt + `TODO(asset)`) by the 04 Collection Home redesign.
- Two distinct custom-asset pipelines — do not mix them:
  1. **Illustrations** (proof artwork, empty states, sensing scenes):
     vector assets in an `Illustrations.xcassets` (to be added with the
     first real asset), rendering `Original`, light/dark variants when
     colors are embedded.
  2. **Custom symbols** (small reusable glyphs that behave like SF
     Symbols): authored from an SF Symbols app template as SVG symbol
     sets, validated in the SF Symbols app, added to the asset catalog —
     this preserves weights, scales, text alignment, and accessibility
     behavior. Single-color template glyphs are tinted only via
     `DS.Color.*`.
- Temporary path until assets exist: a new surface that *needs* a brand
  moment MAY ship with a placeholder (small SF Symbol ≤ 32 pt or plain
  layout) plus a `TODO(asset): <asset-name>` comment and a checklist note —
  never with an oversized decorative SF Symbol.
- MUST: Decorative images use `.accessibilityHidden(true)`.
- MUST: Symbols paired with text scale with Dynamic Type (`@ScaledMetric`
  or font-relative sizing).
- Asset naming: kebab-case, motif-prefixed — e.g. `encounter-field-empty`,
  `proof-seal-collected`.

## 13. Accessibility

Acceptance criteria for every component and screen, not post-hoc QA:

- MUST: Contrast ≥ WCAG AA for text against its actual background in both
  appearances (verify against `surfaceCanvas` *and* `surfaceRaised`).
- MUST: Dynamic Type through AX sizes without clipped text (§6).
- MUST: VoiceOver — every screen readable in a sensible order; cards are
  single elements with composed labels (§10); icon-only buttons labeled
  (`CollectionHomeView`'s "person.crop.circle" account button MUST carry
  "Account").
- MUST: Reduce Motion honored (§9); Reduce Transparency degrades materials
  to solid `surfaceRaised`.
- MUST: State never by color alone; `VerifyingView` progress announces
  "{n} of {total} peers verified" as text, which VoiceOver reads.
- SHOULD: The sensing session posts meaningful VoiceOver announcements on
  phase changes (event found, verified, collected).

## 14. Dark Mode and High Contrast

- MUST: Every `DS.Color` token has a dark variant (already true in
  `Colors.xcassets`); no view opts out of dark mode.
- MUST: PRs adding UI include light *and* dark previews
  (`.preferredColorScheme` variants in `#Preview`).
- MUST: The proof-card generated gradient remains legible against both
  canvas values; card text sits on `surfaceRaised`, never directly on the
  gradient.
- SHOULD: High-contrast colorset variants are added at palette ratification;
  until then, high-contrast rendering falls back to the base values and
  must at minimum not lose information.
- FORBIDDEN: `.colorScheme(.dark)` / `.preferredColorScheme` forced in
  production views (previews only).

## 15. Copywriting Voice

Language model (Ken decision, 2026-07-10): the app's primary language is
**English**, localized via String Catalogs to the confirmed locale set
`en` (source) + `ja`, `zh-Hans`, `es`, `fr` — the full localization process
lives in `AGENTS.md`.

- MUST: All copy is authored in English as the source language; the voice,
  vocabulary, and forbidden-term rules below are defined against English.
- MUST: Translations preserve the register per locale (calm/factual,
  ceremonial, recovery — §3); the forbidden-term list maps per language
  (e.g. the Japanese equivalents of "mint"/"NFT" jargon are equally
  forbidden).
- MUST: User-facing strings go through the String Catalog — no hardcoded
  display strings that bypass localization.
- Per-locale term mapping, Japanese (Ken decision, 2026-07-10): the UI terms
  are **検知** for "Sensing" and **証明** for "Proof". Do NOT "correct" these
  to the team-internal vocabulary (センシング / 証) — plain-user readability
  wins over internal jargon. Future translators: this is a deliberate,
  ratified choice, not an oversight.

- Vocabulary: "proof", "encounter", "event", "sense/sensing", "collect",
  "seal", "verify". A proof is **collected** or **sealed**, never "minted",
  "dropped", or "claimed".
- FORBIDDEN in user-facing copy: "NFT", "token", "on-chain", "gas", "mint",
  "airdrop", "web3". Wallet copy says what the wallet does for the user
  ("sign your proofs"), not what protocol it speaks.
- Trust model: beid's whitepaper trust model is a pragmatic compromise and
  the product says so plainly where relevant — settings/about copy states
  what is and isn't cryptographically guaranteed, upfront, in one sentence.
  No overclaiming ("tamper-proof", "trustless") anywhere.
- Grammar: sentence case everywhere, including buttons ("Sense Event" is
  grandfathered until ratification; new CTAs use sentence case —
  `PROPOSAL — Ken ratification pending`). No exclamation marks. Present
  tense. Second person only when instructing.
- Error formula: what happened + why + one action. Model:
  "beid lost the connection to {event}. Move closer and we'll pick it back
  up automatically." + "Try Again".
- CTAs are verb-first and specific: "Start sensing", "Open Settings",
  "Connect wallet". FORBIDDEN as generic action labels: "OK", "Submit".
  "Continue" MAY be used where the next step is genuinely a continuation
  (multi-step onboarding), with a stated reason; never as a lazy default.

## 16. Agent Compliance Checklist

Copy-paste this into every UI PR description and check each item:

```md
## Design Compliance Checklist (DESIGN.md §16)

- [ ] No hardcoded colors, fonts, spacing, radii, or durations in Views (DS.* only).
- [ ] `scripts/lint.sh` passes. ("Passes" = zero violations beyond the checked-in baseline template `lint/baseline.template.json`. I did NOT regenerate the template to absorb new violations; if I migrated a scaffold file I regenerated it to shrink and said so in the PR.)
- [ ] All icon-only buttons have accessibility labels.
- [ ] All interactive targets are ≥ 44×44 pt.
- [ ] Light and dark previews attached (screenshots or #Preview variants).
- [ ] Dynamic Type checked at AX3 or larger — no clipped text.
- [ ] Empty/error/loading states implemented for new surfaces.
- [ ] No decorative SF Symbols > 32 pt; custom asset used or a TODO(asset) filed.
- [ ] State is never conveyed by color alone.
- [ ] Copy follows §15 (English source, String Catalog, vocabulary, no web3 jargon, error formula).
- [ ] Any deviation carries `DesignException: <rationale or link>`.
```

Enforcement layers:

1. **Lint-level**: `.swiftlint.yml` encodes five custom rules —
   `no_hardcoded_swiftui_color`, `no_hardcoded_swiftui_font`,
   `no_hardcoded_spacing`, `no_hardcoded_radius`,
   `no_hardcoded_animation` — activated via `only_rules: [custom_rules]`,
   with `match_kinds` excluding comments/strings. Known scaffold debt is
   recorded in the checked-in, violation-level baseline **template**
   `lint/baseline.template.json` (SwiftLint 0.65 baselines store absolute
   paths, so the template roots them at a `__REPO_ROOT__` placeholder;
   `scripts/lint.sh` materializes the gitignored
   `.swiftlint-baseline.json` for the current checkout and then runs
   swiftlint). The baseline suppresses exactly those recorded violations
   and nothing else, so any new violation — in an old file or a new one —
   is reported. **"No new violations" is computed as:** `scripts/lint.sh`
   reports zero violations. Regenerating the template to absorb new
   violations is FORBIDDEN; it may only be regenerated to *shrink* after
   a migration lands. Lint fixtures proving pass/fail behavior live in
   `lint-fixtures/` (see its README for the proof-run procedure).
   (Config + script only for now; CI wiring is a follow-up.)

   The lint layer intentionally catches the common ~80% of violations —
   direct call-site literals. The long tail is **review-level MUST**, not
   lint-covered: values laundered through expressions or variables
   (`CGFloat(16)`, `let pad = 20`), negative paddings, `cornerSize:`,
   animation curves inside `withAnimation { }` bodies or
   `Transaction(animation:)`, raw color/value strings inside string
   literals, decorative-symbol size (§12), the one-accent map (§5), hit
   targets, and Dynamic Type behavior. An honest 80% lint layer plus
   review beats a broken 100% regex.
2. **Review-level**: the checklist above.
3. **Exception process**: a PR that must deviate states
   `DesignException: <reason>` in its description and links the decision;
   silent deviations are rejected.

Known pre-existing violations: the current scaffold (all 13 screens)
predates this contract and violates §2.1/2.2/2.3 and §12 broadly. Migration
is the UI worker's phase 2; agents MUST NOT copy scaffold patterns into new
code, and MUST NOT "fix" scaffold views in unrelated PRs.

## 17. Appendices

### A. Token table (excerpt — canonical values live in Tokens.swift)

| Token | Swift | Value | Role |
| --- | --- | --- | --- |
| `color.surface.canvas` | `DS.Color.surfaceCanvas` | L `#F7F4EE` / D `#111315` | Root background |
| `color.signal.active` | `DS.Color.signalActive` | L `#18C7A7` / D `#62E8D0` | Live sensing |
| `color.proof.seal` | `DS.Color.proofSeal` | L `#6E5AEF` / D `#9D8CFF` | Sealed proof |
| `color.label.onWarning` | `DS.Color.labelOnWarning` | L `#1A1C1E` / D `#111315` | CTA label on `signalWarning` fill |
| `color.label.onSeal` | `DS.Color.labelOnSeal` | L `#FFFFFF` / D `#111315` | CTA label on `proofSeal` fill |
| `space.m` | `DS.Space.m` | 16 pt | Default gap |
| `radius.card` | `DS.Radius.card` | 16 pt | Cards |
| `layout.state.content.maxWidth` | `DS.Layout.stateContentMaxWidth` | 600 pt | Readable state-screen and CTA width in regular size classes |
| `layout.collection.content.maxWidth` | `DS.Layout.collectionContentMaxWidth` | 960 pt | Maximum collection width in regular size classes |
| `layout.grid.card.minimum.regular` | `DS.Layout.regularGridCardMinimumWidth` | 260 pt | Minimum proof-card width in regular grids |
| `layout.grid.card.minimum.compact` | `DS.Layout.compactGridCardMinimumWidth` | 150 pt | Minimum proof-card width in compact grids |
| `size.status.dot` | `DS.Size.statusDot` | 8 pt | `BeidStatusPill` dot diameter |
| `size.radar.field` | `DS.Size.radarField` | 210 pt | Sensing radar frame (`SensingView`) |
| `size.radar.core` | `DS.Size.radarCore` | 86 pt | Sensing radar center glyph (`SensingView`) |
| `size.proofCard.artwork` | `DS.Size.proofCardArtwork` | 76 pt | `ProofCardView` circular gradient-avatar diameter |
| `type.section.title` | `DS.Font.sectionTitle` | title3 semibold | State titles |
| `motion.proof.resolve` | `DS.Motion.proofResolve` | spring 0.6/0.8 | Seal ceremony |
| `color.status.on` | `DS.Color.statusOn` | L `#1E7E34` / D `#30D158` | Binary on/off status, "on" (Bluetooth active) |
| `color.status.off` | `DS.Color.statusOff` | L `#6B7075` / D `#83898F` | Binary on/off status, "off" (Bluetooth off) |

(Full set: 14 color tokens, 7 space, 4 radius, 5 size, 9 font, 5 motion,
plus 1 artwork generator — see `ios/Beid/DesignSystem/Tokens.swift`.)

### B. Asset inventory

Currently empty — no custom assets exist yet. First assets to produce
(priority order): `encounter-field-empty` (04b), `proof-seal-collected`
(07), `encounter-field-sensing` (05). Naming per §12.

### C. Decision log

| Date | Decision | Status |
| --- | --- | --- |
| 2026-07-09 | Initial contract authored (this document) | PROPOSAL — Ken ratification pending for all tagged values |
| 2026-07-09 | Palette anchors, motif names, tone thesis, type ramp | PROPOSAL — Ken ratification pending |
| 2026-07-09 | Token structure (DS namespace + xcassets), lint rules, section skeleton | Adopted (structural) |
| 2026-07-10 | Revision round 1 (GPT-Pro audit): lint activation via `only_rules: [custom_rules]` + TEMP-DEBT model, 5 lint rules, `DS.Artwork.proofCardGradient`, accent map + `actionPrimary`, Liquid Glass availability wording, illustrations/custom-symbol split, English-primary copy (String Catalogs) | Adopted (structural; PROPOSAL tags unchanged) |
| 2026-07 (Figma MTG) | Organizer mode, organizer thresholds, event-code rescue check-in, pre-check-in status transitions flagged as future surfaces (Koya Onodera comments on Minimal v4) | Recorded — out of scope for this slice, see §11 |
| 2026-07-10 | **Ken ratification**: (1) palette direction — deep ink + quiet teal (`#18C7A7` family) + violet proof seal; Figma Minimal v4 blue resolved against; (2) tone thesis "quiet field instrument" + all four motifs (Encounter Field / Proof Seal / Ledger Trace / Event Artifact) as-is; (3) locale set `en` + `ja`/`zh-Hans`/`es`/`fr`; (4) Japanese UI terms 検知 (Sensing) / 証明 (Proof), not team-internal センシング/証 | Ratified — PROPOSAL tags removed on these four areas; exact secondary hexes, type ramp, CTA sentence-case grandfathering remain PROPOSAL |
| 2026-07-10 | Revision round 2 (GPT-Pro re-audit, final): TEMP-DEBT path exclusions replaced by checked-in violation-level baseline (`.swiftlint-baseline.json`); regex FP fixes (blanket `.shadow(color:)` scoped, `minLength:` scoped to `Spacer(`, bare `duration:` branch dropped) and FN fixes (`Font.custom`, `.font(Font.…)`); long-tail patterns explicitly demoted to review-level MUST (§16); pinned SwiftLint + `lint-fixtures/` proof pair; `abs(seed)` → `seed.magnitude`; `DS.Motion.sensingPulse` sanctioned token; §2 lint claim scoped to common surface forms | Adopted (enforcement) |
| 2026-07-10 | Revision round 3 (Fable audit): SwiftLint 0.65 baselines store absolute paths, so the checked-in baseline is replaced by a portable template (`lint/baseline.template.json`, `__REPO_ROOT__` placeholder) + `scripts/lint.sh` that materializes the gitignored per-checkout `.swiftlint-baseline.json` and runs swiftlint; shrink-only policy governs the template | Adopted (enforcement) |
| 2026-07-12 | Proof-signing feature adds `DS.Color.statusCaution` (declined/timed-out/failed wallet-signature status, deliberately separate from `signalWarning`'s BLE-only scope) and documents `ProofCardView`'s "default only" states note as superseded by `ItemDetailView`/`ProofCollectedView` carrying the new signature states instead of the card itself | PROPOSAL — Ken ratification pending for the exact `statusCaution` hex values, same as other secondary hexes |
| 2026-07-27 | Account sheet reskin (Figma `104:463`, `docs/specs/account-redesign.md`) adds `DS.Color.statusOn`/`DS.Color.statusOff` (binary Bluetooth on/off status pair, deliberately separate from `signalWarning`'s BLE-signal-*quality*-only scope, `statusCaution`'s signature-failure-only scope, and `signalActive`'s reserved sensing-screen-accent scope), replacing `AccountSheetView`'s raw `.orange`/`.green` (Non-Negotiable #1 fix). `statusOn`'s hue is sourced from Figma's Bluetooth badge (`#34C759`) but darkened for light mode to clear WCAG AA text contrast (the raw Figma value measures ~2:1 on white, well under the 4.5:1 text minimum); `statusOff` has no Figma reference (Figma's mock never draws the "off" state) and uses a neutral gray pair instead of an alarm hue, since Bluetooth-off in the Account sheet is a neutral toggle state, not the degraded-signal alarm `signalWarning` already owns | PROPOSAL — Ken ratification pending for the exact `statusOn`/`statusOff` hex values, same as other secondary hexes |
| 2026-07-28 | Collection Home reskin (Figma `104:300`, `docs/specs/collection-redesign.md`) adds `DS.Size.proofCardArtwork` (76 pt) and wires the previously-unused `DS.Artwork.proofCardGradient(seed:)` into `ProofCardView` as a centered circular avatar, replacing the seal icon/checkmark/divider/Peers-verified row (peers count stays on `ItemDetailView`). Bottom "Sense Event" CTA becomes icon-only once proofs exist (labeled CTA retained on the 04b empty state per §3's first-run-discoverability rule); the existing localized "Sense Event" string is retained as the icon button's `.accessibilityLabel`, not removed. `CollectionHomeView`'s empty-state icon fixed to the 32 pt cap (see §12) | Adopted (no new PROPOSAL tag — reuses existing ratified tokens/artwork generator, no new color) |

### D. Deprecated patterns

Everything the scaffold does that new code must not repeat: `.tint(.blue)`
as brand accent, oversized decorative SF Symbols, `.font(.system(size:))`,
raw padding literals, `Color(hue:)` outside a designated artwork generator.
