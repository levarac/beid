# Spec — beid#114: defer window signing/persistence to `.recording`

Status: **APPROVED** (PM ruling, 2026-08-09 — Option B below). Recorded in
`DECISIONS.md`: *"2026-08-09 #114 は Option B — フェーズ遷移は据え置き、署名・
永続化を .recording 以降に限定する"*.
Owner: SubPM a-20260809-003 (Track D), for PM a-20260808-020.
Builds on: beid#116 (shared `ScanPhase`/`applyScanDetection` family,
`shared/src/commonMain/kotlin/org/levarac/beid/shared/sensing/ScanPhase.kt`).
**Implementation is sequenced strictly after #116 merges**, and #116 is
itself sequenced after beid#162 (device-count source move) per PM's
2026-08-09 coordination notice. This spec documents the approved design;
it does not itself change any shipped behavior.

## 1. Problem

`.sensing → .eventFound` fires on the first BLE detection, unconditionally
— no mutual-sensing threshold. That transition is intentionally left
unchanged by beid#116 and by this spec (see §3).

Independently of that transition, today's `SensingCoordinator.observe(...)`
opens an ENIN window and, on window close, **signs the accumulated peer
set with the event signing key and persists it** (`WindowReportStore` +
the unsent-window ledger) for **every** phase that reaches `observe`,
including `.eventFound` — not only `.recording`. Concretely: a single,
possibly spurious BLE detection is enough to produce a real, signed,
durably-stored `WindowReport` claiming an observation window, before
`shouldConfirmEvent` (the existing N-device mutual-sensing threshold gate
on `.eventFound → .recording`, unchanged since before this issue was
filed — see `docs/specs/scan-slice2-redesign.md` §4.3, and DECISIONS
2026-08-01) has ever evaluated true for that session.

This is the protocol-level gap beid#114 names: *when* a signed,
persistable artifact may first exist, not merely how the UI labels an
early moment.

## 2. Two designs considered

**Option A** (rejected): gate `.sensing → .eventFound` itself on the
mutual-sensing threshold, instead of first detection. Rejected because, by
the time `.eventFound` would fire under this design, the identical
threshold condition `.eventFound → .recording` already checks is already
true — the two transitions collapse to firing back-to-back on the same
observation, which in practice removes `EventFoundView`'s distinct
entrance moment (`DS.Motion.entrance`, the Encounter Field motif) and
overturns the deliberate, ratified choice in `scan-slice2-redesign.md`
§4.3 to keep `.sensing → .eventFound` on first detection ("the same
automatic transition style the app already uses"). If a merged
eventFound/recording moment is ever wanted, it should be decided for that
UX reason on its own, not fall out as a side effect of closing this
protocol gap.

**Option B** (adopted, this spec): leave `.sensing → .eventFound`
unchanged — first detection, no threshold, purely a "we noticed
something" UI cue with no protocol claim attached. Move the window
open/sign/persist side effects so they only run once `phase == .recording`.
Pre-recording detections still feed the threshold counters
(`hasEnoughCoPresentDevicesToConfirm`/`hasEnoughDistinctDevicesToConfirm`,
or their post-beid#162 shared-sourced equivalents) so the threshold can
still be evaluated each detection, but produce no signed artifact until
the event is actually confirmed.

## 3. What does not change

- `.sensing → .eventFound` stays exactly as shipped: unconditional,
  first-detection, no threshold. beid#116 already carries this into
  `shared/` unchanged; this spec does not reopen it.
- The threshold **value** (3) and its **configuration mechanism** (the
  `BeidConfig.eventConfirmThreshold` constant + `#if DEBUG`
  `-beid-threshold-override <n>` launch-arg override) are unchanged — this
  is outside what DECISIONS 2026-07-30 fixed, and this spec does not touch
  either.
- The two existing threshold arms (`hasEnoughCoPresentDevicesToConfirm`,
  `hasEnoughDistinctDevicesToConfirm`) and their disjunction
  (`shouldConfirmEvent`) are unchanged — only *which phase's side effects*
  they gate expands from "always" to "only from `.recording` onward, for
  window signing specifically."
- `Proof` creation timing is unchanged — a `Proof` is still created the
  instant `.recording` begins (this was already true before this spec: see
  `SensingCoordinator.beginRecording`'s doc comment).

## 4. What changes

`SensingCoordinator.observe(enin:rpid:detectedDisplayId:for:)`'s call to
`advanceWindowIfNeeded(enin:eventCode:)` (which opens/closes/signs/persists
ENIN windows) moves from running unconditionally to running only when
`phase` is (or, within this same call, becomes) `.recording`. Detections
that arrive while `.sensing`/`.eventFound` still update the threshold
counters (so the threshold can still be crossed), but must not open, sign,
or persist a window.

**Accepted trade-off, stated plainly per PM's instruction not to bury it**:
ENIN windows observed *before* the mutual-sensing threshold is first
crossed produce **no report at all**, even if real co-presence occurred in
one of those earlier windows. Today's (buggy) behavior over-reports — it
signs and persists windows a confirmation check hasn't yet blessed. This
fix does not under-report anything that was ever going to be confirmed: it
only withholds windows from before the "is this a real event" bar was
cleared, which is the same bar `.recording`/`Proof` creation already uses
elsewhere in this type. This is a narrow, real loss of early-window
evidence versus what ships today, accepted deliberately, not a side
effect nobody weighed.

## 5. Vectors required (in addition to beid#116's own vector set)

- A session that never crosses the threshold: no window ever opens, signs,
  or persists (today: it does, incorrectly).
- A session that crosses the threshold mid-window vs. exactly at a window
  boundary: confirm the crossing window itself is signed/persisted
  correctly in both cases.
- A `.signalLost` → `resumeSensing()` cycle occurring before vs. after the
  threshold is first crossed: windows opened pre-threshold are never
  retroactively signed once the threshold is later crossed — only windows
  from the crossing point onward ever produce a report.
- The existing threshold-of-1 edge case beid#116 already found and vectors
  (`SENSING` can move straight through `EVENT_FOUND` to `RECORDING` in one
  call when the very first detection already meets the threshold, reachable
  today only via `-beid-threshold-override 1`): confirm that in this case
  the *same* detection that causes the double phase-move is the one whose
  window is allowed to open/sign, not a window from before it.

## 6. Native adapter shape

The phase-gating decision itself (which counts, which arms, the
disjunction) stays entirely in `shared/`'s `ScanPhase` family per beid#116
— this spec does not add a second decision point. The *side-effect gating*
(should `observe` call `advanceWindowIfNeeded` this time) reads
`resultingPhase`/`transitionedToEventFound`/`confirmedEvent` off
beid#116's `ScanDetectionResult` (or equivalent) and applies a plain `if
resultingPhase == .recording` guard around the existing window-management
call — no threshold comparison is re-implemented in the adapter.

## 7. Cross-reference

Superseding note added to `docs/specs/scan-slice2-redesign.md` §4.3 (same
PR) citing this spec and the DECISIONS 2026-08-09 entry: the first-
detection `.eventFound` choice §4.3 made still stands: its scope is
narrower than originally shipped (window signing no longer starts there).
