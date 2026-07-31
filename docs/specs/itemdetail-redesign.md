# Spec — 08 Item Detail redesign (Beid iOS)

Status: **APPROVED — cleared for implementation.** All three open items in
§5 resolved by PM; resolutions recorded in place below (§5 kept as a record
of the decision, not as open questions).
Owner: SubPM a-20260728-016, for PM a-20260727-036.
Scope strategy: model-independent visual reskin of Item Detail's *display*
chrome only, explicitly isolating the shared signing component pending
Option C (see §1 OUT).
Survey: `docs/redesign-itemdetail-survey.md`. Figma:
`xf2uFHceIYg0h0gJndUkmI` node `104:407` ("08 Item Detail").

## 1. Scope

**IN**: visual reskin of `ios/Beid/Views/ItemDetailView.swift`'s header/
artwork block and its Method/Peers-verified/Status metadata panel to Figma
`104:407`, keeping current behavior (read the `Proof` passed in via
`navigationDestination(item:)`, render `ProofSignatureControlsView`
unchanged below it).

**OUT (defer)**:
- **`ProofSignatureControlsView` and `ProofSignatureState`** — shared with
  `07 Proof Collected`, expected to be replaced by Option C. Not reskinned,
  not restructured, not moved out of its current `BeidPanel` wrapper beyond
  whatever layout shift is mechanically required by the surrounding
  `VStack`/`BeidGlassGroup` change (see §3.3). No change to its copy,
  tokens, or states.
- Any change to `Proof`/`ProofStore` schema, a venue/location field, an
  on-chain/protocol-verification field or state — see survey §4/§5.
- A share action — no equivalent exists in the app today; adding one is new
  product behavior requiring its own spec (what gets shared, in what
  format), not a visual reskin. Custom back-button chrome — the standard
  system back button already satisfies this, per DESIGN.md §2.10 and the
  04 Collection spec's identical precedent (§5.1 there).
- Any change to `CollectionHomeView`/`ProofCardView` (already shipped, PR
  #71) beyond nothing — this slice touches `ItemDetailView.swift` only.

## 2. Source-of-truth precedence

Decision record > Figma > current code, per DESIGN.md §0. Figma's raw pixel
values (28 px artwork-card radius, 22 px verification-panel radius, 40 px
card padding, the `#f2f2f7` fill, the `#34C759` green) are a *layout*
reference only — map to existing `DS.*` tokens wherever a token with the
right role already exists; a genuinely new role (the item-detail artwork
diameter, §4) may source its literal value from Figma's measurement, the
same way `DS.Size.proofCardArtwork` (76 pt) did in the 04 Collection spec.

## 3. Screen spec

### 3.1 Nav chrome — RESOLVED: no change

Keep the standard system nav bar exactly as today: automatic back button
(from `navigationDestination(item:)`), `.navigationTitle("Proof Detail")`,
`.navigationBarTitleDisplayMode(.inline)`. Figma's custom back-pill is not
adopted (duplicates standard chrome, DESIGN.md §2.10). Figma's share pill
is not adopted (§1 OUT) — no toolbar item is added.

### 3.2 Header / artwork block (node `104:439`/`104:443`, replaces the
current header `BeidPanel`)

- Remove the current header `BeidPanel` entirely: the `BeidGlyph(seal.fill,
  proofSeal, 72)` leading glyph and the trailing `Label("Verified",
  checkmark.circle.fill)` are both dropped. (The "Verified" meaning they
  carried is not lost — it is consolidated into the single Status row in
  §3.3; showing it twice on one screen, once near the artwork and once in
  the metadata panel, is the duplication Figma's own layout resolves by
  only drawing it once.)
