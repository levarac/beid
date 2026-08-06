# Spec — Event Discovery (gh#100)

Status: **APPROVED** (user, 2026-08-06). §9's two open decisions are both
resolved, each in favour of this document's own recommendation — see the
RESOLVED blocks in §9.a and §9.b, and `DECISIONS.md` 2026-08-06.

Implementation has **not** started. One prerequisite landed as a separate
issue after this spec was written: the join path is currently unreachable
in shipped builds, so every real device falls back to the literal event
code `"beid-demo-event"` (gh#101). A discovery hint has nowhere to lead
until that is fixed, so **gh#101 comes first**.

Author: Worker `a-20260806-018`, for SubPM `a-20260806-017`.
Phase 1 findings: this document's claims about Barnard 0.3.0 and about
beid's current source were established in a separate research pass earlier
this session (reported to the SubPM as the Phase 1 findings report,
2026-08-06) and are re-cited here at their original file:line /
spec-section:line granularity, not re-derived. Two new claims not covered
in Phase 1 — whether `EventCodeEntryView` is reachable under the live
onboarding mode, and whether beid has any QR/deep-link capability today —
were verified fresh this session and are cited the same way.
Builds on: `docs/redesign-barnard-0.3-survey.md` §4 (initial B005 fit
read); `docs/specs/barnard-binding-conformance.md` §6.a (the
no-`.entitlements`-file finding, reused here for the deep-link vs.
universal-link tradeoff in §4).
Tracks: gh#100 ("Event Discovery"). Barnard is pinned at 0.3.0
(`ios/project.yml:10`); the B005 event-info discovery characteristic was
adopted per `DECISIONS.md`'s 2026-08-06 entry ("B005 event-info discovery
を採用する"), which also fixed this spec's key boundary in advance —
quoted verbatim where relevant below.

## 1. Scope

**IN**: the full proposed join lifecycle covering both the walk-up case
(no prior code) and the pre-shared-code case (§3); how a code physically
reaches a user, with an actual recommendation (§4); the concrete trust-model
UI/behavior for unauthenticated B005 hints, including conflict handling
(§5); whether beid ships any B005-serving capability in this slice (§6);
where event display names and venues come from, including B005's hard
limits (§7); two decisions genuinely left to the PM/user (§9); and
acceptance criteria + sub-slicing (§10).

**OUT** (see §8 for the full list and reasoning): `SensingCoordinator`'s
session-end finalization, window reporting, or self-proof paths (gh#91,
currently under active concurrent implementation — the exact reason this
spec's own additions there are written to be narrow and additive, §3.3);
the wallet-binding ceremony (gh#88); the wallet connectors; the per-window
report wire format; any change to `WalletConnectView`'s own
keep-or-remove fate (still pending the 2026-07-28 decision record, unrelated
to this spec).

**Method note**: no product code was written or edited to produce this
document. Every function signature, file:line, and spec clause cited below
was read directly from `levarac/barnard` v0.3.0 source (the exact pinned
revision, confirmed via `git rev-parse HEAD` inside the SwiftPM checkout
under Xcode's DerivedData — see the Phase 1 report's provenance note) and
beid's current `ios/Beid` source, this session or the immediately preceding
Phase 1 pass in the same session.

## 2. Today's join lifecycle, and a reachability gap this spec must close first

Before proposing anything new, one fact has to be stated plainly because it
changes what "add discovery to the existing join flow" actually means in
practice: **the existing join flow is not reachable from the app's live
onboarding path today.**

- `OnboardingMode.current` is hardcoded to `.guestFirst`
  (`OnboardingMode.swift:19`) — this is not a runtime toggle, it is the
  actual shipped default.
- Every `AppScreen` assignment in the app was enumerated directly
  (`grep -rn "screen = \." ios/Beid`): `.walletConnect` is only ever
  assigned from `beginOnboarding()`'s `.walletFirst` branch
  (`AppCoordinator.swift:41`) and from `returnToWalletConnect()`
  (`AppCoordinator.swift:71`, itself only reachable from
  `EventCodeEntryView`'s own "Connect wallet instead" button). `.guestFirst`
  (the live mode) routes `beginOnboarding()` straight to
  `.bluetoothPermission` (`AppCoordinator.swift:43`) and never visits
  `.walletConnect`.
- `EventCodeEntryView` (`AppScreen.eventCodeEntry`) is only reachable via
  `skipWalletForEventCode()` (`AppCoordinator.swift:63-65`), which is only
  called from `WalletConnectView`'s secondary action.
- Therefore, under the live default mode, there is currently **no path
  in the shipped UI that reaches `EventCodeEntryView` at all.**
- The knock-on effect is worse than a dead screen: `CollectionHomeView`'s
  "Sense Event" CTA (`CollectionHomeView.swift:99-100`) calls
  `coordinator.startScan()` directly →
  `SensingCoordinator.startSensing(eventCode:demoEvent:)`
  (`SensingCoordinator.swift:232-248`), whose very first line is
  `let eventCode = eventCode ?? joinedEventCode ?? "beid-demo-event"`
  (`SensingCoordinator.swift:233`) — a line that runs unconditionally,
  **not** gated by `useDemoEventMode` (that flag, checked two lines later
  at line 236, only selects whether the *scripted* demo sequence runs; it
  does not affect which event code the real engine gets configured with).
  Since `joinedEventCode` can never be set today (the only place that sets
  it, `SensingCoordinator.joinEvent(_:)` called from
  `AppCoordinator.joinEvent(code:)`, is behind the unreachable
  `EventCodeEntryView`), **every real-device tap of "Sense Event" under the
  live default configures the real Barnard engine to scan for the literal
  event code `"beid-demo-event"`** — a string no real event will ever use —
  and then waits indefinitely, matching nothing. Real-device sensing is
  effectively non-functional today outside the simulator/demo-launch-arg
  path, independent of anything B005 does.
- `SensingView` (`SensingView.swift:19`), the screen actually shown while
  waiting (`ScanFlowView`'s `.idle`/`.sensing` phase,
  `ScanFlowView.swift:96-97`), already carries the copy **"Walk into an
  event — it will show up here automatically."** This is aspirational
  copy for a capability that, per the Phase 1 finding, cannot exist without
  B005 or an equivalent: RPID is derived from the event code, so a device
  cannot recognize an event whose code it does not already have.

This spec's design (§3) therefore does two things at once, deliberately:
it wires B005 discovery into the app, and it is what finally gives
`SensingView`'s existing promise something real to point at — closing a
gap gh#100 did not create but that gh#100 is the first feature to actually
need fixed, since without a reachable code-entry surface there is nowhere
for a discovery hint to lead. The fix is scoped narrowly (a new entry point
into an existing, already-built, already-tested view — not a redesign of
onboarding, not a change to `WalletConnectView`'s pending fate, not a
change to `OnboardingMode`) and is included in Sub-slice 1 (§10.1).

## 3. The proposed join lifecycle

### 3.1 Walk-up case (no prior code)

1. User taps "Sense Event" from `CollectionHomeView` (unchanged trigger,
   `CollectionHomeView.swift:99-100`).
2. `ScanFlowView` presents; `SensingCoordinator` phase is `.idle`. **New**:
   while `phase == .idle`, `SensingCoordinator` runs a discovery-only scan
   — `engine.startAuto()` without a preceding `engine.configure(eventCode:)`
   call (confirmed legal: `startAuto()`'s only parameters are
   `scanAllowDuplicates`/`advertiseFormatVersion`, `BarnardEngine.swift:568-570`,
   and does not require a prior `configure(eventCode:)` call; the spec's
   own Central Behavior §2 states a Central "MAY read [B005] whether or not
   it already has an event code," spec lines 380-381). This scan is
   discovery-only: `handleDetection` already ignores `.idle`
   (`SensingCoordinator.swift:191-196`, existing `.idle, .signalLost: break`
   arm — unchanged), so no window/self-proof/binding state is touched by
   running the engine before a code is known.
3. `SensingView` renders its existing radar UI **plus** a new, bounded list
   of unverified nearby-event hints (§5) as `.eventInfoHint` events arrive.
4. User taps a hint, or the existing "Enter code manually" affordance
   (**new** — a link into `EventCodeEntryView`, presented via
   `ScanFlowView`'s own `NavigationStack` push rather than the root
   `AppCoordinator.screen` switch, so the full-screen scan cover is not
   dismissed just to type a code; `EventCodeEntryView` itself is unchanged).
   Tapping a hint does **not** prefill the code field — B005 never carries
   the raw code (§3.3, Claim 1) — it prefills only the ambient context (the
   candidate `eventDisplayName`, e.g. as a "You're near {name} — enter its
   code below" banner).
5. User types (or the deep link in §4 supplies) a code and taps "Join
   Event" — unchanged `EventCodeEntryView.submit()` →
   `AppCoordinator.joinEvent(code:)` → `SensingCoordinator.joinEvent(_:)` →
   `BarnardEngine.joinEvent(_:)` (`BarnardEngine.swift:597`). If a retained
   hint's `eventCodeHash` matches `BarnardCoreCrypto.computeEventCodeHash(code)`
   (public API, `BarnardCoreCrypto.swift:176` — already imported via
   `import BarnardCore`, `SensingCoordinator.swift:5`), the confirmation
   copy may say so (a cross-check, not a gate — see §5.2 for what this must
   never do).
6. Discovery scan stops (or transparently continues as the same
   `BarnardEngine` instance, now `configure(eventCode:)`-d for the joined
   code — no stop/restart needed); real sensing proceeds exactly as today
   (`SensingCoordinator.startSensing`'s existing real-path branch, lines
   239-246, unchanged).

### 3.2 Pre-shared-code case (someone was handed a code in advance)

Same as today (`EventCodeEntryView` → `AppCoordinator.joinEvent(code:)` →
`SensingCoordinator.joinEvent(_:)`), now reachable per §2's fix, plus: if a
B005 hint matching the user's typed code was already observed during the
same discovery session (§3.1 step 2's scan runs regardless of whether the
user arrived with a code already in hand, since both cases pass through the
same `SensingView`/discovery-scan state), the same optional cross-check
copy from §3.1 step 5 applies. Nothing else changes.

### 3.3 Where `.eventInfoHint` plugs in, and where it explicitly does not

**New, narrow addition to `SensingCoordinator.handle(_:)`**
(`SensingCoordinator.swift:161-171`):

```swift
private func handle(_ event: BarnardEvent) {
  switch event {
  case .state(let state):
    isScanning = state.isScanning
    isAdvertising = state.isAdvertising
  case .detection(let detection):
    handleDetection(enin: detection.enin, rpid: detection.rpid)
  case .eventInfoHint(let hint):          // new
    handleEventInfoHint(hint)             // new — see below
  default:
    break
  }
}
```

This is the entire change to that switch: one new case, alongside the two
that already exist, with the same `default: break` still covering
`.constraint`/`.error`/`.rssiUpdate` unchanged. `handleEventInfoHint(_:)`
itself is new code living in its own section of `SensingCoordinator`
(mirroring how "Wallet connect+binding" and "Per-window report signing"
already live in their own `// MARK:`-delimited sections in the same file,
`SensingCoordinator.swift:359,512`) — it reads and writes only new
`@Published` state (`discoveredEventHints`, §5) and never touches
`phase`, `distinctPeerRpids`, `currentWindowEnin`/`currentWindowRpids`,
`activeCommit`, `activeProofId`, `bindingState`, or any method under the
"Per-window report signing" or "Self-proof" `// MARK:` sections. This is
the concrete form of the Phase 1 report's own closing concern: additive
alongside `SensingCoordinator`'s other paths, not a restructuring, so it
does not collide with gh#91's concurrent work on the same file's
session-end/window/self-proof paths.

**What `.eventInfoHint` explicitly does not do** (Claim 1, re-cited): it
never calls `AppCoordinator.joinEvent`, `SensingCoordinator.joinEvent`, or
any other admission-adjacent method. The only two things a hint can ever
trigger are (a) appearing in the discovery list (§5) and (b) supplying
display copy once the user has separately, explicitly submitted a code.
Spec: "a hint may speed discovery but never auto-joins" is beid's own
paraphrase (Phase 1 report, DECISIONS.md 2026-08-06) of the spec's actual
Non-goals line 46 ("Automatically joining, selecting, or suppressing an
event") and Central Behavior §4 (spec lines 386-387, "MUST require the user
to confirm before joining").

## 4. How a code reaches a user

### 4.1 What exists today, verified this session

- **QR — generation only, no scanning.** `QRCodeRenderer.swift:9-11` wraps
  `CIFilter.qrCodeGenerator()` and is used exactly once, to render the
  WalletConnect pairing URI (`WalletConnectView.swift:222`). Grepped the
  whole of `ios/Beid`/`ios/BeidTests` for `AVFoundation`, `AVCapture`,
  `VisionKit`, and `CodeScanner`: zero matches. There is no camera-based
  reading capability anywhere in the app, and no camera usage description
  in `ios/project.yml`.
- **Deep link — the plumbing already exists, unused for this purpose.**
  `ios/project.yml:69-71` registers `CFBundleURLSchemes: [beid]`;
  `BeidApp.swift:14-20`'s `.onOpenURL` handler already exists and currently
  routes every incoming URL to three wallet connectors
  (`ReownWalletConnectClient`, `CoinbaseWalletConnector`, and in `DEBUG`,
  `MetaMaskConnector`) — never to anything event-code-related.
- **No universal links.** Confirmed (reusing the finding already made in
  `docs/specs/barnard-binding-conformance.md` §6.a for an unrelated
  question): there is no `.entitlements` file anywhere in the repo, so no
  Associated Domains capability exists — a universal-link (`https://`)
  delivery mechanism would require standing up real, beid-controlled
  infrastructure (DNS + hosting + entitlement) from nothing, unlike the
  custom `beid://` scheme, which is already registered and already wired.
- **Manual/spoken entry — already shipped**, just unreachable today (§2).

### 4.2 Recommendation

**Primary: extend the existing `beid://` custom-scheme deep link.** Add a
`beid://join?code=<event code>` form, parsed in `BeidApp.onOpenURL` as one
new branch alongside (not replacing) the three existing connector calls —
the same "narrow addition next to what's already there" shape as §3.3's
`SensingCoordinator` change. This is the cheapest possible new mechanism:
zero new Apple entitlements, zero new permissions (no camera usage
description needed), zero new third-party frameworks, and it reuses
infrastructure (`CFBundleURLTypes`, the `onOpenURL` hook) that already
ships and is already tested via the wallet-connector flows.

**QR is the recommended physical transport for that same link, not a
separate mechanism**: an organizer displays or prints a QR code that
encodes the `beid://join?code=...` URL (generation is an organizer-side
concern — e.g. a small web tool or script, out of this app's scope, same
as beid never having built an organizer registry, §6) — attendees scan it
with the **stock iOS Camera app**, which already recognizes QR-encoded URLs
(including custom schemes) and offers a banner to open the corresponding
installed app. This means the deep-link handler in §4.2's "Primary" bullet
is *also* the entire QR story — no in-app scanning code is needed for a
working v1. Building an in-app camera-based scanner (e.g., `VisionKit`'s
`DataScannerViewController`, available on beid's iOS 17 minimum without a
new permission-description string beyond a camera usage description) is a
plausible future enhancement — e.g., if organizers want attendees to scan
within beid directly rather than routing through the system Camera app —
but is **not required** for the v1 flow to function, and is not part of
Sub-slice 1 (§10.1).

**Manual/spoken entry stays the universal fallback**, unchanged — this is
what §2's reachability fix restores, and it is the only mechanism that
requires nothing from the organizer beyond being willing to say or post the
code (matches the spec's own "QR code, staff member, or venue sign" framing,
`specs/113-event-info-discovery/spec.md:95`).

**Pre-registration** is not a beid mechanism to build at all: an external
system (email, event-platform notification) that sends the same
`beid://join?code=...` link achieves the same effect through the identical
deep-link handler — nothing beid-side changes to "support" it.

This is stated as a recommendation, not an open decision (§9), because the
technical case is one-sided given what already exists in the repo — see
the Phase 2 report for why this was not escalated.

## 5. Trust model for unauthenticated hints

### 5.1 UI element and labeling

A new, bounded list on `SensingView` (§3.1 step 3), each row showing
`eventInfo.eventDisplayName` rendered as **plain text only** (spec
requirement, "MUST render it as untrusted plain text and MUST NOT
interpret it as markup," spec line 277) inside a visually muted/outlined
chip — not the solid-fill style beid's design system (`DESIGN.md`) uses for
confirmed/verified state, matching `docs/specs/barnard-binding-conformance.md`
§3's precedent of distinguishing ceremony-in-progress states visually. Each
row is labeled with copy that names the hint as a suggestion, not a fact —
e.g. "Nearby, unverified" as a secondary label under the event name (exact
copy is an implementation-time wording choice, not fixed by this spec;
whatever is chosen must satisfy AGENTS.md's localization process — a
translator `comment:` is required here specifically, since "unverified"
next to an event name is exactly the kind of short, ambiguous-out-of-context
string AGENTS.md flags as needing one). Tapping a row navigates into
`EventCodeEntryView` per §3.1 step 4 — it never joins directly.

### 5.2 What a hint must never do

Concrete, not principled — each of these is a specific UI/behavior
guarantee, not a bulleted value statement:

- **Never joins.** The only call site for `AppCoordinator.joinEvent(code:)`
  remains `EventCodeEntryView.submit()` (§3.3) plus the new deep-link branch
  (§4.2) — both require an explicit user action (a tap, or having followed
  a link they chose to open) that supplies an actual code. No code path
  introduced by this spec calls `joinEvent` from inside hint-handling code.
- **Never suppresses or overrides a directly observed event or peer.**
  Spec Central Behavior §6 (line 393): "B005 absence, failure, or mismatch
  MUST NOT suppress a directly observed advertisement or an otherwise valid
  existing same-event detection." Concretely: `handleEventInfoHint(_:)`
  never touches `phase`, and the existing real-detection path
  (`handleDetection`, `SensingCoordinator.swift:180-198`) is entirely
  unmodified by this spec — a real peer detection during `.sensing`/
  `.eventFound`/`.recording` proceeds exactly as it does today regardless
  of what hints are or aren't present in `discoveredEventHints`.
- **Never treated as proximity/attendance proof.** A hint updates only the
  new `discoveredEventHints` UI state; it never creates a `Proof`, never
  sets `activeCommit`/`activeProofId`, and is discarded (not persisted
  anywhere beyond the current discovery session) the moment the scan sheet
  closes or a real join occurs for a different event.
- **A hash match is a courtesy, not a gate.** The cross-check described in
  §3.1 step 5 may only ever *add* confirming copy; a code with no matching
  hint, or a code whose hash mismatches every retained hint, must join
  exactly as successfully as it does today — mismatch proves nothing about
  legitimacy (spec line 469-470: "Hash equality is not authentication and
  hash inequality does not prove that either event is legitimate").

### 5.3 Conflict handling — an actual answer, not a deferral

The Barnard engine already performs the spec-mandated bookkeeping
internally (`BarnardEventInfoDiscoverySession`, `BarnardEventInfo.swift:198-232`)
and surfaces its result on every `BarnardEventInfoHintEvent` via
`additionalNamesOmitted`/`additionalEventsOmitted`
(`BarnardEngine.swift:119-124`) — beid does not need to re-implement the
32-hash/4-name-per-hash retention caps. What beid does need, and what the
SDK does not provide, is the actual retained set to render. Proposed
`SensingCoordinator` state:

```swift
struct DiscoveredEventHint: Identifiable, Equatable {
  var id: Data { eventCodeHash }
  let eventCodeHash: Data
  var eventDisplayName: String
  var hasNameConflict: Bool = false   // same hash, ≥2 distinct names seen
}
```

`handleEventInfoHint(_:)` upserts by `eventCodeHash` into a bounded
`@Published private(set) var discoveredEventHints: [DiscoveredEventHint]`:
same hash + same name already present → no-op; same hash + a *different*
name → set `hasNameConflict = true` on that entry (row renders as "Multiple
names reported nearby" instead of a single name — spec line 469's
"MUST surface every multiple-name condition as a conflict rather than
silently selecting a name," applied concretely); a genuinely new hash →
append, bounded at a small UI-relevant cap (e.g. 8 — deliberately smaller
than the SDK's own 32-hash safety cap, since 32 simultaneous rows is not a
usable list; the exact number is an implementation detail, not fixed by
this spec). If `additionalEventsOmitted` is set on an incoming event (SDK
signals 33rd+ distinct hash), append one static "more nearby events not
shown" row rather than attempting to parse the event's own payload (which,
per `eventInfoForDiscoveryHint`, `BarnardEventInfo.swift:189-195`, is
already replaced by an empty marker in that case — parsing it as a real
hint would be wrong).

## 6. Serving side

**This slice does not ship end-user-facing serving.** Reasoning:

- `configureEventInfoServing(organizerDesignated:eventActiveForDiscovery:eventDisplayName:)`
  (`BarnardEngine.swift:471-483`) requires the caller to already know *who*
  is allowed to flip `organizerDesignated` to `true`. beid has no role,
  permission, or organizer concept anywhere today — confirmed by grep
  (`grep -rni organizer ios/Beid` returns only user-facing copy strings and
  one doc comment about a value being organizer-configurable *in the
  future*; `BeidConfig.swift:12`).
- The Barnard spec deliberately does not answer this either — it is not an
  oversight to fill in from the SDK side. Non-goals (spec line 52):
  "Defining organizer provisioning, event-registry, signing, or
  user-interface APIs" is explicitly out of Barnard's own scope. Rejected
  alternatives under design decision 2 (spec lines 128-135) name and reject
  three candidate shortcuts beid must not silently reach for later: "every
  joined device serves" (unbounded disclosure), "a designated-device
  identifier in the payload" (adds a tracking handle), and "inferring
  organizer status from RPID or displayId" (neither proves authority).

**Addressed head-on: a consuming-only implementation is inert without at
least one serving device.** `DECISIONS.md`'s own 2026-08-06 entry already
states this plainly ("送信する端末が1台も無ければ受信側は何も受け取らない").
Recommendation to make Sub-slice 1 (§10.1) actually testable/dogfoodable
despite this, without resolving §9.a: reuse the exact pattern
`useDemoEventMode` already established for a different capability-gating
problem — a `DEBUG`-only launch argument (mirroring
`-beid-demo-event`, `SensingCoordinator.swift:120`), e.g.
`-beid-serve-event-info`, that calls `configureEventInfoServing` with a
fixed test event code/display name on app launch. This gives whoever
implements/reviews this spec a real device that serves a real B005 payload
to test the consuming side against, with zero organizer UI, zero role
system, and zero risk of an end user ever triggering it (the same guard
shape `useDemoEventMode`'s `Release`-build no-op setter already uses,
`SensingCoordinator.swift:123-131`, applies identically here). This is a
recommendation to include now, independent of how §9.a resolves — §9.a is
specifically about *real*, end-user-facing serving with an actual organizer
concept, which is a materially bigger decision the debug toggle does not
prejudge.

## 7. Where event names and venues come from

**Today, unchanged as the fallback**: when no confirmed hint exists for the
joined code, `SensingCoordinator.handleDetection`'s real path
(`SensingCoordinator.swift:183-184`) keeps synthesizing
`EventSession(id: eventCode, name: eventCode, venue: nil)` exactly as it
does now — the raw code as the display name, venue absent. This spec does
not regress that fallback.

**Once a hint is confirmed for the joined event** (the retained
`DiscoveredEventHint` whose `eventCodeHash` matches the joined code's
`BarnardCoreCrypto.computeEventCodeHash` result, §3.1 step 5):
`EventSession.name` should be populated from
`eventInfo.eventDisplayName` instead of the raw code — this is populating
an **existing** field (`EventSession.name: String`, already non-optional,
`EventSession.swift:14`) with a real value for the first time on the real
path, not adding new model surface.

**Venue is a hard wall, not an open question this slice can close.** B005's
TLV registry defines exactly two assigned types — `0x01 eventDisplayName`
and `0x02 eventCodeHash` (spec lines 265-270); there is no venue type,
assigned or reserved. `BarnardEventInfo` (`BarnardEventInfo.swift:7-18`)
correspondingly has no venue field. **B005 cannot deliver a venue string in
any version of the v1 wire format** — this is not a gap this spec's own
scope can fill by reading the payload differently; it would require either
a future Barnard format version (explicitly gated behind "an explicit
privacy review and a new format version," spec lines 112-113) or a source
entirely outside B005. `EventSession.venue: String?`
(`EventSession.swift:17`) — already-existing, already-designed to render as
an absent line rather than a placeholder — stays `nil` on the real path
under this spec, exactly as today, unless and until the organizer-metadata
feature in §9.b ships. This spec does not propose reading venue from B005
because there is nothing there to read.

## 8. What stays out of scope

- **`SensingCoordinator`'s session-end finalization, window reporting, and
  self-proof paths** (everything under the `// MARK: - Per-window report
  signing` and `// MARK: - Self-proof` sections, `SensingCoordinator.swift:512,609`) —
  unmodified by this spec's §3.3 addition, which lives in its own section
  and touches none of that state. Another engineer is concurrently
  implementing gh#91 against exactly these paths in the same file; this
  spec's own narrow-addition discipline (§3.3) exists specifically so the
  two efforts don't collide.
- **The wallet-binding ceremony** (gh#88, `BindingMessage`,
  `OwnerKeyProvider`, `EventBindingSheetView`) — untouched; a confirmed B005
  hint has no relationship to wallet binding, which happens later in the
  session and off a different trust model entirely.
- **The wallet connectors** (`ReownWalletConnectClient`,
  `CoinbaseWalletConnector`, `MetaMaskConnector`) — `BeidApp.onOpenURL`'s
  three existing calls to them (§4.2) are unmodified; the new join-link
  branch is additive, not a restructuring of that closure.
- **The per-window report wire format** — B005 hints never enter
  `windowReportPayload` (`SensingCoordinator.swift:599-607`) or any signed
  artifact; they are UI-local, ephemeral, discovery-session-scoped state
  only, matching the Barnard spec's own "Deduplication is observer-local
  state and MUST NOT be transmitted" (spec line 400).
- **`WalletConnectView`'s keep-or-remove fate** — still pending the
  2026-07-28 decision record ("次回 MTG で Option C と一括判断"); this
  spec's §2 fix adds a *new*, independent path into `EventCodeEntryView`
  from `SensingView` and does not touch `WalletConnectView`'s existing
  `skipWalletForEventCode()` entry point, so nothing here narrows or
  presupposes that pending decision either way.
- **In-app QR/camera scanning** (§4.2) — deferred, not required for a
  functioning v1 given the system-Camera-app + deep-link combination.

## 9. Open decisions (blocking approval)

These two are raised in escalation format — background, options with real
tradeoffs, and a recommendation — because they go directly to the project
owner and, per this repo's standing rule, the spec cannot be approved
without them. Both are written for a non-engineer reader.

### 9.a Should beid ship real, end-user-facing B005 serving in this slice — and if so, who counts as an "organizer"?

**Background**: "Serving" is the half of this feature where a device
broadcasts "there's an event called X here" to everyone nearby. Today,
nothing in beid decides who is trusted to turn that broadcasting on — there
is no staff login, no event-ownership record, no admin role of any kind
anywhere in the app. Barnard's own protocol deliberately leaves this
decision to beid entirely — it will not tell us who an organizer is. §6
already recommends a safe, invisible-to-users debug switch so the
receiving side (§3-§5) has something real to test against without
answering this question — that part is not blocked on this decision.

**Options**:

- **(a) Ship nothing user-facing this slice.** Only the debug toggle from
  §6 exists; no real event can broadcast a hint unless a developer manually
  flips a hidden switch on their own test device. Real users only ever see
  the *receiving* side of this feature (discovery, code entry) — until a
  future slice adds real serving, most real-world events will have zero
  devices serving, so most users will simply never see a nearby-event hint
  and will fall back to typing a code, exactly as they do today.
  - *For*: ships now with no new trust/security surface to design or get
    wrong; broadcasting "there's an event here, and here's its name" to
    every phone within Bluetooth range is a real decision (anyone nearby
    can see it, per §5's trust-model discussion) that deserves its own
    consideration rather than riding along with this slice.
  - *Against*: the feature stays largely theoretical for real events until
    a follow-up ships — an organizer who wants to use this today has no
    supported way to.
- **(b) Ship a minimal self-serve toggle: any device can serve, no
  verification.** Add a plain, discoverable "Broadcast this event to
  nearby phones" switch, available to whoever has joined an event on their
  own device — no proof they're actually the organizer, no approval step.
  - *For*: simplest possible real feature; an organizer (or even an
    enthusiastic attendee) can turn it on immediately.
  - *Against*: anyone who has joined an event — including someone with no
    connection to actually running it — could broadcast it as if they were
    the organizer, with a name they typed themselves. This doesn't create a
    *new* impersonation risk beyond what an attacker could already do with
    their own copy of the Barnard SDK (§5.2 already assumes hints can be
    forged by anyone), but it does mean beid's own UI would be actively
    encouraging normal users to broadcast, which reads as an implicit
    "we vouch for this" the app currently never claims for anything.
- **(c) Ship a self-serve toggle gated behind some lightweight
  proof-of-organizer step** (e.g., whoever created the event code in some
  future event-registration flow is the only one who can enable serving for
  it). Requires a concept beid does not have today at all: a notion of
  "who created this event."
  - *For*: closes option (b)'s implicit-endorsement gap without needing a
    full account/login system.
  - *Against*: real, non-trivial new product surface (event creation/
    registration) that this spec cannot design as a side effect — it would
    need its own spec, and likely connects to §9.b's event-metadata
    question below (an organizer registering an event and naming it are
    naturally the same moment).

**Recommendation: (a) for this slice**, with (c) as the natural next step
once (or if) an event-registration concept exists at all — which is also
what §9.b is asking about. (b) is not recommended: it's the only option
that adds a new *product* trust claim ("beid lets you broadcast an event"
with zero backing) rather than merely exposing a protocol Barnard already
designed to be unauthenticated.

**RESOLVED — (a), user, 2026-08-06.** Ship no end-user-facing serving in
this slice; a `DEBUG`-only dogfood toggle is the whole of it. The deciding
reason is the one this section already gives: (b) is the only option that
would have beid assert something the protocol itself does not, and the
protocol deliberately exposes these hints as unauthenticated. Recorded in
`DECISIONS.md` 2026-08-06.

### 9.b Should beid build organizer-supplied event name/venue metadata, independent of whether B005 is present?

**Background**: today, real events on the real path have never had a human
name — only the raw code (§7). B005 can supply a name (when a device is
serving, which per §9.a may not happen for a while) but can *never* supply
a venue (§7 — this is a hard wire-format limit, not a policy choice). A
separate, B005-independent feature — an organizer types their event's name
and venue somewhere, and that gets attached to the event code — would give
every joined session a real name/venue regardless of whether anyone is
broadcasting a B005 hint, and is the only way `EventSession.venue` is ever
populated on the real path at all, ever, under any option in §9.a.

**Options**:

- **(a) Build it now, alongside this slice.** Add a lightweight
  organizer-facing "name this event" step (mechanism unspecified —
  plausibly the same moment an event code is created, which beid also does
  not have a flow for today) so `EventSession.name`/`.venue` are populated
  from real organizer input independent of B005.
  - *For*: solves the venue gap entirely (something B005 alone cannot ever
    do); makes every joined event's proof/collection UI show a real name,
    not just events lucky enough to have a serving device nearby.
  - *Against*: this is a materially bigger feature than event discovery —
    it requires deciding how an event code is created in the first place
    (beid has never had that flow; today event codes appear to be handed
    out by organizers through some out-of-band process this app has no
    visibility into), which is its own product question, not a natural
    extension of gh#100's actual ask ("let a walk-up user discover a nearby
    event").
- **(b) Do not build it now; venue stays absent, name stays the raw code
  except when a B005 hint fills it in.** Revisit only if/when event
  creation itself becomes something beid's app is involved in.
  - *For*: keeps this slice scoped to what gh#100 actually asked for;
    avoids designing a speculative event-registration system with no
    concrete owner-side requirement driving its shape yet.
  - *Against*: venue stays permanently absent for the foreseeable future,
    and event name stays the raw code for any event with no serving device
    nearby — which, per §9.a's recommendation, is most events for now.

**Recommendation: (b).** This spec's own scope (gh#100, "Event Discovery")
is about finding an event, not about organizers registering one — (a) is a
real, valuable idea but is a different feature with its own open questions
(who creates an event code today, and how), and forcing it into this slice
would make an already two-part feature (discovery + serving) into a third,
unrelated one.

**RESOLVED — (b), user, 2026-08-06.** No organizer-metadata feature in this
slice; `venue` stays `nil`. Note the structural limit this locks in, since
it is easy to misread as temporary: B005's TLV registry defines exactly two
record types (`0x01 eventDisplayName`, `0x02 eventCodeHash`), so venue
cannot ever arrive over B005 — only an organizer-metadata feature could
supply it, and that is now explicitly deferred. Recorded in `DECISIONS.md`
2026-08-06.

## 10. Acceptance criteria and sub-slicing

**Split, three sub-slices**, isolating what needs zero decisions from §9
resolved first — same discipline `docs/specs/barnard-binding-conformance.md`
§7 and `docs/specs/session-end-finalization.md` §8 both applied to their
own scope.

### 10.1 Sub-slice 1 — consuming side + reachability fix (§2, §3, §4.2, §5)

Depends on nothing in §9. This is the entire user-visible feature for a
typical user today, since §9.a's recommendation means most real events
won't have a serving device for a while regardless.

- `EventCodeEntryView` reachable from `SensingView` via a new "Enter code
  manually" link, pushed within `ScanFlowView`'s existing `NavigationStack`
  (§2, §3.1 step 4). New test (`EventCodeJoinTests.swift`): the link is
  present and, when tapped, presents `EventCodeEntryView` without
  dismissing `ScanFlowView`'s full-screen cover.
- New `.eventInfoHint` case added to `SensingCoordinator.handle(_:)`
  exactly as shown in §3.3 — no other case's behavior changes. New test
  (`SensingCoordinatorTests.swift`): a synthetic `.eventInfoHint` event
  while `phase == .idle` updates `discoveredEventHints` and leaves `phase`,
  `distinctPeerRpids`, `activeCommit`, `activeProofId`, and `bindingState`
  unchanged (proves the "narrow, additive" claim mechanically, not just by
  code inspection).
- `DiscoveredEventHint` dedup/conflict logic (§5.3): new tests covering
  same-hash-same-name (no-op), same-hash-different-name (sets
  `hasNameConflict`), new-hash-within-cap (appends), and
  `additionalEventsOmitted` (appends the static overflow row, does not
  attempt to parse the empty-marker payload).
- Discovery-only scan lifecycle: `engine.startAuto()` called on
  `SensingView` appearing while `phase == .idle`, without a preceding
  `configure(eventCode:)` call; stopped/superseded cleanly on either
  joining (transitions into the existing real-path `configure`+`startAuto`)
  or the scan sheet closing (`AppCoordinator.finishScan()`, unchanged).
- Cross-check copy (§3.1 step 5, §5.2): new test confirms a successful join
  is identical in outcome (same `SensingCoordinator.joinEvent` return
  value, same phase transition) whether or not a matching/mismatching hint
  was present — the hash comparison affects only display copy, never the
  join's success/failure.
- `beid://join?code=...` deep link (§4.2): new branch in `BeidApp.onOpenURL`,
  alongside the three existing connector calls, routing to
  `AppCoordinator.joinEvent(code:)`. New test covering the two concrete
  cases this spec designs for — link opened while on `EventCodeEntryView`
  or `SensingView`'s idle discovery state (prefills and lets the user
  confirm) — and a documented, deliberately simple fallback for the
  cold-start-before-`beginOnboarding()` and
  already-recording-another-event cases: the code is held (e.g. a new
  `AppCoordinator.pendingJoinCode: String?`) and only auto-navigated to
  `EventCodeEntryView` once onboarding reaches a point where that screen
  would normally be reachable, and is silently ignored (not queued, not
  erroring) if a session is already `.recording` a different event — this
  app's existing "never discard in-progress data" posture
  (`SensingCoordinator.swift:271-272`'s D4 comment) extends naturally here;
  a fuller multi-session UX is out of this spec's scope.
- New/updated localized copy (the hint chip's "unverified" label, the
  manual-entry link, any new `EventCodeEntryView`-adjacent strings) follows
  AGENTS.md's existing localization process — translator `comment:`s where
  meaning isn't self-evident, all five target locales present in
  `Localizable.xcstrings` (`needs_review` acceptable) before this
  sub-slice's PR merges.
- `xcodebuild -project ios/Beid.xcodeproj -scheme Beid -destination
  'platform=iOS Simulator,name=iPhone 17 Pro' clean build` = BUILD
  SUCCEEDED. `scripts/lint.sh` = 0 violations. Xcode Cloud PR CI
  (`BeidTests`) green.

### 10.2 Sub-slice 2 — dogfood serving toggle (§6)

Depends on nothing in §9 (§6 explains why the debug toggle doesn't
prejudge §9.a). Independently reviewable/shippable from 10.1, though
testing 10.1's hint-rendering UI against a *real* B005 payload (rather than
a synthetic test event) needs this sub-slice's device to exist.

- `DEBUG`-only launch argument (e.g. `-beid-serve-event-info`, mirroring
  `-beid-demo-event`'s existing pattern, `SensingCoordinator.swift:120`)
  that calls `engine.configureEventInfoServing(organizerDesignated: true,
  eventActiveForDiscovery: true, eventDisplayName:)` with a fixed test
  event code/name at launch.
- New test confirming this launch argument has zero effect in a
  `Release`-configured build (mirroring
  `SensingCoordinator.swift:123-131`'s existing `useDemoEventMode`
  Release-build no-op guard pattern exactly).
- Manual/on-device verification note (per this repo's convention of naming
  real execution where it grounds a claim, `docs/specs/session-end-finalization.md`
  §8.2's precedent): two physical devices, one launched with
  `-beid-serve-event-info`, the other running Sub-slice 1's discovery UI,
  confirming a real hint round-trips end to end — not a substitute for the
  automated tests above, but worth doing once during implementation review.
- `xcodebuild ... clean build` = BUILD SUCCEEDED. `scripts/lint.sh` = 0
  violations. Xcode Cloud PR CI green.

### 10.3 Sub-slice 3 — event name from a confirmed hint (§7)

Depends on 10.1 (needs `DiscoveredEventHint`/the cross-check machinery to
exist). Does not depend on 10.2 (a real device is convenient for testing
this but any `.eventInfoHint`-shaped test fixture exercises the same code
path). Does not depend on §9 (venue stays out of reach regardless per §7;
this sub-slice only ever touches `EventSession.name`).

- `SensingCoordinator.handleDetection`'s real path populates
  `EventSession.name` from a confirmed hint's `eventDisplayName` when one
  exists for the joined code's hash, falling back to the raw code exactly
  as today when none does. New test: joining a code with a
  hash-matching retained hint produces an `EventSession` whose `name` is
  the hint's display name, not the raw code; joining with no matching hint
  is byte-for-byte unchanged from today's behavior.
- New test confirming `EventSession.venue` remains `nil` on the real path
  unconditionally in this sub-slice — a regression guard specifically
  because §7 states plainly that B005 can never supply it, so a future
  reader shouldn't expect this sub-slice to have quietly added it.
- `xcodebuild ... clean build` = BUILD SUCCEEDED. `scripts/lint.sh` = 0
  violations. Xcode Cloud PR CI green.

## 11. Branch note

Base Sub-slice 1 on `main`; base 2 and 3 on `main` after 1 merges (either
order between 2 and 3, per §10's independence findings) — same
sequential-sub-slice convention `docs/specs/barnard-binding-conformance.md`
§8 and `docs/specs/session-end-finalization.md` §10 both used. No in-flight
branch work targeting this area is known beyond gh#91's concurrent, disjoint
work on `SensingCoordinator`'s session-end paths (§8) — this spec's own
`SensingCoordinator` addition (§3.3) touches none of the same lines and
should not conflict, but should still be rebased onto `main` immediately
before implementation starts to confirm that in practice, not just by
reading, since gh#91 may have merged in the interim.
