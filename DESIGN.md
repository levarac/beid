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

**Proposal tags.** Brand-defining values in this document are marked
`PROPOSAL — Ken ratification pending`. Those values (tone thesis wording,
motif names, palette hex anchors, type ramp choice) are the author's proposal
and may be replaced wholesale in review. Structural and enforcement rules
carry no tag and are not pending.

---

## 0. Source of Truth

DESIGN.md documents **rules**; repo artifacts hold **values**.

| Artifact | Canonical for |
| --- | --- |
| `ios/Beid/DesignSystem/Tokens.swift` | The `DS` namespace: all color/space/radius/font/motion tokens |
| `ios/Beid/DesignSystem/Colors.xcassets` | Adaptive (light + dark) color values |
| `.swiftlint.yml` (repo root) | Enforcement rules for banned raw values |
| DESIGN.md (this file) | Semantics, usage rules, tone, review criteria |
| Figma "Minimal v4" board | Visual *reference* for screen layouts (01–09), not a value source |

Note on the Figma board: the mock (branded "SenseProof", an earlier name)
anchors a light minimal look with a blue, Bluetooth-centric accent. This
document's palette proposal (§5) deviates from that blue deliberately; both
are `PROPOSAL — Ken ratification pending`, and ratification decides. Layout
and flow in the Figma are authoritative reference; its colors are not
tokens.

- MUST: When this document and `Tokens.swift` disagree on a value, the code
  is right and this document has drifted — fix the document, and treat the
  drift as a bug.
- MUST: Token excerpts in this document are illustrative; never copy values
  from prose into code.
- FORBIDDEN: Raw color/font/spacing/radius/duration values anywhere in
  `ios/Beid/**` outside `ios/Beid/DesignSystem/`.

## 1. Product Design Thesis

`PROPOSAL — Ken ratification pending` (wording)

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

Agents can audit each of these mechanically.

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

`PROPOSAL — Ken ratification pending` (motif names and definitions)

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
   `DS.Space.m`, `DS.Font.sectionTitle`, `DS.Motion.proofResolve`). This is
   the only tier Views may use.
3. **Component conventions** — per-component token bindings documented in
   §10 (e.g. proof cards use `DS.Radius.card`).

Rules:

- MUST: New semantic tokens are added by editing `Tokens.swift` (+ a colorset
  in `Colors.xcassets` for colors) *and* the token table in §17 in the same PR.
- MUST: Token names describe role, not appearance (`signalActive`, not
  `tealAccent`).
- SHOULD: Prefer reusing an existing semantic token over minting a near-
  duplicate; mint a new one only when the *role* is genuinely new.
- MAY: Introduce a DTCG `tokens.json` upstream source later if design-tool
  sync becomes real; until then Swift + xcassets are canonical.

## 5. Color

`PROPOSAL — Ken ratification pending` (hex anchors; roles and structure are
not pending)

| Token | Light | Dark | Role | Allowed use | Forbidden use |
| --- | --- | --- | --- | --- | --- |
| `DS.Color.surfaceCanvas` | `#F7F4EE` | `#111315` | Root background | Screen roots, scroll backgrounds | Buttons, icons |
| `DS.Color.surfaceRaised` | `#FFFFFF` | `#1B1E20` | Cards, sheets | Proof cards, event cards, sheet surfaces | Full-screen backgrounds |
| `DS.Color.textPrimary` | `#1A1C1E` | `#ECEDEE` | Primary text | Titles, body | Decorative fills |
| `DS.Color.textSecondary` | `#5C6165` | `#9BA1A6` | Supporting text | Subtitles, metadata | Primary CTAs |
| `DS.Color.signalActive` | `#18C7A7` | `#62E8D0` | Live sensing signal | Sensing pulse, verifying progress, one key accent per scan screen | Body text, large fills |
| `DS.Color.signalWarning` | `#C7841A` | `#E8B562` | Degraded/lost signal | `SignalLostView`, `BluetoothOffView` accents | Errors that aren't signal-related |
| `DS.Color.proofSeal` | `#6E5AEF` | `#9D8CFF` | Sealed proof artifacts | Seal artwork, mint/verified moments, proof accents | Generic links, nav tint |
| `DS.Color.strokeHairline` | `#E3DFD6` | `#2A2E31` | Hairlines | Dividers, card strokes | Text |

Rules:

- MUST: Every color is an adaptive asset colorset (light + dark) exposed
  through `DS.Color.*`. High-contrast variants SHOULD be added to the same
  colorsets when the palette is ratified.
- MUST: At most **one** accent color per screen: `signalActive` during
  sensing, `proofSeal` at ceremony moments. Never both prominent at once.
- FORBIDDEN: The system default blue as brand accent (`.tint(.blue)` — the
  current scaffold's pattern; it is migration debt, not precedent).
- MAY: System semantic colors (`.primary`, `.secondary`, `Color(.systemRed)`)
  inside `DesignSystem/` as implementation details of a token — never
  directly in Views.
- Note: the per-proof generated gradient in `ProofCardView`
  (`Color(hue: seed)`) is a deliberate *data-driven* visual, not a token.
  It MUST move into `DesignSystem/` as a documented artifact generator when
  the proof-card artwork direction is ratified; until then it is a known
  exception, confined to `ProofCardView`.

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
| `DS.Font.cta` | `.headline` | Primary CTA labels | |

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
- MUST: Full-width primary CTAs sit at the bottom with horizontal padding
  `DS.Space.pageMargin` (the pattern in `WelcomeView`, `SignalLostView`,
  `ProofCollectedView`).
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
- Materials: deployment target is iOS 17, so Liquid Glass APIs (iOS 26) are
  not available. Use system materials (`.ultraThinMaterial` etc.) for
  overlay chrome. When the min target reaches iOS 26, standard controls
  adopt the new design automatically; custom glass MUST be deliberate
  (Beid-specific controls or proof moments), never decorative noise.
- FORBIDDEN: Faking glass with arbitrary blur rectangles.

## 9. Motion and Haptics

Motion is spring-first and interruptible. Springs are parameterized by
damping and response (`DS.Motion`), not fixed-duration curves.

| Token | Value | Use |
| --- | --- | --- |
| `DS.Motion.fast` | spring, response 0.25, damping 1.0 | Press feedback, small state flips |
| `DS.Motion.standard` | spring, response 0.35, damping 1.0 | Default transitions |
| `DS.Motion.entrance` | spring, response 0.5, damping 0.85 | Content entering (event card in `EventFoundView`) |
| `DS.Motion.proofResolve` | spring, response 0.6, damping 0.8 | Proof mint/seal ceremony |
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
  `DS.Color.textSecondary`. Artwork: seed-driven gradient (known exception,
  §5).
- States: default only (pending/failed proof states do not exist yet; when
  they do, they MUST pair color with a symbol per §2.9).
- Accessibility: entire card one element; label "Proof of {eventName},
  {date}".

### Component: ScanFlowView (phase container)

- Purpose: Full-screen cover hosting the sensing flow, switching on
  `SensingCoordinator.phase` (`ScanPhase`: idle/sensing → eventFound →
  verifying → verified → collected, with signalLost branch).
- Use when: The single entry point to sensing; presented via
  `fullScreenCover` from `RootView`.
- Don't use when: Anything else — there is exactly one scan flow.
- Rules: phase transitions animate with `DS.Motion.standard`; Cancel is
  always reachable in the toolbar; each phase view owns its content but not
  its chrome.

### Component: Sensing pulse (in SensingView)

- Purpose: The Encounter Field ambient indicator while scanning.
- Required tokens: `DS.Color.signalActive`, `DS.Motion.sensingPulsePeriod`.
- Rules: the only permitted `repeatForever` animation; MUST degrade under
  Reduce Motion (§9); center symbol needs `.accessibilityHidden(true)` with
  the state conveyed by the title text.

### Component: State screen (pattern shared by 01/02/03/06c/06d/07)

- Purpose: Icon/artwork → title → supporting text → optional bottom CTA.
  Used by `WelcomeView`, `BluetoothPermissionView`, `BluetoothOffView`,
  `VerifiedView`, `SignalLostView`, `ProofCollectedView`.
- Required tokens: `DS.Space.l` stack spacing, `DS.Space.pageMargin`
  margins, `DS.Font.sectionTitle`/`ceremonyTitle` + `DS.Font.supporting`,
  bottom CTA with `DS.Font.cta`.
- Rules: SHOULD be extracted into a shared `StateScreen` container when the
  UI worker migrates views (phase 2); until then new state screens copy the
  pattern exactly.

### Component: Detail meta row (detailRow in ItemDetailView)

- Purpose: Ledger Trace metadata (`Method`, `Peers verified`, `Status`).
- Required tokens: `DS.Font.supporting`, `DS.Color.textSecondary` label,
  `DS.Font.ledgerMono` for identifiers/addresses when they appear.
- Rules: status values pair text with color (`Verified` +
  `DS.Color.proofSeal`), never color alone.

### Component: Primary CTA button

- Purpose: The one main action per screen ("Get Started", "Sense Event",
  "Try Again", "Done").
- Rules: `.borderedProminent`, tinted with the screen's single accent
  (`signalActive` in scan contexts, `proofSeal` at ceremony, default accent
  elsewhere), label `DS.Font.cta`, full width inside `DS.Space.pageMargin`.
  Max one per screen.

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
  a clear exit (Cancel). Phase progression is linear; `SignalLostView`
  (06d) is the recovery branch and MUST always offer "Try Again".
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
  `BluetoothOffView`, `BluetoothPermissionView`, `WalletConnectView`,
  `CollectionHomeView` empty state ("tray" 48 pt).
- MUST: Custom illustrations go in an `Illustrations.xcassets` (to be added
  with the first real asset) with light/dark variants when colors are
  embedded; rendering `Original`.
- MUST: Tintable custom icons are single-color template assets, tinted only
  via `DS.Color.*`.
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
  "Connect wallet" — never "OK", "Continue", "Submit".

## 16. Agent Compliance Checklist

Copy-paste this into every UI PR description and check each item:

```md
## Design Compliance Checklist (DESIGN.md §16)

- [ ] No hardcoded colors, fonts, spacing, radii, or durations in Views (DS.* only).
- [ ] `swiftlint --config .swiftlint.yml` reports no new violations in files I touched.
- [ ] All icon-only buttons have accessibility labels.
- [ ] All interactive targets are ≥ 44×44 pt.
- [ ] Light and dark previews attached (screenshots or #Preview variants).
- [ ] Dynamic Type checked at AX3 or larger — no clipped text.
- [ ] Empty/error/loading states implemented for new surfaces.
- [ ] No decorative SF Symbols > 32 pt; custom asset used or a TODO(asset) filed.
- [ ] State is never conveyed by color alone.
- [ ] Copy follows §15 (vocabulary, no web3 jargon, error formula).
- [ ] Any deviation carries `DesignException: <rationale or link>`.
```

Enforcement layers:

1. **Grep-level**: the FORBIDDEN patterns in §2 are regex-detectable;
   `.swiftlint.yml` custom rules `no_hardcoded_swiftui_color` and
   `no_hardcoded_swiftui_font` encode the two highest-value ones.
   (Config only for now; CI wiring is a follow-up.)
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
| `space.m` | `DS.Space.m` | 16 pt | Default gap |
| `radius.card` | `DS.Radius.card` | 16 pt | Cards |
| `type.section.title` | `DS.Font.sectionTitle` | title3 semibold | State titles |
| `motion.proof.resolve` | `DS.Motion.proofResolve` | spring 0.6/0.8 | Seal ceremony |

(Full set: 8 color tokens, 7 space, 4 radius, 9 font, 5 motion — see
`ios/Beid/DesignSystem/Tokens.swift`.)

### B. Asset inventory

Currently empty — no custom assets exist yet. First assets to produce
(priority order): `encounter-field-empty` (04b), `proof-seal-collected`
(07), `encounter-field-sensing` (05). Naming per §12.

### C. Decision log

| Date | Decision | Status |
| --- | --- | --- |
| 2026-07-10 | Initial contract authored (this document) | PROPOSAL — Ken ratification pending for all tagged values |
| 2026-07-10 | Palette anchors, motif names, tone thesis, type ramp | PROPOSAL — Ken ratification pending |
| 2026-07-10 | Token structure (DS namespace + xcassets), lint rules, section skeleton | Adopted (structural) |
| 2026-07 (Figma MTG) | Organizer mode, organizer thresholds, event-code rescue check-in, pre-check-in status transitions flagged as future surfaces (Koya Onodera comments on Minimal v4) | Recorded — out of scope for this slice, see §11 |

### D. Deprecated patterns

Everything the scaffold does that new code must not repeat: `.tint(.blue)`
as brand accent, oversized decorative SF Symbols, `.font(.system(size:))`,
raw padding literals, `Color(hue:)` outside a designated artwork generator.