- Add an artwork card: `Circle().fill(DS.Artwork.proofCardGradient(seed:
  proof.gradientSeed))`, sized via a new `DS.Size` token (§4), centered
  inside a container styled with `.beidSurface(interactive: false,
  cornerRadius: DS.Radius.seal)` — **not** `BeidPanel`, since `BeidPanel` is
  hardwired to `DS.Radius.card` (survey §2) and Figma's 28 px card radius
  maps exactly to the existing `DS.Radius.seal` (28 pt) role, which is
  thematically apt here (a proof-seal-adjacent artwork moment, §8's "Seal/
  ceremony surfaces use `DS.Radius.seal`"). Vertical padding around the
  circle uses `DS.Space.xl` (32 pt) — the closest existing `DS.Space` token
  to Figma's raw 40 pt, per §2's precedence (no new spacing token for a
  value with an adequate existing neighbor).
- `proof.eventName`: keep `DS.Font.sectionTitle` (current token) — do
  **not** adopt `DS.Font.ceremonyTitle` despite its closer visual size
  match to Figma's 28 px bold; `ceremonyTitle` is scoped "Ceremony moments
  only" (`Verified`, `Proof Collected`) and Item Detail is a persistent
  record view, not a ceremony moment (survey §5 item 4). Center-align (was
  left-aligned in the old header panel; matches Figma's centered title
  block). Keep `.fixedSize(horizontal: false, vertical: true)`.
- Date: reformat to a **medium-style date only** (drop the time-of-day
  component the current `DateFormatter` shows) — align with
  `ProofCardView`'s own `.medium`-only formatter for consistency across the
  two screens that render `proof.date`. Center-align, keep `DS.Font.body`
  (or `DS.Font.supporting`, an implementation choice between the two
  existing secondary-text roles — not a new token either way) +
  `DS.Color.textSecondary`.
- **Venue text ("Tokyo Big Sight" in Figma) is not rendered** — no backing
  `Proof` field exists (survey §3 OD-3, §4). The date line shows only the
  date, not a "date · venue" composite.

### 3.3 Verification panel (node `104:446`, the existing "Proof" `BeidPanel`)

- Keep `BeidPanel` wrapping (unchanged radius/material — Figma's `#f2f2f7`
  fill is not adopted, per §2; the existing `beidSurface`/`BeidPanel`
  treatment stays).
- Drop the plain `Text("Proof")` section title — Figma's panel goes
  straight into rows; DESIGN.md §10's "Detail meta row" entry does not
  require a title either.
- `Method` row: unchanged, `BeidMetricRow(label: "Method", verbatimValue:
  proof.method)`.
- `Peers verified` row: unchanged, `BeidMetricRow(label: "Peers verified",
  verbatimValue: "\(proof.peersVerified)")`.
- **`Status` row — RESOLVED (§5.2).** Keep the row, keep its value
  unconditional (not derived from `proof.signatureState` or any new
  field), drop "on-chain" from the copy (forbidden term, DESIGN.md §15,
  and unmodeled), reuse the existing `"Verified"` localization key
  as-is. Pair it with a small inline checkmark glyph
  (`checkmark.circle.fill`, ≤ 32 pt per §12, tinted `DS.Color.proofSeal`)
  ahead of the text for visual parity with Figma — implemented as a
  bespoke `HStack` at the call site rather than a `BeidMetricRow`
  argument, since `BeidMetricRow.value` has no icon slot (survey §2).

## 4. New/changed tokens (design-system)

- **New `DS.Size` token** for the item-detail artwork diameter (e.g.
  `DS.Size.itemDetailArtwork`), added to `Tokens.swift` + the token table
  in DESIGN.md §17 in the same PR, per §4's "MUST: New semantic tokens are
  added by editing `Tokens.swift` *and* the token table in §17 in the same
  PR." Value sourced from Figma's 190 pt measurement (same precedent as
  `DS.Size.proofCardArtwork`'s 76 pt — a brand-new size role has no
  existing token to defer to, so the Figma measurement becomes the value).
- **No new color token.** `DS.Artwork.proofCardGradient(seed:)` and
  `DS.Color.proofSeal` already exist and already have the right semantics.
  Figma's `#34C759` green (Status row) and `#f2f2f7` gray (card fills) are
  explicitly **not** adopted (§2).
