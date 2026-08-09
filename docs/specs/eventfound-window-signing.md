# Spec — beid#114: defer window signing/persistence to `.recording`

Status: **APPROVED** (PM ruling, 2026-08-09 — Option B below, §1-§7).
**Amended 2026-08-09** (§8 — venue-device threshold-counting, Option A):
also approved. Recorded in `DECISIONS.md`: *"2026-08-09 #114 は Option B —
フェーズ遷移は据え置き、署名・永続化を .recording 以降に限定する"*.
Owner: SubPM a-20260809-003 (Track D), for PM a-20260808-020.
Builds on: beid#116 (shared `ScanPhase`/`applyScanDetection` family,
`shared/src/commonMain/kotlin/org/levarac/beid/shared/sensing/ScanPhase.kt`,
merged as PR #188).
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

**SUPERSEDED — 2026-08-09.** The paragraph above undersold the real risk
and, read on its own, would lead an implementer straight into a
regression shaped exactly like beid#154's (device × window) inflation —
this time inside the co-presence threshold arm instead of the
distinct-device count beid#154 originally fixed.

The mechanism: `currentWindowRpids` (the co-presence arm's own input,
`hasEnoughCoPresentDevicesToConfirm`) is cleared at every ENIN window
boundary — that clearing is what keeps a single lingering device
contributing exactly 1 to every window, forever. The proximity identifier
(`rpid`) rotates every ENIN window by design (beid#154). If the *entire*
`advanceWindowIfNeeded` call — including the boundary-crossing clear of
`currentWindowRpids` — were wrapped in the naive `if resultingPhase ==
.recording` guard this section originally described, that clear would
stop running for every detection before the event first confirms. A
single lingering device, observed across several pre-confirmation
windows, would then insert a *fresh, rotated* `rpid` into
`currentWindowRpids` every window, into a set nothing ever empties —
reproducing beid#154's device-times-window inflation shape, but inside
the co-presence arm this time, and potentially satisfying
`hasEnoughCoPresentDevicesToConfirm` from one real device alone.

**Corrected native adapter shape**: the two side effects §4 describes as
one must be split. `currentWindowRpids`' per-window clearing (and the
rest of ENIN-boundary bookkeeping — `currentWindowEnin`/`firstWindowEnin`/
`lastWindowEnin`/the self-proof checkpoint) stays **unconditional**,
running on every detection exactly as it does today, regardless of
`phase`. Only the ledger-touching half — signing and durably persisting a
`WindowReport`, and the corresponding `unsentWindowLedgerRuntime`
open/close calls — defers to `phase == .recording` (read from
`resultingPhase`, as this section already said). Because the
unconditional half keeps `currentWindowRpids` correctly scoped to "just
this window's peers" at all times, the first window the ledger half ever
opens — whether that happens exactly at a window boundary or mid-window —
is already seeded with an accurate, correctly-scoped peer set, with no
special-casing needed for the confirming detection itself.

Implemented in beid#114's landing PR as `advanceWindowBookkeepingIfNeeded`
(concern 1, unconditional) and `ensureLedgerWindowOpen`/the
`currentWindowLedgerOpened`-gated close inside the same function
(concern 2, `.recording`-gated) in `SensingCoordinator.swift`. The
regression this correction exists to prevent is exercised directly by
`DeviceCountTests.testOneLingeringDeviceAcrossManyPreConfirmationWindowsNeverInflatesCoPresenceCount`.

## 7. Cross-reference

Superseding note added to `docs/specs/scan-slice2-redesign.md` §4.3 (same
PR) citing this spec and the DECISIONS 2026-08-09 entry: the first-
detection `.eventFound` choice §4.3 made still stands: its scope is
narrower than originally shipped (window signing no longer starts there).

## 8. Amendment (2026-08-09): what the threshold counts — venue-device inflation

**Status: APPROVED (Option A below).** PM ruling, DECISIONS 2026-08-09.
Sequenced the same as the rest of this spec: documentation only, no
behavior change, implementation still waits on beid#116.

### 8.1 Problem

`#138`'s venue-device organizer mode broadcasts Barnard's B005 event-info
hint. Tracing the pinned Barnard 0.3.0 source confirms B005 cannot be
served in isolation: `startAdvertiseInternal()` unconditionally builds one
GATT service exposing all four characteristics — B002 (RPID), B003
(displayId), B004 (EventCodeHash), and B005 (eventInfo) — with no
B005-only path. A venue device serving B005 therefore also advertises a
real RPID, displayId, and EventCodeHash, and **is detected by nearby
participants exactly like a genuine peer.** It lands in
`distinctPeerDisplayIds` (the shared aggregation family, beid#109/#162)
and contributes to `devicesVerified`, which is one of `#116`'s two
threshold arms (`eventConfirmThreshold`, fixed at 3 per DECISIONS
2026-07-30).

Concretely: **a room with 2 real attendees plus 1 active venue device can
still cross a threshold of 3 and start recording/signing**, because
nothing on the receiving side can distinguish the kiosk's B002-004 output
from a genuine peer's. Filed upstream as `levarac/barnard#132` (not
blocking — the fix, if it lands, is a future Barnard capability, not
something this spec waits on).

### 8.2 What was considered and rejected

- **Dwell-time/temporal heuristics** (a stationary kiosk is present in
  every window for its entire broadcast period) — **rejected**: beid#154
  deliberately established that neither existing threshold arm may be
  sensitive to dwell time — a person who arrives early and stays the whole
  event must count identically to one who doesn't. A heuristic here would
  cut against that already-settled principle rather than extend it, and a
  genuine long-staying attendee produces the identical signal shape to a
  kiosk, so it would not even reliably distinguish the two.
- **A beid-curated venue-device registry** the receiving app could consult
  to exclude known-active kiosk identities — **rejected on trust-model
  grounds**: DECISIONS 2026-08-09's `#138` ruling already attaches the
  constraint that beid must not assert it vouches for a given broadcast's
  authenticity. A registry beid itself curated and every client consulted
  would be a step toward exactly that kind of vouching, not a neutral
  technical filter.
- **A native correlation between "this device also sent me a B005 hint"
  and its B002-004 identity** — **rejected as unavailable**:
  `levarac/barnard#132`'s own text confirms the receive API does not
  expose whether a detected peer is currently serving event info (the same
  shape as the relay-identity gap in `levarac/barnard#128`). There is no
  protocol-level signal to build this on today.

### 8.3 Decision: Option A — accept the inflation as a documented v1 limitation

No native mitigation is attempted. The threshold counts every detected
device exactly as `#116` already ships it, kiosk or human, because nothing
available today can tell them apart. **Quantified**: while a venue device
is actively broadcasting and in range, the real-human bar to cross
`eventConfirmThreshold` is reduced by up to 1 per active venue device —
the threshold *value* itself stays unchanged at 3 (DECISIONS 2026-07-30
still governs the value and its config mechanism; this amendment touches
neither).

**Why this is bounded rather than open-ended, and therefore defensible
rather than merely cheap**: the gate loosening does not corrupt any
individual signed artifact, and — this is the reason the limitation stays
bounded — **it cannot create a false mutual observation at the verifier
either, because the kiosk never reports.** A venue device signs nothing;
it only broadcasts. `#144`'s cross-matching stage (two independently
signed observations → one mutual observation) has nothing from the kiosk
to match against, so no fabricated mutual-observation record can ever
result from this gap. What loosens is purely the local gate that decides
*when* to start recording; the accuracy of every per-observation claim
that does get signed is untouched.

Cross-reference `levarac/barnard#132` as the eventual real fix, should
Barnard ever add a B005-only serving mode.

