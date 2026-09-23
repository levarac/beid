# Beid Design System Contract

This document is the design contract for all beid UI. It is written for two
audiences at once: human designers and AI coding agents. It covers all SwiftUI
UI in `ios/Beid/`, previews, empty states, in-app artwork, and the review
criteria applied to UI PRs.

**[This opening paragraph is itself the exact gap beid#339 was filed
over: it names "all beid UI" as scope in sentence one, then describes
coverage only in SwiftUI/`ios/Beid/` terms — the word "Android" appears
nowhere in it. Left as written per this task's instructions (existing
text is not reworded); see the new "Platform scope" note below and
`docs/decisions/issue-339-design-md-android-scope.md` for whether/how
Android's coverage gets stated here.]**

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

> **Annotation 2026-09-22 (owner decision, beid#627).** Flat 2b was
> adopted ([decision record](docs/decisions/issue-627-flat-2b.md)). The
> ratified palette direction is superseded (§5), and the type ramp
> PROPOSAL is superseded by Flat 2b's bundled families (§6). CTA sentence
> case is still `PROPOSAL` (#24; Open item 1). The tone thesis, the four
> motifs and the Japanese term decision were not overturned, although the
> locale set has since narrowed to `en` only (§15).

**Flat 2b (2026-09-22).** Where this document says "Superseded
2026-09-22", the old rule is quoted verbatim with its provenance and the
new rule follows. Every such block cites
[`docs/decisions/issue-627-flat-2b.md`](docs/decisions/issue-627-flat-2b.md)
(below: "D-627"), which also holds the numbered **Open items** referenced
throughout.

**Platform scope — open decision (beid#339).** Whether this contract binds
Android as written, or iOS is source-of-truth and Android follows/adapts,
is an owner decision that has **not** been made yet, and it is **not**
decided anywhere in this document. See
[`docs/decisions/issue-339-design-md-android-scope.md`](docs/decisions/issue-339-design-md-android-scope.md)
for the two options and their costs. Independent of how that decision
resolves, every section and rule below now carries one of three labels:
**Platform-neutral**, **iOS-specific mechanism — Android counterpart
named**, or **iOS-only as written — do not apply verbatim to Android**.
These labels classify what a rule's *content* says and whether an Android
mechanism exists for it today; they do not by themselves decide whether
Android is *held* to a "Platform-neutral" rule with the same MUST/FORBIDDEN
weight iOS is — that weighting is exactly the open decision above.

---

## 0. Source of Truth

> **Platform scope:** iOS-specific mechanism — Android counterpart named.
> The "rules vs. values" principle is platform-neutral; the table below
> names concrete iOS files, so each row gets its own Android counterpart
> immediately after it (verified against current Android source, not by
> analogy).
>
> **Flat 2b (2026-09-22):** the Flat 2b authority below binds iOS now
> (owner: iOS first). Android's theme files still implement the superseded
> values; that is not a violation until an Android follow-up is scheduled,
> and as of 2026-09-22 no Android Flat 2b issue exists. The bindingness
> question in `docs/decisions/issue-339-design-md-android-scope.md` is not
> decided by this change.

DESIGN.md documents **rules**; repo artifacts hold **values**.

**Flat 2b is the design authority (owner decision 2026-09-22, beid#626 /
beid#627, [D-627](docs/decisions/issue-627-flat-2b.md)).** Figma file
`xf2uFHceIYg0h0gJndUkmI` ("Beid - Native"):

- **Flat 2b — Library** (node `189-2`) is the authority for **values**:
  the color variable collection `Flat 2b / Color`, the text styles, and
  the components.
- **Flat 2b — Screens** (node `183-2`) is the authority for **layouts**
  (the spec lists 18 screens; 22 frames at the 2026-09-22 read, below).
- "Minimal v4" and the Liquid Glass-era "Fixed" page are historical input
  only.
- The product name is **beid**. "SenseProof" on the Flat 2b board and in
  its spec is the designer's mistake, not a rename (owner, 2026-09-22).

| Artifact | Canonical for |
| --- | --- |
| Figma "Flat 2b — Library" (`189-2`) | Design values: colors, text styles, components |
| Figma "Flat 2b — Screens" (`183-2`) | Screen layouts |
| `ios/Beid/DesignSystem/Tokens.swift` | The `DS` namespace: all color/space/radius/size/font/motion tokens and artwork generators — what ships, and the only place code reads values |
| `ios/Beid/DesignSystem/Colors.xcassets` | Color values: the 13 Library variables, each a single-appearance colorset named after its Library variable (since #628, §4/§5). The app-level appearance mechanism, the illustrations' dark variants and the previews are still #632's |
| `.swiftlint.yml` (repo root) | Enforcement rules for banned raw values |
| DESIGN.md (this file) | Semantics, usage rules, tone, review criteria |
| Figma "Minimal v4" board | Historical visual input only (superseded by Flat 2b, 2026-09-22) |

**Library → repository mapping.** DS token and component *names* are not
decided here: §4's rule (names describe role, not appearance) still
applies, so Library names such as `semantic/red` do not become `DS` names
verbatim.

| Library | Repository home | Decided in |
| --- | --- | --- |
| Color collection `Flat 2b / Color` (13 variables, §5) | `DS.Color` + `Colors.xcassets`; also the fate of the 8 old color tokens with no Flat 2b counterpart | #628 (names and fates: §5) |
| Text styles (Display / Title / Body / Label Mono, §6) | `DS.Font` + bundled font files | #629 |
| `Button/Primary` | SwiftUI primary-button component (replaces the §10 CTA pattern) | not assigned to an issue yet (none of #628–#644 names it) |
| `Row/List`, `Row/KeyValue`, `Label/Section` | SwiftUI row / key-value / section-label components | not assigned to an issue yet (none of #628–#644 names it) |
| `Block/Empty` | `BeidEmptyBlock` (`ios/Beid/DesignSystem.swift`), the dashed empty-state frame (§8) | #630 (2026-09-23) |
| `Bar/Nav` | Text-only navigation row | #631 |
| `Sigil/Mini` | The mini form of the Sigil generator | #633 |

Not components in the Library (raw nodes, spec §7): the sensing graph,
the window bar, the timeline bar, the stacked bar chart, the black
now-sensing card, the session row and the Account sheet. Their homes are
decided by #634 (graph, window bar), #635 (card), #639/#640 (timeline,
chart, session row) and #642 (sheet).

**What was read, and when.** Figma is not versioned in this repository,
so a later disagreement must be traceable to a Figma edit rather than
argued from memory. The file was read on **2026-09-22** through the
Figma API (`get_metadata` / `get_variable_defs`) while this change was
prepared:

- File key `xf2uFHceIYg0h0gJndUkmI`; "Flat 2b — Library" node `189-2`;
  "Flat 2b — Screens" node `183-2`.
- Library components (7): `Button/Primary` (Size=Large 354×56,
  Size=Small 140×52), `Row/List`, `Row/KeyValue`, `Block/Empty`,
  `Label/Section`, `Bar/Nav`, `Sigil/Mini`.
- Color variables: all 13 read directly; they match spec §3.1 exactly
  (listed in §5).
- Text styles observed under "Flat 2b/": Display/60, Display/46,
  Display/Number 40, Display/Address 34, Title/19, Title/17, Title/16,
  Title/15, Body/15, Body/13, Label/Mono 11, Label/Mono 10, Label/Mono 10
  tight, Label/Mono 9, Label/Mono 11 time. Families and weights match spec
  §3.2 (Bricolage Grotesque ExtraBold 800, DM Sans Bold 700 and Regular
  400, DM Mono Medium 500). Letter spacing matches (Mono 8, Mono 9 and 10
  tight 6, Mono 11 time 0; Display −2 / −1.5 / −1). **Not observed** in
  the frames read: Display/52 and Label/Mono 13 value; they are in the
  spec only. Line heights are not stated beyond the spec (the API reports
  mixed units).
- Screens: 22 top-level frames at read time, not 18 — the spec's 18 plus
  four under the heading "メニュー整理で追加した画面" (screens added in a
  menu reorganization): 04c Events — Clock warning, 05c Sensing — Signal
  Lost, 13 Enter Event Code, 14 Venue (iOS). Their existence does not
  settle #644.
- The live copy already differs from the spec copy in places. Both are
  recorded; neither is chosen here:
  - 06: the frame is named "06 Sensing — Sealed" and reads "SEALED · 6
    WINDOWS" / "Proof sealed · 10:00 – 10:30" (spec: "VERIFIED · 6
    WINDOWS").
  - 07: reads "SEALED · VERIFYING" (spec: "VERIFIED ON-CHAIN").
  - 09: still reads "TOKEN ID" and a STATUS value "Verified on-chain".
  - 10 Account Sheet: rows Bluetooth / Enter event code / How sensing
    works / What we send, a "VENUE · ORGANIZER" group (Broadcast this
    venue, Serve signed proofs), then Disconnect wallet, and a footer
    "SENSEPROOF 1.0 · 4C99036" (the spec has 3 rows).
  - 01 Welcome and 10's footer still show "SENSEPROOF" (the product name
    is beid; see above).
- The values in §5/§6 are unaffected: the Library values match the spec.
- `Block/Empty` (node `190:53`) was read again on **2026-09-23** through
  the Figma API for #630: stroke `line-dashed` (a variable alias), weight
  1, align INSIDE, dash pattern [4, 4]; corner radius 16; padding 24
  horizontal and 40 vertical; item spacing 10; no fills. Its
  component description: 「空状態ブロック。破線1px・角丸16。タイトルは等幅大文字、本文は2行まで。」
  `DS.Size.emptyBlockDash` (4) comes from this read.

The spec's own open questions (spec §10: window length, peer cap, the
Rejected report state, AVG SIGNAL display, the Account address typeface,
dark mode) are cross-referenced as **Open item 7** in D-627, owned by
#626 and the screen issues. None is decided here. If a Rejected state is
ever shown as red text on `bg`, it fails AA (3.41:1, §5).

**Android counterparts** (verified against
`android/app/src/main/kotlin/org/levarac/beid/ui/theme/` and
`ui/designsystem/`, 2026-09-07):

- `Tokens.swift`'s `DS` namespace → split across three files rather than
  one namespace: `ui/theme/Color.kt` (`BeidPalette` primitives +
  `BeidColorScheme`), `ui/theme/Spacing.kt` (`BeidSpacing`/`BeidRadius`/
  `BeidSize`), `ui/theme/Type.kt` (`BeidTypography`). Screens read through
  `BeidTheme.colors.*` (`ui/theme/Theme.kt`), the Compose analogue of `DS.*`
  usage.
- `Colors.xcassets`'s adaptive colorsets → no asset-catalog equivalent
  exists on Android. `BeidPalette` in `Color.kt` holds separate `*Light`/
  `*Dark` `Color(0x...)` constants, and `BeidAppTheme` in `Theme.kt`
  (`if (darkTheme) DarkBeidColors else LightBeidColors`) selects between
  them at composition time — a conditional branch, not a per-asset variant.
- `.swiftlint.yml` → **does not exist yet.** No detekt or ktlint
  configuration exists anywhere under `android/` as of this writing. See
  §16's new enforcement-asymmetry note below — this is not a missing-file
  detail, it is the same gap stated at the enforcement-layer level.
- DESIGN.md (this row) → itself platform-neutral, contingent on the open
  scope decision above.
- Figma "Minimal v4" board → iOS-only as written (see the note on the
  board immediately below); no Android-specific visual input exists in
  this document today.

> **Superseded 2026-09-22 (owner decision, beid#627,
> [D-627](docs/decisions/issue-627-flat-2b.md)).** Flat 2b replaces this
> note: the Library and Screens nodes above are now the authority, not
> historical input. "SenseProof" was never an earlier product name; it is
> the designer's mistake. Previously (authored in `14ebd53`, 2026-07-10,
> with the "historical visual input, not authority" wording from `b65d5c9`,
> 2026-08-08, both NAOE Kenichi; kept for history):
>
> Note on the Figma board: the mock (branded "SenseProof", an earlier name)
> anchors a light minimal look with a blue, Bluetooth-centric accent. This
> document's palette (§5) deviates from that blue deliberately; Ken resolved
> the tension **against** blue on 2026-07-10 (deep ink + quiet teal + violet
> seal adopted). Figma remains historical visual input, not authority for the
> current flow: ratified `docs/specs/` redesigns and the component/screen
> inventory in §§10–11 govern when they differ. Its colors are not tokens.

> **Platform scope:** iOS-only as written. This note is entirely about an
> iOS-only historical mock (SwiftUI-era naming, an iOS palette resolution);
> it makes no claim about Android and none is implied. See #104's
> discussion in `docs/decisions/issue-339-design-md-android-scope.md` for
> whether bringing Android into this document's scope changes that issue's
> reach.

> **Superseded 2026-09-22 (owner decision, beid#627,
> [D-627](docs/decisions/issue-627-flat-2b.md)).** `Tokens.swift` keeps
> the pre-Flat 2b values until #628 lands, so this rule cannot stand
> unchanged. Previously (initial contract, `14ebd53`, NAOE Kenichi,
> 2026-07-10; structural per §C):
>
> - MUST: When this document and `Tokens.swift` disagree on a value, the code
>   is right and this document has drifted — fix the document, and treat the
>   drift as a bug. **[Android counterpart: the same principle, against
>   Android's token homes — `Color.kt`/`Spacing.kt`/`Type.kt` — when this
>   document and those files disagree.]**

- MUST (transition): Until #628, #629, #630, #631 and #632 have landed,
  code that still carries superseded values or components is migration
  debt tracked in those issues, not evidence that this document drifted.
- MUST (steady state, confirmed 2026-09-22): The Flat 2b Library is the
  design authority for values. `Tokens.swift` is canonical for what ships
  and is the only place code reads values. A mismatch between the Library
  and `Tokens.swift` after the migration is a defect to file as an issue,
  not something resolved automatically in either direction. This document
  holds no values of its own, so a mismatch between this document and
  `Tokens.swift` is still fixed in the document.
- MUST: Token excerpts in this document are illustrative; never copy values
  from prose into code. **[Platform-neutral as a principle; applies
  identically once Android values are cited in this document.]**
- FORBIDDEN: Raw color/font/spacing/radius/duration values anywhere in
  `ios/Beid/**` outside `ios/Beid/DesignSystem/`. **[iOS-specific mechanism
  — Android counterpart: the equivalent path-shaped rule would be raw
  values anywhere in `android/app/src/main/kotlin/org/levarac/beid/**`
  outside `ui/theme/` and `ui/designsystem/`. Naming this rule for Android
  is a content classification only — §16's new note states plainly that no
  lint mechanism currently checks it there.]**

## 1. Product Design Thesis

> **Platform scope:** Platform-neutral. The thesis, the "MUST NOT feel
> like" list, and the guest-first wallet-optional requirement are product
> statements about the app, not about SwiftUI — nothing here names an
> iOS API or file.

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

> **Unresolved conflict, recorded 2026-09-22 (Open item 2,
> [D-627](docs/decisions/issue-627-flat-2b.md)).** The rule above is
> unchanged and still binds. The Flat 2b spec says login is WalletConnect
> only, and 01 Welcome has a single Connect Wallet CTA. This is a sixth
> MUST conflict that the 2026-09-22 owner decision did not name; it goes
> to the owner and is not resolved here (#642, #643, #644).

## 2. Non-Negotiables

> **Platform scope:** the *intent* behind every rule below is
> platform-neutral (tokens-not-literals, accessible hit targets, Dynamic
> Type, dark mode, labeled icons, color-plus-symbol, standard containers,
> a capped decorative-symbol size, a documented-exception process). Rules
> 1–4 and 11 name iOS APIs as their *current expression* — Android
> counterparts are named per-rule below. Rule 5's exact number is iOS-only
> as written (see below). None of rules 1–13 has any automated check on
> Android today (§16's new note); on iOS, rules 1–4 have lint plus the
> author's own review, rules 5–12 have only the author's own review, and
> rule 13 alone is test-backed (below) — the independent-review gate
> described later in this document is currently suspended repo-wide
> (AGENTS.md).

Rules 1–4 are lint-backed for their *common surface forms*
(`.swiftlint.yml` catches the direct call-site patterns — roughly the 80%
case); values reached through expressions, wrappers, or indirection are
review-level (§16 lists the known long tail). Rules 5–12 are review-level
checks against running UI, previews, or PR metadata — auditable, but not
by grep alone. Rule 13 is in neither category: it is **test-backed**.
`ios/BeidTests/SignalStrengthNeverRecordedTests.swift` (beid#652) goes red
if signal strength reaches persistence, signature input or the submission
payload. That test is the guard; rule 13 records what it guards, and this
document enforces nothing.

1. MUST: All colors in Views come from `DS.Color.*`. FORBIDDEN: `Color(red:`,
   `Color(hue:`, `Color(hex:`, `Color.white/.black/.blue/...`, shorthand
   member colors in `.tint(.blue)` / `.foregroundStyle(.orange)` / `.fill(.green)`,
   and `#RRGGBB` literals — anywhere outside `DesignSystem/`. **[Android
   counterpart: colors come from `BeidTheme.colors.*` (`ui/theme/Color.kt`);
   FORBIDDEN would be `Color(0x...)`/`Color(red = ...)`/Material default
   colors (`Color.White`, `MaterialTheme.colorScheme.*` used as a color
   source instead of `BeidTheme.colors.*`) outside `ui/theme/`. No lint rule
   enforces this on Android today — see §16.]**
2. MUST: All fonts in Views come from `DS.Font.*`. FORBIDDEN: `Font.system(`,
   `.font(.title3...)` shorthand, `.font(.custom(` outside `DesignSystem/`.
   **[Android counterpart: fonts come from `MaterialTheme.typography.*` as
   configured by `BeidTypography` (`ui/theme/Type.kt`); FORBIDDEN would be
   a literal `fontSize = N.sp`/`TextStyle(...)` constructed inline outside
   `ui/theme/`.]**
3. MUST: Spacing and padding use `DS.Space.*`. Numeric literals other than
   `0` and `1` (hairlines) in spacing/padding are FORBIDDEN outside
   `DesignSystem/`. **[Android counterpart: `BeidSpacing.*`
   (`ui/theme/Spacing.kt`); same `0`/`1.dp` hairline exception.]**
4. MUST: Corner radii use `DS.Radius.*`. **[Android counterpart:
   `BeidRadius.*` (`ui/theme/Spacing.kt`) — verified this file also carries
   `BeidRadius.glyph` (24dp). iOS has had the same `DS.Radius.glyph` (24)
   since #628 folded `BeidDesign.Radius.glyph` into `DS` (§8), so it is no
   longer an Android-only addition; the two radius sets still differ in
   iOS's `emptyBlock`/`nowCard` (§8).]**
5. MUST: Every interactive element has a hit region ≥ 44×44 pt
   (`DS.Size.minHitTarget`). **[iOS-only as written: 44×44pt is Apple's
   Human Interface Guidelines minimum, not a unit-converted number.
   Android's own platform accessibility minimum is 48×48dp (Material
   Design) — a different value, not the same value in different units.
   Android has no named token equivalent to `DS.Size.minHitTarget` today:
   `BeidPrimaryButton` hardcodes `heightIn(min = 52.dp)` and
   `BeidSecondaryButton` hardcodes `heightIn(min = 44.dp)`
   (`ui/designsystem/BeidButtons.kt`) — the secondary button's 44dp is
   below Android's own 48dp platform minimum, not just below a
   not-yet-ported iOS number. Flagged here as a discovered fact, not
   fixed — out of scope for this docs-only change.]**
   *Flat 2b note (2026-09-22): unchanged, and it binds the new text-only
   controls (`← EVENTS`, `CLOSE`, `COPY`, …) — an 11pt label still needs a
   44×44pt hit region (§12, #631).*
6. MUST: All text uses Dynamic Type-compatible fonts (every `DS.Font.*` role
   is built on text styles, not fixed sizes). **[Android counterpart: every
   `BeidTypography` role is a Material3 `TextStyle` reached via
   `MaterialTheme.typography.*`, which scales with the user's Android font
   size setting the same way Dynamic Type scales with iOS's — see
   `Type.kt`'s own role-mapping table.]**
7. MUST: Every screen renders correctly in the single Flat 2b appearance,
   whatever the OS dark-mode setting is; the app does not follow it (§14,
   #632).

   > **Superseded 2026-09-22 (owner decision, beid#627,
   > [D-627](docs/decisions/issue-627-flat-2b.md)).** Previously (initial
   > contract, `14ebd53`, NAOE Kenichi, 2026-07-10; structural per §C):
   >
   > 7. MUST: Every screen renders correctly in light and dark mode; all
   >    `DS.Color.*` tokens are adaptive asset colors. **[Android counterpart:
   >    the *outcome* (every screen correct in both modes) is platform-neutral;
   >    the *mechanism* differs — Android has no adaptive asset-catalog
   >    equivalent (see §0's new note above), so "adaptive asset colors" as
   >    written does not apply verbatim. Android's actual mechanism is
   >    `BeidAppTheme`'s `if (darkTheme)` branch over `LightBeidColors`/
   >    `DarkBeidColors` (`ui/theme/Theme.kt`).]**
8. MUST: Icon-only buttons have `.accessibilityLabel`. **[Android
   counterpart: `contentDescription` on the `Icon`/`IconButton`, e.g. the
   analogue of `CollectionHomeView`'s "person.crop.circle" account button
   needing "Account" as its accessibility label (§13).]**
   *Flat 2b note (2026-09-22): under Flat 2b there are no icon-only
   controls, so the labeling duty moves to text controls whose visible
   text reads badly aloud (e.g. "←") — see §12 and §13.*
9. MUST: State is never conveyed by color alone (verified/warning states pair
   color with a symbol and/or text). **[Platform-neutral principle;
   Android's `BeidStatusPill` already follows it — see §10.]**
   *Flat 2b note (2026-09-22): unchanged, and it binds the semantic status
   dots — every red/amber/green dot is paired with a text label (§5).*
10. MUST: Standard SwiftUI containers first — `NavigationStack`, `TabView`,
    `.sheet`, `.fullScreenCover`, `.alert`, `.confirmationDialog` — before
    any custom chrome. **[iOS-specific mechanism — Android counterpart:
    Compose Navigation (`NavHost`/`composable`, as `AppNavHost.kt` already
    uses), `AlertDialog`, `ModalBottomSheet` before custom chrome. Note:
    Android's current `AccountScreen` is a plain nav-graph destination
    (`Scaffold` + `Column`), not a `ModalBottomSheet` — see §11's Android
    note on the Account pattern for why this is a real shape difference,
    not just an unported detail.]**
11. FORBIDDEN: Decorative `Image(systemName:)` larger than 32 pt (see §12).
    **[iOS-specific mechanism — Android counterpart: the same 32pt/32dp cap
    on a decorative `Icon`/`ImageVector` — see §12's fuller treatment.]**
    *Flat 2b note (2026-09-22): the cap is moot under Flat 2b's no-icons
    rule (§12, #631); symbols still in code until #631 lands remain bound
    by it.*
12. MUST: Any deviation from this document links a decision record in the PR
    (`DesignException: <link or rationale>`). **[Platform-neutral process
    rule; not tied to any iOS API.]**
13. MUST: Signal strength (BLE RSSI) is
    **used for display only, never for any decision** (beid#652). It MAY
    reach the sensing-time drawing (§10's sensing-graph entry, #634) and
    nothing else. FORBIDDEN: signal strength — or any value derived from
    it — in records, in signature input, or in the submission payload.
    **[Android counterpart: none exists. Android is out of scope for
    beid#652 because the receiving branch does not exist there yet — there
    is no Android sensing graph for signal strength to be drawn in. Named,
    not left silent: whenever that branch is built, this constraint is what
    it has to satisfy.]**
    *Backed by `ios/BeidTests/SignalStrengthNeverRecordedTests.swift`
    (beid#652), which goes red if signal strength reaches persistence,
    signature input or the submission payload. The test is the primary
    guard; this rule is the second one, and it is second.*

## 3. Tone and Manner

> **Platform scope:** Platform-neutral for the motif *names and
> meanings*, the do/don't formula, and the voice-register principles —
> none of that is SwiftUI-specific. The "UI use" column and the voice
> registers below name concrete iOS view identifiers as *today's*
> instances of each motif; Android's current screen graph does not have
> one-to-one matching views for several of them (no dedicated
> `SensingView`/`EventFoundView`/`RecordingView`/`CollectionHomeView`/
> `ItemDetailView`/`AccountSheetView` — see §11's Android notes for the
> verified current shape). Treat the motif column as "where this idea
> currently lives on iOS," not as a claim that Android has a matching view
> by that name.

Adjectives don't constrain agents; named motifs do. Each motif names a
recurring visual idea, where it applies, and what it must not decay into.

Ratified (Ken, 2026-07-10) — all four motif names and definitions adopted
as-is.

| Motif | Meaning | UI use | Avoid |
| --- | --- | --- | --- |
| **Encounter Field** | Nearby people sensed over time | `SensingView` pulse rings, proximity/sensing states, scan-flow backgrounds | Radar/sonar clichés, sci-fi neon, spinning sweeps |
| **Proof Seal** | An encounter became durable | `RecordingView` entrance ceremony, proof card/detail artwork | Generic checkmark-only success, confetti |
| **Ledger Trace** | A verifiable record exists behind this artifact | Metadata rows in `ItemDetailView`, address row in `AccountSheetView`, monospaced identifiers | Blockchain jargon, wallet chrome, explorer-link prominence |
| **Event Artifact** | A proof is a collectible memory of a real event | `ProofCardView` cards, `CollectionHomeView` grid, event recap | NFT-marketplace aesthetics, price/rarity framing |

Concrete do/don't pair (the empty state of `CollectionHomeView`):

```
DO:
Empty state uses the `encounter-field-empty` Encounter Field asset,
title "No proofs yet",
body "Start sensing at an event to collect your first proof.",
CTA "Sense Event",
background DS.Color.surfaceCanvas.

DON'T:
Image(systemName: "tray") at 48 pt,
generic title "No data",
system blue accent,
or any wallet/crypto iconography.
```

**[Android note: no collection-home empty state exists yet on Android
(no `CollectionHomeView` counterpart — §11). Android's closest analogue,
`RecordsScreen`'s empty state, uses a plain centered `Text` with no icon
and no CTA at all (verified, `RecordsScreen.kt`) — it is not this do/don't
pair's target. Also note the CTA text itself: Android's actual join
button string is `"Join event"` (`event_join_button`,
`strings.xml`), not `"Sense Event"` — the two platforms do not currently
share this grandfathered string; see #24's treatment in
`docs/decisions/issue-339-design-md-android-scope.md`.]**

> **Annotation 2026-09-22 (Flat 2b, beid#627,
> [D-627](docs/decisions/issue-627-flat-2b.md)).** In the pair above, the
> `encounter-field-empty` asset, `DS.Color.surfaceCanvas` and the icon
> DON'T are superseded by 04b's dashed empty block (`NO EVENTS YET`; §8,
> §12; #635). The rest of the pair (specific title and body, no generic
> "No data", no system blue, no wallet/crypto iconography) still holds.
> The four motifs themselves are unchanged. **Open item 6:** the Flat 2b
> sensing graph's concentric rings sit next to Encounter Field's "avoid
> radar/sonar clichés"; that is open, not settled (#634).

Voice registers by moment:

- **Sensing** (`SensingView`, `EventFoundView`): calm, factual, present tense.
  "Sensing automatically." No exclamation marks.
- **Recording and proof entrance** (`RecordingView`): one short,
  declarative, slightly formal entrance moment ("Proof collected."), then
  calm factual recording status. Give the entrance one quiet moment of
  weight, not a celebration.
- **Recovery** (`SignalLostView`, `BluetoothOffView`): plain instructions,
  no blame, always a way forward.

**[Android note: the voice-register *principle* for each moment is
platform-neutral. Structurally, Android currently renders Sensing/
EventFound/Recording/SignalLost inside one screen
(`EventJoinScreen`'s `ScanPhaseDetail`, verified `EventJoinScreen.kt`)
rather than one view per moment, so "which screen this register applies
to" does not map view-for-view to iOS — see §11.]**

## 4. Token Architecture

> **Platform scope:** the three-tier *architecture* (primitive → semantic
> → component convention) is platform-neutral. The file names in tier 1
> and the "MUST edit `Tokens.swift`" rule are iOS-specific mechanism — see
> the Android counterparts below each. Android's three tiers verified
> present: primitives (`BeidPalette` in `Color.kt`), semantic tokens
> (`BeidTheme.colors.*`, `BeidSpacing`/`BeidRadius`/`BeidSize`,
> `BeidTypography`), component conventions (§10, e.g. `BeidPanel` uses
> `BeidRadius.card`).

Three tiers:

1. **Primitive values** — hex components in `Colors.xcassets`, numeric
   constants in `Tokens.swift`. Never referenced directly by Views. The
   color primitives are the 13 Flat 2b Library variables (§5), each stored
   as a single-appearance colorset named after its Library variable
   (`ink`, `bg`, `sub`, `line`, `lineDashed`, `tile`, `chartMuted`,
   `onInkSub`, `onInkLine`, `onInkIdle`, `semanticRed`, `semanticAmber`,
   `semanticGreen`; #628). Primitive names follow the Library rather than
   the role-naming rule below, because only `DS.Color` reads them.
   **[Android counterpart: `BeidPalette` in `ui/theme/Color.kt` — the
   `internal object` holding raw `Color(0x...)` constants, never referenced
   directly by screens (verified: screens read `BeidTheme.colors.*`, not
   `BeidPalette.*`).]**
2. **Semantic tokens** — the `DS.*` namespace (`DS.Color.statusOn`,
   `DS.Space.m`, `DS.Size.minHitTarget`, `DS.Font.sectionTitle`,
   `DS.Motion.proofResolve`, `DS.Artwork.proofCardGradient(seed:)`). This
   is the only tier Views may use. `DS.Color` names a role, and several
   roles may point at one primitive (`textPrimary` and `actionPrimary` are
   both `ink`; §5). **[Android counterpart:
   `BeidTheme.colors.signalActive`, `BeidSpacing.m`, `BeidTypography`'s
   roles via `MaterialTheme.typography.*`. Two gaps verified, not
   invented: Android has no named token equivalent to `DS.Size.minHitTarget`
   (§2 rule 5) and no motion-token namespace equivalent to `DS.Motion.*`
   exists under `ui/theme/` — Android's motion/spring usage (§9) is not
   yet centralized the way `DS.Motion` centralizes iOS's.]**
3. **Component conventions** — per-component token bindings documented in
   §10 (e.g. proof cards use `DS.Radius.card`). **[Android counterpart:
   the same §10 component list, e.g. `BeidPanel`/`BeidNumberedStepList`
   use `BeidRadius.card` — verified in `ui/designsystem/BeidPanel.kt` and
   `BeidNumberedStepList.kt`.]**

Rules:

- MUST: New semantic tokens are added by editing `Tokens.swift` (+ a colorset
  in `Colors.xcassets` for colors) *and* the token table in §17 in the same PR.
  **[Android counterpart: editing the relevant `ui/theme/*.kt` file (there
  is no per-color "colorset" step to mirror, since Android has no
  asset-catalog equivalent — see §0) and the §17 token table in the same
  PR — a rule this document does not yet state for Android because §17's
  table today has no Android column (see §17's own note below).]**
- MUST: Token names describe role, not appearance (`statusOn`, not
  `semanticGreen`). **[Platform-neutral naming principle; Android's existing
  names already follow it (`signalActive`, `actionPrimary`, etc. —
  verified `Color.kt`).]**
- SHOULD: Prefer reusing an existing semantic token over adding a near-
  duplicate; introduce a new one only when the *role* is genuinely new.
  **[Platform-neutral.]**
- MAY: Introduce a DTCG `tokens.json` upstream source later if design-tool
  sync becomes real; until then Swift + xcassets are canonical. **[iOS-only
  as written: names a specific future iOS-side format; no Android claim is
  made or implied.]**

## 5. Color

> **Platform scope:** iOS-specific mechanism — Android counterpart named.
> The palette direction, hex values, and role/allowed/forbidden semantics
> are platform-neutral content; "adaptive asset colorset" is an iOS-only
> mechanism (§0). Verified against `ui/theme/Color.kt`: Android's
> `BeidPalette`/`BeidColorScheme` port every row's exact light/dark hex
> pair of the superseded token table quoted below **except**
> `DS.Color.statusCaution`, which has **no Android counterpart** — it is
> simply absent from `BeidColorScheme`, not renamed or substituted. Since
> #628 (2026-09-23) iOS no longer has that table: its colors are the Flat
> 2b tokens below, and `statusCaution`, `signalActive`, `signalWarning`,
> `proofSeal`, `labelOnWarning`, `labelOnSeal` and `surfaceRaised` exist
> only on Android, under the superseded palette.
>
> **Flat 2b (2026-09-22):** the Flat 2b palette below binds iOS now (owner:
> iOS first). The Android statements above describe today's Android code,
> which still implements the superseded palette; that is not a violation
> until an Android follow-up is scheduled (none exists as of 2026-09-22).

**Flat 2b palette (owner decision 2026-09-22, beid#627,
[D-627](docs/decisions/issue-627-flat-2b.md)).** Principles (spec §2):

- **Black is "what is happening now"** — a state, not a theme. Sensing is
  full-screen black; on Home only the in-progress event is a black card;
  the Account sheet is black as the layer being operated.
- **Black, white and grays only**, plus **three semantic colors, each with
  one meaning**: red = destructive / off, amber = verifying / pending,
  green = active / on.
- **No per-event colors.** An event's identity is its Sigil's shape (§12,
  #633), never a hue.

Library variables (collection `Flat 2b / Color`). Hex values are
illustrative (§0: never copy values from prose into code). The primitive
colorset carries the Library variable's name (§4 tier 1); the DS tokens
are named by role (§4), so one variable may back several tokens (#628).

| Library variable | Hex | Role | Allowed use | Forbidden use | DS token |
| --- | --- | --- | --- | --- | --- |
| `ink` | `#0B0B0F` | Ink; the "now" ground | Text, primary button fill, black-screen ground, Sigil | Decorative fills unrelated to "now" | `textPrimary` (text and marks on the page ground); `actionPrimary` (`Button/Primary` Tone=Primary fill, app-level tint); `labelOnActionInverse` (label on an `actionInverse` fill) |
| `bg` | `#FFFFFF` | Page ground | Screen ground; text and Sigil on `ink` | — | `surfaceCanvas` (page ground); `labelOnActionPrimary` (label on an `actionPrimary` fill); `actionInverse` (`Button/Primary` Tone=Inverse fill, on black screens and the black sheet) |
| `sub` | `#6E6E78` | Secondary text on `bg` | Secondary text, section labels | Primary CTAs | `textSecondary` |
| `line` | `#ECECF1` | Hairline | 1px row and list dividers | Text | `strokeHairline` |
| `line-dashed` | `#C9C9CF` | Empty-state frame | Dashed 1px empty-block frame | Text | `strokeEmptyState` |
| `tile` | `#F2F2F4` | Gray tile | Timeline track, gray tiles | Text | `surfaceTile` |
| `chart-muted` | `#D9D9DE` | Chart "detected" | "Detected" bars in charts | Text | `chartDetected` |
| `on-ink/sub` | `#8E8E96` | Secondary text on `ink` | Secondary text on black | Text on `bg` | `textSecondaryOnInk` |
| `on-ink/line` | `#2A2A31` | Hairline on `ink` | Dividers, graph rings, future-window bars on black | Text | `strokeHairlineOnInk` |
| `on-ink/idle` | `#5C5C66` | Idle node on `ink` | Detected-only nodes on black | Text | `graphNodeIdle` |
| `semantic/red` | `#FF453A` | Destructive / off | Disconnect wallet; Bluetooth OFF dot | Any other meaning; text on `bg` | `statusOff` |
| `semantic/amber` | `#FF9F0A` | Verifying / pending | Report VERIFYING dot | Any other meaning; text on `bg` | `statusPending` |
| `semantic/green` | `#30D158` | Active / on | Bluetooth ACTIVE dot | Any other meaning; text on `bg` | `statusOn` |

That is 17 `DS.Color` tokens over 13 primitives. `surfaceCanvas`,
`textPrimary`, `textSecondary`, `strokeHairline` and `actionPrimary` kept
their names; `statusOn` and `statusOff` kept their names and took the
green and red values; the other ten are new.

**Removed by #628 (2026-09-23)** — old tokens with no Flat 2b counterpart,
and where their uses went:

- `signalActive` — Flat 2b has one ink and no motif accents, so screen
  tints use `actionPrimary`. Its one dot (`BeidStatusPill`
  `.sensingAutomatically`) uses `statusOn`: sensing is "active".
- `signalWarning` — screen tints use `actionPrimary`. Its dots:
  `BeidStatusPill` `.sensingPaused` uses `statusPending` (waiting for the
  signal to return; nothing was turned off); the venue radio's `.failed`
  uses `statusOff` (the radio is not transmitting; the paired text says
  why).
- `proofSeal` — tints use `actionPrimary`; text and icons use
  `textPrimary`. A sealed proof is none of on / pending / off.
- `statusCaution` — error text and warning icons use `textPrimary`: Flat
  2b has no "error" color, and red text on `bg` fails AA (3.41:1). The
  radio's `.waitingForBluetooth` dot uses `statusPending`; refusal and
  failure dots that are not an on / pending / off state use `textPrimary`.
- `labelOnWarning` — no warning fill remains; the CTA label is
  `labelOnActionPrimary`.
- `labelOnSeal` — it already had no call sites.
- `surfaceRaised` — its light value was `bg`'s, and Flat 2b has no raised
  elevation (§8); its one use takes `surfaceCanvas`.

`statusOn` and `statusOff`, the other two of the eight old tokens #628 had
to decide, were mapped rather than removed: they are now `semantic/green`
and `semantic/red`. Dots keep them; their text uses moved to
`textPrimary`, and `statusOff`'s neutral-gray "not yet available" text
moved to `textSecondary` (the old `statusOff` was already a neutral gray,
close to `sub`).

Contrast, **measured** (WCAG 2.x relative luminance, 2026-09-22; spec §9's
two stated figures are wrong — see D-627):

| Pair | Ratio | | Pair | Ratio |
| --- | --- | --- | --- | --- |
| `ink` on `bg` | 19.64:1 | | `semantic/red` on `ink` | 5.77:1 |
| `sub` on `bg` | 5.04:1 | | `semantic/amber` on `ink` | 9.56:1 |
| `sub` on `tile` | 4.51:1 | | `semantic/green` on `ink` | 9.72:1 |
| `on-ink/sub` on `ink` | 6.04:1 | | `semantic/red` on `bg` | 3.41:1 |
| `ink` on `tile` | 17.57:1 | | `semantic/amber` on `bg` | 2.06:1 |
| | | | `semantic/green` on `bg` | 2.02:1 |

Rules:

- MUST: Only the Library colors above, through the `DS.Color.*` tokens
  named in the table. No per-event or per-proof hue.
- MUST: A semantic color is used only for its one meaning.
- MUST (forced by §13's AA MUST, which is unchanged): semantic colors are
  **indicators**. A semantic color may be **text only on `ink`**, where it
  passes AA (e.g. "Disconnect wallet" in red on the black Account sheet).
  On `bg` it is a non-text indicator — a dot — always paired with a text
  label (§2 rule 9). Amber and green dots on `bg` are also under 3:1, so
  the paired text carries the meaning.
- Call sites follow this as **dots carry color, words carry meaning**:
  `statusOn`, `statusPending` and `statusOff` color a status dot (or a
  shape standing in for one) and never text on `bg`; the word beside the
  dot uses `textPrimary` or `textSecondary`. They may color text only on
  `ink`, where the ratios above pass §13's AA MUST.
- MUST: The primary CTA is an `ink` fill with a `bg` label (§10,
  `Button/Primary` Tone=Primary): `actionPrimary` with
  `labelOnActionPrimary`.
- `sub` on `tile` passes AA with almost no margin (4.51:1); a change to
  either value puts §13's AA MUST at risk.
- Open item 4 (D-627): `chart-muted` bars on `bg` (1.41:1) and
  `on-ink/idle` nodes on `ink` (2.97:1) are under WCAG 1.4.11's 3:1 for
  non-text. Recorded; no new rule (#634, #640).

> **Superseded 2026-09-22 (owner decision, beid#627,
> [D-627](docs/decisions/issue-627-flat-2b.md)).** The ratified palette
> direction and the token table below are replaced by the Flat 2b palette
> above. The direction was added in `8076f04` (NAOE Kenichi, 2026-07-10)
> and has an explicit §C "Ken ratification" row (2026-07-10); the table's
> structure dates from the initial contract (`14ebd53`) and its secondary
> hexes stayed `PROPOSAL`. Overturned on the owner's authority without
> Ken's sign-off; Ken is to be informed afterwards. The table still
> describes today's `Tokens.swift`/`Colors.xcassets` and is migration debt
> until #628. Previously:
>
> Direction ratified (Ken, 2026-07-10): deep ink background + quiet teal
> (`#18C7A7` family) + violet proof seal — the Figma Minimal v4 blue is
> resolved **against**. Exact secondary hex values (surfaces, text, hairline,
> `actionPrimary`, dark variants) remain
> `PROPOSAL — Ken ratification pending`; roles and structure are not pending.
>
> | Token | Light | Dark | Role | Allowed use | Forbidden use |
> | --- | --- | --- | --- | --- | --- |
> | `DS.Color.surfaceCanvas` | `#F7F4EE` | `#111315` | Root background | Screen roots, scroll backgrounds | Buttons, icons |
> | `DS.Color.surfaceRaised` | `#FFFFFF` | `#1B1E20` | Cards, sheets | Proof cards, event cards, sheet surfaces | Full-screen backgrounds |
> | `DS.Color.textPrimary` | `#1A1C1E` | `#ECEDEE` | Primary text | Titles, body | Decorative fills |
> | `DS.Color.textSecondary` | `#5C6165` | `#9BA1A6` | Supporting text | Subtitles, metadata | Primary CTAs |
> | `DS.Color.actionPrimary` | `#2A2E33` | `#E8EAEC` | Neutral primary action | CTA tint on screens with no motif accent; app-level accent | Motif moments (sensing/ceremony/recovery) |
> | `DS.Color.signalActive` | `#18C7A7` | `#62E8D0` | Live sensing signal | Sensing pulse, event-found state, one key accent per sensing screen | Body text, large fills |
> | `DS.Color.signalWarning` | `#C7841A` | `#E8B562` | Degraded/lost signal | `SignalLostView`, `BluetoothOffView` accents | Errors that aren't signal-related |
> | `DS.Color.proofSeal` | `#6E5AEF` | `#9D8CFF` | Sealed proof artifacts | Recording/proof entrance, seal artwork, proof accents | Generic links, nav tint |
> | `DS.Color.labelOnWarning` | `#1A1C1E` | `#111315` | CTA label on `signalWarning` fill | Prominent-button labels on recovery screens | Anything except labels sitting on a `signalWarning` fill |
> | `DS.Color.labelOnSeal` | `#FFFFFF` | `#111315` | CTA label on `proofSeal` fill | Prominent-button labels at ceremony moments | Anything except labels sitting on a `proofSeal` fill |
> | `DS.Color.strokeHairline` | `#E3DFD6` | `#2A2E31` | Hairlines | Dividers, card strokes | Text |
> | `DS.Color.statusCaution` | `#B23A2E` | `#E2897C` | Non-signal caution/error state | Declined/timed-out/failed wallet-signature status (`ItemDetailView` signature controls) | BLE signal issues (use `signalWarning` instead) |
> | `DS.Color.statusOn` | `#1E7E34` | `#30D158` | Binary on/off status, "on" | Bluetooth-active badge (`AccountSheetView`) | BLE signal quality (use `signalWarning`), wallet-signature status (use `statusCaution`), sensing-screen accent (use `signalActive`) |
> | `DS.Color.statusOff` | `#6B7075` | `#83898F` | Binary on/off status, "off" | Bluetooth-off badge (`AccountSheetView`) | Same as `statusOn`'s forbidden uses — this pair is for a neutral toggle state only, not an alarm |

- MUST: Colors are single-appearance values (§14); the app does not follow
  the OS dark-mode setting. The colorsets have had no dark variants since
  #628; how the app stops following the OS setting, and what happens to
  the illustrations' dark variants and the previews, is #632's choice.

> **Superseded 2026-09-22 (owner decision, beid#627,
> [D-627](docs/decisions/issue-627-flat-2b.md)).** Previously (initial
> contract, `14ebd53`, NAOE Kenichi, 2026-07-10; structural per §C):
>
> - MUST: Every color is an adaptive asset colorset (light + dark) exposed
>   through `DS.Color.*`. High-contrast variants SHOULD be added to the same
>   colorsets when the palette is ratified. **[iOS-only mechanism as
>   written — Android has no colorset to add to (§0). Android counterpart:
>   every color is a `*Light`/`*Dark` pair in `BeidPalette`, exposed through
>   `BeidTheme.colors.*`; a future high-contrast pass would add variant
>   fields to `BeidColorScheme` rather than a colorset.]**

- Flat 2b has no motif accents: there is one ink, and the three semantic
  colors each carry one meaning (above).

> **Superseded 2026-09-22 (owner decision, beid#627,
> [D-627](docs/decisions/issue-627-flat-2b.md)).** Previously (revision
> round 1, `79cd005`, NAOE Kenichi, 2026-07-10; §C status "Adopted
> (structural; PROPOSAL tags unchanged)"). Today's code still applies this
> map; it is migration debt until #628:
>
> - MUST: Exactly **one** motif accent per screen, mapped by moment:
>   `signalActive` on sensing screens (`SensingView`, `EventFoundView`),
>   `proofSeal` on `RecordingView` and proof artwork, `signalWarning` on
>   recovery screens (`SignalLostView`, `BluetoothOffView`). Screens outside these moments
>   (onboarding, home, account) have **no** motif accent — their CTAs and
>   controls tint with `DS.Color.actionPrimary`. **[The one-accent-per-screen
>   principle is platform-neutral; the named views are iOS's current screen
>   graph, not Android's — see §11's Android notes. Verified consistent with
>   the principle: Android's `BluetoothOffScreen` passes `signalWarning`/
>   `labelOnWarning` explicitly to every warning-accented element on that
>   screen (`BluetoothOffScreen.kt`'s own kdoc explains this is because
>   Compose has no ambient `.tint()` to inherit from, unlike SwiftUI).]**

Rules carried over from before Flat 2b (still in force; the token names
they cite are the current ones, since #628):

- MUST NOT: System default blue as an *implicit fallback* — every tintable
  control gets an explicit `DS.Color.*` tint, and the app-level accent is
  `actionPrimary`. FORBIDDEN: `.tint(.blue)` (a retired scaffold pattern,
  not precedent). **[Android counterpart: no default Material3 blue as an
  implicit fallback; `BeidAppTheme`'s `lightColorScheme`/`darkColorScheme`
  already wire `primary = beidColors.actionPrimary` explicitly
  (`Theme.kt`), consistent with this rule as verified today — not a gap.]**
- MAY: System semantic colors (`.primary`, `.secondary`, `Color(.systemRed)`)
  inside `DesignSystem/` as implementation details of a token — never
  directly in Views. **[Android counterpart, as a principle: Material3
  semantic colors (`MaterialTheme.colorScheme.*`) MAY appear inside
  `ui/theme/`/`ui/designsystem/` as a token's implementation detail, never
  directly in `ui/screens/`.]**
- MUST: Prominent CTA labels never rely on the button style's default
  white. Label pairing per fill (see `BeidPrimaryButton`, whose default
  label color is `labelOnActionPrimary`): `actionPrimary` →
  `labelOnActionPrimary` (`Button/Primary` Tone=Primary), `actionInverse`
  → `labelOnActionInverse` (Tone=Inverse). A new fill MUST add its on-fill
  label token first. Any fill value change MUST re-check ≥4.5:1
  label-on-fill contrast in the single appearance (§14).
  **[Android already has a component of the same name: `BeidPrimaryButton`
  (`ui/designsystem/BeidButtons.kt`) requires `containerColor`/
  `contentColor` as non-defaulted parameters, for the same "no default
  tint" reason stated in its own kdoc — verified consistent with this rule
  today.]**

  > **Superseded by #628 (2026-09-23).** `proofSeal`, `signalWarning`,
  > `signalActive`, `labelOnSeal` and `labelOnWarning` were removed (above),
  > so the pairings that named them no longer describe any fill. The
  > principle (explicit label color, never the style default) is unchanged.
  > Previously (verbatim, with its 2026-09-22 Flat 2b note):
  >
  > Label pairing per fill (see `BeidPrimaryButton`):
  > `actionPrimary` → `surfaceCanvas` (fill inversion), `proofSeal` →
  > `labelOnSeal`, `signalWarning` → `labelOnWarning`. `signalActive` is a
  > sanctioned CTA tint per the §10 accent map but no sensing screen has a
  > primary CTA today — whoever introduces one MUST add its on-fill label
  > token first (ink-style measures ~8:1/12:1; the inversion default fails
  > at ~2:1). Any fill hex change (including ratifying this PROPOSAL
  > palette) MUST re-check ≥4.5:1 label-on-fill contrast in both modes.
  >
  > *Flat 2b note (2026-09-22): the principle (explicit label color, never
  > the style default) stands. Under Flat 2b the only primary-CTA pairing is
  > `ink` fill → `bg` label; the `proofSeal`/`signalWarning`/`signalActive`
  > pairings describe today's code and are migration debt until #628. "In
  > both modes" now means the single appearance (§14).*
- MUST: A proof's appearance is its **Sigil**, drawn deterministically
  from observation data, with no image assets (spec §5; #633). Same data,
  same Sigil.
- Migration debt: until #633 lands the Sigil,
  `DS.Artwork.proofCardGradient(seed:)` stays in `Tokens.swift` as the only
  home of `Color(hue:)`. It MUST NOT be extended, copied, or given new call
  sites; #633 removes it once the Sigil works.

> **Superseded 2026-09-22 (owner decision, beid#627,
> [D-627](docs/decisions/issue-627-flat-2b.md)).** Previously (revision
> round 1, `79cd005`, NAOE Kenichi, 2026-07-10; §C status "Adopted
> (structural; PROPOSAL tags unchanged)"):
>
> - The per-proof generated gradient is a *data-driven* artwork generator,
>   not a token: `DS.Artwork.proofCardGradient(seed:)` in `Tokens.swift` is
>   its canonical home and the only sanctioned source of `Color(hue:)`.
>   `ProofCardView` and `ItemDetailView` call that generator directly; a local
>   copy of the same math would reintroduce the retired scaffold debt.
>   **[iOS-only as written today: no artwork-generator equivalent exists
>   under `ui/theme/`/`ui/designsystem/` — verified no `hue`/gradient
>   generator anywhere in `android/app/src/main/kotlin`. This is a missing
>   mechanism, not a renamed one; §10's `ProofCardView`/`ItemDetailView`
>   entries have no Android screen to point at yet either (no Android
>   `CollectionHomeView`/`ItemDetailView`, per §11).]**

## 6. Typography

> **Platform scope:** iOS-specific mechanism — Android counterpart named.
> The ramp's *roles* and constraints are platform-neutral; `DS.Font`
> itself is an iOS namespace. `ui/theme/Type.kt`'s own kdoc already states
> a role-for-role Material3 mapping, verified below.
>
> **Flat 2b (2026-09-22):** the Flat 2b ramp binds iOS now. Android's
> `BeidTypography` (system fonts) implements the superseded ramp; not a
> violation until an Android follow-up is scheduled (none exists as of
> 2026-09-22).

**Flat 2b type (owner decision 2026-09-22, beid#627,
[D-627](docs/decisions/issue-627-flat-2b.md)).** Three families, all
Google Fonts under the SIL Open Font License, bundled with the app
(#629):

- **Bricolage Grotesque ExtraBold** — display (titles, numbers, the
  Account address).
- **DM Sans** Bold / Regular — titles and body.
- **DM Mono** Medium — labels.

Ramp (Library text styles "Flat 2b/…"; sizes are **base sizes at the
default content size**; see the Dynamic Type rules below). Values from
spec §3.2; §0 records which styles were observed in Figma.

| Library style | Family | Base size | Tracking | Line height | Role |
| --- | --- | --- | --- | --- | --- |
| Display/60 | Bricolage Grotesque ExtraBold | 60 | −2% | 100% | Home title "Events" |
| Display/52 | 〃 | 52 | −2% | 100% | Onboarding titles (spec only; not observed in Figma, §0) |
| Display/46 | 〃 | 46 | −1.5% | 100% | Screen titles (event name, Session 1, Report #2, Proof collected) |
| Display/Number 40 | 〃 | 40 | −1% | auto | Sensing figures |
| Display/Address 34 | 〃 | 34 | −1% | auto | Account sheet address (typeface open: spec §10-5, #642) |
| Title/19 · 17 · 16 · 15 | DM Sans Bold | 19–15 | 0 | auto | Row titles, buttons, key-value values |
| Body/15 · 13 | DM Sans Regular | 15 / 13 | 0 | 140% | Body copy |
| Label/Mono 11 · 10 · 9 | DM Mono Medium | 11 / 10 / 9 | +8% (9: +6%) | auto | **Uppercase.** Section labels, nav, meta, status |
| Label/Mono 10 tight | DM Mono Medium | 10 | +6% | auto | In-row meta (IDs, session numbers) |
| Label/Mono 11 time · 13 value | DM Mono Medium | 11 / 13 | 0 | auto | Times, addresses, ID values (13 value: spec only, §0) |

Flat 2b rules:

- MUST: Every Flat 2b style is defined in `DS.Font` with
  `Font.custom(_:size:relativeTo:)`, so the base size scales with a text
  style. `Font.custom` stays inside `DesignSystem/` (§2 rule 2). That
  constraint governs app code; the test target may construct a comparison
  font, which is how #629 asserts that a Display style stays on a flatter
  curve than `.body` (it is the only way to build the same face on a
  different curve).
- **Text styles (#629, 2026-09-23).** Each style takes the Apple text
  style whose *default* size is nearest its base size, so the Dynamic Type
  multiplier starts near 1: Title/19 → `.title3`, 17 → `.headline`, 16 →
  `.callout`, 15 → `.subheadline`; Body/15 → `.subheadline`, 13 →
  `.footnote`; Label/Mono 13 value → `.footnote`, and Mono 11, 11 time, 10,
  10 tight and 9 → `.caption2`. **Every Display style is the exception: all
  five take `.largeTitle`**, the flattest accessibility curve available.

  What `UIFontMetrics.scaledValue` actually does (measured on iOS 26.5, and
  *not* what an earlier draft of this bullet claimed): for a given (text
  style, content size category) it applies a **single constant multiplier**
  to any base size, quantised to 1/3 pt. That multiplier is **not** the
  ratio of the text style's own preferred sizes — `.largeTitle`'s own size
  goes 34 → 52 at AX3, a ratio of 1.53, while the multiplier it scales by
  is about 1.49. Measured at AX3: `.largeTitle` about 1.49, `.body` about
  2.18, `.caption2` about 2.69. The multiplier falls as the text style's
  own size rises, which is why `.largeTitle`, the largest text style, is
  the flattest curve available. (Only those three styles were measured;
  the trend is stated, not measured, for the rest of the ramp.)

  Consequence, measured on iOS 26.5: Display/60 reaches **89.33 pt at AX3**
  and **102.33 pt at AX5**. The same 60 pt on `.body`'s curve would reach
  **131.0 pt at AX3** and **169.0 pt at AX5**, which the AX3 MUST below
  would not survive.
- MUST: Mono labels are uppercase (spec §3.2). In code this is the three
  *label* styles only — Mono 11, 10 and 9. The three *value* styles (Mono
  13 value, 11 time, 10 tight) are deliberately not uppercased: they carry
  addresses, times and IDs, and an EIP-55 address encodes its checksum in
  the letter case of its hex digits, so uppercasing one is a correctness
  bug, not a style choice (#629). Whether buttons are uppercase is still
  open — §15, #24, Open item 1 (D-627); #629 uppercases no string that
  exists today, so #24 is untouched.
- **Tabular figures (#629, 2026-09-23):** `Display/Number 40` only. Those
  are the digits that change while someone is watching them, and
  proportional digits make the figure jitter sideways as it counts. DM Mono
  needs no such setting — it is already monospaced — and no other style
  displays a live number.
- **Language (owner decision 2026-09-22, settled item B in D-627):** the
  UI is English-only, so the three families having no Japanese glyphs is
  not a gap. This matches the existing locale policy — target locales are
  `en` only since the owner decision of 2026-08-21
  (`docs/localization-process.md`), and `ios/Beid/Localizable.xcstrings`
  holds `en` only. It is not a new policy, and it does not relax §15's
  String Catalog MUST.
- The Dynamic Type and AX3 MUSTs below are unchanged and bind the bundled
  fonts. Flat 2b's row and button heights (spec §3.3: list row 92, KV 44,
  session 48, report 60, proof 72, primary button 56) are **minimum**
  heights, because fixed-height containers around text remain FORBIDDEN.

> **Superseded 2026-09-22 (a PROPOSAL, not an overturned rule;
> [D-627](docs/decisions/issue-627-flat-2b.md)).** The ramp line below was
> never ratified; Flat 2b replaces it. Previously (initial contract,
> `14ebd53`, NAOE Kenichi, 2026-07-10):
>
> `PROPOSAL — Ken ratification pending` (ramp choice: system SF Pro + SF Mono
> for ledger traces; no custom brand font in this phase)

Current code (2026-09-23, #629 landed — `DS.Font` is two tiers, the same
shape #628 gave `DS.Color`; §4). Tier 1 is `DS.Font.Library`: 17
`DS.Font.Style` constants, one per ramp row above, named after the Library
because only `DS.Font` reads them. Tier 2 is the eight role tokens Views
use. `DS.Font.Style` carries the face's PostScript name, the base size, the
text style, tracking, line height, case and tabular digits.

Tier 1 — `DS.Font.Library` (base size and text style; families, tracking
and line heights are the ramp table above):

| Library style | `DS.Font.Library` | Base size | Text style |
| --- | --- | --- | --- |
| Display/60 | `display60` | 60 | `.largeTitle` |
| Display/52 | `display52` | 52 | `.largeTitle` |
| Display/46 | `display46` | 46 | `.largeTitle` |
| Display/Number 40 | `displayNumber40` | 40 | `.largeTitle` (tabular digits) |
| Display/Address 34 | `displayAddress34` | 34 | `.largeTitle` |
| Title/19 | `title19` | 19 | `.title3` |
| Title/17 | `title17` | 17 | `.headline` |
| Title/16 | `title16` | 16 | `.callout` |
| Title/15 | `title15` | 15 | `.subheadline` |
| Body/15 | `body15` | 15 | `.subheadline` |
| Body/13 | `body13` | 13 | `.footnote` |
| Label/Mono 11 | `labelMono11` | 11 | `.caption2` (uppercase) |
| Label/Mono 10 | `labelMono10` | 10 | `.caption2` (uppercase) |
| Label/Mono 9 | `labelMono9` | 9 | `.caption2` (uppercase) |
| Label/Mono 10 tight | `labelMono10Tight` | 10 | `.caption2` |
| Label/Mono 11 time | `labelMono11Time` | 11 | `.caption2` |
| Label/Mono 13 value | `labelMono13Value` | 13 | `.footnote` |

Tier 2 — the roles Views use. Names and call sites are unchanged from the
superseded SF Pro ramp; #629 re-pointed them, so no View changed:

| Token | Library style | Role | Constraint |
| --- | --- | --- | --- |
| `DS.Font.screenTitle` | `display46` | Screen title | Max one per screen |
| `DS.Font.sectionTitle` | `title19` | State/section titles | |
| `DS.Font.cardTitle` | `title17` (the Library's `Row/List` title) | Card and row titles | `lineLimit(1)` + truncation on cards |
| `DS.Font.body` | `body15` | Body copy | |
| `DS.Font.supporting` | `body13` | Supporting copy | Pair with `textSecondary` |
| `DS.Font.meta` | `body13` | Dates, counts, fine print | Deliberately not a mono label style — see below |
| `DS.Font.ledgerMono` | `labelMono13Value` | Addresses, hashes, proof IDs | Ledger Trace motif only; never uppercased |
| `DS.Font.cta` | `title16` (the Library's `Button/Primary` label) | Primary CTA labels | Label color per §5's CTA-label rule (never the style default white) |

`meta` is `Body/13`, not a mono label style, on purpose: the Library's mono
labels are uppercase, and `meta`'s 44 call sites carry sentence-case copy
that #629 does not re-author. A mono meta role belongs with the screen
issues.

**TRANSITIONAL GAP (#629, 2026-09-23).** A role token is a
`SwiftUI.Font`, so a plain `.font(DS.Font.body)` call site — which is every
call site today — gets **family, size, Dynamic Type and tabular figures,
and none of tracking, line height or case**. Those three reach a view only
through `beidTextStyle(_:)`, the full-style modifier in `Tokens.swift`,
which the screen issues adopt. Concretely: `screenTitle`'s −1.5% tracking
and Body's 140% line height are **not** applied at today's call sites, and
no mono label is uppercased today because no role points at one. This is a
known, named gap, not a claim that the ramp is fully wired.

**Display 100% line-height gap (#629, 2026-09-23).** Display/60 · 52 · 46
ask for a 100% line height, but Bricolage Grotesque's own line height is
1.2 em (hhea 930/−270 over 1000 upem), so 100% needs *negative* extra
spacing. SwiftUI's only line-height control on this deployment target
(iOS 17) is `View.lineSpacing(_:)`, which writes
`EnvironmentValues.lineSpacing` and is additive; UIKit documents the
underlying `NSParagraphStyle.lineSpacing` as "always nonnegative"
(`NSParagraphStyle.h`, iPhoneSimulator27.0 SDK). A real line-height API
exists — `View.lineHeight(_:)` taking `AttributedString.LineHeight`, in
`SwiftUICore.swiftinterface` — but it is `@available(iOS 26.0, *)`, above
the iOS 17 deployment target. So the Library value stays 1.0 in
`DS.Font.Library` (it is the Library's value) and
`DS.Font.Style.lineSpacing(atPointSize:)` clamps at 0: **a line height
below the face's own is not applied, and Display renders at Bricolage's
1.2 em.** Nothing is faked and §6's table is not rewritten to match what
SwiftUI can do. Closing it needs either an owner decision to raise the
deployment target or an OS-version-conditional path; neither is taken here.
Tracked as **#661**, which owns that choice — not #629.

> **Superseded by #629 (2026-09-23).** The table below described the SF Pro
> ramp that `DS.Font` carried until #629 replaced it, and is kept for
> provenance only. Every role above kept its name; the *values* changed
> from `Font.system(...)` to bundled `Font.custom(...)` Library styles, and
> `DS.Font.ceremonyTitle` was **removed**: it had no Swift call site
> (`git grep -w ceremonyTitle` found only documentation), and a role with
> no caller is a guess about a screen nobody has built. #637 may add one.
> Previously (verbatim):
>
> Current code (migration debt until #629 — the table describes today's
> `DS.Font`, not the Flat 2b target):
>
> Ramp (all Dynamic Type text styles, defined in `DS.Font`):
>
> | Token | Style | Role | Constraint |
> | --- | --- | --- | --- |
> | `DS.Font.screenTitle` | `.largeTitle` bold | Screen title | Max one per screen |
> | `DS.Font.ceremonyTitle` | `.title` bold | "Proof Collected" entrance in `RecordingView` | Ceremony moments only |
> | `DS.Font.sectionTitle` | `.title3` semibold | State/section titles | |
> | `DS.Font.cardTitle` | `.subheadline` semibold | Card titles | `lineLimit(1)` + truncation on cards |
> | `DS.Font.body` | `.body` | Body copy | |
> | `DS.Font.supporting` | `.subheadline` | Supporting copy | Pair with `textSecondary` |
> | `DS.Font.meta` | `.caption` | Dates, counts | |
> | `DS.Font.ledgerMono` | `.footnote` monospaced | Addresses, hashes, proof IDs | Ledger Trace motif only |
> | `DS.Font.cta` | `.headline` | Primary CTA labels | Label color per §5's CTA-label rule (never the style default white) |

**Android counterpart** (verified `ui/theme/Type.kt`, `BeidTypography`):
`screenTitle` → `headlineLarge`, `ceremonyTitle` → `headlineMedium`,
`sectionTitle` → `titleLarge`, `cardTitle` → `titleMedium`, `body` →
`bodyLarge`, `supporting` → `bodyMedium`, `meta` → `labelSmall`,
`ledgerMono` → `bodySmall` (monospace `FontFamily`), `cta` → `labelLarge`.
Reached as `MaterialTheme.typography.*`, the same way `DS.Font.*` is
reached on iOS. This mapping already exists in the codebase's own kdoc —
this document did not have to invent it. *(#629, 2026-09-23: the iOS side
of the `ceremonyTitle` → `headlineMedium` pair no longer exists — the role
was removed as callerless. Android's `Type.kt` is unchanged and still
names it; Android is out of #629's scope, and its Flat 2b follow-up is
still unscheduled.)*

Rules:

- MUST: All fonts support Dynamic Type (text styles, never fixed point sizes).
  **[Android counterpart: every `BeidTypography` role is a Material3 role,
  which scales with the Android system font-size setting — see §2 rule
  6.]**
- MUST: Layouts survive AX3 text sizes: multiline text wraps, never clipped;
  fixed-height containers around text are FORBIDDEN. **[Android
  counterpart: layouts must survive Android's largest font-scale setting
  the same way; `Modifier.height(fixed)` around text is the equivalent
  FORBIDDEN pattern. Not independently verified against every Android
  screen in this pass — a review-level check, same as iOS.]**
- SHOULD: Long event names truncate with `lineLimit` on cards, wrap on
  detail screens. **[Android counterpart: `Text(..., maxLines = 1,
  overflow = TextOverflow.Ellipsis)` on cards — `BeidHeroHeader` already
  does this (`maxLines = 2`, `TextOverflow.Ellipsis`, verified
  `BeidHeroHeader.kt`), wrap (no `maxLines`) on detail screens.]**
- FORBIDDEN in Views: `.font(.system(size: N))`. A system-symbol fallback
  may size itself inside `DesignSystem/`, but it must still respect §12's
  32 pt decorative-symbol cap. **[Android counterpart: a literal
  `fontSize = N.sp` outside `ui/theme/`/`ui/designsystem/` — see §2 rule
  2's Android note.]**

## 7. Spacing, Layout, Safe Areas

> **Platform scope:** iOS-specific mechanism — Android counterpart named.
> Verified `ui/theme/Spacing.kt`: Android's `BeidSpacing` ports the exact
> same six values, in dp instead of pt (`xs 4.dp / s 8.dp / m 16.dp /
> l 24.dp / xl 32.dp / xxl 48.dp`) — a direct 1:1 port of the base scale,
> not just a same-shaped scale. It is **no longer** a 1:1 port of
> `pageMargin`: Android's is still `32.dp`, iOS's has been 24 since #628,
> and Android has no `emptyBlockVertical`. Per §0's Flat 2b note, Android's
> superseded values are not a violation until an Android follow-up is
> scheduled.

4 pt base scale in `DS.Space`: `xs 4 / s 8 / m 16 / l 24 / xl 32 / xxl 48`,
plus `DS.Space.pageMargin` (24) for full-width content and bottom CTAs,
and `DS.Space.emptyBlockVertical` (40), the vertical padding of the
`Block/Empty` empty state (§8).

> **Flat 2b note (2026-09-22, beid#627,
> [D-627](docs/decisions/issue-627-flat-2b.md)):** Flat 2b sets the page
> margin to 24 (content width 354 on a 402-wide screen). #628 changed
> `DS.Space.pageMargin` from 32 to 24 (2026-09-23).
>
> **Token fold (#628, 2026-09-23).** `BeidDesign` in
> `ios/Beid/DesignSystem.swift` used to carry its own duplicate spacing,
> radius, size and animation scales. They were folded into `DS`:
> `Spacing.screenHorizontal` (24) → `DS.Space.pageMargin`,
> `Spacing.section` (24) → `DS.Space.l`, `Spacing.compact` (8) →
> `DS.Space.s`, and `Spacing.content` (14) → `DS.Space.m` (16, a 2pt
> change); the radius, size and animation folds are in §8, §17 A and §9.
> `BeidDesign` now holds only `haptic(_:)`, which is feedback behavior, not
> a design value. Tokens live only in `DS`.

- MUST: All padding/spacing values come from `DS.Space.*` (exceptions: `0`, `1`).
  **[Android counterpart: `BeidSpacing.*` — see §2 rule 3.]**
- MUST: On state screens in compact width, full-width primary CTAs sit at
  the bottom with horizontal padding `DS.Space.pageMargin` (the pattern in
  `WelcomeView` and `SignalLostView`). Sheets, regular-
  width layouts, and secondary actions MAY deviate with a stated reason.
  **[Android counterpart: verified in `WelcomeScreen`/`BluetoothOffScreen`
  — both use `BeidScreen`'s `footer` slot with `BeidSpacing.pageMargin`
  horizontal padding, matching this pattern. Android is phone-only today
  (no regular-width/tablet layout class in this codebase), so the "regular
  width" deviation clause has no Android instance yet — not a violation,
  just an unexercised case.]**
- MUST: Respect safe areas; content never hides behind home indicator or
  notch. Keyboard avoidance uses standard SwiftUI behavior. **[Android
  counterpart: respect system window insets (status bar, navigation bar,
  display cutouts) — `Scaffold`'s `innerPadding`, which `EventJoinScreen`/
  `AccountScreen`/`ManualEventCodeScreen` already thread through
  (verified). Keyboard avoidance uses standard Compose/`Scaffold` behavior.]**
- SHOULD: Grid layouts use `DS.Space.m` (16) gutters (the
  `CollectionHomeView` `LazyVGrid` pattern). **[iOS-only as written: no
  `CollectionHomeView`/grid layout exists on Android today (§11) — the
  gutter *value* recommendation (`BeidSpacing.m`) would carry over to a
  future Compose `LazyVerticalGrid`, but there is no current screen this
  rule governs.]**
- SHOULD: Vertical rhythm inside a state screen (icon → title → body → CTA)
  uses `DS.Space.l` (24) as the default stack spacing. **[Android
  counterpart: `Arrangement.spacedBy(BeidSpacing.l)` — verified as the
  actual spacing `BeidStateScreen`/`BeidScreen` use internally
  (`ui/designsystem/BeidStateScreen.kt`, `BeidScreen.kt`).]**

## 8. Shape, Material, Elevation

> **Platform scope:** mixed, annotated per bullet below. The radii
> values/roles and the matte-elevation principle are platform-neutral
> with a named Android counterpart; the Liquid Glass material paragraphs
> are iOS-only as written (Android has no Liquid Glass API at all — see
> §8a's own tag below and `ui/designsystem/BeidSurface.kt`'s kdoc, which
> states this directly in the code).
>
> **Flat 2b (2026-09-22):** the Flat 2b surface rules below bind iOS now.
> Android's `beidSurface` (matte `surfaceRaised` + hairline) is already
> glass-free; its values are the superseded palette, not a violation until
> an Android follow-up is scheduled (none exists as of 2026-09-22).

**Flat 2b surfaces (owner decision 2026-09-22, beid#627,
[D-627](docs/decisions/issue-627-flat-2b.md); implementation #630):**

- FORBIDDEN: glass (`glassEffect`, glass button styles,
  `GlassEffectContainer`), system materials, blur, shadows, and
  gradients on any surface the app draws. OS-drawn chrome the app does
  not draw itself (system alerts and confirmation dialogs, the keyboard,
  permission dialogs) is outside this rule, as in §12, so §2 rule 10's
  standard containers stay usable. The Account sheet's background is not
  in that carve-out: Flat 2b draws it in `ink`, so it is app-drawn.
- MUST: Separation comes from 1px `line` hairlines and whitespace. The
  hairline sits on the **top** edge of each row; a list adds one extra
  bottom hairline after its last row. On `ink`, hairlines use
  `on-ink/line`.
- MUST: The empty state is a dashed 1px `line-dashed` frame, radius 16,
  with 40pt vertical padding (`Block/Empty`).
- The now-sensing card on Home is an `ink` card, radius 20 (#635). The
  primary button is a pill (`Button/Primary`). The Account sheet uses the
  OS sheet (drawn with a 36 top radius in Figma; #642). Screen corners
  belong to the OS.
- Radius values (#628, 2026-09-23): the empty block is
  `DS.Radius.emptyBlock` (16), the now-sensing card `DS.Radius.nowCard`
  (20), and the primary button `DS.Radius.pill` — a capsule, which is how
  `Button/Primary`'s 28 at 56pt and 26 at 52pt (half its height) are
  expressed, with no separate token. Rounded rectangles keep
  `style: .continuous`; Flat 2b does not contradict it.
- Surfaces (#630, 2026-09-23): `View.beidSurface(cornerRadius:)`
  (`ios/Beid/DesignSystem.swift`) is a `DS.Color.surfaceCanvas` fill plus
  a 1px `DS.Color.strokeHairline` border with continuous corners — no
  glass, no `Material`, no OS-version branch; its `interactive:` and
  `fallback:` parameters are gone. `BeidGlassGroup` was deleted.
  `BeidPrimaryButton` is `.borderedProminent` at `.controlSize(.large)`
  and `BeidSecondaryButton` `.bordered`, both a `DS.Radius.control`
  rounded rectangle; Home's icon Scan button is a `.borderedProminent`
  circle. The scan-flow cover's presentation background is `surfaceCanvas`
  (was `.regularMaterial`), and so is the Account sheet's (was the
  OS-default sheet glass) — an interim value; #642 takes the sheet to
  `ink` with its content. Home's Scan-button inset and Sensing's
  manual-entry inset are opaque `surfaceCanvas` with a 1px
  `strokeHairline` rule on their top edge (were `.background(.bar)`). No
  `#available(iOS 26, *)` branch remains (there were five); the
  deployment target is still iOS 17. Two gaps are left open deliberately:
  the primary button is not yet a pill (building `Button/Primary` is not
  assigned, §0), and `.bordered` is a system tint fill, not `bg` +
  `line`. Left as is: the toolbar and navigation-bar glass the OS draws
  on the iOS 26 SDK (#631 owns the navigation bar; hiding it would need
  an iOS 26-only API), `EventCardView`'s `.tint.opacity` badge, and
  `DS.Artwork.proofCardGradient` (#633).
- Empty block (#630, 2026-09-23): `BeidEmptyBlock`
  (`ios/Beid/DesignSystem.swift`) is `Block/Empty` — a dashed 1px
  `DS.Color.strokeEmptyState` frame, radius `DS.Radius.emptyBlock` (16),
  dash `DS.Size.emptyBlockDash` (4, as [4, 4]; from the 2026-09-23 Figma
  read, §0), padding `DS.Space.l` horizontal and
  `DS.Space.emptyBlockVertical` (40) vertical, no fill, content centered.
  It replaces `BeidPanel` at two empty states, `CollectionHomeView`'s
  (04b) and `DailySummaryView`'s empty day; their content is unchanged
  (the 04b copy is #635's, the glyph #631's).

Radii in `DS.Radius`: `control 12 / card 16 / seal 28 / pill 999 /
glyph 24 / emptyBlock 16 / nowCard 20`. All rounded rectangles use
`style: .continuous`. `glyph` is the `BeidGlyph` icon roundel's radius,
folded from `BeidDesign.Radius.glyph` by #628; #631 removes it with the
icons. The same fold moved `BeidDesign.Radius.card` (18) to
`DS.Radius.card` (16) and `BeidDesign.Radius.control` (14) to
`DS.Radius.control` (12), so the components that used them lost 2pt of
radius (§7's token-fold note).

**[Android counterpart, verified `ui/theme/Spacing.kt`'s `BeidRadius`:**
`control 12.dp / card 16.dp / seal 28.dp / pill 999.dp / glyph 24.dp` — an
exact 1:1 port of those five (`glyph 24.dp` is `BeidGlyph`'s icon roundel
there too). Android has no `emptyBlock` or `nowCard`. **iOS-only as written:**
`style: .continuous` names SwiftUI's continuous/squircle corner curve;
Compose's `RoundedCornerShape` (what `BeidRadius` values are consumed
through, e.g. `BeidSurface.kt`) is a standard circular-arc rounded
rectangle with no continuous-corner equivalent — this is a real visual
difference, not just an API rename.**]**

- MUST: Proof cards and event cards use `DS.Radius.card`. **[iOS-only as
  written for now: no Android proof/event card exists yet (§11) — the
  token itself (`BeidRadius.card`) is already used by `BeidPanel`
  (`ui/designsystem/BeidPanel.kt`), Android's closest current analogue.]**
- MUST: Seal/ceremony surfaces use `DS.Radius.seal`. **[iOS-only as
  written for now: no Android ceremony/seal surface exists yet — `BeidGlyph`
  uses `BeidRadius.glyph` (24dp), not `BeidRadius.seal`, for its icon
  roundel (verified `BeidGlyph.kt`), so this is not yet exercised on
  Android at all, not a mismatch.]**
- SHOULD: Separation via a `strokeHairline` hairline and whitespace, not
  heavy drop shadows. Beid surfaces are matte and physical, not floaty.
  **[Android counterpart, verified consistent: `Modifier.beidSurface`
  (`BeidSurface.kt`) is exactly `surfaceRaised` background + 1dp
  `strokeHairline` border — no shadow API used anywhere in
  `ui/designsystem/`. Android keeps `surfaceRaised` under the superseded
  palette (§5).]**
  *Flat 2b note (2026-09-22): "material" no longer qualifies; elevation is
  hairline and whitespace only, and shadows are FORBIDDEN (above).*

  > **Superseded by #628 (2026-09-23).** `DS.Color.surfaceRaised` was
  > removed on iOS (its value was `bg`'s, and Flat 2b has no raised
  > surface; §5), so the rule no longer names it. Previously (verbatim):
  >
  > - SHOULD: Elevation via material or `surfaceRaised` + hairline stroke, not
  >   heavy drop shadows. Beid surfaces are matte and physical, not floaty.

> **Superseded 2026-09-22 (owner decision, beid#627,
> [D-627](docs/decisions/issue-627-flat-2b.md)).** No glass, no materials,
> no blur (above). #630 removed the code (2026-09-23), including the five
> iOS 26 availability gates that existed only for glass; the deployment
> target stays iOS 17 (`ios/project.yml` — a fact, not a decision made
> here).
> Provenance: the "Materials:" bullet and the `glassEffect` MUST were added
> in revision round 1 (`79cd005`, NAOE Kenichi, 2026-07-10; §C "Adopted
> (structural; PROPOSAL tags unchanged)"); the blur FORBIDDEN is from the
> initial contract (`14ebd53`, 2026-07-10) and survives in stricter form
> as "no blur at all". Previously:
>
> - Materials: the deployment target is iOS 17, so iOS 26 Liquid Glass APIs
>   (e.g. `glassEffect`) are usable only behind availability gates
>   (`if #available(iOS 26, *)`), never unguarded. Standard SwiftUI
>   controls/navigation adopt the new system appearance automatically when
>   the app is rebuilt with the iOS 26 SDK — prefer that free adoption. For
>   pre-26 fallback and overlay chrome, use system materials
>   (`.ultraThinMaterial` etc.). **[iOS-only as written: an iOS deployment-
>   target/availability-gating concern with no Android analog. Android's
>   `beidSurface` has no OS-version branch at all — its own kdoc states it
>   is "the fallback path alone, always applied" (`BeidSurface.kt`).]**
> - MUST: Custom `glassEffect` use requires explicit design approval
>   (a `DesignException` link). Glass is a functional layer for controls and
>   navigation, not content decoration — proof/ceremony artwork is content
>   and does not get glass by default. No glass-on-glass nesting. **[iOS-only
>   as written: `glassEffect` does not exist on Android; there is no glass
>   layer to require approval for or to nest.]**
> - FORBIDDEN: Faking glass with arbitrary blur rectangles. **[iOS-only as
>   written: Android has no glass effect to fake — not applicable, not a
>   named counterpart.]**

### 8a. Liquid Glass materials (design-approved surface, DesignException: this section)

> **Platform scope:** iOS-only as written, for the entire subsection —
> not merely untranslated. Liquid Glass is an iOS 26 SDK API family with
> no Android analog at all, not a mechanism that needs an Android name.
> Android's own `Modifier.beidSurface` (`ui/designsystem/BeidSurface.kt`)
> already states this directly in its kdoc: it is "material-fallback path
> only... Android has no Liquid Glass equivalent and no 'below OS 26'
> branch to speak of, so this is that fallback path alone, always
> applied." Android's matte/hairline surface treatment is §8's material
> rule (already covered there), not a renamed instance of anything in this
> subsection — nothing below needs or gets an Android counterpart tag.
>
> **Flat 2b (2026-09-22):** this whole subsection is superseded (below);
> Android was never bound by it.

> **Superseded 2026-09-22 (owner decision, beid#627,
> [D-627](docs/decisions/issue-627-flat-2b.md)).** All of §8a is replaced
> by §8's Flat 2b surface rules: no glass, no materials, no blur. #630
> removed `beidSurface`'s glass path, the glass button styles and
> `BeidGlassGroup` (2026-09-23), so the code the text below describes no
> longer exists (§8 "Surfaces (#630)"). The five iOS 26 availability gates
> existed only for glass and went with it; the deployment target stays
> iOS 17 (a fact about `ios/project.yml`, not a decision made here).
> Provenance: added in `0d6394f` (NAOE Kenichi, **2026-07-22**, PR #49),
> with its own `DesignException: this section` in the heading; §C has no
> row for it. Ken's "ふんだんに" (generously) directive, quoted below, is
> retired with it. Overturned on the owner's authority without Ken's
> sign-off; Ken is to be informed afterwards.
> Previously (verbatim):
>
> Beid expresses Liquid Glass through the quiet-field-instrument register, not
> against it: glass is restrained, matte-adjacent, and reserved for chrome —
> never a decorative flourish layered onto content or artwork.
>
> - **The one sanctioned mechanism**: `View.beidSurface(interactive:cornerRadius:fallback:)`
>   in `ios/Beid/DesignSystem.swift`. On iOS 26+ it applies `.glassEffect`
>   (regular, `.interactive()` only when the surface is genuinely tappable);
>   below iOS 26 it falls back to a system `Material` plus a
>   `DS.Color.strokeHairline` stroke. This modifier owns the entire surface
>   fill — call sites MUST NOT pair it with a separate
>   `.background(material:)`/`.background(color:)`. (A real instance of this
>   bug shipped in the original `beidGlass` helper: `BeidPanel` and
>   `ProofCardView` both painted `.background(.regularMaterial, in: …)`
>   *underneath* `.glassEffect(...)`, stacking two materials on iOS 26 — the
>   exact glass-on-glass nesting this document forbids. Fixed by folding the
>   fallback material into `beidSurface` itself, so glass and material are
>   mutually exclusive by construction, not by call-site discipline.)
> - **Where glass applies** (functional chrome, per the existing §8 rule):
>   `BeidGlyph` (icon roundels), `BeidPanel` (metadata/status card
>   backgrounds), `ProofCardView` (interactive grid cards — `interactive:
>   true`, since tapping opens the detail screen), `BeidPrimaryButton`
>   (`.buttonStyle(.glassProminent)`) and `BeidSecondaryButton`
>   (`.buttonStyle(.glass)`), `BeidBulletRow`'s icon roundel.
> - **Where glass does not apply**: `DS.Color.surfaceCanvas` screen
>   backgrounds (a root background is structural, not a floating control —
>   glassing it would remove the "matte and physical" ground everything else
>   sits on); proof/ceremony artwork (`DS.Artwork.proofCardGradient`, seal
>   moments) — content, per the existing §8 rule, not chrome; `AccountSheetView`'s
>   `List` rows (§2.10: standard containers first; a system `List` already
>   gets the platform's own Liquid Glass row treatment on iOS 26 for free —
>   wrapping rows in `beidSurface` on top of that would itself be
>   glass-on-glass); the `WalletConnectPairingView` QR code surface and the
>   `EventCodeEntryView` text-field container, which stay `surfaceRaised` +
>   hairline — a scan target and a text-entry field are read, not tapped as
>   chrome, so matte legibility wins over glass.
> - **Grouping**: `BeidGlassGroup` (also in `DesignSystem.swift`) wraps
>   `GlassEffectContainer` on iOS 26+ (plain passthrough below it). Use it
>   around any cluster of `beidSurface`-backed views that sit close together
>   on one screen, so iOS 26 can blend/merge them in one render pass instead
>   of compositing each independently — `BeidScreen` wraps its whole
>   content+footer stack (covers every state-screen pattern: glyph header +
>   panel + CTA), `CollectionHomeView` wraps the proof-card grid,
>   `ItemDetailView` wraps its three stacked panels. Do not wrap views that
>   are far apart or on different screens; that defeats the container's
>   purpose per the upstream guidance.
> - **Deployment target**: stays iOS 17 (`ios/project.yml`); every Liquid
>   Glass call site is gated behind `#available(iOS 26, *)` with a real
>   fallback, never unguarded. Ken's "ふんだんに" (generously) directive is
>   read as *thorough adoption of the sanctioned surface pattern across every
>   eligible chrome element*, not as raising the minimum OS — beid's existing
>   users on iOS 17–25 get an equivalent matte-material look (the pre-26
>   fallback path in `beidSurface` now draws its hairline stroke from
>   `DS.Color.strokeHairline` instead of the previous `.separator.opacity`,
>   a deliberate token-correctness fix, not a value-preserving no-op); iOS 26
>   users get glass. No `DesignException` is
>   needed for staying on iOS 17; raising the deployment target is a
>   business decision (device-support cutoff) outside this design pass's
>   scope.

## 9. Motion and Haptics

> **Platform scope:** iOS-specific mechanism — Android counterpart named,
> with a real caveat. The spring-first/interruptible/reduce-motion/
> haptics-at-commits *principles* are platform-neutral; the exact
> parameter values are not portable as-is (below). Verified: Android has
> **no** motion/animation/haptics code at all today — no `spring(`,
> `animate*AsState`, `rememberInfiniteTransition`, or haptic-feedback call
> anywhere under `ui/`, and no `DS.Motion`-equivalent token namespace
> exists under `ui/theme/` (§4). This section is entirely unimplemented on
> Android, not implemented differently.

Motion is spring-first and interruptible. Springs are parameterized by
damping and response (`DS.Motion`), not fixed-duration curves.

| Token | Value | Use |
| --- | --- | --- |
| `DS.Motion.fast` | spring, response 0.25, damping 1.0 | Press feedback, small state flips |
| `DS.Motion.standard` | spring, response 0.35, damping 1.0 | Default transitions |
| `DS.Motion.entrance` | spring, response 0.5, damping 0.85 | Content entering (event card in `EventFoundView`) |
| `DS.Motion.proofResolve` | spring, response 0.6, damping 0.8 | Proof seal ceremony |
| `DS.Motion.sensingPulsePeriod` | 1.8 s | One radar pulse cycle in `SensingView` |
| `DS.Motion.screenTransition` | spring, response 0.36, damping 0.88 | Root screen switches (`RootView`) and scan-flow phase switches (`ScanFlowView`) |

`DS.Motion.screenTransition` is `BeidDesign.Animation.soft` moved into
`DS` unchanged by #628 (2026-09-23), and `BeidDesign.Animation.entrance`,
which was an alias of `DS.Motion.entrance`, is gone; its call site uses
`DS.Motion.entrance` directly (§7's token-fold note).

**[iOS-specific mechanism, not a numeric port: Compose's spring API
(`androidx.compose.animation.core.spring`) is parameterized by
`dampingRatio`/`stiffness`, not SwiftUI's `response`/`damping`. These are
different curve parameterizations — a future Android motion-token file
would need its own `dampingRatio`/`stiffness` pairs tuned to feel
equivalent, not these response/damping numbers relabeled. No such file
exists yet (see the section tag above).]**

Rules:

- MUST: Default to critically damped (damping 1.0). Overshoot (damping < 1)
  is reserved for moments that carry momentum or ceremony: `entrance` and
  `proofResolve`. **[Platform-neutral principle; Android counterpart would
  use `dampingRatio = Spring.DampingRatioNoBouncy` (critically damped) by
  default, `Spring.DampingRatioMediumBouncy`-class values reserved for
  ceremony/entrance — not yet implemented.]**
- MUST: Animations are interruptible — never lock out input during a
  transition; animate from the current (presentation) value. **[Platform-
  neutral principle; Compose counterpart is animating from an
  `Animatable`'s live value, same as SwiftUI's presentation-value
  interruption — not yet implemented.]**
- MUST: Honor Reduce Motion — replace slides/springs with opacity
  cross-fades; the `SensingView` pulse loop degrades to a static state with
  a subtle opacity breathe or none at all. **[Android counterpart:
  Android's system motion-reduction setting
  (`Settings.Global.ANIMATOR_DURATION_SCALE` / the "Remove animations"
  accessibility setting) is the platform analogue to iOS's Reduce Motion.
  Not read or honored anywhere in the current Android codebase — a real
  gap, not a naming gap.]**
- SHOULD: Haptics only at meaningful commits: event found (light), proof
  sealed (success). FORBIDDEN: haptics on every phase change of
  `ScanPhase`. **[Android counterpart: `HapticFeedback`/
  `LocalHapticFeedback.current.performHapticFeedback(...)`, same
  restraint rule. No haptic call exists anywhere in the current Android
  codebase — not yet exercised, so the FORBIDDEN clause has no current
  violation to point at either.]**
- FORBIDDEN: `repeatForever` animations on screens other than `SensingView`
  (ambient motion is the Encounter Field motif's privilege, nobody else's).
  **[iOS-only as written for now: no Android screen has an ambient/looping
  animation at all today (no `SensingView` counterpart exists — §11), so
  there is currently nothing on Android for this FORBIDDEN clause to
  either permit or forbid. The Android counterpart mechanism, when a
  sensing-phase screen lands, would be `rememberInfiniteTransition`.]**

## 10. Component Inventory

> **Platform scope:** annotated per component below. As a general note,
> every Android component cited here lives under
> `android/app/src/main/kotlin/org/levarac/beid/ui/designsystem/` and was
> read directly, not assumed by analogy to its iOS name.

Real components in this codebase. Each entry is the contract for reuse.

> **Flat 2b annotation (2026-09-22, beid#627,
> [D-627](docs/decisions/issue-627-flat-2b.md)).** The entries below
> describe **today's code** and stay accurate until the implementing issues
> land. Where an entry names glass/`beidSurface` (#630), the per-proof
> gradient (#633), a close (X) or other icon (#631), or the motif accents
> `signalActive`/`signalWarning`/`proofSeal` (#628), that part is migration
> debt against §5/§8/§12, not precedent for new work. Flat 2b's Library
> components (§0) replace these as the implementing issues land.
>
> **Update (#628, 2026-09-23).** The motif-accent part is done: those three
> tokens are gone from iOS, tints are `actionPrimary`, and status dots use
> `statusOn`/`statusPending`/`statusOff` (§5). The entries below name the
> current tokens; Android notes still name Android's own.
>
> **Update (#630, 2026-09-23).** The glass part is done: `beidSurface` is
> a `surfaceCanvas` fill plus a 1px `strokeHairline` border with no glass
> path, and `BeidGlassGroup` and the glass button styles are gone (§8
> "Surfaces (#630)"). Where an entry below names `beidSurface`, it is that
> flat surface, no longer migration debt.

### Component: ProofCardView

> **Platform scope:** iOS-only as written — no Android counterpart exists.
> There is no Android `CollectionHomeView` (§11), so there is no Android
> proof-card grid for this component to render into. `DS.Artwork.proofCardGradient`
> also has no Android counterpart (§5). Not renamed, not deferred to
> another component — absent.

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
  surfaced in `ItemDetailView`, not on the grid card itself — keeps the card
  dense and avoids a second status affordance.
  Revisit if a future design pass wants a compact card-level signature
  badge; it MUST pair color with a symbol per §2.9.
- Accessibility: entire card one element; label "Proof of {eventName},
  {date}".
- *Flat 2b (2026-09-22): the gradient avatar and `beidSurface` are
  migration debt (#633, #630); the home becomes an event list (#635).*
  The `beidSurface` part was done by #630 (2026-09-23; a flat
  `surfaceCanvas` fill and hairline, §8).

### Component: ScanFlowView (phase container)

> **Platform scope:** iOS-only as written — no Android counterpart
> container exists. Android's phase rendering (`EventJoinScreen`'s
> `ScanPhaseDetail`, verified) is a `when` branch inside one screen, not a
> full-screen-cover container switching between separate phase views —
> see §11's Android note on the scan flow for the verified current shape.
> This is a structural difference, not a missing name.

- Purpose: Full-screen cover hosting the sensing flow, switching on
  `SensingCoordinator.phase` (`ScanPhase`: idle/sensing → eventFound →
  recording, with signalLost branch).
- Use when: The single entry point to sensing; presented via
  `fullScreenCover` from `RootView`.
- Don't use when: Anything else — there is exactly one scan flow.
- Rules: phase transitions animate with `DS.Motion.standard`; a trailing
  close (X) button is always reachable in the toolbar; each phase view owns
  its content but not its chrome.
- *Flat 2b (2026-09-22): the close (X) is superseded — the exit becomes
  the monospaced text control `CLOSE` (and `DONE` when finished), with a
  44×44pt hit region (§12, #631, #636). The "always reachable exit" rule
  itself stands.*

### Component: Sensing pulse (in SensingView)

> **Platform scope:** iOS-only as written — no Android counterpart exists
> (§9's motion section already establishes Android has zero animation code
> today; there is also no `SensingView`-equivalent screen for a pulse to
> live in, §11). Android is out of scope for #652 on the same grounds:
> there is no Android sensing graph for signal strength to be drawn in.

- Purpose: The Encounter Field ambient indicator while scanning.
- Required tokens: `DS.Color.actionPrimary` (the screen tint the rings
  follow), `DS.Motion.sensingPulsePeriod`.
- Rules: the only permitted `repeatForever` animation; MUST degrade under
  Reduce Motion (§9); center symbol needs `.accessibilityHidden(true)` with
  the state conveyed by the title text.
- Signal strength (#652, 2026-09-23): the graph's radial axis is BLE signal
  strength, and it is **used for display only, never for any decision**. No
  beid decision reads it, and records, signatures and submissions do not
  contain it — #652's tests pin that; this sentence does not, and no lint
  rule can. A node with no usable measurement yet MUST be drawn at the
  weakest position — outermost — never at the center. On a graph whose
  semantic is "distance from center = signal strength", drawing an
  unmeasured node at the center would make the strongest possible proximity
  claim from zero measurement: absence of evidence must never render as
  evidence of proximity. The damping that keeps nodes from jittering
  (smoothing plus redraw coalescing) is **not verified on real hardware** —
  no device was run for this change, so its constants are unverified, not
  tuned; only a run on real devices with real peers moving settles them.
  The drawing itself is #634, not #652 — #652 builds the data path #634
  consumes.
- *Flat 2b (2026-09-22): the pulse is replaced by the sensing graph
  (#634), which carries a VoiceOver summary (§13). Its former tint,
  `signalActive`, was removed by #628 (2026-09-23).*

### Component: BeidStatusPill

> **Platform scope:** iOS-specific mechanism — Android counterpart named,
> with a deliberately different API shape (not just a port). Android's
> `BeidStatusPill` (`ui/designsystem/BeidStatusPill.kt`) is real and in
> production use (`EventJoinScreen`, `RecordsScreen`).

- Purpose: Dot + label status indicator, e.g. "Sensing automatically" atop
  `SensingView`.
- Use when: A screen needs a compact, glanceable state readout that is not
  a navigable control.
- Don't use when: The status is interactive (use a button/toggle) or needs
  more than a dot + one line of text (use `BeidBulletRow` or a bespoke row
  instead).
- API: `BeidStatusPill(state:)`, `state: BeidStatusPill.State` —
  `.sensingAutomatically` / `.sensingPaused`. **[Android's actual API
  diverges here on purpose, per its own kdoc: `BeidStatusPill(label:
  String, tone: Tone)` where `Tone` is `Active`/`Paused`/`Neutral`/`Sealed`
  and carries **no string** — the caller supplies `label` via
  `stringResource`. The kdoc states why: baking English label strings into
  a Kotlin enum (as iOS's `State` does) would bake §15's still-unratified
  sentence-case decision (#24) into the component. `Neutral`/`Sealed` are
  Android-only tones added for `RecordsScreen`'s three-state signature
  pill (beid#121) — Android added tones iOS's `State` enum doesn't have,
  not the reverse.]**
- Required tokens: `DS.Space.m` (horizontal padding), `DS.Space.s`
  (vertical padding and the dot-label gap), `DS.Size.statusDot`,
  `DS.Radius.pill` (via `beidSurface`), `DS.Font.supporting`,
  `DS.Color.textSecondary` (label, both states), `DS.Color.statusOn` /
  `DS.Color.statusPending` (dot). **[Android counterpart: the same roles
  by Android name — `BeidSpacing.m`/`.s`, `BeidSize.statusDot`,
  `BeidRadius.pill` via `beidSurface`, `MaterialTheme.typography.bodyMedium`,
  `BeidTheme.colors.textSecondary`/`.signalActive`/`.signalWarning` —
  verified 1:1 in `BeidStatusPill.kt`; the dots keep the superseded
  palette's `signalActive`/`signalWarning` there (§5).]**
- States: `.sensingAutomatically` (active, `statusOn` dot) /
  `.sensingPaused` (pending — waiting for the signal to return —
  `statusPending` dot; rendered in `SignalLostView`). Label color never
  changes with state — only the dot does, and the label text itself names
  the state, so color is never the only signal (§2.9). **[Android: same "label color never
  changes, only the dot" rule — verified `BeidStatusPill.kt` always uses
  `textSecondary` for the label regardless of `tone`.]**
- Accessibility: dot is `.accessibilityHidden(true)` (decorative — state is
  named by the label text); label is a plain `Text`, not merged into a
  combined accessibility element, so it stays independently queryable by
  its string. **[Android counterpart: the dot `Box` carries no semantics
  node (the Compose equivalent of `.accessibilityHidden(true)` — verified
  no `.semantics {}` on the dot in `BeidStatusPill.kt`); the label is a
  plain, unmerged `Text`.]**
- *Flat 2b (2026-09-22): the dot colors and `beidSurface` are migration
  debt (#628, #630). Under Flat 2b a status dot uses a semantic color for
  its one meaning, always beside its text label (§5).* The dot colors
  were done by #628 (2026-09-23; `statusOn`/`statusPending` above), and
  `beidSurface` by #630 (2026-09-23; a flat `surfaceCanvas` fill and
  hairline, §8).

### Component: BeidBulletRow

> **Platform scope:** iOS-specific mechanism — Android counterpart named,
> component exists (`ui/designsystem/BeidBulletRow.kt`) but **has no
> current production caller**. `BluetoothPermissionScreen` reproduces its
> *text* layout by hand instead of calling it (verified — see the
> component's own note below).

- Purpose: One benefit/permission bullet — an icon roundel plus a title, and
  optionally a second, smaller supporting sentence.
- Use when: A state screen needs a short list of benefit/permission bullets
  (`BluetoothPermissionView`'s three Bluetooth benefits).
- Don't use when: The row needs numbering/sequence (use
  `BeidNumberedStepList` instead) or is itself a full panel/card.
- API: `BeidBulletRow(systemImage: String, title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil)`.
  Omit `subtitle` for a title-only row. **[Android's actual signature:
  `BeidBulletRow(icon: ImageVector, title: String, tint: Color, subtitle:
  String? = null)` — `icon` takes a real `ImageVector`, not a symbol-name
  `String`, and `tint` is a required parameter with no ambient-tint
  fallback (Compose has no ambient `.tint()` — see §5's accent-map note).
  Verified `BluetoothPermissionScreen.kt` does **not** call this component:
  its kdoc states the scaffold has no `material-icons-core`/`-extended`
  dependency, so it reproduces `BeidBulletRow`'s title+subtitle text layout
  by hand instead, without an icon roundel at all.]**
- Required tokens: `DS.Space.s`/`DS.Space.xs` stack spacing, `DS.Font.cardTitle`
  (title), `DS.Font.meta` + `DS.Color.textSecondary` (subtitle),
  `DS.Radius.control` + `DS.Size.bulletIcon` (icon roundel; folded from
  `BeidDesign` by #628, §7). Icon tint follows ambient `.tint()`, which is
  `actionPrimary` on every screen since #628 (§5 has no motif accents).
  **[Android counterpart:
  `BeidSpacing.s`/`.xs`, `MaterialTheme.typography.titleMedium` (title),
  `.labelSmall` + `BeidTheme.colors.textSecondary` (subtitle),
  `BeidRadius.control` + `BeidSize.bulletIcon` (icon roundel) — verified
  1:1 in the component file, even though nothing calls it yet.]**
- Accessibility: icon roundel is `.accessibilityHidden(true)` (decorative;
  the title/subtitle text already carries the meaning). **[Android
  counterpart: the `Icon` carries no `contentDescription`
  (`contentDescription = null`) — verified.]**
- *Flat 2b (2026-09-22): the icon roundel is superseded (§12, #631, #643);
  02 Enable Bluetooth uses numbered text promises instead.*

### Component: BeidNumberedStepList

> **Platform scope:** iOS-specific mechanism — Android counterpart named
> and, unlike `BeidBulletRow`, **actually called** in production
> (`BluetoothOffScreen`, verified).

- Purpose: Sequential numbered instructions in a bordered card — one filled
  index badge + one line per step.
- Use when: A recovery/setup screen needs an ordered short sequence
  (`BluetoothOffView`'s "Open Settings / Tap Bluetooth / Switch it on").
- Don't use when: The list isn't ordered (use `BeidBulletRow` instead) or
  has more than a handful of steps (this is not a scrolling list).
- API: `BeidNumberedStepList(steps: [LocalizedStringKey], labelColor: Color = DS.Color.labelOnActionPrimary)`.
  **[Android's actual signature makes both `badgeColor` and `labelColor`
  required, with no default: `BeidNumberedStepList(steps: List<String>,
  badgeColor: Color, labelColor: Color)`. The component's own kdoc gives
  the reason directly: iOS defaults the badge fill to the screen's ambient
  `.tint()`, but Compose has no ambient tint to read implicitly, so both
  colors are caller-supplied instead of defaulted.]**
- Required tokens: `DS.Space.m`/`DS.Space.s`/`DS.Space.xs` spacing,
  `DS.Font.meta` (badge number) + `DS.Font.body` (step text),
  `DS.Radius.card` + `DS.Size.stepBadge` (badge; folded from `BeidDesign`
  by #628, §7), hairline
  `Divider()` between rows. **[Android counterpart, verified 1:1:
  `BeidSpacing.m`/`.s`/`.xs`, `MaterialTheme.typography.labelSmall` (badge
  number) + `.bodyLarge` (step text), `BeidRadius.card` + `BeidSize.stepBadge`,
  `HorizontalDivider`.]**
- Rules: the badge fill follows ambient `.tint()` so it always matches the
  hosting screen's tint (`actionPrimary`, §5) — `labelColor` MUST be that
  tint's on-fill pairing token (`actionPrimary` fill →
  `labelOnActionPrimary` label, the default; the same rule
  `BeidPrimaryButton` follows). Never hardcode a specific `DS.Color` for
  the badge fill; that would fight whatever tint the screen sets.
  **[Android counterpart: same pairing rule, enforced by the caller
  instead of an ambient tint — verified `BluetoothOffScreen` passes
  `signalWarning`/`labelOnWarning` explicitly together (Android's
  superseded palette, §5).]**

  > **Superseded by #628 (2026-09-23).** `signalWarning` and
  > `labelOnWarning` were removed on iOS, and `BluetoothOffView` now uses
  > the default pairing. Previously (verbatim):
  >
  > - Rules: the badge fill follows ambient `.tint()` so it always matches the
  >   hosting screen's single motif accent (§5) — `labelColor` MUST be that
  >   tint's on-fill pairing token (e.g. `signalWarning` fill → `labelOnWarning`
  >   label, the same rule `BeidPrimaryButton` follows).
- Accessibility: badge + step text read as one line per row; no separate
  accessibility grouping needed since nothing is interactive. **[Android
  counterpart: `Modifier.semantics(mergeDescendants = true) {}` on each row
  — verified, the direct Compose equivalent of
  `.accessibilityElement(children: .combine)`.]**
- *Flat 2b (2026-09-22): the tint-following badge fill is migration debt
  (§5 accent map superseded; #628, #643).* #628 (2026-09-23) removed the
  accent map's tints, so the badge now follows `actionPrimary`; the
  component itself is still #643's.

### Component: State screen (pattern shared by 01/02/03/06d)

> **Platform scope:** iOS-specific mechanism — Android counterpart
> exists in the design system (`BeidStateScreen`,
> `ui/designsystem/BeidStateScreen.kt`) but, like `BeidBulletRow`, **has no
> current production caller** — verified: no screen under `ui/screens/`
> calls `BeidStateScreen(`. `BeidStateScreen.kt`'s own kdoc claims it is
> "used by Welcome, BluetoothPermission, BluetoothOff, and SignalLost";
> that claim does not match current source and should not be repeated as
> fact from this document. All of `WelcomeScreen`/`BluetoothPermissionScreen`/
> `BluetoothOffScreen` instead hand-roll this pattern's text layout without
> the shared container, each citing the same no-`material-icons`-dependency
> reason in their own kdoc.

- Purpose: Icon/artwork → title → supporting text → optional bottom CTA.
  Used by `WelcomeView`, `BluetoothPermissionView`, `BluetoothOffView`,
  and `SignalLostView`.
- Required tokens: `DS.Space.l` stack spacing, `DS.Space.pageMargin`
  margins, `DS.Font.sectionTitle` + `DS.Font.supporting`, bottom CTA with
  `DS.Font.cta`. (#629 removed `DS.Font.ceremonyTitle`, which this slot
  also named; it had no call site — §6.) **[Android counterpart, verified in
  `BeidStateScreen.kt`/`BeidScreen.kt`: `BeidSpacing.l` stack spacing,
  `BeidSpacing.pageMargin` margins, `MaterialTheme.typography.titleLarge`/
  `headlineMedium` + `.bodyLarge`, footer CTA with `.labelLarge`.]**
- Rules: This is a conceptual pattern, not a missing phase-2 task. Extract a
  shared `StateScreen` container only when a new reuse case justifies it;
  until then new state screens match the required slots and tokens above
  without pixel-copying an existing view. **[On Android this needs the
  opposite caution stated in the reverse direction: the shared container
  (`BeidStateScreen`) already exists but is unused because of the
  material-icons dependency gap (§12) — do not describe it as "missing,"
  and do not assume every future icon-bearing state screen should skip it
  the way today's three do.]**

### Component: Detail meta row (detailRow in ItemDetailView)

> **Platform scope:** iOS-only as written — and not merely absent. Where
> Android *does* have a comparable surface (`RecordDetailScreen`, beid#122),
> its current design **deliberately does not** show an unconditional
> "Verified" status the way this component does: `RecordDetailScreen.kt`'s
> own kdoc cites beid#222 rejecting "a measured-looking zero" and beid#240
> having already forced the removal of an unbacked "Verified" claim twice,
> and states its five rows use only "Recorded"/"Not yet available" instead.
> Applying this component's fixed-"Verified" behavior to Android verbatim
> would not just be untranslated — per Android's own current, deliberate
> policy it would be wrong. `DS.Artwork.proofCardGradient`/
> `DS.Size.itemDetailArtwork` also have no Android counterpart (§5, §17).

- Purpose: Ledger Trace metadata (`Method`, `Devices sensed`, `Status`), in
  a `BeidPanel` with no section title — the panel goes straight into rows
  (as of the 08 Item Detail redesign, `docs/specs/itemdetail-redesign.md`).
- Required tokens: `DS.Font.supporting`, `DS.Color.textSecondary` label,
  `DS.Font.ledgerMono` for identifiers/addresses when they appear.
- Rules: status values pair text with color (`Verified` +
  `DS.Color.proofSeal`, plus a `checkmark.circle.fill` glyph as of the 08
  redesign), never color alone. `Status` is a fixed, unconditional
  "Verified" — deliberately NOT derived from `Proof.signatureState`.
  "On-chain"/protocol-verification language is FORBIDDEN on this row (§15)
  — there is no such backing claim.

  > **Annotation 2026-09-22 (beid#627).** The two sentences above about a
  > fixed "Verified" are stale. Since PR #246 (merged 2026-08-20; #240,
  > `DECISIONS.md` 2026-08-20) the Status row shows "Recorded on device"
  > (the shared `status.recordedOnDevice` string also used by
  > `TransparencyView`), still unconditional and still not derived from
  > `Proof.signatureState` (`ItemDetailView.swift`, `statusRow`, verified
  > 2026-09-22). The glyph and `proofSeal` color are unchanged in code
  > until #631/#628. The owner decision of 2026-09-22 (settled item A in
  > [D-627](docs/decisions/issue-627-flat-2b.md)) confirms the rule:
  > "Verified" may be shown only after a third party has verified. The
  > "on-chain" prohibition in the sentence above stands.

  > **Annotation 2026-09-23 (beid#628).** `DS.Color.proofSeal` was
  > removed. The Status row's text and glyph now use
  > `DS.Color.textPrimary` (`ItemDetailView.swift`, `statusRow`); the
  > `checkmark.circle.fill` glyph itself stays until #631.
- Header: above this panel, a centered `DS.Artwork.proofCardGradient(seed:)`
  avatar (`DS.Size.itemDetailArtwork`, in a non-interactive
  `.beidSurface(cornerRadius: DS.Radius.seal)` container) replaces the
  former seal-glyph + "Verified" label header; `proof.eventName`
  (`DS.Font.sectionTitle`, centered) and a medium-style, date-only caption
  (`DS.Color.textSecondary`, centered — no venue/time, matching
  `ProofCardView`'s date formatting) follow.

  > **Annotation 2026-09-22 (beid#627).** The gradient header, the
  > `beidSurface` container, the `checkmark.circle.fill` glyph and
  > `proofSeal` are migration debt (#633, #630, #631, #628). 09 Proof
  > Detail is rebuilt in #638; its Figma STATUS value ("Verified on-chain")
  > and "TOKEN ID" row are not authorized (§15).
  >
  > **Update (#628, 2026-09-23):** the `proofSeal` part is done
  > (`textPrimary`, annotation above).
  >
  > **Update (#630, 2026-09-23):** the `beidSurface` part is done (a flat
  > `surfaceCanvas` fill and hairline, §8).

### Pattern: Primary CTA button

> **Platform scope:** iOS-specific mechanism — Android counterpart named
> and in production use (`BeidPrimaryButton`, verified across
> `WelcomeScreen`/`EventJoinScreen`/`ManualEventCodeScreen`).

- Purpose: The one main action per screen ("Get Started", "Sense Event",
  "Try Again", "Done"). A convention, not a reusable component (yet).
  **[Android's actual CTA strings for this same role are "Get Started"
  (`welcome_get_started`) and "Join event" (`event_join_button`) — not
  "Sense Event"; see #24's discussion in
  `docs/decisions/issue-339-design-md-android-scope.md`.]**
- Rules: `.borderedProminent`, label `DS.Font.cta`, full width inside
  `DS.Space.pageMargin` (compact-width state screens, §7). Tint is
  `DS.Color.actionPrimary` on every screen (§5 has no motif accents). There
  is no "default" tint — an unspecified tint is a §5 violation, not a
  fallback. Label color follows §5's CTA-label pairing rule (never the
  style default white; `labelOnActionPrimary` on `actionPrimary`). Max one
  per screen. **[Android
  counterpart, verified `BeidButtons.kt`: `BeidPrimaryButton` is a
  Material3 `Button` (the Compose equivalent of `.borderedProminent`),
  label `MaterialTheme.typography.labelLarge`, `fillMaxWidth()` inside
  `BeidSpacing.pageMargin`-padded content, min height 52dp. `containerColor`/
  `contentColor` are required parameters with no default — the same "no
  default tint" rule, enforced the same way `BeidNumberedStepList` enforces
  it (by requiring the caller to pass it, since Compose has no ambient
  tint to fall back to).]**
- *Flat 2b (2026-09-22): the accent-map tint is superseded. The Flat 2b
  primary button is `Button/Primary`: an `ink` pill with a `bg` label, one
  per screen, 0.8 opacity when pressed (spec §7; §5, #628). Capitalization
  of its label is open (§15, #24).* Its tokens since #628 (2026-09-23):
  `actionPrimary` / `labelOnActionPrimary`, `DS.Radius.pill`,
  `DS.Size.primaryButtonMinHeight` (56) and, for Size=Small,
  `DS.Size.compactPrimaryButtonMinHeight` (52) /
  `DS.Size.compactPrimaryButtonWidth` (140). #628 added the tokens only;
  `BeidPrimaryButton`'s geometry (min height 52 today) is unchanged, and
  building the `Button/Primary` component is not assigned to an issue yet
  (§0). Since #630 (2026-09-23) `BeidPrimaryButton` is `.borderedProminent`
  on every OS version (its iOS 26 `.glassProminent` branch is gone), still
  a `DS.Radius.control` rounded rectangle, not the pill (§8).

  > **Superseded by #628 (2026-09-23).** The accent-map tints were removed
  > (§5). Previously (verbatim):
  >
  > Tint follows the
  > §5 accent map exactly: `signalActive` on sensing screens, `proofSeal` at
  > ceremony, `signalWarning` on recovery screens, `DS.Color.actionPrimary`
  > everywhere else.

## 11. Screen Patterns

> **Platform scope:** iOS-specific mechanism — Android counterpart named
> per bullet below, verified 2026-09-07 directly against
> `android/app/src/main/kotlin/org/levarac/beid/navigation/{Screen.kt,
> AppNavHost.kt}` and `ui/screens/*.kt` — not against AGENTS.md's own
> prose summary, which states it was last checked 2026-09-03 and warns its
> own snapshot can go stale. It already has, in one respect: AGENTS.md
> currently states Android has "six screens" (Welcome, Bluetooth
> permission, Bluetooth off, Join event, Account, Records); the verified
> current navigation graph has **nine** real destinations — those six plus
> `ManualEventCode`, `TodaySummary`, and `RecordDetail` — none of which are
> hidden or dead code (`AppNavHost.kt` wires all nine into `NavHost`). This
> is not a claim this document is authorized to fix in AGENTS.md; it is
> named here because §11 must describe Android's *current* shape
> accurately, not repeat a prose summary that has already drifted.
>
> Direction note: this section states what each screen's current shape
> *is*, not which platform's shape a future convergence would adopt. At
> least one area below (the entry flow) currently has Android ahead of
> iOS, not behind it — see the scan-flow bullet.

The app's navigation shape (all real, from `ios/Beid/Navigation/`):

- **Root switch**: `RootView` switches on `AppScreen`
  (welcome / walletConnect / eventCodeEntry / bluetoothPermission /
  bluetoothOff / home).
  Onboarding order depends on `OnboardingMode` (walletFirst | guestFirst).
  MUST: both orders stay coherent; no screen may assume a wallet exists.
  **[Android counterpart, verified `Screen.kt` + `AppNavHost.kt`: a
  Compose-Navigation graph over nine routes — `Welcome`,
  `BluetoothPermission`, `BluetoothOff`, `EventJoin`, `Account`,
  `ManualEventCode`, `Records`, `TodaySummary`, `RecordDetail`. No
  `walletConnect` route exists (expected — gated on #124, matching
  beid#335's own comparison table). `EventJoin` stands in for iOS's
  `.home` (`Screen.kt`'s own comment says this explicitly) — there is no
  Android `OnboardingMode` equivalent (guest-first is the only path;
  Android has no wallet-first onboarding order to keep coherent, since
  wallet-first has no Android entry point yet).]**
- **Onboarding screens (01–03)**: state-screen pattern (§10), one CTA,
  benefits as short icon bullets (`BluetoothPermissionView`). Permission
  requests explain value *before* the system prompt. **[Android
  counterpart: `WelcomeScreen`/`BluetoothPermissionScreen`/
  `BluetoothOffScreen` match this role, but (§10) hand-roll the layout
  instead of calling `BeidStateScreen`/`BeidBulletRow` due to the
  material-icons dependency gap (§12). `BluetoothPermissionScreen`
  explains value before `session.requestBluetoothPermission` is called,
  matching the "explain before the system prompt" rule (verified
  `AppNavHost.kt`'s composable body).]**
- **Collection home (04)**: `NavigationStack` + adaptive `LazyVGrid` of
  `ProofCardView`; account entry top-trailing; "Sense Event" CTA in the
  bottom bar. Empty state (04b) follows the §3 do/don't. **[iOS-only as
  written — no Android counterpart. `Screen.kt`'s own comment: `EventJoin`
  "stands in for iOS's `.home`, since Android has no post-onboarding
  collection-home screen yet." Promoting a screen to this role is
  explicitly deferred to #141 (per `Screen.kt`/`RecordsScreen.kt`'s own
  kdoc), not something this document should describe as already true.]**
- **Scan flow (05–06d)**: `fullScreenCover` — sensing is a modal session with
  a clear exit (a trailing close (X) button). Phase progression is linear;
  `SignalLostView` (06d) is the recovery branch and MUST always offer "Try
  Again". **[Android's current shape differs structurally, not just by
  name: `EventJoinScreen`'s `ScanPhaseDetail` (verified) renders
  Sensing/EventFound/Recording/SignalLost as a `when` branch inside one
  non-modal screen — no full-screen-cover container, no close (X) button
  (there is nothing separate to close; leaving happens via `Account`'s
  "Leave Event"). The SignalLost branch's actual button reads "Resume"
  (`event_join_resume_sensing` — verified `strings.xml`), not "Try Again."
  Separately, and not part of this bullet's iOS-described flow at all:
  `EventJoinScreen` already offers **automatic nearby-event discovery**
  (`NearbyEventCards`, BLE-driven, verified `EventJoinScreen.kt`) before a
  user ever enters a code — iOS's current entry flow has no equivalent
  auto-discovery card list. This is a concrete case of Android currently
  being ahead of iOS on the entry flow, not behind it; this document does
  not take a position on whether or how that gets reconciled.]**
  *Flat 2b annotation (2026-09-22, beid#627,
  [D-627](docs/decisions/issue-627-flat-2b.md)): the "trailing close (X)
  button" is superseded by the monospaced text control `CLOSE` (§12,
  #631, #636); the modal session with a clear exit stands. The bullets in
  this section describe today's screens; the Flat 2b screens replace them
  through #635–#644.*
- **Detail (08)**: push via `navigationDestination(item:)` from the grid.
  **[Android counterpart: `Screen.RecordDetail` is a parameterized
  Compose-Navigation route (`"records/{recordId}"`), pushed from
  `RecordsScreen` row taps (verified `AppNavHost.kt`/`RecordsScreen.kt`) —
  the same push-navigation *intent*, different navigation API. Also see
  §10's "Detail meta row" entry: Android's `RecordDetailScreen` is one
  screen collapsing iOS's `ItemDetailView`/`TransparencyView`/
  `ParticipationSummaryView` three-screen push chain (per beid#335's
  2026-09-03 addendum, which treats this collapse as content the app
  already gets right, with only the screen *count* differing) — and it
  deliberately never shows "Verified" (§10).]**
- **Account (09)**: `.sheet` with `List` + inline title; wallet
  connect/disconnect lives here in guest-first mode. Destructive actions
  (`Disconnect Wallet`) use `role: .destructive` and MUST confirm via
  `.confirmationDialog`. The current `AccountSheetView` performs the
  disconnect directly; that review-level violation is migration debt, not
  precedent. **[Android's shape differs, not just its chrome:
  `AccountScreen` is a plain nav-graph destination (`Scaffold` + `Column`
  of `BeidSecondaryButton` rows, verified `AccountScreen.kt`), not a
  `.sheet`/`List`. No wallet connect/disconnect exists (out of scope,
  #124). Android does have its own destructive action — "Leave Event" —
  and it has the *same* shape of gap this document already calls
  migration debt for iOS: `AccountScreen`'s `onClick = viewModel::leaveEvent`
  fires directly with no confirmation dialog (verified). This document
  names that gap as a fact about current Android source, on the same
  terms it already names it for iOS — it does not decide whether Android
  should get a confirmation dialog before or independently of iOS.]**
- Loading: indeterminate work shows calm progress (`RecordingView`'s
  activity indicator with cumulative peer count), never blocking spinners
  without copy or an invented denominator. **[Android counterpart: no
  activity-indicator/spinner exists on Android today; the closest current
  analogue is `BeidMetricRow`'s cumulative peers-verified count in
  `ScanPhaseDetail` and `RecordsScreen`'s rows (verified) — a real count,
  never an invented denominator, consistent with the rule.]**
- Errors: recovery screens state what happened, why, and one action —
  the `SignalLostView` formula. **[Android counterpart: `EventJoinScreen`'s
  field-error row ("⚠" + `error.message()`, verified) states what
  happened; the SignalLost branch's "Resume" button is the one action.
  Android has no screen dedicated to this formula the way `SignalLostView`
  is dedicated to it — it is one branch of `ScanPhaseDetail`, per the
  scan-flow bullet above.]**

**Planned surfaces (Figma MTG comments, 2026-07 — not yet designed).**
Organizer-side comments on the Minimal v4 board name surfaces that do not
exist in this codebase yet: an organizer mode (主催者モード), organizer-set
verification thresholds, a manual event-code check-in as a rescue path when
sensing fails, and richer pre-check-in status transitions before the scan
flow. The current `EventCodeEntryView` is a wallet-optional onboarding
fallback, not that sensing-recovery surface. Agents MUST NOT improvise these;
when they land, they are designed against this contract (the event-code
rescue path, for example, is a Recovery-register screen per §3, not a new
visual language).

> **Platform scope — #23, verified facts only (see the decision doc for
> the full treatment):** Android already has its own manual event-code
> screen, `ManualEventCodeScreen`/`ManualEventCodeRoute`
> (`ui/screens/EventJoinScreen.kt`), reached only from `AccountScreen`'s
> "Enter event code" button (`account_manual_event_code_button`,
> `Screen.ManualEventCode` route) — **not** from onboarding, and **not**
> from the scan-flow/recovery path this paragraph reserves. It is
> currently the closest Android analogue to iOS's `EventCodeEntryView`
> role (a manual-entry fallback reached outside the main sensing flow),
> and it sits at a similar naming/role distance from this paragraph's
> reserved rescue-path surface that `EventCodeEntryView` itself does on
> iOS — which is exactly what #23 warns must not be assumed reusable
> without checking fit. This document does not conclude what the eventual
> Android rescue-path screen should reuse or avoid, or which platform's
> shape any future convergence follows; see
> `docs/decisions/issue-339-design-md-android-scope.md`.

## 12. Iconography and Illustration

> **Platform scope:** iOS-specific mechanism — Android counterpart named
> as a **parity principle**, not a snapshot of today's dependency graph
> (beid#338 is actively landing Android icon/asset work in a parallel
> change as this document is written, so a "Android currently has no
> icons" claim would go stale immediately). The principle: both platforms
> lean on the *platform's own always-available bundled symbol set* for
> the system-actions/toolbar/small-inline (≤32pt) tier this table's left
> column names, and both reserve custom brand artwork for the right
> column's proof/ceremony/empty-state moments. Android's counterpart to
> "SF Symbols" in that always-available sense is Android's own bundled
> vector icon set (`androidx.compose.material.icons` / Material Symbols),
> used for the same left-column tier — not a claim about which specific
> icons are wired into any given screen today. As of this writing, no
> `material-icons` artifact is on `:app`'s Gradle classpath and no custom
> drawable/illustration assets exist under `android/app/src/main/res` —
> current facts, not a permanent state; do not restate them without
> re-checking.
>
> **Flat 2b (2026-09-22):** the no-icons rule below binds iOS now. The
> parity principle above describes the superseded policy; Android is not
> in violation until an Android follow-up is scheduled (none exists as of
> 2026-09-22).

**Flat 2b: no icons (owner decision 2026-09-22, beid#627,
[D-627](docs/decisions/issue-627-flat-2b.md); implementation #631).**

- MUST: The app draws no icons. Controls are monospaced uppercase text in
  DM Mono (§6): `← EVENTS`, `CLOSE`, `DONE`, `COPY`, `OPEN →`.
- The only exception is the OS status bar. OS-drawn chrome the app does
  not draw itself (system alerts and confirmation dialogs, the keyboard,
  permission dialogs) is outside this rule. There are no other
  exceptions.
- MUST: Every text control meets §2 rule 5's 44×44pt hit region; an 11pt
  label needs its hit region widened.
- MUST: A text control whose visible text reads badly aloud (e.g. "←")
  carries a VoiceOver label. This applies §13's existing VoiceOver MUST;
  it is not a new rule.
- Status dots are shapes paired with text (§5, §2 rule 9), not icons.
- Illustrations are gone. The Welcome hero is a line-drawn Sigil from
  sample data (#633, #643); empty states use the dashed `Block/Empty`
  (§8). A proof's artwork is its Sigil (§5).
- **SHARE is not part of this contract** (owner decision 2026-09-22,
  settled item C in D-627). The 2026-07-28 rejection (§C, Item Detail
  reskin row: "no share action exists in the app") stands; no share
  feature exists. #631 and #638 remove SHARE from 09 Proof Detail's nav
  row.
- **Open item 5 (D-627):** whether the `NavigationStack` back button is
  replaced by `← PARENT` text is open (#631); it touches §2 rule 10
  (standard containers first).
- Until #631 lands, SF Symbols and the four illustration assets still in
  code are migration debt. The two accessibility MUSTs quoted below
  ("Decorative images use `.accessibilityHidden(true)`" and "Symbols
  paired with text scale with Dynamic Type") keep applying to any image or
  glyph that remains.

> **Superseded 2026-09-22 (owner decision, beid#627,
> [D-627](docs/decisions/issue-627-flat-2b.md)).** The SF Symbols /
> custom-assets policy, the 32pt decorative-symbol FORBIDDEN, the two
> custom-asset pipelines and the `TODO(asset)` placeholder path are
> replaced by the no-icons rule above. Provenance: the policy table, the
> 32pt FORBIDDEN, the two accessibility MUSTs and the asset naming rule are
> from the initial contract (`14ebd53`, NAOE Kenichi, 2026-07-10;
> structural per §C); the pipeline split is from revision round 1
> (`79cd005`, 2026-07-10, "illustrations/custom-symbol split"); the
> `TODO(asset)` path is from `b65d5c9` (NAOE Kenichi, 2026-08-08, PR
> #153). Overturned on the owner's authority without Ken's sign-off; Ken
> is to be informed afterwards. Previously (verbatim):
>
> Policy split:
>
> | SF Symbols (keep) | Custom assets (required) |
> | --- | --- |
> | System actions: close, back, share, settings, person/account | Proof seals, encounter/sensing artwork, empty states |
> | Toolbar and tab affordances | Ceremony moments (`RecordingView` entrance seal) |
> | Small inline symbols beside text (≤ 32 pt) | Any brand moment that lacks suitable custom artwork |
>
> **[Android counterpart column: system actions/toolbar/small-inline (≤32dp)
> → Material Icons/Material Symbols vector set. Proof seals/encounter
> artwork/empty states/ceremony moments → custom vector assets under
> `android/app/src/main/res` (no asset pipeline decision recorded for
> Android yet — track that decision where it lands, not in this table).]**
>
> - FORBIDDEN: Decorative `Image(systemName:)` larger than 32 pt. There are no
>   known current violations: hero headers route through `BeidGlyph`, whose
>   default 72 pt container renders a 27.36 pt system-symbol fallback, and
>   available brand moments use custom assets. Treat this as a continuing cap,
>   not permission to grow the fallback. **[Android counterpart: the same
>   32dp cap on a decorative `Icon`/`ImageVector`. `BeidGlyph`
>   (`ui/designsystem/BeidGlyph.kt`) already sizes its icon at `size * 0.38f`
>   of the container — the same proportional-fallback shape iOS's `BeidGlyph`
>   uses — so a future icon dependency landing there inherits the cap by
>   construction, not by a new rule.]**
> - Two distinct custom-asset pipelines — do not mix them:
>   1. **Illustrations** (proof artwork, empty states, sensing scenes):
>      vector assets in `Illustrations.xcassets`, rendering `Original`, with
>      light/dark variants when colors are embedded.
>   2. **Custom symbols** (small reusable glyphs that behave like SF
>      Symbols): authored from an SF Symbols app template as SVG symbol
>      sets, validated in the SF Symbols app, added to the asset catalog —
>      this preserves weights, scales, text alignment, and accessibility
>      behavior. Single-color template glyphs are tinted only via
>      `DS.Color.*`. **[iOS-specific mechanism — no Android counterpart
>      pipeline exists yet. Android's nearest structural equivalents would
>      be vector drawables (`res/drawable/*.xml`) for illustrations and
>      `ImageVector`s for custom symbols, but neither pipeline has been
>      decided or built as of this writing — naming the eventual mechanism
>      is out of this document's job (see beid#338).]**
> - Temporary path when a required asset does not yet exist: a new surface
>   that *needs* a brand moment MAY ship with a placeholder (small SF Symbol
>   ≤ 32 pt or plain layout) plus a `TODO(asset): <asset-name>` comment and a
>   checklist note. Remove that TODO when the named asset lands; never use an
>   oversized decorative SF Symbol. **[Platform-neutral principle; Android's
>   actual current placeholder path is "plain layout" (no icon at all) —
>   `WelcomeScreen`/`BluetoothPermissionScreen`/`BluetoothOffScreen` all take
>   this branch today, per their own kdoc, rather than a small placeholder
>   icon, since no icon dependency exists to draw even a placeholder from.]**
> - MUST: Decorative images use `.accessibilityHidden(true)`. **[Android
>   counterpart: no semantics node on the decorative `Icon` — verified
>   `BeidGlyph.kt` already omits `contentDescription`.]**
> - MUST: Symbols paired with text scale with Dynamic Type (`@ScaledMetric`
>   or font-relative sizing). **[Android counterpart: font-relative sizing
>   via `.sp`-based or `TextUnit`-relative dimensions, the Compose analogue
>   of `@ScaledMetric` — not yet exercised on Android since no such symbol
>   exists in production today.]**
> - Asset naming: kebab-case, motif-prefixed — e.g. `encounter-field-empty`,
>   `encounter-field-pulse`, `proof-seal-mark`. **[Platform-neutral naming
>   convention; would apply verbatim to Android drawable resource names once
>   they exist, modulo Android resource-name rules (lowercase, underscores
>   instead of hyphens — Android resource identifiers cannot contain a
>   hyphen), e.g. `encounter_field_empty`.]**

## 13. Accessibility

> **Platform scope:** Platform-neutral for every principle below;
> VoiceOver → TalkBack is a direct platform naming swap, not a mechanism
> gap. No independent Android accessibility audit (TalkBack pass) was run
> for this document — the notes below are source-level, same limitation
> as everywhere else in this pass.
>
> **Flat 2b (2026-09-22):** the requirements below are unchanged and bind
> Flat 2b on iOS now; only the annotations are new.

Acceptance criteria for every component and screen, not post-hoc QA:

> **Flat 2b annotations (2026-09-22, beid#627,
> [D-627](docs/decisions/issue-627-flat-2b.md)).** The requirements in
> this section are unchanged. Read them as follows under Flat 2b:
>
> - "In both appearances" and "verify against `surfaceCanvas` *and*
>   `surfaceRaised`" now mean the single appearance (§14) and the Flat 2b
>   backgrounds: `bg`, `tile` and `ink`. Measured ratios are in §5.
> - The icon-only account-button example ("`CollectionHomeView`'s
>   "person.crop.circle" account button MUST carry "Account"") is
>   superseded: the account entry becomes the address text (#631, #642).
>   The labeling MUST itself stands and now covers text controls that read
>   badly aloud (§12).
> - Reduce Transparency has no app-drawn materials left to degrade since
>   #630 (2026-09-23, §8); the toolbar and navigation-bar glass the OS
>   draws on the iOS 26 SDK is left as is (#631).
> - Flat 2b's own accessibility ask is adopted as part of the contract
>   (spec §9): graphs and Sigils carry information, not decoration, so
>   each carries a VoiceOver summary (for example, "7 mutual, 13 detected,
>   window 6"; #633, #634, #640).
> - Open item 4 (D-627): non-text contrast under WCAG 1.4.11 is not
>   covered by this section today, which covers text; recorded, no new
>   rule.

- MUST: Contrast ≥ WCAG AA for text against its actual background in the
  single appearance (verify against `surfaceCanvas`, `surfaceTile` *and*
  the `ink` ground; measured ratios in §5). **[Platform-neutral; applies
  against Android's own hex pairs (§5, still the superseded palette) the
  same way.]**

  > **Superseded by #628 (2026-09-23).** `DS.Color.surfaceRaised` was
  > removed (§5), and the Flat 2b annotation above already read this rule
  > against `bg`, `tile` and `ink`. Previously (verbatim):
  >
  > - MUST: Contrast ≥ WCAG AA for text against its actual background in both
  >   appearances (verify against `surfaceCanvas` *and* `surfaceRaised`).
  >   **[Platform-neutral; applies against Android's identical hex pairs
  >   (§5) the same way.]**
- MUST: Dynamic Type through AX sizes without clipped text (§6). **[Android
  counterpart: Android's largest font-scale setting through Material3 text
  styles without clipped text — see §6's Android note.]**
- MUST: VoiceOver — every screen readable in a sensible order; cards are
  single elements with composed labels (§10); icon-only buttons labeled
  (`CollectionHomeView`'s "person.crop.circle" account button MUST carry
  "Account"). **[Android counterpart: TalkBack — every screen readable in
  a sensible order; cards merge to one semantics node with a composed
  label (`Modifier.semantics(mergeDescendants = true)`, already used by
  `BeidNumberedStepList` — §10); icon-only buttons carry
  `contentDescription`. No Android `CollectionHomeView`/account
  icon-button exists yet (§11) — `EventJoinScreen`'s account entry point
  is plain clickable `Text`, which is inherently labeled by its own
  visible string, not an icon-only control needing a separate label.]**
- MUST: Reduce Motion honored (§9); Reduce Transparency degrades any
  remaining material to a solid surface (`surfaceCanvas`; the app draws
  none since #630, 2026-09-23, §8). **[Android counterpart per §9: Android's
  motion-reduction setting, not currently read anywhere in this codebase —
  a real gap, not a mechanism gap. "Reduce Transparency" has no Android
  analogue to name yet, since Android has no glass/transparency material
  at all (§8a) — `beidSurface` is unconditionally solid `surfaceRaised`
  already, so this half of the rule is trivially satisfied, not
  unaddressed.]**

  > **Superseded by #628 (2026-09-23).** `DS.Color.surfaceRaised` was
  > removed on iOS; its value was `bg`'s, which `surfaceCanvas` now holds
  > (§5). Previously (verbatim): "Reduce Transparency degrades materials
  > to solid `surfaceRaised`."
- MUST: State never by color alone; `RecordingView` exposes the cumulative
  "Recording your attendance automatically · {n} devices sensed" text for
  VoiceOver, without inventing a total. **[Platform-neutral principle,
  already followed on Android: `BeidStatusPill`'s label text names the
  state independent of the dot color (§10), and `ScanPhaseDetail`'s
  `BeidMetricRow` "Devices sensed" figure is a real `peersVerified` count,
  never an invented denominator (verified `EventJoinScreen.kt`,
  `RecordDetailScreen.kt`).]**
- SHOULD: The sensing session posts meaningful VoiceOver announcements on
  phase changes (event found, recording, signal lost, resumed). **[Android
  counterpart: TalkBack announcements on phase changes, e.g. via
  `Modifier.semantics { liveRegion = LiveRegionMode.Polite }` or an
  equivalent explicit announcement — not currently implemented on Android
  (no `liveRegion`/announcement call found in `ui/screens/`).]**

## 14. Dark Mode and High Contrast

> **Platform scope:** iOS-specific mechanism — Android counterpart named
> per bullet; the underlying "every screen correct in both modes, previews
> prove it, forced overrides only in previews" principle is
> platform-neutral.
>
> **Flat 2b (2026-09-22):** single appearance binds iOS now. Android's
> `BeidAppTheme` still follows `isSystemInDarkTheme()`; that is not a
> violation until an Android follow-up is scheduled (none exists as of
> 2026-09-22).

**Flat 2b: single appearance (owner decision 2026-09-22, beid#627,
[D-627](docs/decisions/issue-627-flat-2b.md); implementation #632).**

- MUST: The app has one appearance and does not follow the OS dark-mode
  setting. A device in dark mode shows the same intended design.
- Black is a **state, not a theme**: a screen is black because something
  is happening now (sensing, the in-progress event card, the Account
  sheet as the layer being operated — §5).
- A dark mode would be considered only if it is ever needed (spec §10-6);
  it is not planned.
- #632 chooses the mechanism (Info.plist, removing the dark variants, or
  another). This document does not choose it. Retiring the FORBIDDEN
  quoted below is what makes #632 implementable.
- MUST: Previews show the single appearance; light *and* dark preview
  pairs are no longer required. Until #632 lands, the existing
  `.preferredColorScheme` preview variants are migration debt.

Kept unchanged:

- SHOULD: High-contrast colorset variants are added at palette ratification;
  until then, high-contrast rendering falls back to the base values and
  must at minimum not lose information. **[Android counterpart: the same
  fallback principle against `BeidPalette`; no high-contrast variant
  mechanism exists in `BeidColorScheme` today, matching iOS's own
  not-yet-added state — not a platform gap, a shared one.]**

> **Superseded 2026-09-22 (owner decision, beid#627,
> [D-627](docs/decisions/issue-627-flat-2b.md)).** The dark-variant MUST,
> the light+dark previews MUST, the gradient-legibility MUST and the
> FORBIDDEN on forcing an appearance in production are replaced by the
> single-appearance rules above. The gradient itself is superseded by the
> Sigil (§5, #633). Provenance: all four are from the initial contract
> (`14ebd53`, NAOE Kenichi, 2026-07-10; §C dates it 2026-07-09;
> structural). Overturned on the owner's authority without Ken's sign-off;
> Ken is to be informed afterwards. Previously (verbatim):
>
> - MUST: Every `DS.Color` token has a dark variant (already true in
>   `Colors.xcassets`); no view opts out of dark mode. **[Android
>   counterpart: every `BeidColorScheme` field has a `*Light`/`*Dark` pair in
>   `BeidPalette` (verified — all thirteen fields present in both, except
>   `statusCaution`, which has neither, per §5's note); no screen opts out of
>   `BeidAppTheme`.]**
> - MUST: PRs adding UI include light *and* dark previews
>   (`.preferredColorScheme` variants in `#Preview`). **[Android counterpart:
>   `@Preview` supports a `uiMode = UI_MODE_NIGHT_YES` parameter for the same
>   purpose. Verified gap: all seven current `@Preview` functions under
>   `ui/screens/` render light-mode only — none passes a night-mode
>   `uiMode` — so this rule does not currently hold on Android. Named as a
>   fact, not fixed here.]**
> - MUST: The proof-card generated gradient remains legible against both
>   canvas values; card text sits on `surfaceRaised`, never directly on the
>   gradient. **[iOS-only as written for now: no Android proof card or
>   gradient generator exists (§5, §10) — nothing to check yet.]**
> - FORBIDDEN: `.colorScheme(.dark)` / `.preferredColorScheme` forced in
>   production views (previews only). **[Android counterpart: forcing
>   `BeidAppTheme(darkTheme = true/false)` instead of the default
>   `isSystemInDarkTheme()` in a production screen call site would be the
>   equivalent violation — verified no screen does this; `darkTheme`'s
>   default is used everywhere `BeidAppTheme` is called in `@Preview`
>   functions and (by omission) at the real app root.]**

## 15. Copywriting Voice

> **Platform scope:** mixed, annotated per bullet. The voice/vocabulary/
> forbidden-term/trust-model/error-formula/CTA-shape rules are
> platform-neutral. The localization *mechanism* (String Catalog) is
> iOS-specific — Android's counterpart is named below, worded like
> AGENTS.md's `LocalizedStringKey`-never-`String` framing for Compose, per
> this task's own brief. **This document does not restate which specific
> locales are currently targeted** — that list has moved at least twice
> (§C decision log shows the 2026-07-10 ratification; AGENTS.md's own
> Localization Process section records further changes since) — see
> AGENTS.md's Localization Process section for the current locale set
> rather than treating any list repeated here as current.
>
> **Flat 2b (2026-09-22):** every rule in this section stays, including
> the forbidden vocabulary; this change only adds annotations. They bind
> iOS copy now and Android's copy as before.

Language model (Ken decision, 2026-07-10): the app's primary language is
**English**, localized via String Catalogs to the confirmed locale set
`en` (source) + `ja`, `zh-Hans`, `es`, `fr` — the full localization process
lives in `AGENTS.md`.

> **Annotation 2026-09-22 (beid#627,
> [D-627](docs/decisions/issue-627-flat-2b.md)).** The sentence above is
> stale and kept for history: "Language model (Ken decision, 2026-07-10):
> the app's primary language is **English**, localized via String Catalogs
> to the confirmed locale set `en` (source) + `ja`, `zh-Hans`, `es`, `fr`".
> Target locales have been `en` only since the owner decision of 2026-08-21
> (`docs/localization-process.md`), and the owner decision of 2026-09-22
> confirms English-only for the Flat 2b UI (settled item B in D-627). The
> String Catalog MUST below is unchanged: the localization mechanism stays
> in place, so no string may bypass the catalog.

- MUST: All copy is authored in English as the source language; the voice,
  vocabulary, and forbidden-term rules below are defined against English.
  **[Platform-neutral; applies to Android's English source strings the
  same way.]**
- MUST: Translations preserve the register per locale (calm/factual,
  ceremonial, recovery — §3); the forbidden-term list maps per language
  (e.g. the Japanese equivalents of "mint"/"NFT" jargon are equally
  forbidden). **[Platform-neutral principle. Which locales this applies to
  is exactly the point this section's platform-scope note above declines
  to restate — see AGENTS.md.]**
- MUST: User-facing strings go through the String Catalog — no hardcoded
  display strings that bypass localization. **[Android counterpart:
  Android string resources (`res/values/strings.xml`) via
  `stringResource()`, never a hardcoded literal in a `Text()`/composable —
  the same rule AGENTS.md's Localization Process states for
  `LocalizedStringKey`, worded for Compose. Verified consistent with
  current Android source: every user-facing string found in `ui/screens/`
  is resolved via `stringResource(R.string.*)`, none hardcoded (test tags
  are the one deliberate exception — `EventJoinScreenTestTags`'s own kdoc
  states test tags are not user-facing copy and so deliberately bypass the
  string catalog, mirroring this rule's own carve-out logic). One gap
  worth naming, not fixing here: AGENTS.md's MUST rule requires
  design-system components to take `LocalizedStringKey`, never `String`,
  specifically so a genuinely dynamic runtime value can't be mistaken for
  copy. Every Android design-system component (`BeidBulletRow`,
  `BeidStatusPill`, `BeidNumberedStepList`, `BeidHeroHeader`,
  `BeidPrimaryButton`, `BeidMetricRow` — verified) takes a plain `String`
  parameter; Kotlin/Compose has no type distinguishing a
  `stringResource()`-sourced value from an arbitrary runtime string the
  way `LocalizedStringKey` does. Today's actual call sites comply in
  practice (verified: every call site passes a `stringResource(...)`
  result, not a raw literal), but nothing in the type system would catch
  a future violation the way it would on iOS.]**
- Per-locale term mapping, Japanese (Ken decision, 2026-07-10): the UI terms
  are **検知** for "Sensing" and **証明** for "Proof". Do NOT "correct" these
  to the team-internal vocabulary (センシング / 証) — plain-user readability
  wins over internal jargon. Future translators: this is a deliberate,
  ratified choice, not an oversight. **[iOS-only as written today: Android
  has no Japanese string resources at all (the target locale set is
  `en`-only per AGENTS.md) — this term mapping has no current Android
  application, not a missing port.]**

  > **Annotation 2026-09-22 (beid#627).** Stale while the target locale
  > set is `en` only (2026-08-21; confirmed for Flat 2b 2026-09-22). Kept
  > verbatim for history and for any future widening of the locale set;
  > the term choice itself was not overturned.

- Vocabulary: "proof", "encounter", "event", "sense/sensing", "collect",
  "seal", "verify". A proof is **collected** or **sealed**, never "minted",
  "dropped", or "claimed". **[Platform-neutral; Android's actual strings
  already comply, e.g. `event_join_button` = "Join event",
  `records_signature_status_bound`/`records_signature_status_self_proof`
  (verified `strings.xml`) — no "minted"/"dropped"/"claimed" found.]**
- FORBIDDEN in user-facing copy: "NFT", "token", "on-chain", "gas", "mint",
  "airdrop", "web3". Wallet copy says what the wallet does for the user
  ("sign your proofs"), not what protocol it speaks. **[Platform-neutral;
  no violation found in current Android `strings.xml` (grepped for each
  forbidden term).]**
- *Flat 2b annotation (2026-09-22,
  [D-627](docs/decisions/issue-627-flat-2b.md)): §15 stays, so these Flat 2b
  strings are **not authorized**:*
  - *"VERIFIED" / "VERIFIED · 6 WINDOWS" (06) / "VERIFIED ON-CHAIN" (07) /
    a STATUS row reading Verified or "Verified on-chain" (09). Owner
    decision 2026-09-22 (settled item A): **"Verified" may be shown only
    after a third party has verified** — the stance of #144/#240
    (`DECISIONS.md` 2026-08-20) stands. "On-chain" is also forbidden above
    on its own. The screen issues choose replacement wording (#636, #637,
    #638).*
  - *"TOKEN ID" (09): "token" is forbidden above (#638).*
  - *"CONNECTED VIA WALLETCONNECT" (10): wallet copy says what the wallet
    does, not what protocol it speaks (#642).*
  - *Open item 3 (D-627) tracks these; the live Figma copy already differs
    from the spec in places (§0) and neither is authorized by that alone.*
- Trust model: beid's whitepaper trust model is a pragmatic compromise and
  the product says so plainly where relevant — settings/about copy states
  what is and isn't cryptographically guaranteed, upfront, in one sentence.
  No overclaiming ("tamper-proof", "trustless") anywhere. **[Platform-
  neutral; Android's `RecordDetailScreen` already practices the
  no-overclaiming half of this rule concretely — see §10's "Detail meta
  row" note on its deliberate never-"Verified" wording.]**
- Grammar: sentence case everywhere, including buttons ("Sense Event" is
  grandfathered until ratification; new CTAs use sentence case —
  `PROPOSAL — Ken ratification pending`). No exclamation marks. Present
  tense. Second person only when instructing. **[Platform-neutral
  principle, still `PROPOSAL` — see #24's dedicated treatment in
  `docs/decisions/issue-339-design-md-android-scope.md`. Android has no
  string that mirrors iOS's specific "Sense Event" grandfather clause (its
  own equivalent CTA is "Join event," already sentence case — verified
  `strings.xml`), and Android's own current CTAs already mix Title Case
  ("Get Started", "Leave Event", "Open Settings") and sentence case ("Join
  event", "Enter event code") exactly the way #24 describes for iOS — this
  is not a new problem Android introduces, it is the same undecided rule
  producing the same mixing pattern on both platforms independently.]**
- *Flat 2b annotation (2026-09-22,
  [D-627](docs/decisions/issue-627-flat-2b.md)): mono labels (DM Mono, §6)
  are **uppercase** by spec; that part of Flat 2b is adopted. Buttons stay
  under the sentence-case `PROPOSAL` above, which is still open (#24).
  **Open item 1:** the nav text controls (`← EVENTS`, `CLOSE`) are both
  labels and controls, so the two rules meet there; also undecided is
  whether uppercase lives in the English source strings or in a style
  transform. Not settled here.*
- Error formula: what happened + why + one action. Model:
  "beid lost the connection to {event}. Move closer and we'll pick it back
  up automatically." + "Try Again". **[Platform-neutral principle; Android
  has no screen dedicated to this exact formula yet — see §11's note on
  the scan-flow recovery branch, whose actual button reads "Resume," not
  "Try Again."]**
- CTAs are verb-first and specific: "Start sensing", "Open Settings",
  "Connect wallet". FORBIDDEN as generic action labels: "OK", "Submit".
  "Continue" MAY be used where the next step is genuinely a continuation
  (multi-step onboarding), with a stated reason; never as a lazy default.
  **[Platform-neutral; Android's current CTAs are verb-first
  (`event_join_button` = "Join event", `event_join_open_settings` =
  "Open Settings") and none of "OK"/"Submit"/"Continue" was found in
  `strings.xml`.]**

## 16. Agent Compliance Checklist

> **Platform scope:** the checklist below is reproduced verbatim (it is a
> literal copy-paste template for PR descriptions, so it is not annotated
> line-by-line the way other sections are — reformatting it would break
> its copy-paste use). Its *content* is platform-neutral item-for-item;
> the specific mechanism each line names (`DS.*`, `scripts/lint.sh`, "pt",
> "SF Symbols") is iOS-specific, and each has an Android counterpart
> already named earlier in this document — `DS.*` → §2/§4's Android
> notes, `scripts/lint.sh` → **no Android counterpart exists** (see the
> new enforcement-layer note below), "44×44 pt" → §2 rule 5's Android note
> (a different platform minimum, 48×48dp, not a unit conversion), "SF
> Symbols"/TODO(asset) → §12's Android note, §15 → its own per-bullet
> notes above, `SignalStrengthNeverRecordedTests` → **no Android
> counterpart exists** (§2 rule 13; Android is out of scope for beid#652).
> Use an Android PR's own checklist by substituting those
> named counterparts, not by pasting the iOS-worded block unchanged.
>
> **Flat 2b (2026-09-22, beid#627,
> [D-627](docs/decisions/issue-627-flat-2b.md)):** the checklist was updated
> for Flat 2b on iOS. The "SF Symbols" mechanism named above is superseded
> by §12's no-icons rule, and "light and dark" by §14's single appearance;
> Android PRs keep substituting their own counterparts, and Android's
> superseded palette is not a violation until an Android follow-up is
> scheduled. The pre-Flat 2b checklist is at `git show 25dec6b:DESIGN.md`
> (lines 1488-1502).

Copy-paste this into every UI PR description and check each item:

```md
## Design Compliance Checklist (DESIGN.md §16)

- [ ] No hardcoded colors, fonts, spacing, radii, or durations in Views (DS.* only).
- [ ] `scripts/lint.sh` passes. ("Passes" = zero violations beyond the checked-in baseline template `lint/baseline.template.json`. I did NOT regenerate the template to absorb new violations; if I migrated a scaffold file I regenerated it to shrink and said so in the PR.)
- [ ] No icons: controls are monospaced text; the OS status bar is the only exception (§12).
- [ ] Text controls whose visible text reads badly aloud (e.g. "←") have accessibility labels.
- [ ] All interactive targets, including text controls, are ≥ 44×44 pt.
- [ ] No glass, material, blur, shadow, or gradient (§8).
- [ ] Semantic colors (red/amber/green) only for their one meaning, and as text only where AA passes (on ink) (§5).
- [ ] Single-appearance previews attached (screenshots or #Preview); the app does not follow OS dark mode (§14).
- [ ] Dynamic Type checked at AX3 or larger with the bundled fonts — no clipped text; row/button heights are minimums.
- [ ] Graphs and Sigils carry a VoiceOver summary (§13).
- [ ] Empty/error/loading states implemented for new surfaces (empty = dashed block, §8).
- [ ] State is never conveyed by color alone.
- [ ] No new field reaching persistence, signature input, or the submission payload carries signal strength, or anything derived from it (§2.13). ("No" = I read the diff for it; a green `SignalStrengthNeverRecordedTests` is necessary, not sufficient.)
- [ ] Copy follows §15 (English source, String Catalog, vocabulary, no web3 jargon, error formula; no unauthorized Flat 2b strings).
- [ ] Any deviation carries `DesignException: <rationale or link>`.
```

Enforcement layers:

1. **Lint-level**: `.swiftlint.yml` encodes six custom rules —
   `no_hardcoded_swiftui_color`, `no_hardcoded_swiftui_font`,
   `no_hardcoded_spacing`, `no_hardcoded_radius`, `no_hardcoded_animation`,
   `no_glass_or_material` — activated via `only_rules: [custom_rules]`,
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
   Hosted enforcement and lane ownership follow the repository's
   authoritative [PR CI contract](AGENTS.md#pr-ci) and its executable
   workflow, `.github/workflows/pr-ci.yml`; this document does not duplicate
   that job list.

   The lint layer intentionally catches the common ~80% of violations —
   direct call-site literals. The long tail is **review-level MUST**, not
   lint-covered: values laundered through expressions or variables
   (`CGFloat(16)`, `let pad = 20`), negative paddings, `cornerSize:`,
   animation curves inside `withAnimation { }` bodies or
   `Transaction(animation:)`, raw color/value strings inside string
   literals, decorative-symbol size (§12), the one-accent map (§5), hit
   targets, and Dynamic Type behavior. An honest 80% lint layer plus
   review beats a broken 100% regex.

   *Flat 2b note (2026-09-22): the lint layer does **not** cover the Flat
   2b rules. `.swiftlint.yml` does not ban `glassEffect`,
   `Image(systemName:)` or `preferredColorScheme` today (checked
   2026-09-22), so no-glass, no-icons and single-appearance are
   review-level until a lint rule lands. Any such rule belongs to #628,
   #630, #631 or #632, not to this document. (The decorative-symbol size
   and one-accent map named above are superseded, §12 and §5.)* Since
   #630 (2026-09-23) no-glass is lint-covered: `no_glass_or_material`,
   scoped to `ios/Beid` like the other rules but, unlike them, with no
   excluded paths, so `ios/Beid/DesignSystem/` is covered too, flags
   `glassEffect`, `GlassEffectContainer`, the glass button styles,
   `Material` and its members, and the `.bar` shape style. No-icons and
   single-appearance are still review-level.
2. **Review-level**: the checklist above.
3. **Exception process**: a PR that must deviate states
   `DesignException: <reason>` in its description and links the decision;
   silent deviations are rejected.
4. **Platform scope — enforcement asymmetry (Android), stated precisely,
   not as "automated vs. review-level."** No detekt or ktlint
   configuration exists anywhere under `android/` as of this writing (§0,
   §2). That means what actually happens per PR is not symmetric with
   "lint-level + review-level" on either platform, and it must not be
   described that way: this repository's independent-review gate is
   currently **suspended repo-wide** (AGENTS.md's "Review gate — SUSPENDED
   as of 2026-08-19" section) — a PR merges once CI is green, with no
   independently dispatched reviewer required, on *either* platform.
   Stated plainly, per platform:
   - **iOS**: `scripts/lint.sh` (SwiftLint, items 1–4 and 8's cap) runs in
     PR CI, **plus** the author's own review for every other item.
   - **Android**: the author's own review, for every item, and nothing
     else. No lint mechanism exists to catch even the "common 80%"
     call-site literals (§2, §4's Android notes) automatically.

   This is not a lag this document should paper over: a rule this section
   calls MUST/FORBIDDEN, checked by nobody but the person who wrote the
   code, is discovered when it's violated, not enforced beforehand — which
   is the exact failure shape beid#335/#339 exist to fix in the first
   place. AGENTS.md's own stated reason for suspending the independent-
   review gate applies directly here, not as an outside argument: "A gate
   that is documented but never runs is worse than no gate, because it
   gets cited as though it were in force." A DESIGN.md that quietly reads
   as binding Android, while only iOS has a lint gate and neither platform
   has independent review, would become exactly that. See the decision
   doc's cost analysis for how this bears on the Option A/B choice.
5. **Test-level (§2 rule 13 only)**:
   `ios/BeidTests/SignalStrengthNeverRecordedTests.swift` (beid#652) goes
   red if signal strength reaches persistence, signature input or the
   submission payload. What it pins is the observable *outputs* — the
   persisted bytes, the signature input, the payload — not the shape of the
   code that produces them, which is where the guarantee actually lives.
   So it is necessary, not sufficient: a green suite does not substitute
   for reading the diff for a new field, which is what the checklist line
   above asks for. iOS only — Android is out of scope for beid#652, so
   nothing of this kind exists there.

Known pre-existing lint debt is the exact five-entry set recorded in
`lint/baseline.template.json`, all in `ios/Beid/DesignSystem.swift` at the
last verification point. #628 shrank it from eight: it removed
`BeidDesign`'s `soft` animation by moving its value into
`DS.Motion.screenTransition`, and dropped two entries
(`HStack(spacing: 12) {` and `.font(.body.weight(.semibold))`) that were
already stale before #628 — neither text was in `DesignSystem.swift`. The
screen-level phase-2 migration has landed; do not describe every screen
as scaffold debt or use the baseline as permission to add another
violation. **[iOS-only as written: Android has
no lint baseline of any kind, since it has no lint mechanism at all (item
4 above) — there is no Android equivalent list to keep current or point
to.]**

## 17. Appendices

### A. Token table (excerpt — canonical values live in Tokens.swift)

> **Platform scope:** iOS-specific mechanism — Android counterpart named
> per row below. This table has no Android column; per §4's rule, adding
> Android tokens to §17 in the same PR that adds them is a rule this
> document does not yet state for Android — the notes below are this
> pass's inventory, not a commitment to keep a parallel table current
> going forward.

> **Migration debt (2026-09-22, beid#627,
> [D-627](docs/decisions/issue-627-flat-2b.md)).** This table describes
> today's `Tokens.swift`. #628's part is done (2026-09-23): the colors,
> space, radius and size rows below are the Flat 2b tokens. #629's is done
> too (2026-09-23): `DS.Font` is the bundled Flat 2b ramp (§6, including
> its two named gaps). #633 (artwork) remains, so `DS.Artwork` is still the
> pre-Flat 2b value (§5).

| Token | Swift | Value | Role |
| --- | --- | --- | --- |
| `color.surface.canvas` | `DS.Color.surfaceCanvas` | `bg` `#FFFFFF` | Page ground |
| `color.surface.tile` | `DS.Color.surfaceTile` | `tile` `#F2F2F4` | Gray tiles, timeline track |
| `color.text.primary` | `DS.Color.textPrimary` | `ink` `#0B0B0F` | Primary text and marks on the page ground |
| `color.text.secondary` | `DS.Color.textSecondary` | `sub` `#6E6E78` | Secondary text, section labels on the page ground |
| `color.text.secondary.onInk` | `DS.Color.textSecondaryOnInk` | `on-ink/sub` `#8E8E96` | Secondary text on an `ink` ground |
| `color.stroke.hairline` | `DS.Color.strokeHairline` | `line` `#ECECF1` | 1pt row and list dividers on the page ground |
| `color.stroke.hairline.onInk` | `DS.Color.strokeHairlineOnInk` | `on-ink/line` `#2A2A31` | Dividers, graph rings, future-window bars on `ink` |
| `color.stroke.emptyState` | `DS.Color.strokeEmptyState` | `line-dashed` `#C9C9CF` | Dashed 1pt `Block/Empty` frame |
| `color.chart.detected` | `DS.Color.chartDetected` | `chart-muted` `#D9D9DE` | "Detected" bars in charts |
| `color.graph.node.idle` | `DS.Color.graphNodeIdle` | `on-ink/idle` `#5C5C66` | Detected-only (idle) graph nodes on `ink` |
| `color.action.primary` | `DS.Color.actionPrimary` | `ink` `#0B0B0F` | `Button/Primary` Tone=Primary fill; app-level tint |
| `color.label.onActionPrimary` | `DS.Color.labelOnActionPrimary` | `bg` `#FFFFFF` | Label on an `actionPrimary` fill |
| `color.action.inverse` | `DS.Color.actionInverse` | `bg` `#FFFFFF` | `Button/Primary` Tone=Inverse fill (black screens, black sheet) |
| `color.label.onActionInverse` | `DS.Color.labelOnActionInverse` | `ink` `#0B0B0F` | Label on an `actionInverse` fill |
| `color.status.on` | `DS.Color.statusOn` | `semantic/green` `#30D158` | Active / on — dot on `bg`; text only on `ink` |
| `color.status.pending` | `DS.Color.statusPending` | `semantic/amber` `#FF9F0A` | Verifying / pending — dot on `bg`; text only on `ink` |
| `color.status.off` | `DS.Color.statusOff` | `semantic/red` `#FF453A` | Destructive / off — dot on `bg`; text only on `ink` |
| `space.m` | `DS.Space.m` | 16 pt | Default gap |
| `space.page.margin` | `DS.Space.pageMargin` | 24 pt | Full-width content and bottom CTAs (was 32) |
| `space.emptyBlock.vertical` | `DS.Space.emptyBlockVertical` | 40 pt | `Block/Empty` vertical padding |
| `radius.card` | `DS.Radius.card` | 16 pt | Cards |
| `radius.glyph` | `DS.Radius.glyph` | 24 pt | `BeidGlyph` icon roundel (from `BeidDesign`; removed with icons in #631) |
| `radius.emptyBlock` | `DS.Radius.emptyBlock` | 16 pt | `Block/Empty` frame |
| `radius.nowCard` | `DS.Radius.nowCard` | 20 pt | The now-sensing `ink` card on Home (#635) |
| `layout.state.content.maxWidth` | `DS.Layout.stateContentMaxWidth` | 600 pt | Readable state-screen and CTA width in regular size classes |
| `layout.collection.content.maxWidth` | `DS.Layout.collectionContentMaxWidth` | 960 pt | Maximum collection width in regular size classes |
| `layout.grid.card.minimum.regular` | `DS.Layout.regularGridCardMinimumWidth` | 260 pt | Minimum proof-card width in regular grids |
| `layout.grid.card.minimum.compact` | `DS.Layout.compactGridCardMinimumWidth` | 150 pt | Minimum proof-card width in compact grids |
| `size.status.dot` | `DS.Size.statusDot` | 8 pt | `BeidStatusPill` dot diameter |
| `size.hairline` | `DS.Size.hairline` | 1 pt | The hairline rule's thickness |
| `size.emptyBlock.dash` | `DS.Size.emptyBlockDash` | 4 pt | `Block/Empty` dash and gap length ([4, 4]; #630) |
| `size.row.list.minHeight` | `DS.Size.listRowMinHeight` | 92 pt | `Row/List` minimum height |
| `size.row.keyValue.minHeight` | `DS.Size.keyValueRowMinHeight` | 44 pt | `Row/KeyValue` minimum height |
| `size.row.session.minHeight` | `DS.Size.sessionRowMinHeight` | 48 pt | Session row minimum height |
| `size.row.report.minHeight` | `DS.Size.reportRowMinHeight` | 60 pt | Report row minimum height |
| `size.row.proof.minHeight` | `DS.Size.proofRowMinHeight` | 72 pt | Proof row minimum height |
| `size.button.primary.minHeight` | `DS.Size.primaryButtonMinHeight` | 56 pt | `Button/Primary` Size=Large minimum height |
| `size.button.primary.compact.minHeight` | `DS.Size.compactPrimaryButtonMinHeight` | 52 pt | `Button/Primary` Size=Small minimum height |
| `size.button.primary.compact.width` | `DS.Size.compactPrimaryButtonWidth` | 140 pt | `Button/Primary` Size=Small width (Home's Scan) |
| `size.bullet.icon` | `DS.Size.bulletIcon` | 32 pt | `BeidBulletRow` icon roundel (from `BeidDesign`) |
| `size.step.badge` | `DS.Size.stepBadge` | 28 pt | `BeidNumberedStepList` index badge (from `BeidDesign`) |
| `size.radar.field` | `DS.Size.radarField` | 210 pt | Sensing radar frame (`SensingView`) |
| `size.radar.core` | `DS.Size.radarCore` | 86 pt | Sensing radar center glyph (`SensingView`) |
| `size.proofCard.artwork` | `DS.Size.proofCardArtwork` | 76 pt | `ProofCardView` circular gradient-avatar diameter |
| `size.itemDetail.artwork` | `DS.Size.itemDetailArtwork` | 190 pt | `ItemDetailView` circular gradient-avatar diameter |
| `type.screen.title` | `DS.Font.screenTitle` | `Library.display46` — Bricolage Grotesque ExtraBold 46 / `.largeTitle` | Screen titles |
| `type.section.title` | `DS.Font.sectionTitle` | `Library.title19` — DM Sans Bold 19 / `.title3` | State and section titles |
| `type.ledger.mono` | `DS.Font.ledgerMono` | `Library.labelMono13Value` — DM Mono Medium 13 / `.footnote` | Addresses, hashes, proof IDs |
| `motion.proof.resolve` | `DS.Motion.proofResolve` | spring 0.6/0.8 | Seal ceremony |
| `motion.screen.transition` | `DS.Motion.screenTransition` | spring 0.36/0.88 | Root screen and scan-flow phase switches (from `BeidDesign.Animation.soft`) |

(Full set: 17 color tokens, 8 space, 7 radius, 18 size, 4 layout, 8 font
roles over 17 `DS.Font.Library` styles (§6; #629 removed `ceremonyTitle`,
which had no call site, taking the roles from 9 to 8),
7 motion, plus 1 artwork generator — see
`ios/Beid/DesignSystem/Tokens.swift`. Hex values are the primitive
colorset's Library variable (§4, §5); illustrative only, §0. The
`Button/Primary` Size=Large width, 354, is not a token: it is the full
content width at `pageMargin` 24. Row, button and key-value heights are
minimums (§6). Removed by #628: `DS.Color.surfaceRaised`, `signalActive`,
`signalWarning`, `proofSeal`, `labelOnWarning`, `labelOnSeal` and
`statusCaution` (§5). An earlier version of this table listed
`DS.Size.qrCode` (220 pt, `WalletConnectPairingView`); `Tokens.swift` had
no such token at f9e9251, so the row was dropped.)

**Android counterparts, verified against `ui/theme/{Color.kt,Spacing.kt,
Type.kt}` (2026-09-07; names rechecked against `Color.kt`/`Spacing.kt`
2026-09-23). Android's theme still implements the superseded palette and
values, which is not a violation until an Android follow-up is scheduled
(§0):**

- **Exist today**, same role and name (Android values are the superseded
  ones): `color.surface.canvas` → `BeidTheme.colors.surfaceCanvas`;
  `color.text.primary`/`color.text.secondary` → `.textPrimary`/
  `.textSecondary`; `color.stroke.hairline` → `.strokeHairline`;
  `color.action.primary` → `.actionPrimary`;
  `color.status.on`/`color.status.off` → `.statusOn`/`.statusOff` (on
  Android still the old green / neutral-gray pair, not `semantic/green`/
  `semantic/red`); `space.m` → `BeidSpacing.m`; `space.page.margin` →
  `BeidSpacing.pageMargin` (still 32dp, §7); `radius.card` →
  `BeidRadius.card`; `radius.glyph` → `BeidRadius.glyph`;
  `size.status.dot` → `BeidSize.statusDot`; `size.bullet.icon`/
  `size.step.badge` → `BeidSize.bulletIcon`/`.stepBadge`;
  `type.section.title` → `MaterialTheme.typography.titleLarge` (§6's role
  mapping).
- **Removed on iOS by #628, kept on Android** under the superseded
  palette: `BeidTheme.colors.surfaceRaised`, `.signalActive`,
  `.signalWarning`, `.proofSeal`, `.labelOnWarning`, `.labelOnSeal`.
  (`statusCaution` never had an Android counterpart, §5.)
- **Do not exist yet** (honest gap, not a rename — each depends on a
  screen or feature Android doesn't have, per §11/§9's notes, or on the
  Android Flat 2b follow-up that is not scheduled): the ten new Flat 2b
  colors (`color.surface.tile`, `color.text.secondary.onInk`,
  `color.stroke.hairline.onInk`, `color.stroke.emptyState`,
  `color.chart.detected`, `color.graph.node.idle`,
  `color.label.onActionPrimary`, `color.action.inverse`,
  `color.label.onActionInverse`, `color.status.pending`);
  `space.emptyBlock.vertical`; `radius.emptyBlock`/`radius.nowCard`;
  `size.hairline` and the `size.row.*`/`size.button.primary.*` minimums;
  the four `layout.*` entries (no regular-width/tablet layout class exists
  on Android at all — §7); `size.radar.field`/`size.radar.core` (no
  `SensingView` equivalent); `size.proofCard.artwork`/
  `size.itemDetail.artwork` (no proof-card/item-detail artwork — §5, §10);
  `motion.proof.resolve` and `motion.screen.transition` (no
  `DS.Motion`-equivalent namespace exists — §9).

### B. Asset inventory

> **Platform scope:** iOS-only as written for now. **[Android counterpart:
> no custom drawable/illustration assets exist under
> `android/app/src/main/res` as of this writing — verified, zero files
> under any `drawable*` directory. This is a current fact, stated as a
> parity principle per §12's note above, not a permanent claim — beid#338
> is active work in this area.]**

`Illustrations.xcassets` currently contains four original-rendering SVG image
sets, each with light and dark variants:

- `welcome-mark` — `WelcomeView`
- `encounter-field-empty` — the `CollectionHomeView` empty state
- `encounter-field-pulse` — `SensingView`
- `proof-seal-mark` — the one-time `RecordingView` entrance ceremony

The image-set directories and the four `assetImage:` call sites are the
inventory evidence. Naming remains governed by §12.

> **Migration debt (2026-09-22, beid#627,
> [D-627](docs/decisions/issue-627-flat-2b.md)).** These four assets and
> their dark variants stay in the code until #631/#632/#633/#643 replace
> them (Sigil hero, dashed empty block, sensing graph). Flat 2b has no image
> assets (§12); this inventory describes today's code.

### C. Decision log

> **Platform scope:** iOS-only as written — every entry below records an
> iOS-side ratification or revision; none mentions Android. This document
> does not add a row for beid#339 itself; that decision belongs in
> `docs/decisions/issue-339-design-md-android-scope.md` and, once the
> owner decides, in `DECISIONS.md` per this repository's normal process —
> not invented here as a new log entry ahead of that decision.
>
> **2026-09-22 rows:** the Flat 2b rows bind iOS first (owner decision);
> the full record, with verbatim old rules and provenance, is
> [`docs/decisions/issue-627-flat-2b.md`](docs/decisions/issue-627-flat-2b.md).

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
| 2026-07-12 | Proof-signing feature adds `DS.Color.statusCaution` (declined/timed-out/failed wallet-signature status, deliberately separate from `signalWarning`'s BLE-only scope) and documents `ProofCardView`'s "default only" states note as superseded by `ItemDetailView` and the then-current Screen 07 carrying the new signature states instead of the card itself. Scan Slice-2 later retired separate Screen 07; `ItemDetailView` is the current signing-control surface. | PROPOSAL — Ken ratification pending for the exact `statusCaution` hex values, same as other secondary hexes |
| 2026-07-27 | Account sheet reskin (Figma `104:463`, `docs/specs/account-redesign.md`) adds `DS.Color.statusOn`/`DS.Color.statusOff` (binary Bluetooth on/off status pair, deliberately separate from `signalWarning`'s BLE-signal-*quality*-only scope, `statusCaution`'s signature-failure-only scope, and `signalActive`'s reserved sensing-screen-accent scope), replacing `AccountSheetView`'s raw `.orange`/`.green` (Non-Negotiable #1 fix). `statusOn`'s hue is sourced from Figma's Bluetooth badge (`#34C759`) but darkened for light mode to clear WCAG AA text contrast (the raw Figma value measures ~2:1 on white, well under the 4.5:1 text minimum); `statusOff` has no Figma reference (Figma's mock never draws the "off" state) and uses a neutral gray pair instead of an alarm hue, since Bluetooth-off in the Account sheet is a neutral toggle state, not the degraded-signal alarm `signalWarning` already owns | PROPOSAL — Ken ratification pending for the exact `statusOn`/`statusOff` hex values, same as other secondary hexes |
| 2026-07-28 | Collection Home reskin (Figma `104:300`, `docs/specs/collection-redesign.md`) adds `DS.Size.proofCardArtwork` (76 pt) and wires the previously-unused `DS.Artwork.proofCardGradient(seed:)` into `ProofCardView` as a centered circular avatar, replacing the seal icon/checkmark/divider/Peers-verified row (peers count stays on `ItemDetailView`). Bottom "Sense Event" CTA becomes icon-only once proofs exist (labeled CTA retained on the 04b empty state per §3's first-run-discoverability rule); the existing localized "Sense Event" string is retained as the icon button's `.accessibilityLabel`, not removed. `CollectionHomeView`'s empty-state icon fixed to the 32 pt cap (see §12) | Adopted (no new PROPOSAL tag — reuses existing ratified tokens/artwork generator, no new color) |
| 2026-07-28 | Item Detail reskin (Figma `104:407`, `docs/specs/itemdetail-redesign.md`) adds `DS.Size.itemDetailArtwork` (190 pt) and reuses `DS.Artwork.proofCardGradient(seed:)` in `ItemDetailView` at detail scale, replacing the former seal-glyph + "Verified"-label header. The Method/Peers-verified/Status panel drops its plain "Proof" section title and pairs the Status row with a `checkmark.circle.fill` glyph; Status stays a fixed, unconditional "Verified" deliberately decoupled from `Proof.signatureState` (that state has its own distinct readout in `ProofSignatureControlsView` directly below), and Figma's "on-chain" qualifier is dropped as unmodeled and forbidden copy (§15). Figma's venue text ("Tokyo Big Sight") is not rendered — no backing `Proof` field — and the date caption drops to date-only (medium style, no time), matching `ProofCardView`. Figma's custom back/share nav pills are not adopted (standard back button kept; no share action exists in the app). `ProofSignatureControlsView`/`ProofSignatureState`/`Proof`/`ProofStore` are untouched — reskin is display-chrome only, pending Option C. **Superseded (2026-08-11):** Option C landed (gh#88), and the provisional signing path this row names (`ProofSignatureControlsView`) was removed per gh#196 — see the 2026-08-11 row below | Adopted (no new PROPOSAL tag — reuses existing ratified tokens/artwork generator, no new color) |
| 2026-08-11 | AttendanceProof/v1 manual signing path removed (`docs/specs/attendance-proof-v1-removal.md`, gh#196): `ProofSignatureControlsView` (and its call site in `ItemDetailView`, and `AppCoordinator.signProof(_:)`) deleted outright. `Proof.signatureState`, `ProofSignatureState`, `SignatureRecord`, and `SignaturePayload` are kept as-is (Codable-compatibility for historical local data, per `DECISIONS.md`'s 2026-08-09 schema-migration ruling) — they simply never transition again. Item Detail gains no replacement control; the Barnard-conformant binding model (gh#88) is the real protocol-level self-proof mechanism now, surfaced during the connect+binding interstitial, not on this screen | Adopted |
| 2026-09-22 | **Flat 2b adopted** as the design authority (beid#626/#627, [D-627](docs/decisions/issue-627-flat-2b.md)): Figma Library `189-2` for values, Screens `183-2` for layouts; Minimal v4 and the Liquid Glass-era Fixed page become historical. §0's "the code is right, fix the document" MUST is replaced by a transition clause (#628–#632) and a steady-state rule (Library = design authority for values; `Tokens.swift` = what ships; Library-vs-code mismatch is a defect to file). Product name stays beid ("SenseProof" is the designer's mistake) | Adopted — owner decision 2026-09-22 without Ken's sign-off; Ken to be informed afterwards |
| 2026-09-22 | §5 palette overturned: the ratified direction (deep ink + teal + violet; `8076f04`, §C Ken-ratification row 2026-07-10), the token table, and the one-motif-accent MUST (`79cd005`) → black/white/grays + red/amber/green semantic colors, no per-event colors (#628) | Adopted — owner decision 2026-09-22 without Ken's sign-off; Ken to be informed afterwards |
| 2026-09-22 | §8/§8a Liquid Glass overturned: the `glassEffect` MUST and Materials bullet (`79cd005`), the blur FORBIDDEN (`14ebd53`), and all of §8a including "ふんだんに" (`0d6394f`, 2026-07-22, PR #49) → no glass, materials, blur, shadows or gradients; hairlines and whitespace (#630) | Adopted — owner decision 2026-09-22 without Ken's sign-off; Ken to be informed afterwards |
| 2026-09-22 | Per-proof gradient overturned as the sanctioned artwork (§5 `79cd005`; §10 `0787306`, 2026-07-28; §14 `14ebd53`) → the Sigil, generated from observation data (#633); `proofCardGradient` is migration debt until then | Adopted — owner decision 2026-09-22 without Ken's sign-off; Ken to be informed afterwards |
| 2026-09-22 | Icons overturned: §12's SF Symbols/custom-assets policy, 32pt cap, asset pipelines and `TODO(asset)` path (`14ebd53`, `79cd005`, `b65d5c9`); §10/§11 close (X) (`88a5beb`, 2026-07-27); §13's icon-only account-button example → no icons, monospaced text controls, OS status bar only (#631) | Adopted — owner decision 2026-09-22 without Ken's sign-off; Ken to be informed afterwards |
| 2026-09-22 | Dark mode overturned: §2 rule 7, §5's adaptive-colorset MUST, §14's dark-variant, light+dark-preview and gradient-legibility MUSTs and the FORBIDDEN on forcing an appearance in production (all `14ebd53`) → single appearance; black is state, not theme (#632 picks the mechanism) | Adopted — owner decision 2026-09-22 without Ken's sign-off; Ken to be informed afterwards |
| 2026-09-22 | §6 SF Pro ramp `PROPOSAL` (`14ebd53`, never ratified) superseded by Bricolage Grotesque / DM Sans / DM Mono, bundled (#629). Recorded as a superseded proposal, not an overturned rule | Superseded proposal — owner decision 2026-09-22 |
| 2026-09-22 | Settled by the owner (relayed by the PM): (A) "Verified" only after third-party verification — #144/#240 stance stands, Flat 2b's VERIFIED strings not authorized (#636/#637/#638); (B) English-only UI, consistent with the 2026-08-21 `en`-only locale policy, String Catalog MUST unchanged; (C) SHARE is not built — the 2026-07-28 rejection stands (#631/#638) | Adopted — owner decision 2026-09-22 |
| 2026-09-23 | **Flat 2b tokens landed** (beid#628): `DS.Color` is 17 tokens named by role over 13 single-appearance primitive colorsets named after the Library variables (§4, §5); several roles may share a primitive. Of the 8 old tokens with no Flat 2b counterpart, `signalActive`, `signalWarning`, `proofSeal`, `statusCaution`, `labelOnWarning` and `labelOnSeal` were removed (tints → `actionPrimary`; text and icons → `textPrimary`; dots → `statusOn`/`statusPending`/`statusOff`), and `statusOn`/`statusOff` were mapped to `semantic/green`/`semantic/red`; `surfaceRaised` was also removed (→ `surfaceCanvas`). `Button/Primary` tone pairs: `actionPrimary`/`labelOnActionPrimary` (Tone=Primary) and `actionInverse`/`labelOnActionInverse` (Tone=Inverse). `DS.Space.pageMargin` 32 → 24, new `emptyBlockVertical`, `DS.Radius.glyph`/`emptyBlock`/`nowCard`, new row/button minimum sizes and `DS.Motion.screenTransition`. `BeidDesign`'s duplicate scales folded into `DS` (content spacing 14 → 16, card radius 18 → 16, control radius 14 → 12); only `haptic(_:)` remains in `BeidDesign` | Adopted — token naming delegated to #628 by D-627 |
| 2026-09-23 | **Flat 2b surfaces landed** (beid#630): `beidSurface` is a `surfaceCanvas` fill plus a 1px `strokeHairline` border (glass path, `Material` fallback and its `interactive:`/`fallback:` parameters removed); `BeidGlassGroup` and its 7 wrappers deleted; the glass button styles replaced (`BeidPrimaryButton` `.borderedProminent`, `BeidSecondaryButton` `.bordered`, both a `DS.Radius.control` rounded rectangle; Home's icon Scan button a `.borderedProminent` circle); all 5 `#available(iOS 26, *)` branches removed (deployment target still iOS 17); the scan-flow cover's `.regularMaterial` and the Home/Sensing insets' `.background(.bar)` → opaque `surfaceCanvas` (insets with a top `strokeHairline` rule); new `BeidEmptyBlock` (`Block/Empty`, `DS.Size.emptyBlockDash` 4 from the 2026-09-23 Figma read) replaces `BeidPanel` at the 04b and empty-day states; new lint rule `no_glass_or_material` (six custom rules). Open gaps named, not fixed: the primary button is not yet a pill (`Button/Primary` unassigned), and `.bordered` is a system tint fill, not `bg` + `line`. The Account sheet's background is `surfaceCanvas` as an interim value replacing the OS-default sheet glass; #642 takes it to `ink`. Left as is: the OS-drawn toolbar/navigation-bar glass (#631), `EventCardView`'s `.tint.opacity` badge, `DS.Artwork.proofCardGradient` (#633) | Adopted — implements the 2026-09-22 §8/§8a decision |
| 2026-09-23 | **Flat 2b type ramp landed** (beid#629): the three OFL families (Bricolage Grotesque ExtraBold, DM Sans Bold/Regular, DM Mono Medium) are bundled, and `DS.Font` becomes two tiers — `DS.Font.Library`, the 17 Library text styles as `DS.Font.Style` values, and the 8 role tokens Views use, re-pointed onto them with no call site changed (§6). `ceremonyTitle` removed (no Swift call site). Text styles: nearest-default-size per style, `.largeTitle` for all five Display styles — `UIFontMetrics` applies one constant multiplier per (text style, content size category), quantised to 1/3 pt, and that multiplier is not the style's own size ratio; measured at AX3 on iOS 26.5, `.largeTitle` is about 1.49 against `.body`'s 2.18 and `.caption2`'s 2.69, so Display/60 reaches 89.33 pt at AX3 and 102.33 pt at AX5, versus 131.0 pt and 169.0 pt on `.body`'s curve. Uppercase: the three mono *label* styles only — the mono *value* styles stay mixed-case because EIP-55 addresses carry their checksum in letter case. Tabular figures: `Display/Number 40` only. `beidTextStyle(_:)` in `Tokens.swift` applies a whole style (tracking and line height scaled with Dynamic Type, case); plain `.font(DS.Font.x)` call sites still get family/size/Dynamic Type only — a named transitional gap. Display's 100% line height is **not** applied: `lineSpacing` is additive and nonnegative and `View.lineHeight(_:)` is iOS 26+, above the iOS 17 deployment target — also a named gap. #24 (button capitalization) untouched: #629 uppercases no existing string | Adopted — text-style, uppercase-scope and tabular-figure choices delegated to #629 by §6/D-627 |

### D. Deprecated patterns

> **Platform scope:** iOS-specific mechanism — Android counterpart named.
> The underlying prohibitions (no default-blue tint, no oversized
> decorative symbols, no fixed-size fonts, no raw padding, no ad hoc hue
> math) are platform-neutral; each named API is iOS's.

Patterns new code must not introduce: `.tint(.blue)` as brand accent,
oversized decorative SF Symbols, `.font(.system(size:))` in Views, raw
padding literals, and `Color(hue:)` outside the designated artwork
generator.

*Flat 2b annotation (2026-09-22,
[D-627](docs/decisions/issue-627-flat-2b.md)): under Flat 2b new code also
must not introduce any SF Symbol or icon (§12), glass/material/blur/shadow/
gradient (§8), per-event hues (§5), or a forced dark variant (§14). The
"designated artwork generator" is migration debt until #633, and may not be
extended.*

**[Android counterpart: a default Material3 blue as brand accent (verified
not present — `Theme.kt` wires `actionPrimary` explicitly, §5); oversized
decorative `Icon`/`ImageVector` beyond 32dp (§12); `fontSize = N.sp`
literals in Views (§2, §6); raw `Dp`/`sp` padding literals outside
`ui/theme/` (§2 rule 3); `Color(hue = ...)` math outside a designated
artwork generator — moot today since no such generator exists on Android
(§5).]**
