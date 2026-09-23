# Issue #627 — adopting Flat 2b, and the DESIGN.md rules it overturns

**Status:** decided 2026-09-22 by the repository owner. Binding for iOS
now; Android follows later (see "Platform scope"). Umbrella issue:
beid#626. This record is the reference that every "Superseded 2026-09-22"
block in `DESIGN.md` points to.

**Authority note.** Five `DESIGN.md` MUST/FORBIDDEN areas are overturned
here **on the owner's authority, without Ken's sign-off**. The owner
decided to proceed and to inform Ken afterwards. This record does not
claim that Ken has been informed.

## What was adopted

- **The spec:** `SenseProof-Flat2b-Implementation.md`, first edition
  2026-09-22 (Japanese). "Spec §N" below refers to its sections. The spec
  is not checked into this repository.
- **The Figma nodes**, file key `xf2uFHceIYg0h0gJndUkmI` ("Beid - Native"):
  - **Flat 2b — Library** (node `189-2`): the color variable collection
    `Flat 2b / Color`, the text styles, and the components. Authority for
    **values**.
  - **Flat 2b — Screens** (node `183-2`): the spec lists 18 screens; 22
    frames at the 2026-09-22 read (below). Authority for **layouts**.
  - "Minimal v4" and the Liquid Glass-era "Fixed" page are historical
    input only from 2026-09-22 on.
- **The product name stays beid.** "SenseProof" in the spec and on the
  Figma board is the designer's mistake, not a rename (owner confirmation,
  2026-09-22). `DESIGN.md` §0's older note, which called "SenseProof" "an
  earlier name", is annotated to say the same.
- **Order:** iOS first; Android later. The redesign outranks the
  remaining v1.0 work.

The five directions (spec §2): black means "what is happening now" (a
state, not a theme); black, white and grays only, plus three semantic
colors; no shadows, gradients, blur or glass; no icons (controls are
monospaced text); a proof's appearance is generated deterministically
from its data (the Sigil).

## What was read in Figma, and when

Figma is not versioned in this repository, so a later disagreement must be
traceable to a Figma edit rather than argued from memory. The file was
read on **2026-09-22** through the Figma API (`get_metadata` /
`get_variable_defs`) while this change was prepared. The same record is in
`DESIGN.md` §0.

- File key `xf2uFHceIYg0h0gJndUkmI`; "Flat 2b — Library" node `189-2`;
  "Flat 2b — Screens" node `183-2`.
- Library components (7): `Button/Primary` (Size=Large 354×56,
  Size=Small 140×52), `Row/List`, `Row/KeyValue`, `Block/Empty`,
  `Label/Section`, `Bar/Nav`, `Sigil/Mini`.
- Color variables: all 13 read directly; they match spec §3.1 exactly:
  `ink` #0B0B0F, `bg` #FFFFFF, `sub` #6E6E78, `line` #ECECF1,
  `line-dashed` #C9C9CF, `tile` #F2F2F4, `chart-muted` #D9D9DE,
  `on-ink/sub` #8E8E96, `on-ink/line` #2A2A31, `on-ink/idle` #5C5C66,
  `semantic/red` #FF453A, `semantic/amber` #FF9F0A, `semantic/green`
  #30D158.
- Text styles observed under "Flat 2b/": Display/60, Display/46,
  Display/Number 40, Display/Address 34, Title/19, Title/17, Title/16,
  Title/15, Body/15, Body/13, Label/Mono 11, Label/Mono 10, Label/Mono 10
  tight, Label/Mono 9, Label/Mono 11 time. Families and weights match spec
  §3.2 (Bricolage Grotesque ExtraBold 800 / DM Sans Bold 700 and Regular
  400 / DM Mono Medium 500). Letter spacing matches (Mono 8, Mono 9 and
  10 tight 6, Mono 11 time 0; Display −2 / −1.5 / −1). **Not observed**
  in the frames read: Display/52 and Label/Mono 13 value. Line heights are
  not stated beyond the spec (the API reports mixed units).
