# Spec — Scan flow redesign, Slice 2: Event Found → Proof Collected + connect/binding

Status: **APPROVED.** §0 records the 2026-07-30 PM+user ratification that
closed §9.1 (owner-key continuity) and §9.2 (threshold formula/value) and
confirmed §5.5's proposed 07→entrance-ceremony synthesis. §9.3
(`WalletConnectView` fate) and §9.4 (interstitial visual design) remain
open but do not block sub-slice 2a (model/threshold-confirm/local
signing only, per §10) — they gate 2b/2c.
Owner: SubPM a-20260730-030, for PM a-20260727-036.
Survey: `docs/redesign-scan-slice2-survey.md`. Builds on
`docs/specs/scan-protocol-model.md` (Option C) and `DECISIONS.md`'s
2026-07-30 D1/D2/D3 entries.
Figma: `xf2uFHceIYg0h0gJndUkmI`, nodes `104:636` / `104:516` / `104:702` /
`104:766` / `104:208`. No frame exists for the new interstitial (§5.6).

## 0. Resolved decisions (2026-07-30, PM + user ratification)

Closes §9.1 and §9.2 below, and ratifies §5.5's proposed synthesis. Recorded
here verbatim as the operative decisions; §9's own text is left unchanged
as a historical record of the options that were weighed.

- **Owner key (closes §9.1, supersedes its "(a) DeviceSecret-derived"
  recommendation):** beid (app)-generated secp256k1, **no continuity for
  v1** — the key regenerates per device/reinstall rather than being
  DeviceSecret-derived. Stored at the same level `BarnardIdentity`'s
  `DeviceSecret` uses today (plain `UserDefaults`, not Keychain/iCloud).
  Moving that storage to iCloud Keychain is explicitly **not** part of this
  work — it is a deferred slice. `commit = H(event signing key ‖ owner key
  ‖ salt)` (§5) is computable against this key as of sub-slice 2a.
