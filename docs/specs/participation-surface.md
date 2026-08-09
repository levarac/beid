# Spec — Venue-Device Serving + Post-Join Self-Heal (gh#138, #139 layer 3)

Status: **DRAFT**, for SubPM review before PM submission. Not yet
approved. Per `DECISIONS.md` 2026-08-03 ("実装前に spec を起票して承認を得
る(コード先行禁止)"), no product code is written against this document
until it is approved.

Author: Worker `a-20260809-007`, restructured by SubPM `a-20260808-026`
after a PM ruling narrowed Track B's scope (see §0 below). The original
combined draft covered gh#141, #138, #139 (all three layers), and #101;
its #141/#101/#139-layer-2 analysis is preserved verbatim in Appendix A,
not deleted — it is genuinely useful to whoever picks that work up next,
and two independent verification passes (the Worker's and this SubPM's)
already confirmed its technical claims.

Builds on `docs/specs/event-discovery.md` (**APPROVED**, 2026-08-06;
§9.a/§9.b revised 2026-08-09). This document does not re-litigate anything
that spec already settled: the B005 trust model (§5), the "hint never
auto-joins on its own" invariant (§3.3 Claim 1), and §9's current
resolution (real end-user serving via #138, sender-enforced validity
period, trust-disclaimer UI required).

## 0. Why this document is narrower than its title once was

Three items that were originally in scope are now explicitly excluded.
Stating why, with dates, rather than silently dropping them:

- **#141 (event-card UI) and #101 (shipped-build reachability fix) stay
  with the user.** `DECISIONS.md` 2026-08-09 ("#141 と起動→参加画面群はユ
  ーザーが実装する(2026-08-08 のオーナー裁定を維持)"): a 2026-08-08 owner
  ruling (recorded by knaoe in a comment on #141) assigns #141 and #53's
  launch→participation screens to the user (小野寺さん/Onodera-san)
  personally, "同じ画面を触るため一本化" (unified because they touch the
  same screens). #101's fix lives inside that same screen group
  (`SensingView` → `EventCodeEntryView`), so the same entry covers it. The
  same DECISIONS entry states plainly: "Track B に残る範囲: #138(会場端末
  モード)と #139 の層3(参加直後の自己修復)のみ."
- **#139 layer 2 (relay/majority display) is out of 8/20 scope entirely,
  not merely blocked.** `DECISIONS.md` 2026-08-09 ("#139 層2(実勢表示)は
  8/20 のスコープから外す"): Barnard 0.3.0's B005 receive API exposes no
  relayer identity, so layer 2's one input cannot be filled with real data
  (confirmed independently by this spec's Appendix A analysis, by Track C,
  and by knaoe on the #139 thread — three independent paths, same root
  cause, same cross-repo issue: `levarac/barnard#128`). Building a
  beid-side approximation is explicitly ruled out — `RelayMajority.kt`'s
  own doc comment says so, and this spec does not revisit that. **Distinct
  from the earlier Barnard-dependency finding**: `DECISIONS.md`'s
  2026-08-09 "#138 の Barnard 依存は誤認だった" entry covered only the
  *validity-period* transport question (§3 below) — it does not extend to
  the relay-count gap, which is a real, standing Barnard dependency.
  `DECISIONS.md` records this distinction explicitly so the two are not
  conflated later.

This document's actual scope, going forward, is **#138 in full, and
#139 layer 3 to the extent it can be built independently of the above**
— see §2's finding on exactly how far that independence goes.

## 1. Scope

**IN**: #138's venue-device organizer UI in full (§3), and #139 layer 3's
post-join self-heal *mechanism* only (§4) — not its full end-user-visible
feature, per §4's own finding.

**OUT**: #141, #101, #139 layer 2 (§0); `ScanPhase`'s transition rules and
the confirm-threshold mechanism (Track D/#116/#114); the device-count
source (Track C/#162); window-close/ledger-registration paths (Track A);
the wallet-binding ceremony and connectors; `EventDefinition`/registry
decode (#108); `EventFoundView`'s redesign (the #104 finding, Appendix A.2)
— that screen belongs to #141's screen group per §0, and this document
does not design it.

## 2. Ownership boundary

`SensingCoordinator.swift` is being touched by four concurrent tracks.
This document's remaining scope touches it far less than the original
draft did:

- **#138 does not touch `SensingCoordinator` at all.** It is a new,
  separate screen calling `BarnardEngine.configureEventInfoServing`
  directly — a sending-side action, unrelated to the participation-
  lifecycle region or any other track's territory.
- **#139 layer 3's mechanism** (§4) touches only the participation-
  lifecycle region Track B was always scoped to own: "which event a
  session starts against." It does not touch the `ScanPhase` state
  machine's transition rules (Track D), the device-count source (Track
  C), or window-close/ledger paths (Track A) — it only clears
  `joinedEventCode` and returns the session to a not-yet-joined state,
  the same category of action `AppCoordinator`/`SensingCoordinator` already
  perform via existing, shipped code paths.

## 3. #138 — venue-device organizer UI

### 3.1 Two designs are on the table, and they are not equivalent

`DECISIONS.md` 2026-08-09 and `docs/specs/event-discovery.md`'s §9.a/§9.b
revision describe #138 as: an operator screen where a device sets a
**label** (mapping onto the existing `eventDisplayName` TLV) and a
**validity period** (sender-enforced, no wire change), with reassignment
history and a hard trust-disclaimer requirement. That is a real, buildable
design against the pinned v1 B005 API, with no Barnard dependency for
*this* question — see §0's note on the validity-period/relay-count
distinction.

**A later, independent-audit comment on #138 (knaoe, 2026-08-07) proposes
something materially different**: label and validity period should
**not** be app-editable local values at all. They should be an
**organizer-signed assignment** — read and displayed by the app, never
typed into it — specified by a new, separate issue the audit filed,
`levarac/barnard#127` ("Signed key-role assignment... fixed before
counting, append-only replacement history"). The audit's stated reason: an
app-local mutable value can't back the "fixed before counting starts"
guarantee the UX canon depends on. The same comment also says the on/off
toggle itself should not be the normal interaction — normal flow is "open
the app on a device with a registered key, and it becomes a beacon
automatically"; manual on/off is for emergency-stop/diagnostics only.

**Checked this session: `levarac/barnard#127` is Backlog, zero comments,
unassigned, no timeline** — the same unstarted state as #122/#123, just
filed later and not yet covered by the 2026-08-09 walkback (which only
checked #122/#123). Adopting the audit's design as written would
reintroduce exactly the kind of Barnard dependency the 2026-08-09 decision
worked to eliminate.

**Recommendation: proceed with the app-editable design (the one
`DECISIONS.md` already committed to) for this milestone.** Treat the
audit's signed-assignment model as a legitimate future hardening — parallel
to how barnard#122's authenticity signature is already treated — not a
blocker. This is flagged as an explicit open decision (§5.1) rather than
resolved unilaterally: it is a real security critique from an independent
audit, not a stylistic disagreement, and overriding it is a call for the
PM/owner, not this spec.

### 3.2 What this sub-slice builds, under the recommended design

- A new screen (placement: §5.3) with a label text field
  (`eventDisplayName`-bound, same 64-UTF-8-byte limit the B005 codec
  enforces per `docs/specs/event-discovery.md` §7), a validity-period
  picker (start/end, purely local — sender-enforced, no wire
  representation), an on/off control calling
  `configureEventInfoServing(organizerDesignated:eventActiveForDiscovery:
  eventDisplayName:)` (`BarnardEngine.swift:471-483`), and a
  reassignment-history list (§5.4).
- **Trust disclaimer**, hard requirement carried forward from
  `DECISIONS.md` 2026-08-09 verbatim ("運営者UIには『beidはこのbroadcast
  を保証しない』ことが利用者から見て分かる表現を設計に含める"). Candidate
  copy (DESIGN.md §15: sentence case, no exclamation marks, no
  overclaiming, no forbidden terms) — proposed, not final (§5.5):
  > "Beid does not verify who is broadcasting this. Anyone nearby with
  > the app can see it."
  Needs a translator `comment:` (ambiguous out of context — "this" refers
  to the broadcast, not the app itself) and PM/copy sign-off before
  landing.
- **Dual-role question**, from the audit's point 3: can one device be a
  venue-device broadcaster and a sensing participant at the same time?
  Needs verification against `BarnardEngine`'s actual behavior
  (`configureEventInfoServing` + `configure(eventCode:)` + `startAuto()`
  concurrently) before implementation — not established either way this
  session. Flagged as §5.2, with a recommendation to allow dual-role for
  solo/small-team dogfood testing unless verification shows it's
  unsupported, in which case the audit's fallback (a 3-device demo instead
  of 2) applies.

## 4. #139 layer 3 — post-join self-heal

### 4.1 A finding this restructuring surfaced: layer 3's own text ties it to #141, which is no longer Track B's

#139's own issue text frames layer 3 as *"ゼロタップ自動参加の安全網"* — a
safety net **for #141's zero-tap auto-participation specifically**. With
#141 (and the candidate list #100 would have fed it) now held for the user
(§0), the scenario layer 3 exists to recover from — auto-selecting the
wrong event from a rendered candidate list — has no Track-B-built UI to
attach to. Separately, #101 also being held means the *existing* manual
path has no reachable entry point either (`EventCodeEntryView` stays
unreachable under live `.guestFirst` routing until the user's work lands),
so there is no "wrong pick" scenario reachable in a real, shipped build
right now regardless of which mechanism would have picked wrong.

**This spec does not have a full, end-user-visible version of layer 3 to
propose as a result.** What follows is the honest reduction: the part that
*is* independently buildable, buildable now, and useful to whoever builds
either #101 or #141 next.

### 4.2 What's independently buildable: the reset mechanism, not the trigger

"Leave the currently-selected event and return to a joinable state" is a
capability that belongs to the participation-lifecycle region regardless
of *how* a session got into that state — manual entry today, #141's cards
later. Recommend building this now, as a plain, tested method on
`SensingCoordinator`:

- A method (name TBD, e.g. `leaveJoinedEvent()`) callable while `phase`
  is `.sensing` or `.eventFound` (never `.recording` — see §4.3), that
  clears `joinedEventCode` and returns the coordinator to a state
  equivalent to never having joined, without touching `discoveredEventCandidates`,
  `phase`'s own transition rules, or the device-count source — pure
  participation-lifecycle state, matching §2's boundary exactly.
  Constructing this as a `SensingCoordinator` method rather than an
  `AppCoordinator`-level UI flow is deliberate: it makes the capability
  callable by whichever screen ends up hosting the affordance,
  independent of which of #101/#141 lands it first.
- **The UI trigger is deliberately not built here.** There is no reachable
  screen state today for a person to be looking at when they'd want it
  (§4.1), and prescribing where the button goes would mean designing
  either `EventCodeEntryView`'s or `EventFoundView`'s UI — both belong to
  the user's screen group now. This spec stops at a tested, callable
  method and documents the integration contract (§4.4) for whoever wires
  it in.
- Test coverage possible now, independent of any UI: call the method
  directly against a coordinator that has joined a (test) event, assert
  `joinedEventCode` clears and a subsequent `joinEvent(_:)` for a
  different code succeeds cleanly; assert calling it while
  `phase == .recording` is a no-op (§4.3).

### 4.3 Why this is safe pre-`.recording`, and why it must not be offered after

Per `DECISIONS.md` 2026-08-09 ("#114 は Option B"): window open/close —
signing, persistence, unsent-ledger registration — only happens once
`phase == .recording`. Before that, `.eventFound` is "we noticed
something, no protocol claim yet." So `leaveJoinedEvent()` called before
`.recording` never has to unwind cryptographic or ledger state — it is
purely a change of which event is associated with the session, nothing
more, because nothing has been committed to yet. This spec's method
enforces that boundary directly (no-op once `.recording`) rather than
leaving it to whichever caller wires in the trigger to remember. Building
a real post-`.recording` correction mechanism is out of scope here — that
would cross into Track A's ledger/window-close territory and is follow-up
work with its own spec if wanted, not designed here.

### 4.4 Integration contract, for whoever builds the trigger next

Documented here so #101's or #141's implementer doesn't have to re-derive
it: call `leaveJoinedEvent()` from any screen state where `phase` is
`.sensing` or `.eventFound` and the user has indicated the current
selection is wrong; it is safe to call unconditionally in that window (a
no-op if nothing is joined); do not call it once `phase == .recording`
(the method itself refuses, but callers should not rely on that as their
only guard — a UI that dims/hides the affordance once recording starts is
still the caller's responsibility). No new shared/`Barnard` state is
touched.

## 5. Open decisions (for PM sign-off — none of these are resolved by this spec)

1. **#138's design**: app-editable label/validity (recommended, ships now,
   matches `DECISIONS.md`) vs. the audit's organizer-signed assignment via
   `levarac/barnard#127` (harder, currently unowned, reopens a Barnard
   dependency). Recommend the former for this milestone.
2. **#138 dual-role** (venue-device + participant sensing on one device
   simultaneously) — needs verification against `BarnardEngine`'s actual
   behavior before implementation; recommend allow if supported, 3-device
   demo fallback if not.
3. **#138 placement** ("アプリの奥まった場所"). Recommend a sub-screen off
   the existing Account Sheet (DESIGN.md §11's "09 Account" already houses
   wallet/Bluetooth technical state the general participant rarely
   touches; #126's Android parity work situates equivalent settings-like
   controls there too). Alternative locations were not found with a
   comparable existing precedent in this codebase.
4. **Reassignment-history shape** — minimal proposal: a local,
   append-only, unsigned list of (label, validity-period start/end,
   assigned-at timestamp) shown read-only under the current assignment.
   Explicitly not cryptographically signed under the recommended §5.1
   design — a signed history would only be meaningful under the audit's
   alternate design.
5. **Trust-disclaimer exact copy** — candidate given in §3.2, needs
   PM/copy sign-off, not finalized here.
6. **§4's reduced scope for layer 3** — confirm building the mechanism
   only, with no UI trigger, is an acceptable interim rather than holding
   all of #139 layer 3 until #101/#141 land. Alternative: hold this too,
   and Track B's active scope becomes #138 alone until one of those
   unblocks it. This spec recommends building the mechanism now (§4.2's
   reasoning: cheap, independently testable, removes rework later) but
   flags the choice explicitly rather than assuming it.

## 6. Both-OS statement

**Both remaining items are iOS-only.** #138: Android has no equivalent
concept of a venue-device screen and no post-join flow to place one
within — building an Android venue-device UI is a separate, larger effort
with no current call site, tracked the same way the rest of the
Android-parity gap is (AGENTS.md's KMP contract section, "Android
production wiring remains deferred"). #139 layer 3's mechanism: it lives
on `SensingCoordinator`, which has no Android equivalent participation-
lifecycle state today (`EventJoinCoordinator.kt` stops at
`Idle`/`RequestingPermission`/`Sensing`/`PermissionDenied` — confirmed in
source this session) — there is nothing on Android to leave, so nothing to
build there either, for the same "gap, not oversight" reason.

## 7. Sub-slicing

Two sub-slices, independent of each other.

### 7.1 Sub-slice A — #138 venue-device organizer UI

- Touches: new screen (placement per §5.3), `BarnardEngine.
  configureEventInfoServing` wiring. No `SensingCoordinator` change at
  all.
- Depends on: §5.1/§5.2/§5.3/§5.4/§5.5 resolved before/at start — this
  sub-slice is entirely gated on open decisions, more than any other part
  of this document.
- Acceptance: per the original #138 issue text — mode on/off works and is
  visible; a label-or-validity-period-less assignment cannot be created;
  trust disclaimer is present and passes a translator-comment/locale
  check; reassignment history shows past assignments.
- Both-OS: iOS-only (§6).
- i18n checklist: label field placeholder/validation copy, validity-period
  picker labels, trust-disclaimer text (§3.2, needs sign-off first),
  reassignment-history row copy — all five locales present at
  `needs_review` in the same PR.
- Evidence expected at PR time: real device/simulator build
  (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`-prefixed,
  concrete simulator UDID) and test run, not a stated environment gap —
  both blockers that previously prevented this are resolved.

### 7.2 Sub-slice B — #139 layer 3's mechanism only

- Touches: `SensingCoordinator`'s participation-lifecycle region only —
  one new method (§4.2). No UI.
- Depends on: nothing.
- Acceptance: per §4.2's test coverage description; a test proving the
  method is a no-op once `phase == .recording` (§4.3); a test proving it
  touches none of `phase`'s own transition rules, `devicesVerified`, or
  window/ledger state, mirroring the ownership-boundary test shape
  `docs/specs/event-discovery.md` §10.1 already uses.
- Both-OS: iOS-only (§6).
- i18n: none (no UI in this sub-slice).
- Evidence expected at PR time: same as Sub-slice A.

## 8. Branch note

Independent of each other; land in either order. Rebase each onto `main`
immediately before implementation starts, not just at spec-approval time —
three other tracks are concurrently landing PRs against adjacent files,
and `SensingCoordinator.swift` specifically is under active, concurrent
edit by other tracks even though Sub-slice B's one method is a small,
additive surface.

---

## Appendix A — #141, #101, and #139 layer 2 analysis (reference material, not active Track B scope)

Preserved from the original combined draft for whoever picks this work up
next, most likely the user directly per §0. Both this spec's author
(Worker `a-20260809-007`) and SubPM `a-20260808-026` independently
verified the technical claims below against live source and the actual
GitHub comment threads this session — line-number citations were current
as of 2026-08-09 and should be re-checked before use, per this project's
standing rebase-before-implementing convention, since other tracks
continue to land PRs against the same files.

### A.1 What #101 actually breaks

- `OnboardingMode.current` is still hardcoded `.guestFirst`
  (`OnboardingMode.swift:19`).
- `AppCoordinator.beginOnboarding()` (`AppCoordinator.swift:38-51`) routes
  `.guestFirst` straight to `.bluetoothPermission`; `.walletConnect` is
  only reached via the `.walletFirst` branch or `returnToWalletConnect()`
  (`AppCoordinator.swift:70-71`), itself only reachable from
  `EventCodeEntryView`. `skipWalletForEventCode()`
  (`AppCoordinator.swift:63-65`) is the only path to
  `screen = .eventCodeEntry`, and it hangs off `WalletConnectView`, which
  the live default never visits.
- `SensingCoordinator.startSensing(eventCode:demoEvent:)`
  (`SensingCoordinator.swift:542-558`) opens with
  `let eventCode = eventCode ?? joinedEventCode ?? "beid-demo-event"` —
  unconditional, not gated by `useDemoEventMode`. `joinedEventCode` can
  never be set today because its only setter,
  `SensingCoordinator.joinEvent(_ code: String) -> Bool`
  (`SensingCoordinator.swift:535-540`), sits behind the same unreachable
  screen. `EventCodeEntryView` calls the UI-facing wrapper
  `AppCoordinator.joinEvent(code rawCode:) -> EventCodeJoinError?`
  (`AppCoordinator.swift:80`) — a different function on a different type —
  which validates the trimmed code and then calls
  `sensingCoordinator.joinEvent(trimmed)` internally, translating its
  `Bool` into `.joinFailed` or `nil`. Either way, the route to reach it is
  what's missing, not the join call itself.
- **Android has no equivalent bug.** `AppNavHost.kt:18-20` sets
  `Screen.EventJoin.route` as the app's actual `startDestination`, and
  `EventJoinScreen.kt` is a plain event-code text field wired directly to
  `EventJoinCoordinator.joinEvent(code:)` — reachable from a cold launch
  today.

### A.2 What's already built and unused: `EventCardView` / `EventFoundView` / `ScanFlowView`

`EventCardView` (`ios/Beid/Views/EventCardView.swift:1-133`) is already a
shared, reusable single-event panel — icon, name, optional venue, a
`Badge` (`.detected`/`.recording`/`.paused`), and a generic `caption`
slot — used today by `EventFoundView`, `RecordingView`, and
`SignalLostView`. `ScanFlowView.content` (`ScanFlowView.swift:93-105`)
switches on `SensingCoordinator.phase` to pick which of those to show.
Whoever builds #141's card list should extend `EventCardView`'s badge
vocabulary rather than build a second component.

`EventFoundView.swift:1-42` currently renders `BeidStatusLayout` with a
large `"sparkles"` icon, the title `"Event Found"`, and the static message
`"Verification starts automatically — stay nearby"`, with an
`EventCardView(badge: .detected)` as the layout's `accessory`. The PM's
#104 finding against this exact shape (Figma `104:636` keeps a status-pill
+ continuing-radar treatment with the caption in the card's own slot;
shipped uses the big-icon-and-title pattern instead — radar omission
itself is an already-accepted, closed deviation, DESIGN.md §9) is **not
resolved here** — it belongs to whoever redesigns this screen as part of
#141, since #114's phase-semantics ruling (below) and Figma sign-off both
bear directly on that redesign.

### A.3 `docs/specs/event-discovery.md`'s design: approved, not yet implemented

That spec's `.eventInfoHint` handling (§3.3), discovery-only scan (§3.1
step 2), bounded hint list on `SensingView` (§5), and deep-link/QR code
delivery (§4) are all **approved but unbuilt** — `SensingCoordinator.swift`
has no `.eventInfoHint` case at all; `handle(_:)`
(`SensingCoordinator.swift:351-365`) only switches on `.state` and
`.detection`, `default: break` covering everything else including
`.eventInfoHint`.

### A.4 What's already landed in `shared/`, and its real limits

PR #161 (`a6b270e`, "B005 受信の土台") landed three pure-function files,
all tested (`EventInfoStoreTest.kt`, `EventInfoStoreSeparationTest.kt`,
`RelayMajorityTest.kt`):

- **`EventInfoStore.kt`** — an observer-local store of B005 hint
  observations (`recordEventInfoHint`), joined at read time against
  supplied `EventDefinitionFacts` (`eventInfoCandidates`). It **annotates,
  never filters** — every retained event comes back, matched or not, so
  each of #139's three layers stays independently disableable at the
  native call site rather than inside the store (`EventInfoStore.kt:41-47`).
  `EventCandidate.observationCount` is explicitly documented as "never a
  crowd size" (`EventInfoStore.kt:135-146`).
- **`EventWindowFilter.kt`** — `isEventWindowOpen(definition,
  atWindowIndex)` (`EventWindowFilter.kt:26-29`), a pure predicate over
  `EventDefinitionFacts.eninStart`/`eninEnd`. This is #139 layer 1 —
  complete, tested, ready to call, and already landed shared-side; its
  native wiring is part of the #100/#141 work that stays with the user
  now (§0).
- **`RelayMajority.kt`** — `evaluateRelayMajority(input, parameters,
  atWindowIndex)` (`RelayMajority.kt:177-224`), the pure decision behind
  #139 layer 2 and #141's zero-tap trigger. Complete and tested, but its
  one input cannot be filled with real data today:

  > **Nothing can fill this from live sensing today.** Barnard 0.3.0's
  > B005 receive API carries no relayer identity, so a relay count cannot
  > be derived from it (levarac/barnard#128). [...] Do not feed it a
  > count synthesized from peripheral identity observed in beid's own scan
  > layer; see `RelayCount`.
  > — `RelayMajority.kt:47-53`, doc comment on `RelayObservationInput`

  `EventInfoStore.kt`'s `RelayCount` type carries the same finding:
  `EventCandidate.relayCount` is `Int?`, not `Int` — "absent" and "zero"
  are different claims and only "absent" is true today
  (`EventInfoStore.kt:167-186`); `eventInfoCandidates()` always passes
  `relayCount = null` (`EventInfoStore.kt:388-389`).
  `RelayMajorityParameters`'s proposed defaults (`recentWindowCount = 3`,
  `minimumLeadingRelayCount = 3`, `minimumLeadPercent = 200`) are
  explicitly marked **"PRODUCT SIGN-OFF REQUIRED"** in the source
  (`RelayMajority.kt:11-36`) — not yet ratified by anyone.

  **Checked independently, three ways, same conclusion**: this spec's own
  research, Track C's separate confirmation, and knaoe's comment on the
  #139 thread all converge on the same root cause and the same
  `levarac/barnard#128` cross-reference. `DECISIONS.md` 2026-08-09
  formalized this as "#139 層2は8/20のスコープから外す."

### A.5 The load-bearing question the original draft raised: how would a zero-tap candidate actually get joined?

Even granting a perfectly clear, single, unambiguous B005-matched
candidate, **`EventCandidate` never carries the raw event code** — only
`eventCodeHashHex` (`EventInfoStore.kt:130-131`). Joining requires calling
`SensingCoordinator.joinEvent(_ code: String)` with the actual code,
because `configure(eventCode:)` is what lets the engine derive the RPID
sequence to match against — Barnard's B005 spec deliberately withholds the
raw code from the wire. A hash match tells beid *that* a candidate is real
and registry-matched; it does not tell beid *what to type into
`configure(eventCode:)`*.

**The only protocol mechanism that would close this gap — join directly
off a hash-matched hint, no code ever entered by anyone — is
`levarac/barnard#123` ("code-less walk-up join").** Checked this session:
still Backlog, "direction agreed... the concrete mechanism is NOT
decided," no assignee, no timeline. `DECISIONS.md` 2026-08-09's #138
walkback already recorded #123 as deferred future work, not adopted for
this milestone.

**Three readings of what "zero-tap" can honestly mean**, for whoever
resumes #141:

- **(a) True code-less zero-tap.** Requires barnard#123. Not available.
- **(b) Zero-tap conditioned on the code already being known to the device
  via an already-approved delivery channel** (deep link / QR via system
  Camera app, per `docs/specs/event-discovery.md` §4). Once the code is
  known, `configure(eventCode:)` + the existing real-detection pipeline
  proceeds with no further taps. The B005-hint candidate list stays a
  discovery/ambient-awareness surface for events the device does not yet
  have a code for — tapping such a card routes to manual entry with
  prefilled context, exactly as `docs/specs/event-discovery.md` §3.1
  step 4 already specifies.
- **(c) Some other automatic code-delivery path**, e.g. #108's Ethereum
  registry exposing enough that a hash match alone lets beid derive what's
  needed. Unverifiable: #108 has zero comments and no design yet.

**Recommendation carried forward: (b).** It is what's buildable against
the currently-pinned SDK and matches the project's decision not to wait on
#123. It reframes #141's literal acceptance criterion — a real narrowing
relative to the plain issue text and the UX-canon quote it cites — which
is why it was flagged as requiring explicit owner sign-off rather than
assumed. **Consequence for the "rare selection UI"**: because layer 2 has
no real data and a device only ever has a code for events it was
explicitly given one for, the realistic v1 shape is that the selection UI
is rare but, when ≥2 known-code candidates are live at once, it *always*
appears — `evaluateRelayMajority` can never return `isMajorityClear: true`
while its only input is empty. Not a bug to route around; the honest
behavior of an anti-mischief layer whose evidence doesn't exist yet.

### A.6 #141's own comment thread — the implementer question and the Figma gate

knaoe posted, 2026-08-08T03:36:47Z, on #141 ("オーナー裁定 (2026-08-08 ヒア
リング) を反映します"): point 2 reads verbatim — *"本issue と #53 の起動→
参加画面群は小野寺さんが実装(同じ画面を触るため一本化)"*. Cross-referenced
against `DECISIONS.md`'s consistent use of "小野寺さん"/"ユーザー"
interchangeably (e.g. "決定者: ユーザー(小野寺さん)") and a matching git
commit author email in this repo — this is the finding `DECISIONS.md`
2026-08-09 confirmed and that moved #141/#101 out of Track B's scope (§0).

The same comment's point 3: *"カードのビジュアルは小野寺さんの Figma 先行 —
Figma 確定までカード画面の実装着工は保留"* — the card list's visual design
is gated on Figma sign-off, independent of the implementer question.

A follow-up knaoe comment (2026-08-08T05:24:09Z) on #141 confirms the
majority-judgment boundary: the "is the majority clear" determination
lives in `shared/` (matching `RelayMajority.kt`'s existence), with native
screens only rendering the result — and flags that this determination's
input (relay count) is the same gap A.4 documents, already filed as a
request against `levarac/barnard#128`.

### A.7 If/when this work resumes: open items carried forward, not resolved here

1. **§A.5's reading of "zero-tap"** — recommend (b), needs explicit owner
   sign-off since it narrows the literal issue text.
2. **`EventFoundView`'s redesigned shape** (A.2, the #104 finding) —
   recommend a status-pill-in-card-slot shape over the shipped big-icon
   pattern, reasoning: `EventCardView` already has a caption slot built
   for this, the app already has a shared `statusPill` component (2026-07-27
   decision record), and it reads as more provisional/tentative — which
   independently fits #114's ruling that `.eventFound` carries no protocol
   claim. Final pixels await Figma regardless.
3. **Copy for `.eventFound` vs. `.recording`** must not imply commitment
   before `.recording` is real, per `DECISIONS.md` 2026-08-09's #114
   ruling: something tentative at `.eventFound` ("Nearby: {name}" /
   "Confirming {name}"), "Recording for {name}" only at `.recording`.
4. **`RelayMajorityParameters` defaults** (`recentWindowCount = 3`,
   `minimumLeadingRelayCount = 3`, `minimumLeadPercent = 200`) — marked
   "PRODUCT SIGN-OFF REQUIRED" in the shared source itself; not yet
   ratified. Moot until layer 2 resumes, but worth not losing track of.
5. **Minority-candidate visibility** — an explicit constraint from the
   #139 audit comment: "UX 正本は『複数のカードが並ぶ』『いたずらのカードは
   (実勢により)選ばれない』であり、存在自体を見えなくすることは約束してい
   ない." A non-leading candidate should collapse into a summarized row
   rather than disappear, matching `EventInfoStore.kt`'s own
   `hasEvictedEvents` precedent, whenever the candidate list itself gets
   built.