- Screens: 22 top-level frames at read time, not 18 — the spec's 18 plus
  four under the heading "メニュー整理で追加した画面" (screens added in a
  menu reorganization): 04c Events — Clock warning, 05c Sensing — Signal
  Lost, 13 Enter Event Code, 14 Venue (iOS). Their existence does not
  settle #644.
- The live copy already differs from the spec copy in places. Both are
  recorded; neither is chosen here:
  - 06: frame named "06 Sensing — Sealed", reading "SEALED · 6 WINDOWS" /
    "Proof sealed · 10:00 – 10:30" (spec: "VERIFIED · 6 WINDOWS").
  - 07: "SEALED · VERIFYING" (spec: "VERIFIED ON-CHAIN").
  - 09: still "TOKEN ID" and a STATUS value "Verified on-chain".
  - 10 Account Sheet: rows Bluetooth / Enter event code / How sensing
    works / What we send, a "VENUE · ORGANIZER" group (Broadcast this
    venue, Serve signed proofs), then Disconnect wallet, and a footer
    "SENSEPROOF 1.0 · 4C99036" (the spec has 3 rows).
  - 01 Welcome and 10's footer still show "SENSEPROOF".
- The values in `DESIGN.md` §5/§6 are unaffected: the Library values match
  the spec.

## The five overturned areas

Provenance was established from `git log -S '<phrase>' -- DESIGN.md`,
`DESIGN.md` §C and `DECISIONS.md`, not copied from the issue text. The
issue body and `DECISIONS.md` (2026-09-22 entry) say "four of the five
were ratified by Ken on 2026-07-10". The record is narrower than that:
only the **palette direction** has an explicit Ken-ratification row in §C.
The other rules were authored by NAOE Kenichi and adopted as structural
rules per §C; §8a came later (2026-07-22). The table uses what each
record actually says.

Line numbers refer to `git show 25dec6b:DESIGN.md`.

### 1. Palette (§5)

| Old rule (verbatim) | Provenance |
| --- | --- |
| "Direction ratified (Ken, 2026-07-10): deep ink background + quiet teal (`#18C7A7` family) + violet proof seal — the Figma Minimal v4 blue is resolved **against**." (:379-381) | Added in `8076f04` (NAOE Kenichi, 2026-07-10). §C row "**Ken ratification**" 2026-07-10: *Ratified*. The one area with an explicit ratification record. |
| The 14-row token table (:385-400) | Structure from `14ebd53` (2026-07-10); rows added over time (`statusCaution` 2026-07-12, `statusOn`/`statusOff` 2026-07-27). Hex values: §C status *PROPOSAL — Ken ratification pending* for the secondary hexes. |
| "MUST: Exactly **one** motif accent per screen, mapped by moment: …" (:411-416) | Added in `79cd005` (NAOE Kenichi, 2026-07-10), revision round 1. §C status: *Adopted (structural; PROPOSAL tags unchanged)*. |
| "MUST: Every color is an adaptive asset colorset (light + dark) exposed through `DS.Color.*`." (:404) | Initial contract, `14ebd53` (NAOE Kenichi, 2026-07-10; §C dates the initial contract 2026-07-09). Structural. (Counted under area 5 below.) |

**Replaced by:** black/white/grays plus three semantic colors (red =
destructive/off, amber = verifying/pending, green = active/on); no
per-event colors; an event's identity is its Sigil's shape. Values live
in the Library's `Flat 2b / Color` collection. **Implementing issue:**
#628 (token values and **names**, and the fate of the 8 old tokens with no
Flat 2b counterpart).

### 2. Liquid Glass (§8, §8a)

| Old rule (verbatim) | Provenance |
| --- | --- |
| "MUST: Custom `glassEffect` use requires explicit design approval (a `DesignException` link). Glass is a functional layer for controls and navigation, not content decoration — proof/ceremony artwork is content and does not get glass by default. No glass-on-glass nesting." (§8, :606-609) | `79cd005` (NAOE Kenichi, 2026-07-10), revision round 1 ("Liquid Glass availability wording"). *Adopted (structural)*. |
| "FORBIDDEN: Faking glass with arbitrary blur rectangles." (§8, :612) | `14ebd53`, initial contract. Structural. Its intent (no blur) survives in stricter form. |
| The "Materials:" bullet (§8, :596-602) | `79cd005`, revision round 1. |
| §8a in full, including "call sites MUST NOT pair it with a separate `.background(material:)`/`.background(color:)`" and Ken's "ふんだんに" (generously) directive (:616-686) | `0d6394f` (NAOE Kenichi, **2026-07-22**, PR #49) — not 2026-07-10. §8a carries its own `DesignException: this section` in its heading; §C has no row for it. |