- **No new font/space/radius token.** `DS.Font.sectionTitle`/`body`/
  `supporting`, `DS.Space.xl`, `DS.Radius.seal`/`card` all already exist
  with the right semantics for their new call sites here (§3).

## 5. Decisions (resolved by PM — record, not open questions)

1. **OD-1 — Custom back/share nav chrome — RESOLVED: keep the standard
   system back button, do NOT add a share action.** Figma's back pill is
   redundant with the standard `NavigationStack` back button (unchanged).
   No share action is added — it is new product behavior out of scope for
   this visual reskin; a future share feature gets its own spec.
2. **OD-2 — "Status: Verified on-chain" has no backing model — RESOLVED:
   keep the row unconditional, reuse the existing "Verified" string, drop
   "on-chain."** The Status row is NOT coupled to `proof.signatureState`
   (that would collide with the adjacent Signature panel's own distinct
   state, per the survey §5 OD-2 analysis). "On-chain" is dropped
   (forbidden term, DESIGN.md §15, and an unmodeled claim). A checkmark
   icon (`checkmark.circle.fill`, `DS.Color.proofSeal`) is added beside the
   text for visual parity with Figma.
3. **OD-3 — Venue text has no `Proof` field — RESOLVED: drop the venue
   segment, date-only.** The title-block date line renders only a
   medium-style date (matching `ProofCardView`'s formatter), no venue.

## 6. Localization (per `AGENTS.md`)

- **No new string keys required.** `"Verified"`, `"Method"`, `"Peers
  verified"`, `"Status"`, and `"Proof Detail"` all already exist in
  `Localizable.xcstrings` and are reused verbatim — no translation work
  needed beyond what already ships. Catalog key count is unchanged by this
  slice.
- **If a share action is later approved (§5.1)**, it will need its own new
  keys (button label, accessibility label, and whatever share-sheet copy
  is produced) — out of scope for this spec, noted for the future spec
  that would cover it.
- **No key removed.** The old header panel's `"Verified"` `Label` reused
  the same `"Verified"` string already used by the Status row today, so no
  orphaned key results from removing that `Label` — the string stays
  referenced by the Status row.

## 7. Acceptance criteria

- clean build = BUILD SUCCEEDED.
- `scripts/lint.sh` = 0 violations (this file has none today per survey
  §2 — the reskin must not introduce any).
- Visual matches Figma `104:407`'s *layout* (centered artwork card, title
  block below it, verification panel with three rows) using `DS.*` token
  *values* throughout — confirmed via `get_design_context` → `DS.*`
  mapping, not pixel-matching Figma's raw colors/radii (§2).
- New `DS.Size` token (§4) documented in `DESIGN.md §17`, and
  `ItemDetailView`'s DESIGN.md §10 "Detail meta row" entry updated to
  reflect the dropped section title and the unconditional,
  non-`signatureState`-coupled Status row (§5.2).
- `ProofSignatureControlsView` renders byte-for-byte the same as before
  this change — no copy, token, or state-machine edits to
  `ProofSignatureControlsView.swift` or `ProofSignatureState`
  (`ProofSignature.swift`). Diff on those two files should be empty.
- No `Proof`/`ProofStore` schema change — diff on `Proof.swift` and
  `ProofStore.swift` should be empty.
- `#Preview` variants updated for the new layout (at minimum: wallet
  connected / no wallet, light + dark — matching or exceeding the existing
  3-preview count).
- Behavior unchanged: screen still receives its `Proof` via
  `navigationDestination(item:)`; signing action inside
  `ProofSignatureControlsView` still works identically.
- PR-sized; no `.xcodeproj` hand-edits; PR description notes all resolved
  decisions explicitly and confirms `ProofSignatureControlsView`/
  `ProofSignatureState`/`Proof`/`ProofStore` are untouched.

## 8. Branch note

Base on `main` (current HEAD, after PR #71 merged) or a fresh branch from
`origin/main` — decide at implementation time, independent of any in-flight
Option C branch work.