- **07 Proof Collected (ratifies §5.5's proposed synthesis):** folds into
  `RecordingView` as a one-time entrance ceremony. The ceremony's visual
  design is sub-slice 2c; sub-slice 2a only needs the state machine to
  support it (a `Proof` existing in `ProofStore` from the instant
  `.recording` begins is sufficient groundwork).
- **`ScanPhase` 7 cases → 5 (finalizes §4.2's proposal):**
  `idle` / `sensing` / `eventFound(EventSession)` /
  `recording(event:peersVerified:)` / `signalLost(event:peersVerified:)`.
  `.verifying`/`.verified`/`.collected` merge into `.recording`;
  `.signalLost` freezes `peersVerified` and resumes in place (never a
  restart).
- **Threshold (closes §9.2 — adopts its "(a) fixed count" recommendation,
  value 3):** `BeidConfig.eventConfirmThreshold`, a centralized constant
  fixed at **3** for v1, with a DEBUG-only launch-arg override
  (`-beid-threshold-override <n>`, following the existing
  `-beid-demo-event`/`-beid-ui-test` convention — not an OS environment
  variable, since iOS can't read one set at run time). Crossing the
  threshold auto-flips `.eventFound → .recording`
  (background-capable, zero-tap, per D3).

## 1. Scope

**IN**: redesign of `EventFoundView` (06a), `VerifyingView` + `VerifiedView`
(06b/06c, merged per §4.2), `SignalLostView` (06d), `ProofCollectedView` (07,
repurposed per §5.5), plus a **new connect+binding interstitial** (no Figma
frame — designed here, flagged needs-design). Includes the model changes
that make the UI changes possible: `ScanPhase` state-machine redesign, a real
`EventSession` model replacing `DemoEvent` in the phase machine (Q10),
threshold-based event-confirm (D3), foreground-triggered wallet binding
(D3), and local per-window report signing (Q9, device-side only — see
§4.5's scope boundary).

**OUT** (unchanged this slice):
- Census/Contributor Proof, Token ID field, history drill-down IA (01b/02/
  03/04/05 Proof Detail + empty states) — deferred with D2.
- Any backend report-transport/anchor pipeline — `scan-protocol-model.md §9`
  lists this as separate downstream work from the Slice-2 spec itself; §4.5
  scopes Q9 to local signing only.
- `ItemDetailView` (08) — still embeds `ProofSignatureControlsView`
  unchanged; see §9's cross-slice-impact note (not one of the 5 headline
  opens, but flagged so it isn't silently forgotten).
- Exact commit/report wire-byte encoding (salt derivation, field order) —
  D1 unblocks the *type* of the commit's owner-key component (secp256k1
  compressed pubkey) but not the exact byte layout; see §11.

## 2. Source-of-truth precedence

Decision record (`DECISIONS.md`, `scan-protocol-model.md`) > Figma > current
code, per the 2026-07-26 ratification. Where Figma's linear finite-progress
model conflicts with the window-based decision record (it does, throughout
06b/06c/07), the decision record wins and Figma is used only for its visual
language (shell, tokens, iconography) — this was already the ruling for
Slice-1 and the Option-C spec; this spec just applies it to the remaining
five screens.

## 3. New model: `EventSession` replaces `DemoEvent` in the phase machine (Q10)

```swift
struct EventSession: Equatable, Identifiable {
  let id: String        // event code, e.g. "ETHTOKYO2026" — what BarnardEngine.joinEvent/configure already key on
  let name: String       // display name, e.g. "ETH Tokyo 2026"
  let venue: String?     // e.g. "Tokyo Big Sight" — optional; real events may not report one
}
```

- Replaces `DemoEvent` everywhere it appears in `ScanPhase`. `DemoEvent.swift`
  keeps its file (demo fixture data belongs there per `AGENTS.md`'s
  localization note — DemoEvent strings are real user-facing copy, not test
  fixtures), but its content becomes static `EventSession` fixtures (e.g.
  `EventSession.demoSample`) instead of a competing parallel type. No second
  "event" type coexists with `EventSession` anywhere in the phase machine.
- `venue` is the field Q10 called out as missing — populates Figma's
  "Tokyo Big Sight" line, which the current `DemoEvent` (name +
  `totalPeersToVerify` only) cannot express at all.
- `totalPeersToVerify` is **dropped**, not carried over — it was the fixed
  denominator the whole model is moving away from (§4.2). The demo sequence
  instead simulates a growing open-ended count (§4.6).
- For a real (non-demo) event, `id`/`name` come from
  `BarnardEngine.getCurrentEventCode()` (already used today,
  `SensingCoordinator.swift:76`) or the manually-entered code
  (`EventCodeEntryView` → `joinEvent`); `venue` has no source yet on the real
  path — populate it `nil` until a real event directory/lookup exists (out
  of scope here; falls back to Figma's venue *line* simply not rendering
  when `venue == nil`, never a placeholder like "Unknown").

## 4. `ScanPhase` state-machine redesign

### 4.1 Current (for reference)

```swift
enum ScanPhase: Equatable {
  case idle
  case sensing
  case eventFound(DemoEvent)
  case verifying(event: DemoEvent, peersVerified: Int)
  case verified(event: DemoEvent, peersVerified: Int)
  case signalLost(event: DemoEvent)
  case collected(Proof)
}
```

### 4.2 Proposed

```swift
enum ScanPhase: Equatable {
  case idle
  case sensing
  case eventFound(EventSession)
  case recording(event: EventSession, peersVerified: Int)   // merges verifying + verified + collected
  case signalLost(event: EventSession, peersVerified: Int)  // frozen count, resumable — not a restart
}
```

**Why `.verifying` + `.verified` + `.collected` merge into one `.recording`
case** (this is D4's "follows automatically" list, applied concretely):
window-based reporting has no finish line, so there is no real "verified"
moment distinct from "still recording," and no "collected" moment distinct
from either — a `Proof` now exists in `ProofStore` from the instant
`.recording` begins (§4.6), not at a later terminal step. One phase case
with a growing `peersVerified` count models this correctly; three phase
cases modeling one continuous activity was Figma's linear-flow artifact, not
a real distinction.

**Why `peersVerified` stays on the phase case (not window-report count):**
Figma's own 06b caption already reads as a cumulative, no-denominator count
("23 peers verified," not "23 of N") — the *visible* metric was already
heading this direction before Option C. The window/ENIN report-signing
mechanism (Q9) is a separate, invisible protocol-plumbing counter; exposing
a second number in the UI ("N windows reported") would compete with
`peersVerified` for the user's attention with no benefit, and DESIGN.md's
tone ("quiet field instrument," §1) argues against surfacing protocol
internals as a second stat. `peersVerified` is the same counter used for the
threshold-confirm check (§4.3) — one counter, two uses (compare-to-threshold
internally, display-as-is in the UI), not two counters.

**Why `.collected(Proof)` is removed as a phase case:** a `Proof` is looked
up from `ProofStore` by `event.id` where needed (e.g. the one-time entrance
ceremony, §5.5), not carried through the enum. This also fixes a latent
gap in the current code: today a `Proof` only exists after the *entire* demo
sequence completes, so nothing is stored if the app is killed mid-sequence;
under `.recording`, the `Proof` is created the moment recording starts and
updated in place as `peersVerified` grows, so a kill mid-session still
leaves a real, if smaller, `Proof` behind.

### 4.3 Threshold-confirm (D3)

- `SensingCoordinator` maintains a running `peersVerified` count of distinct
  mutual-sensing observations for the current event (already partially
  present as the demo sequence's loop variable; needs a real-path
  equivalent — currently the real path has no consensus counting at all,
  confirmed in the survey).
- Transition `.eventFound → .recording` fires automatically, **background-
  capable, zero-tap**, the instant `peersVerified >= BeidConfig
  .eventConfirmThreshold` (new, centralized constant — §4.4). This is the
  same automatic transition style the app already uses for `.sensing →
  .eventFound` (first detection); Slice-2 adds one more automatic hop, not a
  new interaction pattern.
- **06a shows no numeric count pre-threshold**, only the "DETECTED" badge +
  an ambient caption. Showing "2 of 5 peers to confirm" would imply the user
  must do something to help it along, when confirmation is deliberately
  automatic/zero-effort (D3) — the threshold is an internal anti-false-
  positive mechanism, not a user-facing progress target. (Diverges from
  Figma's 06a ~6% progress fill on purpose — see §5.1.)

### 4.4 Threshold config constant

```swift
enum BeidConfig {
  static let eventConfirmThreshold = 3   // see §9.2 for the value/formula recommendation
}
```

- A plain, centralized Swift constant — not a per-event field on
  `EventSession` yet. Per the task brief's "structured so it can later
  become organizer/per-event configurable with no rework": the rework-free
  path is that `BeidConfig.eventConfirmThreshold` is the single call site
  `SensingCoordinator` reads; swapping it for
  `event.confirmThreshold ?? BeidConfig.eventConfirmThreshold` later is a
  one-line, one-call-site change. Adding an unused `EventSession
  .confirmThreshold` field now, before any event actually carries one, would
  be speculative — the project's simplicity guidance (no code for scenarios
  that can't happen yet) argues against it.
- **Test override via launch arg, not an OS env var** (iOS can't read env
  vars set at run time, per the task brief) — follows the existing
  `-beid-demo-event`/`-beid-ui-test` convention, but those are boolean-
  presence flags; a threshold override needs a value, so the pattern is:

  ```swift
  static var eventConfirmThreshold: Int {
    #if DEBUG
    let args = ProcessInfo.processInfo.arguments
    if let flagIndex = args.firstIndex(of: "-beid-threshold-override"),
       args.indices.contains(flagIndex + 1),
       let override = Int(args[flagIndex + 1]) {
      return override
    }
    #endif
    return 3
  }
  ```

### 4.5 Per-window report signing (Q9) — scope boundary

- Wire `BarnardIdentity.sign(eventCode:bytes:)` (confirmed to exist, survey
  §3) into an actual signing call once a window closes, replacing the
  discarded `_ = identity.signingPublicKey(eventCode:)` at
  `SensingCoordinator.swift:107`.
- **In scope**: producing and locally queuing a signed window report
  on-device (a new small local store, same pattern as `ProofStore` — flat
  JSON, no server call). **Out of scope**: any network transport of that
  report to a backend, and the batch/anchor pipeline — `scan-protocol-model
  .md §9` lists that as separate downstream work, and no HTTP client exists
  anywhere in the app today (survey §3). Building a transport layer inside
  what's nominally a "UI slice" would silently balloon its scope — this is
  the strongest input into the sub-slicing recommendation (§10).
- Window-boundary detection has no SDK-provided signal (survey §3
  confirms `BarnardEvent` has no window/ENIN-rotation case) — the app must
  derive it from `.detection` events' `enin` field or a timer at the
  configured `eninSeconds`. Left as an implementation detail for whoever
  picks up this sub-slice; not spec'd further here since it doesn't affect
  the UI/state-machine design in this document.

### 4.6 Proof creation timing

- A `Proof` is created in `ProofStore` (via a new
  `ProofStore.startOrUpdate(event:peersVerified:)`-shaped method, replacing
  today's single `add(_:)` called once at the old `.collected` step) the
  instant `.recording` begins, and updated in place as `peersVerified`
  grows — never re-created, never gated on a wallet signature (preserves
  `Proof.swift`'s existing "signatureState is optional enrichment, never a
  gate" contract, extended to the new binding state the same way).
- The exact `commit = H(event signing key ‖ owner key ‖ salt)` byte
  encoding is not finalized here (§11) — D1 unblocks the owner-key
  *component's type* (secp256k1 compressed pubkey), not the full wire
  format. `Proof`'s locally-stored fields (`eventName`, `date`,
  `peersVerified`) don't need to change for this slice; the commit hash is
  a protocol/report-payload concern (§4.5's local queue), not a `Proof`
  display-model concern.

## 5. Per-screen spec

### 5.1 06a Event Found (`EventFoundView`, node `104:636`)

- `let event: EventSession` (was `DemoEvent`).
- Add the `eventCard` pattern from Figma (icon + name + venue line + badge +
  caption) as a new shared sub-component — nothing in current code has this
  shape yet (survey confirmed `EventFoundView` only shows a plain
  `BeidPanel` with a label + name). Venue line renders only when
  `event.venue != nil` (§3).
- Badge: **"DETECTED"** (new eventCard badge vocabulary — see §6).
- **Drop Figma's numeric progress bar** (~6% fill) — per §4.3, no
  fraction-to-threshold is shown. Replace with the existing radar rings
  already on this screen (unchanged from Slice-1) as the sole "something is
  happening" signal, plus the caption below.
- Caption: keep Figma's **"Verification starts automatically — stay
  nearby"** near-verbatim (still accurate under D3 — confirmation *is*
  automatic) — cheapest-possible copy change from current code.
- Tint: `DS.Color.signalActive` (unchanged, sensing-screen accent).

### 5.2 + 5.3 06b/06c merge → `RecordingView` (replaces `VerifyingView` +
`VerifiedView`, nodes `104:516` / `104:702`)

- New `RecordingView(event: EventSession, peersVerified: Int)` replaces both
  `VerifyingView` and `VerifiedView`. `ScanFlowView`'s phase switch collapses
  two cases into one view call.
- Same `eventCard` shell as 06a, badge changes to **"RECORDING"** (new — see
  §6; neither Figma's "VERIFYING" nor "VERIFIED" fit a state with no
  distinct end).
- Caption: **"Recording your attendance automatically · {n} peers
  verified"** (open-ended, no denominator — replaces both 06b's "Collecting
  proof automatically · 23 peers verified" and 06c's "Proof secured — added
  to your Collection"; the latter's storage-already-happened claim is now
  literally true from the first instant of `.recording`, §4.6, so folding it
  into one steady-state caption is accurate, not a downgrade).
- **Drop Figma's fixed-fraction progress bar** (06b ~40%, 06c 100%) for the
  same reason as 06a — no denominator exists to show a fraction of. Replace
  with a subtle non-fractional activity indicator (reuse `DS.Motion
  .sensingPulsePeriod`-style breathing on the eventCard's accent, not a
  literal `ProgressView(value:)`) so the screen still visibly communicates
  "live," without implying a target.
- **Remove the demo-only "Simulate Signal Lost" button from production
  code paths** — unchanged rule from Slice-1's scope (it's a demo escape
  hatch, not a designed affordance); keep it available only under
  `#if DEBUG` / demo mode, same as today.
- Tint: `DS.Color.proofSeal` once recording is confirmed (ceremony-adjacent,
  matches Figma's 06c framing that storage has already happened) rather than
  `signalActive` — a one-time tint change from 06a's `signalActive` to
  `.recording`'s `proofSeal`, which is itself the visual signal that
  confirmation happened, replacing the old badge-text-only signal.

### 5.4 06d Signal Lost (`SignalLostView`, node `104:766`)

- `let event: EventSession`, plus the now-frozen `peersVerified: Int` (was
  implicit/absent) — the count must survive into this phase so it can
  display frozen-but-preserved (Figma's 06d progress bar is drawn frozen at
  ~45%, not reset — the one place Figma's own design already implied
  pause/resume, not restart, ahead of the decision record catching up to it).
- `statusPill` flips to `.sensingPaused` (already exists, currently unused —
  Slice-1 built it "for later reuse," this is that reuse).
- Badge: **"PAUSED"**.
- **CTA behavior changes, label stays** — DESIGN.md §11 requires
  `SignalLostView` to "always offer 'Try Again.'" Under D4, "Try Again" can't
  mean "restart from scratch" (`startSensing(demoEvent:)`, today's handler)
  since that would discard `peersVerified` and re-create the `Proof`.
  Rename the handler target to a new `SensingCoordinator.resumeSensing()`
  that resumes the same `EventSession`/count in place — the label "Try
  Again" is kept (satisfies DESIGN.md's rule at the text level) but its
  semantics change from destructive-restart to resume-in-place. Flag this
  explicitly in the PR description as a `DesignException`-adjacent note,
  since the *behavior* DESIGN.md's rule assumed has changed even though the
  *label* hasn't.
- Real-device signal-loss *detection* (vs. the demo-only manual trigger) is
  still unimplemented after this slice — same gap the original survey
  found; only the phase's *semantics* change here, not real BLE loss
  detection.

### 5.5 07 Proof Collected (`ProofCollectedView`, node `104:208`) — repurposed

**This is the one screen-level decision in this document that most changes
what the task brief described, so it's called out plainly rather than
buried in a diff table:**

Figma's 07 is a distinct hero layout (checkmark artwork, "Added to your
Collection — no action needed," CTA "View Collection"). Under the merged
`.recording` phase (§4.2), there is no terminal moment for this screen to be
*the result of* — `ProofCollectedView` as a phase-driven screen is retired.
Its Figma content is retargeted as a **one-time entrance ceremony inside
`RecordingView`**, shown the instant `.recording` begins (whether or not the
app is foreground at that instant — if backgrounded, it's simply what's on
screen the next time the scan modal is opened, no "you missed it" moment
needed). This reuses Figma's checkmark artwork + copy as an entrance
animation/highlight on `RecordingView` rather than a separate phase/screen.

Rationale: this is the same foreground moment §4.3/§5.6 already needs for
the wallet-binding prompt (D3's "confirmed at &lt;event&gt; — connect to
seal" only fires on foreground) — sequencing the proof-collected ceremony
and the binding prompt together at that one foreground moment is simpler
than inventing a second, separate trigger for a screen that no longer has a
natural phase transition of its own. **This is a proposed synthesis, not
one of DECISIONS.md's settled entries — PM/user should confirm before
build**, even though it isn't listed as one of the 5 headline open
decisions (it follows fairly directly from D3+D4, unlike those 5).

The modal's existing close-(X) toolbar button is unchanged (always
reachable per DESIGN.md §11) and is how a user ends the session — there is
no separate "Done"/"View Collection" terminal CTA anymore, since ending the
session is available at every point in `.recording`, not just at a
manufactured end.

### 5.6 New connect+binding interstitial — needs design (no Figma frame)

Per the task brief, proposing composition/tokens/copy rather than only
flagging the gap:

- **Trigger**: a new `EventBindingState` (on `SensingCoordinator` or
  `AppCoordinator` — TBD at implementation, not a UI concern), separate from
  `ScanPhase` because its trigger is decoupled from phase transitions (D3):

  ```swift
  enum EventBindingState: Equatable {
    case none
    case pendingConnect(EventSession)   // confirmed, awaiting next foreground
    case connecting
    case awaitingApproval
    case bound(BindingRecord)
    case failed(reason: String)
  }
  ```
  Set to `.pendingConnect(event)` the instant `.recording` begins (§4.3),
  regardless of foreground state. Presented as a `.sheet` over `ScanFlowView`
  the next time the app becomes active while `bindingState` is
  `.pendingConnect` — layered over `RecordingView`, not blocking it (wallet
  is optional per DESIGN.md §1; declining/dismissing leaves
  `.pendingConnect` and recording continues un-endorsed).
- **Composition** (reuses existing components, no new visual language):
  `BeidHeroHeader` (already used by `WalletConnectView`/`WalletConnectPairingView`)
  with `systemImage: "checkmark.seal"`, title **"{event.name} confirmed"**,
  subtitle **"Connect a wallet to seal your attendance to this event."** —
  then the existing `WalletConnectPairingView` provider-selection UI
  (Coinbase/MetaMask/Reown), reused as-is (§9.3 covers whether this absorbs
  the standalone `WalletConnectView`). One difference from today's pairing
  flow: on `.connected(address:)`, instead of calling
  `completeWalletConnect` (onboarding-only), it triggers the
  **combined connect+binding round trip** — Coinbase `initialActions` /
  MetaMask `connectAndSign` per beid#33 — producing both the wallet's
  `personal_sign` over "per-event signing pubkey K belongs to wallet W" and
  the device's countersign via `identity.sign(eventCode:bytes:)` (survey §3;
  *not* `proveKeyBinding`, which is the unrelated displayId mechanism).
  `bindingState` becomes `.bound(record)` on success.
- **Dismissible, not modal-locking**: a close affordance (matches the sheet
  convention elsewhere, e.g. `AccountSheetView`) leaves `bindingState` at
  `.pendingConnect` — re-offered next foreground, never nagging mid-session
  (no repeated pop-ups while `.recording` stays on screen).
- **statusPill gets a new state** for this window: `.connectingBinding` (or
  similar — exact name at implementation), so `RecordingView` itself can
  show "Connecting…" in its ambient status rather than only in the sheet,
  satisfying `scan-protocol-model.md §7`'s Q7 ("add a connecting/binding
  state" — carried over unresolved from the prior spec, resolved here).
- Tint: `DS.Color.actionPrimary` (not a motif accent — this is wallet chrome,
  same rule `WalletConnectView` already follows, DESIGN.md §5).

## 6. Component / token deltas

- **New `eventCard` component** (icon + name + optional venue line + badge +
  caption), used by 06a and `RecordingView`. Badge vocabulary: `DETECTED` /
  `RECORDING` / `PAUSED` — **drops `VERIFYING`/`VERIFIED`** (no longer
  distinct phases) and needs no color-only distinction (§2.9 — badge text
  differs per state, not just color).
- **`BeidStatusPill`**: no new *states* needed beyond the existing
  `.sensingAutomatically`/`.sensingPaused` for the scan phases themselves;
  the binding sheet's own in-progress indicator (§5.6) is a separate,
  smaller addition, not a third `BeidStatusPill.State` — keep the pill
  scoped to "is sensing happening," not overloaded with wallet state.
- **Remove**: the fixed-fraction `ProgressView(value:)` pattern from the
  scan flow entirely (06a/06b/06c/06d all drop it, §5.1-§5.4) — no
  replacement token needed, this is a removal, not a new token.
- **`ProofSignatureControlsView` embedding removed from the scan flow**
  (07's old embedding, per Q8/D4) — the type itself is untouched (still used
  by `ItemDetailView`, §9's cross-slice note); only the scan-flow call site
  goes away, replaced by the new binding sheet (§5.6), which is a distinct
  component, not a reskin of the old one.
- No new color/font/space/radius tokens anticipated — the eventCard and
  binding-sheet compositions reuse `DS.Color.signalActive`/`.proofSeal`/
  `.actionPrimary`, `DS.Font.*`, `DS.Space.*`, `DS.Radius.card`/`.pill`
  throughout. If implementation finds a genuine gap, `Tokens.swift` + §17
  addition follows DESIGN.md §4's existing rule — not pre-empted here.

## 7. Localization (per `AGENTS.md`)

New/changed strings, all literal-key (one-off, no reuse/interpolation beyond
the count already handled by explicit-key convention below), English source
+ `needs_review` machine drafts for `ja`/`zh-Hans`/`es`/`fr` in the same PR:

| String | Key form | Comment needed? |
|---|---|---|
| "Verification starts automatically — stay nearby" | literal (near-unchanged from Figma/current) | No |
| "DETECTED" / "RECORDING" / "PAUSED" | literal, short badge labels | Yes — ambiguous out of context, e.g. "RECORDING" could misread as audio/video capture; comment: "Status badge on the event card during BLE sensing, not audio/video recording." |
| "Recording your attendance automatically · {n} peers verified" | **explicit key** (interpolated value) — `String(localized: "scan.recording.caption", defaultValue: "Recording your attendance automatically · %lld peers verified", comment: "Cumulative count of distinct peers who have mutually sensed this device at the event; no fixed target.")` | Yes (placeholder) |
| "{event.name} confirmed" | explicit key (interpolated) — `String(localized: "scan.binding.title", defaultValue: "%@ confirmed", comment: "Event name, e.g. 'ETH Tokyo 2026 confirmed' — heading on the wallet connect+binding prompt.")` | Yes |
| "Connect a wallet to seal your attendance to this event." | literal | No |
| "Try Again" (06d) | **no change** — existing key/string, only its handler target changes (§5.4); translations carry over unchanged |
| "Peers verified" metric-row label, if retained elsewhere | n/a — not introduced by this slice | — |

No key removed outright by this slice: "Event Found"/"Verifying proof"/
"Verified" (old titles) and "Verification starts automatically…" 06a caption
become orphaned or reused per above; String Catalogs tolerate unused keys
(collection-redesign.md precedent, §6).

## 8. Acceptance criteria

- `xcodebuild -project ios/Beid.xcodeproj -scheme Beid -destination
  'platform=iOS Simulator,name=iPhone 17 Pro' clean build` = BUILD SUCCEEDED.
- `scripts/lint.sh` = 0 violations.
- `ScanPhase` compiles with the 5-case shape in §4.2; every call site
  (`ScanFlowView`, `SensingCoordinator`, all five view files, any UI test
  referencing `.verifying`/`.verified`/`.collected`) updated, none left
  matching on the removed cases.
- `EventSession` replaces `DemoEvent` in every `ScanPhase` case and every
  view's `let event:` property; `DemoEvent.swift`'s fixture data still
  compiles as `EventSession` values (§3).
- `BeidConfig.eventConfirmThreshold` is a single named constant, DEBUG-only
  launch-arg override wired per §4.4 exactly (no OS env var read anywhere).
- `identity.sign(eventCode:bytes:)` is called from a real (non-discarded)
  call site producing a queued local report record (§4.5) — `_ =` discard
  pattern at the old `signingPublicKey` call site is gone.
- `RecordingView` replaces `VerifyingView`+`VerifiedView` call sites in
  `ScanFlowView`'s phase switch; both old view files removed, not left dead.
- `ProofCollectedView` is removed as a phase-driven screen; its Figma
  content lives in `RecordingView`'s entrance ceremony (§5.5) — confirm via
  `#Preview` that the ceremony renders once, not on every `RecordingView`
  re-render.
- New binding-sheet component present, reachable via the `EventBindingState`
  trigger in §5.6, dismissible without blocking `.recording`.
- `#Preview` light + dark for `RecordingView`, `SignalLostView` (updated),
  `EventFoundView` (updated), and the new binding sheet.
- No fixed-fraction `ProgressView(value:)` remains anywhere in the scan flow
  (grep-checkable).
- `SignalLostView`'s CTA calls `resumeSensing()`, never `startSensing`,
  proven by a test that `peersVerified` survives a simulated signal-lost →
  resume cycle unchanged.
- UI tests updated for any assertion against old phase copy/badges (`ja`
  string-length check per `AGENTS.md`'s testing section, since "RECORDING"/
  "PAUSED" are new short badge strings prone to `ja` truncation).
- New/changed copy localized (`ja`/`zh-Hans`/`es`/`fr` `needs_review`) per
  §7, including the interpolated-count and interpolated-name explicit keys.
- PR-sized per §10's sub-slicing recommendation — this spec's full scope is
  not asserted to land in one PR.

## 9. Open decisions (raised, not resolved here)

### 9.1 Owner-key continuity across device change/loss

Two options: (a) derive owner key from the existing `DeviceSecret`
(`KDF(DeviceSecret, fixed-context)`, mirroring how the event signing key is
already derived), or (b) generate owner key independently and back it up
separately (e.g. iCloud Keychain).

**Recommendation: (a), DeviceSecret-derived — with a caveat that must be
fixed alongside it.** The event signing key and TEK already share
`DeviceSecret` as a root (per the key roster); deriving owner key the same
way means *one* secret's continuity story covers three keys, not three
separate backup pipelines. **But**: the survey (§4) confirms `DeviceSecret`
is currently stored in plain `UserDefaults`, not Keychain/iCloud — it has
*zero* continuity today. Recommending (a) without also moving
`DeviceSecret`'s storage to iCloud Keychain would just extend today's silent
gap to the owner key too. This is a `BarnardCore`/SDK-level storage change
(`BarnardUserDefaultsKeyStorage` → an iCloud-Keychain-backed
`BarnardCoreKeyStorage` implementation), not an app-layer one — likely needs
a Barnard SDK change, which is outside this app repo's control and should be
raised with whoever owns that package. **This needs user input**, not just
PM self-judgment, given the SDK-boundary and security-tradeoff implications
(iCloud Keychain sync has its own threat model — a compromised iCloud
account could then also compromise the owner key).

### 9.2 Threshold formula + initial value

Options: fixed count, time×count hybrid, size-adaptive (event-size aware).

**Recommendation: fixed count, value 3, as the v1 default.** Simplest to
reason about and test; matches the existing `DemoEvent.sample
.totalPeersToVerify` default (3) so the demo walkthrough's pacing doesn't
need to change incidentally. A time×count hybrid or size-adaptive formula
adds real value once organizer-configurable thresholds exist (per
`DESIGN.md §11`'s "planned surfaces" note on organizer-set verification
thresholds) but is speculative before that surface exists — matches §4.4's
"structured for later, not built for later" principle. Config constant
location: `BeidConfig.eventConfirmThreshold` per §4.4, not on `EventSession`.

### 9.3 `WalletConnectView` (standalone, `walletFirst`) fate

`DECISIONS.md`'s 2026-07-28 entry deferred this exact question to "next MTG,
alongside Option C" — now that Option C's binding mechanics are settled,
this spec surfaces it concretely: does the new interstitial (§5.6) absorb
`WalletConnectView` entirely (one wallet-connect UI in the whole app), or
does `walletFirst`'s onboarding-time connect stay separate from the
event-scoped binding connect?

**Recommendation: keep both, but make the interstitial the only place
binding happens.** `WalletConnectView` (onboarding, `walletFirst` mode) and
the Account-sheet connect path establish a *session* only — they never
produced a binding signature before, and shouldn't gain one now (binding
needs an `eventCode`, which doesn't exist yet at onboarding time). The new
interstitial is the only path that performs the combined connect+binding
round trip. If a wallet is already connected (session-only, from onboarding
or the Account sheet) when `.recording` begins, the interstitial can skip
straight to the binding-signature step (no second `personal_sign`
provider-selection UI) — worth confirming at implementation time, not
asserted as settled here.

### 9.4 Interstitial visual design

No Figma frame exists (survey §5 re-confirms this live). §5.6 proposes a
composition from existing components (`BeidHeroHeader` +
`WalletConnectPairingView`'s provider selection). **Needs design sign-off**
before implementation — flagged per the task brief's explicit ask, not
silently built.

### 9.5 Is Slice-2 too big for one PR? — yes; recommended sub-slicing

See §10.

## 10. Sub-slicing recommendation

**Yes, split.** The scope in §1, taken literally as one PR, bundles three
substantially different kinds of work: a state-machine/model rewrite
touching `SensingCoordinator`/`ScanPhase` at the core, a new wallet-
integration surface, and a screens-only visual pass. Matches the project's
existing vertical-slice ethos (Slice-1 itself was deliberately narrowed to
"screens that don't contradict the decision record," per the 2026-07-27
Option-A decision) — recommend the same discipline here:

1. **Sub-slice 2a — model + threshold-confirm + local signing** (no new
   screens): `EventSession` replacing `DemoEvent` (§3), the `ScanPhase`
   redesign (§4.2), threshold-confirm (§4.3-§4.4), and Q9's local
   per-window signing (§4.5) with `peersVerified` display already updated on
   the *existing* 06a/06b/06c views (minimal copy/badge changes only, not a
   visual rebuild yet). Highest technical risk, most reviewable in
   isolation, unblocks everything else.
2. **Sub-slice 2b — connect+binding interstitial**: `EventBindingState`,
   the new sheet (§5.6), the beid#33 round-trip wiring, §9.3's
   `WalletConnectView` interaction. Depends on 2a's `.recording` phase
   existing as the trigger point.
3. **Sub-slice 2c — terminal-screen visual pass**: `RecordingView`'s merged
   06b/06c visual design including the entrance ceremony (§5.5), 06d's
   frozen-count/resume behavior (§5.4), removing `ProofCollectedView`. Can
   land last since it's the least protocol-risky, most design-review-heavy
   piece — benefits from 2a/2b already being stable so its `#Preview`s use
   real (not placeholder) state shapes.

This ordering matches the task brief's own suggested split almost exactly;
this section confirms it's warranted rather than assuming it.

## 11. Non-blocking implementation TBDs (not among the 5 headline opens)

- Exact `commit`/report-payload byte encoding (salt derivation, field
  order) — D1 unblocks the owner-key component's *type*, not the full wire
  format (§4.6).
- Exact binding-message byte layout for the wallet `personal_sign` +
  device countersign (§5.6) — needs pinning down alongside whichever wallet
  SDK integration lands it (Coinbase `initialActions` vs. MetaMask
  `connectAndSign` may shape this differently).
- Real (non-demo) signal-loss *detection* heuristic (§5.4) — still
  undetermined; this slice only fixes the phase's *semantics*, not detection.
- `ItemDetailView` (08) still shows the old provisional
  `ProofSignatureControlsView`/`signatureState` UI after this slice lands
  (§1, §6) — a known, deliberate gap, not silently missed; follow-up slice
  should reconcile 08's signature panel with whatever binding-state model
  ships here.

## 12. Branch note

Base on `main` (current HEAD) or split per §10's sub-slices, each based on
`main` after the previous sub-slice merges — decide at implementation time.
Independent of any in-flight Option-C-adjacent branch work.