**Replaced by:** no glass, no materials, no blur, no shadows, no
gradients on any surface the app draws. Separation comes from 1px `line`
hairlines and whitespace. OS-drawn chrome the app does not draw itself
(system alerts and confirmation dialogs, the keyboard, permission
dialogs) is outside the rule, as in §12; the Account sheet's `ink`
background is app-drawn and is not.
**Implementing issue:** #630 (removes `beidSurface`'s glass path, the
glass button styles, `BeidGlassGroup`, and the remaining materials). The
iOS 26 availability gates that existed only for glass become unnecessary.
The deployment target stays iOS 17 — a fact about `ios/project.yml`, not
a decision made here.

### 3. The per-proof gradient as the sanctioned artwork generator (§5, §10, §14)

| Old rule (verbatim) | Provenance |
| --- | --- |
| "The per-proof generated gradient is a *data-driven* artwork generator, not a token: `DS.Artwork.proofCardGradient(seed:)` in `Tokens.swift` is its canonical home and the only sanctioned source of `Color(hue:)`." (§5, :450-452) | `79cd005` (NAOE Kenichi, 2026-07-10), revision round 1. *Adopted (structural)*. |
| "Artwork: `DS.Artwork.proofCardGradient(seed:)` (§5), rendered as a centered circular avatar — adopted as of the 04 Collection Home redesign (`docs/specs/collection-redesign.md`); no longer scaffold debt." (§10, :777-781) | `0787306` (Koya Onodera, 2026-07-28, PR #71). §C row 2026-07-28: *Adopted*. |
| "MUST: The proof-card generated gradient remains legible against both canvas values; card text sits on `surfaceRaised`, never directly on the gradient." (§14, :1345-1347) | `14ebd53`, initial contract. Structural. |

**Replaced by:** the Sigil (spec §5), drawn deterministically from
observation data, with no image assets. **Implementing issue:** #633,
which keeps the gradient until the Sigil works. Until then
`DS.Artwork.proofCardGradient(seed:)` is **migration debt**: it stays the
only home of `Color(hue:)` and is not to be extended.

### 4. Icons (§12, §10, §11, §13)

| Old rule (verbatim) | Provenance |
| --- | --- |
| The "SF Symbols (keep) / Custom assets (required)" table (§12, :1213-1217) | `14ebd53`, initial contract. Structural. |
| "FORBIDDEN: Decorative `Image(systemName:)` larger than 32 pt." (§12, :1225) and §2 rule 11 | `14ebd53`. Structural. |
| The two custom-asset pipelines (§12, :1235-1249) | `79cd005`, revision round 1 ("illustrations/custom-symbol split"). |
| The `TODO(asset)` placeholder path (§12, :1250-1258) | `b65d5c9` (NAOE Kenichi, 2026-08-08, PR #153). |
| "MUST: Decorative images use `.accessibilityHidden(true)`." / "MUST: Symbols paired with text scale with Dynamic Type (`@ScaledMetric` or font-relative sizing)." (§12, :1259, :1262) | `14ebd53`. These still hold for any image or glyph that remains; they are not overturned, only mostly moot. |
| "a trailing close (X) button is always reachable in the toolbar" (§10, :809-810) and "a clear exit (a trailing close (X) button)" (§11, :1104-1105) | `88a5beb` (Koya Onodera, 2026-07-27, PR #68). The initial contract said "a clear exit (Cancel)". |
| "icon-only buttons labeled (`CollectionHomeView`'s "person.crop.circle" account button MUST carry "Account")" (§13, :1291-1293) | `14ebd53`. The labeling MUST stays; only the example is superseded. |

**Replaced by:** no icons. Controls are monospaced uppercase text
(`← EVENTS`, `CLOSE`, `DONE`, `COPY`, `OPEN →`). The OS status bar is the
only exception; OS-drawn chrome the app does not draw itself (system
alerts and confirmation dialogs, the keyboard, permission dialogs) is
outside the rule.
**Implementing issue:** #631 (and #642 for the account entry, which
becomes the address text).

### 5. Dark mode (§2, §5, §14)

| Old rule (verbatim) | Provenance |
| --- | --- |
| "MUST: Every screen renders correctly in light and dark mode; all `DS.Color.*` tokens are adaptive asset colors." (§2 rule 7, :209-210) | `14ebd53`. Structural. |
| "MUST: Every color is an adaptive asset colorset (light + dark) exposed through `DS.Color.*`." (§5, :404-405) | `14ebd53`. Structural. |
| "MUST: Every `DS.Color` token has a dark variant (already true in `Colors.xcassets`); no view opts out of dark mode." (§14, :1332-1333) | `14ebd53`. Structural. |
| "MUST: PRs adding UI include light *and* dark previews (`.preferredColorScheme` variants in `#Preview`)." (§14, :1338-1339) | `14ebd53`. Structural. |
| "FORBIDDEN: `.colorScheme(.dark)` / `.preferredColorScheme` forced in production views (previews only)." (§14, :1355-1356) | `14ebd53`. Structural. |

**Replaced by:** a single appearance. The app does not follow the OS
dark-mode setting. Black is a state (sensing is happening), not a theme.
A dark mode would be considered if it is ever needed (spec §10-6).
Retiring the FORBIDDEN above is what makes #632 implementable.
**Implementing issue:** #632, which chooses the mechanism (Info.plist,
removing dark variants, or another). This record does not choose it.

## The superseded §6 proposal (not an overturned rule)

§6's ramp line, "`PROPOSAL — Ken ratification pending` (ramp choice:
system SF Pro + SF Mono for ledger traces; no custom brand font in this
phase)" (:469-470, `14ebd53`), was **never ratified**. Flat 2b replaces it
with Bricolage Grotesque ExtraBold (display), DM Sans Bold/Regular
(titles/body) and DM Mono Medium (labels), all OFL and bundled (#629).
It is recorded as a superseded proposal, not an overturned rule. The
Dynamic Type and AX3 MUSTs in §6 are unchanged.

## Settled on 2026-09-22 (owner decision, relayed by the PM)

The owner settled three questions that the rewrite would otherwise have
left open. They are also recorded in `DECISIONS.md` (2026-09-22,
"Flat 2b の未決 4 点をオーナーが決めた").

- **A. "VERIFIED".** "VERIFIED" may be shown **only after a third party
  has verified**. The stance of #144 and #240 (`DECISIONS.md` 2026-08-20,
  "証明詳細の Status 行は「Verified」をやめ…") stands. `DESIGN.md` therefore does
  **not** authorize the Flat 2b strings "VERIFIED · 6 WINDOWS" (06),
  "VERIFIED ON-CHAIN" (07) or a STATUS row reading Verified (09; live Figma:
  "Verified on-chain") as drawn. The screen issues (#636, #637, #638) choose
  the replacement wording. "ON-CHAIN" is additionally forbidden by §15 on
  its own.
- **B. Language.** Japanese is not needed. The UI is English-only, so the
  three Flat 2b families having no Japanese glyphs is not a gap. This is
  consistent with the existing locale policy, not a new one:
  `docs/localization-process.md` sets target locales to `en` only (owner
  decision 2026-08-21), and `ios/Beid/Localizable.xcstrings` holds `en`
  only (checked 2026-09-22). The String Catalog mechanism stays in place;
  nothing here lets strings bypass it. §15's older five-locale sentence
  and its Japanese UI-term bullet are annotated as stale, not deleted.
- **C. SHARE.** SHARE is not being built. The 2026-07-28 rejection (§C,
  Item Detail reskin row: "no share action exists in the app") stands. A
  SHARE control is not part of the contract; #631 and #638 remove it from
  09 Proof Detail.

## The preserved rules

Unchanged by this decision:

- §1 in full, including "Wallet is optional … The UI MUST read fully
  coherent to a user who never connects a wallet."
- §2 rule 5 (44×44pt hit region) and rule 9 (never color alone). Both now
  bind the new text-only controls and the semantic status dots.
- §2 rule 10 (standard containers first). Whether it yields to "← PARENT"
  text is open (item 5 below).
- §9 motion.
- §11 "Agents MUST NOT improvise these".
- §13's requirements (AA text contrast, Dynamic Type through AX sizes,
  VoiceOver, Reduce Motion, never color alone).
- §14's high-contrast SHOULD ("must at minimum not lose information").
- §15's voice, vocabulary, forbidden terms, trust-model bullet, and the
  String Catalog MUST.
- The token-name rule in §4 (names describe role, not appearance). Library
  names such as `semantic/red` therefore do not become `DS` names
  verbatim; #628 names the tokens.

Flat 2b also adds one accessibility requirement of its own (spec §9):
graphs and Sigils carry information, so each carries a VoiceOver summary.

## The §0 authority rule

The old §0 MUST ("When this document and `Tokens.swift` disagree on a
value, the code is right and this document has drifted") cannot survive
unchanged, because `Tokens.swift` keeps the old values until #628 lands.

1. **Transition.** Until #628, #629, #630, #631 and #632 have landed, code
   that still carries superseded values or components is migration debt
   tracked in those issues, not evidence that `DESIGN.md` drifted.
2. **Steady state (confirmed by the PM, 2026-09-22).** The Library
   is the design authority for values. `Tokens.swift` is canonical for
   what ships and is the only place code reads values. A Library vs
   `Tokens.swift` mismatch after the migration is a defect to file as an
   issue, not something resolved automatically either way. `DESIGN.md`
   holds no values of its own, so a `DESIGN.md` vs `Tokens.swift` mismatch
   is still fixed in the document. Token naming is #628's call.

## Open items

Each item names the issue that owns it. `DESIGN.md` references them as
"Open item N (issue-627-flat-2b.md)" where each one bites.

1. **Button capitalization.** Mono labels are uppercase by spec, but §15's
   sentence case for buttons is still a PROPOSAL and #24 is open. The nav
   text controls are both labels and controls. Also undecided: whether
   the uppercase lives in the English source strings or in a style
   transform (it matters for keeping the source strings consistent).
   Owner: #24 (with #629, #631).
2. **§1's wallet-optional MUST vs the spec — a sixth MUST conflict.**
   §1: "The UI MUST read fully coherent to a user who never connects a
   wallet." The spec says login is WalletConnect only, and 01 Welcome has
   a single Connect Wallet CTA. The 2026-09-22 owner decision did not name
   this conflict. It is still unresolved and goes to the owner; §1's text
   is unchanged and still binds. Owners: #642, #643, #644.
3. **§15's forbidden vocabulary in Flat 2b copy.** §15 stays, so these
   strings are **not authorized**: "ON-CHAIN" (spec 07; the live 09 STATUS
   value "Verified on-chain" is also governed by settled item A), "TOKEN
   ID" (09, spec and live), and "CONNECTED VIA WALLETCONNECT" (10; §15:
   say what the wallet does, not the protocol). This conflict goes to the
   owner; it is not softened here. Owners: #637, #638, #642.
4. **Non-text contrast.** `chart-muted` bars on `bg` (1.41:1) and
   `on-ink/idle` nodes on `ink` (2.97:1) are under WCAG 1.4.11's 3:1 for
   graphical objects. §13 today covers text only. Recorded; no new rule.
   Owners: #634, #640.
5. **The standard back button vs "← PARENT" text** (§2 rule 10, standard
   containers first). Owner: #631.
6. **Encounter Field's "avoid radar/sonar clichés" (§3) vs the Flat 2b
   sensing graph's concentric rings.** Not settled here. Owner: #634.
7. **The spec's own open items** (spec §10): window length, peer cap, the
   Rejected report state, AVG SIGNAL display, the Account address
   typeface, dark mode. Cross-reference only; owner #626 (and #633, #634,
   #639, #640, #642 per item). If a Rejected state is ever shown as red
   text on `bg`, it fails AA (3.41:1); on `ink` it passes (5.77:1).

"Japanese text", "VERIFIED wording" and "SHARE" were settled on
2026-09-22 and are recorded above, not here. The §0 steady-state rule was
confirmed on 2026-09-22 and is not open.

## Corrections to the spec's contrast figures

Measured with the WCAG 2.x relative-luminance formula from the Library
hex values (spec §3.1), 2026-09-22:

| Pair | Measured | Spec §9 says | Result |
| --- | --- | --- | --- |
| `sub` on `bg` | 5.04:1 | 4.9:1 | AA text |
| `sub` on `tile` | 4.51:1 | — | AA text, with almost no margin |
| `on-ink/sub` on `ink` | 6.04:1 | 6.8:1 | AA text |
| `ink` on `bg` | 19.64:1 | — | AA text |
| `ink` on `tile` | 17.57:1 | — | AA text |
| `semantic/red` on `ink` | 5.77:1 | — | AA text |
| `semantic/amber` on `ink` | 9.56:1 | — | AA text |
| `semantic/green` on `ink` | 9.72:1 | — | AA text |
| `semantic/red` on `bg` | 3.41:1 | — | Fails AA text; passes 3:1 non-text |
| `semantic/amber` on `bg` | 2.06:1 | — | Fails AA text and 3:1 non-text |
| `semantic/green` on `bg` | 2.02:1 | — | Fails AA text and 3:1 non-text |

Both figures the spec states are wrong; both corrected values still pass
AA. What the kept AA MUST forces, stated in `DESIGN.md` §5: **semantic
colors are indicators, and are text only on `ink`**, where they pass AA.
On `bg` a semantic color is a non-text indicator (a dot) paired with a
text label. Amber and green dots on `bg` are also under
3:1 for non-text, so the paired text carries the meaning (§2 rule 9).

## Implementing issues

| Issue | Scope | Rules it implements |
| --- | --- | --- |
| #626 | Umbrella | This record |
| #627 | `DESIGN.md` rewrite | This record |
| #628 | Design tokens; token names; page margin 32 → 24; fate of 8 old color tokens | §0, §4, §5, §7, §17 A |
| #629 | Bundle Bricolage Grotesque / DM Sans / DM Mono; `DS.Font`; tabular figures scope | §6 |
| #630 | Remove glass and materials | §8, §8a |
| #631 | Remove icons; text controls; back button; SHARE removal | §12, §2 rules 5/8/10/11, §13 |
| #632 | Single appearance | §2 rule 7, §5, §14 |
| #633 | Sigil | §5, §10, §12, §14 |
| #634 | Sensing graph and window bar | §3, §9, §13 |
| #635 | 04 Events (home) | §11 |
| #636 | 05 Sensing / 06 Verified | §11, §15 (VERIFIED) |
| #637 | 07 Proof Collected | §15 (VERIFIED, ON-CHAIN) |
| #638 | 09 Proof Detail | §12 (SHARE), §15 (TOKEN ID, STATUS) |
| #639 | 08 Event Detail | §11 |
| #640 | 11 Observation Detail | §13 (graph summaries) |
| #641 | 12 Report Detail | §11 |
| #642 | 10 Account Sheet | §13 (account entry), §15 (WalletConnect wording), §1 |
| #643 | 01/02/03 onboarding | §1, §12 (Welcome hero) |
| #644 | Destinations of screens not in the 18 | §1, §11 |

## Platform scope

Flat 2b binds iOS now. Android's current theme (`ui/theme/Color.kt`,
`Type.kt`, `Spacing.kt`, `Theme.kt`) still implements the superseded
values; that is not a violation until an Android follow-up is scheduled.
As of 2026-09-22 **no Android Flat 2b issue exists** (searched open and
closed issues for "Flat 2b"; only #626 and its iOS children match). The
bindingness question that
`docs/decisions/issue-339-design-md-android-scope.md` leaves to the owner
is not decided by this record.
