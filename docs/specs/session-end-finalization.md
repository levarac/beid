# Spec — Session-end finalization (gh#91)

Status: **APPROVED.** §7 contained one blocking open decision (Gap 2's fix
shape) the PM/user had to resolve before implementation, per this repo's
standing "no code before spec approval" rule. It was resolved by the user
on 2026-08-06, matching this document's own recommendation (Option B —
see §7.1's resolution note). Gap 1's fix (§3) never itself required a
PM/user decision — it is a correctness fix restoring already-decided
behavior — but ships in the same PR family since gh#91 bundles both gaps
under one issue.

Author: Worker `a-20260805-030`, for SubPM `a-20260731-027`.

**Method note**: no product code was written or edited to produce this
document, per this task's explicit instruction. Every claim below is
sourced from one of: `ios/Beid` source read directly this session
(`SensingCoordinator.swift`, `AppCoordinator.swift`, `ScanFlowView.swift`,
`BeidApp.swift`, `Info.plist`/`project.yml`), `BeidTests` read directly
(`SensingCoordinatorTests.swift`, `SelfProofTests.swift`), the pinned
Barnard SDK source at the exact revision beid's `Package.resolved` points
to (`levarac/barnard` `57a8a7df7f4b2078150eabff4c06a46cfb2aae0f`, tag
`0.3.0` — read from the real SwiftPM checkout under Xcode's DerivedData,
not a separate/possibly-drifted clone), `DECISIONS.md`'s actual 2026-07-26
entry (read directly, not from the SubPM's paraphrase), gh#91's actual
issue body (`gh issue view 91`), and web research on Apple's documented
app-lifecycle contract (cited inline in §2.3).

Builds on: `docs/specs/barnard-binding-conformance.md` §2.2 (self-proof
introduction, "when to sign, and where to store it" flagged there as a
non-blocking TBD — this spec is that TBD), §5 (golden-vector testability
discipline, reused not repeated in §8); `docs/specs/scan-slice2-redesign.md`
§4.5 (per-window report signing scope boundary, unaffected here).

Tracks: gh#91 ("セッション終了処理の取りこぼし2件" — two session-end
finalization gaps). Found during gh#88 sub-slice B review; both gaps
predate sub-slice B and are not caused by it (issue body, confirmed by
reading the actual `SensingCoordinator.swift` history implied by the
code — `closeWindow`'s window-transition-only trigger is untouched by any
of #90/#92/#94).

## 1. Scope

**IN**: enumerating every real way a sensing session ends (§2), confirming
what iOS actually guarantees at each (§2.3–§2.4), Gap 1's root cause and
fix mechanics including a `closeWindow` idempotency analysis and a
previously-unflagged scoping bug and a previously-unflagged latent state
bug the naive fix would trigger (§3), Gap 2's background and three fix
options in escalation format (§7.1), whether the two gaps are one fix or
two (§6), and acceptance criteria + sub-slicing (§8).

**OUT**: real (non-demo) BLE signal-loss *detection* — unrelated,
pre-existing gap, `scan-slice2-redesign.md` §11 already tracks it
separately. Any self-proof *consumption*/verifier flow — none exists yet
(confirmed by grep, `barnard-binding-conformance.md` §2.2), out of scope
for a producer-side finalization fix. `stopSensing()`'s complete absence of
call sites in `AppCoordinator`/any view (§2.2) is *reported*, not fixed —
wiring `stopSensing()` to an actual UI entry point is a product/UX
question this spec does not decide.

## 2. The correct session-end lifecycle

### 2.1 Every way a sensing session can end

Read directly from `SensingCoordinator.swift`/`AppCoordinator.swift`, not
assumed:

1. **Explicit user stop via the scan sheet's close (×) button** —
   `ScanFlowView.swift:36-46` → `AppCoordinator.finishScan()`
   (`AppCoordinator.swift:126-129`) → `SensingCoordinator.reset()`. The
   **only** reachable UI path today that ends a session.
2. **`SensingCoordinator.stopSensing()`** (`SensingCoordinator.swift:212`)
   — fully implemented (identical shape to `reset()`, including calling
   `finalizeSelfProofIfNeeded()` before `resetSessionState()`), and
   directly exercised by `BeidTests` (`SelfProofTests.swift:185-226`), but
   **has zero call sites in `AppCoordinator` or any view** (confirmed:
   `grep -rn "stopSensing\b"` across all of `ios/` matches only its own
   definition, its own doc-comment references, and test files). Worth
   stating plainly since the task's framing named `stopSensing`/`reset` as
   "the two the code currently handles" — only one of the two is actually
   reachable from the product today. Not a bug this spec proposes fixing
   (no UI/UX decision is implied), just a fact the finalization fix must
   account for: any fix keyed only to `reset()`'s call site would also
   need to cover `stopSensing()` the moment something does wire it up, so
   this spec's fix (§3) is written at the shared level both already
   converge on (`resetSessionState()`), not duplicated per call site.
3. **App backgrounded while a session is active** — named explicitly in
   the 2026-07-26 decision (§2.2 below quotes it verbatim) as a
   finalization trigger. **Not implemented at all today.**
   `ScanFlowView.swift:12,52-55` is the only `scenePhase` observation
   anywhere in `ios/Beid` (confirmed by grep across the whole tree), and
   it only reacts to the *opposite* transition (`oldPhase != .active,
   newPhase == .active`, i.e. returning to foreground) to decide whether
   to present the binding sheet — it never observes `.background` and
   never calls anything on `SensingCoordinator` when backgrounding occurs.
4. **iOS-initiated background termination** (jetsam: the system killing a
   backgrounded, suspended process to reclaim memory). Real, common, and
   — per §2.3 below — offers the app **zero** execution opportunity by the
   time it happens, so "finalizing on jetsam" is not a real design option;
   the only lever is finalizing *before* jetsam can happen (§2.4).
5. **User force-quit** (swipe-away in the App Switcher). Also offers
   **zero** execution opportunity once initiated (§2.3) — but see §2.4's
   important structural point: on iOS, a foreground app cannot be
   force-quit directly; invoking the App Switcher itself backgrounds the
   app first. This matters for how much of the gap a backgrounding hook
   actually closes.
6. **Starting a new session while one is already active.**
   `startSensing()` (`SensingCoordinator.swift:193-209`) calls
   `resetSessionState()` unconditionally on every call, with no guard for
   "was already recording." Today this is only reachable if
   `AppCoordinator.startScan()` (`AppCoordinator.swift:121-124`) is called
   a second time before `finishScan()` — not reachable through the shipped
   UI (the scan sheet's presentation state gates re-entry), so this is a
   **defensive note, not a bug this spec proposes fixing**: flagged so a
   future caller of `startSensing()` doesn't silently reintroduce a
   real data-loss path outside what §3/§7 cover.
7. **Process crash.** Not a lifecycle transition (no OS signal, no
   callback of any kind is theoretically possible) — mentioned only for
   completeness; identical in effect to jetsam/force-quit from this app's
   perspective (zero execution), so §2.4's "finalize proactively, not
   reactively" conclusion covers this case too without needing separate
   handling.

### 2.2 What's wired today vs. what the decision record requires

`DECISIONS.md`'s 2026-07-26 entry "報告粒度(タイムウィンドウ ENIN 単位・
複数回)とビジュアライザー方針" (read directly, not the SubPM's paraphrase),
key sentence: **"ウィンドウ終了時(またはユーザー停止・バックグラウンド移行時)
に未送信ウィンドウ分だけ報告"** — "At window end (or user-stop, or
background-transition), report only the not-yet-sent windows." Three
named triggers, given equal footing. The same entry also says: **"強制終
了で未送信が残れば次回にまとめて送る"** — "If a force-quit leaves unsent
[windows], send them together next time" — i.e. the decision record itself
already anticipates that an ungraceful kill can leave a gap, and its
answer is *not* "prevent it," but "whatever was durably persisted before
the kill gets flushed on the next opportunity." This is the design
precedent §7.1's recommendation leans on for Gap 2.

Today, only trigger 1 of the three (window-end,
`advanceWindowIfNeeded`/`closeWindow`, `SensingCoordinator.swift:455-484`)
is implemented. User-stop and backgrounding are both named in the
decision and both currently produce **zero** window report for whatever
window was open at that moment — this is Gap 1, restated precisely against
the actual decision text rather than the issue's summary of it.

### 2.3 iOS's actual platform contract (not assumed)

Four claims, each checked rather than taken on faith, per the task's
explicit instruction:

- **`applicationWillTerminate(_:)` is not called for a suspended app that
  the system kills.** Confirmed via Apple Developer Forums threads
  discussing this exact behavior (search, this session): "The system
  doesn't call this method if your app is suspended... there is no system
  notification to the app when it is terminated by system whilst already
  suspended." This delegate method only fires if the app is still
  *running* (not yet suspended) when termination is initiated — moot for
  this app anyway, since **`BeidApp.swift` has no `UIApplicationDelegate`
  or `UIApplicationDelegateAdaptor` at all** (confirmed: the whole file is
  23 lines, a bare SwiftUI `App` with `WindowGroup { RootView() }` and
  `.onOpenURL`). Adding one just to reach a callback that's unreliable for
  exactly the case this spec cares about (a *suspended* app being killed)
  would add real complexity for a hook that doesn't cover the target
  scenario.
- **`beginBackgroundTask(expirationHandler:)` grants a bounded extension**
  (commonly cited at up to ~30 seconds, though Apple's own docs
  deliberately don't guarantee an exact figure, only "a limited amount of
  time," and warn the expiration handler fires with a few seconds of
  margin before hard cutoff) — relevant only for *async* work that
  outlives the synchronous background-transition instant. Not needed here
  (see §2.4 — this app's finalization work is synchronous and local-only).
- **`scenePhase.background`'s own documentation states the phase is a
  precursor to suspension**, not a stable running state — the standard,
  widely-documented guidance is that an app should treat entry into
  `.background` as "do state-saving now," because the system can suspend
  it at any point afterward. This is exactly the moment this app already
  uses for the opposite purpose (`ScanFlowView.swift:52-55`), so a
  finalization hook on the same transition is not introducing a new kind
  of assumption, only extending the one already relied on.
- **A force-quit or jetsam kill from the suspended state gives the app
  literally zero code execution** — no delegate call, no `scenePhase`
  transition, nothing. This is the load-bearing fact for §2.4: there is no
  "handle termination" hook to write, because termination-from-suspension
  is definitionally unobservable by app code. The only lever available is
  front-loading durable work into the transitions that *do* reliably fire
  before suspension.

Sources: [Detect O.S suspend my app.](https://developer.apple.com/forums/thread/99165), [Determine if the App is terminated by the User or by iOS](https://developer.apple.com/forums/thread/97582), [How iOS Suspends and Wakes Apps: Understanding the App Lifecycle](https://mohsinkhan845.medium.com/how-ios-suspends-and-wakes-apps-understanding-the-app-lifecycle-af56bc763f27), [UIApplication Background Task Notes](https://developer.apple.com/forums/thread/85066), [Background Execution on iOS](https://www.andyibanez.com/posts/background-execution-in-ios/), [Understanding the iOS 13 Scene Delegate](https://www.donnywals.com/understanding-the-ios-13-scene-delegate/).

### 2.4 What this app can realistically use, and one structural fact worth stating plainly

**This app already declares `bluetooth-central` + `bluetooth-peripheral`
background modes** (`ios/Beid/App/Info.plist`, confirmed directly:
`UIBackgroundModes = [bluetooth-central, bluetooth-peripheral]`; same
declared in `project.yml:66-68`). This is a materially different starting
point than a generic app with no background capability: it means
**backgrounding is not necessarily session-ending** for this app —
CoreBluetooth scanning/advertising can legitimately continue after
`.background`, subject to iOS's usual reduced-rate background BLE
behavior. This directly shapes §3's fix: a backgrounding hook must not be
written as "end the session," only as "checkpoint what's observed so
far," because sensing itself may still be running.

**Structural fact**: a user cannot force-quit an app that is still in the
foreground. Invoking the App Switcher (the only UI path to swipe an app
away) itself transitions the target app out of the active state as part of
presenting the switcher — this is standard, well-established iOS
multitasking behavior (every app snapshot the switcher shows is, by
construction, an app that has already left the foreground). Combined with
`scenePhase.background` firing reliably and synchronously on that same
transition, this means: **a `.background`-triggered checkpoint, if made
durable before the transition completes, is reached before any
force-quit reaches the app** — a force-quit cannot happen to a still-active
app. It *can* still happen to an app that backgrounded, checkpointed, and
was then killed later while suspended — but by then the checkpoint has
already run. The residual gap that a backgrounding checkpoint does **not**
close is a kill that happens while the app is still *foreground/active*
(rare but real — extreme system memory pressure can jetsam a foreground
app too) or a kill that races the checkpoint's own synchronous write
before it completes (vanishingly unlikely given the work is local,
synchronous, and small — see §3).

**Recommended finalization points, given the above**: (a) the existing
explicit-stop call sites (`stopSensing()`/`reset()`, already correctly
positioned before `resetSessionState()` for self-proof, extended in §3 to
also close the final window); (b) the `scenePhase == .background`
transition, as a **checkpoint**, not a session-end, extending
`ScanFlowView`'s already-existing `scenePhase` observation rather than
adding a second, independent observer (avoids a duplicate-firing risk with
no offsetting benefit — see §3.6). No `UIApplicationDelegateAdaptor`,
`sceneDidDisconnect`, or `beginBackgroundTask` is recommended — none of
them cover a case (a) and (b) don't already cover, and each adds real
complexity (a new delegate bridge into a pure-SwiftUI-lifecycle app) for
that zero marginal coverage.

## 3. Gap 1: analysis and fix

### 3.1 `closeWindow`'s idempotency — read directly, not assumed

```swift
private func closeWindow(enin: Int, eventCode: String) {
  guard let commit = activeCommit else { return }
  let payload = windowReportPayload(eventCode: eventCode, enin: enin, peerRpids: currentWindowRpids, commit: commit)
  let signature = identity.sign(eventCode: eventCode, bytes: payload)
  let report = WindowReport(eventCode: eventCode, enin: enin, peerCount: currentWindowRpids.count, commit: commit, signature: signature)
  windowReportStore.add(report)
}
```

(`SensingCoordinator.swift:472-484`.) **Not idempotent on its own** — no
guard against being called twice for the same `enin`; two calls append two
`WindowReport`s to `windowReportStore` (an `add`-only accumulator,
`WindowReportStore.swift:24-27`, no dedup). Today's safety is entirely
caller discipline: the only caller, `advanceWindowIfNeeded`
(`SensingCoordinator.swift:455-465`), calls it exactly once per real
window-boundary crossing (`guard openEnin != enin else { return }` before
calling), then immediately rotates `currentWindowEnin`/`currentWindowRpids`
so the same boundary can't be closed twice. §3.6 below verifies this
discipline is preserved once new call sites are added.

### 3.2 A scoping asymmetry the fix must respect

`closeWindow` is driven by BLE peer observations and gated only on
`activeCommit` (fixed as early as `beginEventFound`,
`SensingCoordinator.swift:286-293`) — it has **no dependency on reaching
the peer-confirm threshold**. `finalizeSelfProofIfNeeded`
(`SensingCoordinator.swift:517-554`), by contrast, is gated on
`activeProofId` — set only in `beginRecording`
(`SensingCoordinator.swift:299-306`), i.e. only once `.recording` begins.
`currentBindingEvent` (`SensingCoordinator.swift:325-332`), the existing
helper `finalizeSelfProofIfNeeded` uses to get an `eventCode`, only covers
`.recording`/`.signalLost` — correct for self-proof (no `Proof` exists
before `.recording`, so there is nothing to attest), but **wrong for
window-close**: a session that detects 1-2 peers during `.eventFound`
(below the confirm threshold, never reaching `.recording`) still opens a
real window with real `currentWindowRpids`, and that window deserves its
own report on user-stop exactly like any other — nothing in the
2026-07-26 decision or in `closeWindow`'s own mechanics ties window
reports to the confirm threshold. Using `currentBindingEvent` for the
window-close fix would silently under-report exactly the shortest, most
threshold-adjacent sessions — the case gh#91 calls out as "most affected."

**Fix**: introduce a broader accessor covering `.eventFound` too:

```swift
private var currentSessionEventCode: String? {
  switch phase {
  case .eventFound(let s), .recording(let s, _), .signalLost(let s, _): return s.id
  case .idle, .sensing: return nil
  }
}
```

Window-close uses this; self-proof continues using `currentBindingEvent`
unchanged (its narrower scope is correct, not a bug).

### 3.3 Fix mechanics: explicit stop

```swift
private func closeFinalWindowIfNeeded() {
  guard let enin = currentWindowEnin, let eventCode = currentSessionEventCode else { return }
  closeWindow(enin: enin, eventCode: eventCode)
}
```

Called from both `stopSensing()` and `reset()`, before
`resetSessionState()` — mirroring exactly where `finalizeSelfProofIfNeeded()`
already sits in both functions (read state before `resetSessionState()`
clears it). Order relative to `finalizeSelfProofIfNeeded()` doesn't matter
(neither reads the other's output), but closing the window first is the
more natural reading (self-proof is conceptually layered above window
data, not the reverse).

### 3.4 Fix mechanics: backgrounding checkpoint (not session-end)

Per §2.4, this must **not** call `resetSessionState()` or touch `phase` —
sensing may continue in the background. A new method:

```swift
func checkpointOpenWindowForBackgrounding() {
  guard let enin = currentWindowEnin, let eventCode = currentSessionEventCode else { return }
  closeWindow(enin: enin, eventCode: eventCode)
  currentWindowRpids = []
  currentWindowEnin = nil
}
```

Wired from `ScanFlowView`'s existing `scenePhase` observer:

```swift
.onChange(of: scenePhase) { oldPhase, newPhase in
  guard oldPhase != .active, newPhase == .active else {
    if newPhase == .background { sensing.checkpointOpenWindowForBackgrounding() }
    return
  }
  presentBindingSheetIfNeeded()
}
```

(Illustrative shape — exact `onChange` structuring is an implementation
detail, not a design decision.) Extending the existing observer rather
than adding a second one avoids two independent `.onChange(of: scenePhase)`
handlers racing on the same transition — no functional need for two, and
one is simpler to reason about.

**Non-blocking implementation note**: this couples finalization to
`ScanFlowView` being mounted, which today is always true while a session
is active (`AppCoordinator.startScan()`/`finishScan()` toggle
`scanPresented` and `startSensing()`/`reset()` together,
`AppCoordinator.swift:121-129`) — not a design flaw today, but if a future
change ever lets sensing run without the scan sheet open, this hook would
need to move to `AppCoordinator`/`BeidApp` root-level `scenePhase`
observation instead. Flagged so it isn't silently forgotten, not treated
as blocking now.

### 3.5 A latent bug the naive version of this fix would trigger

`advanceWindowIfNeeded`:

```swift
private func advanceWindowIfNeeded(enin: Int, eventCode: String) {
  guard let openEnin = currentWindowEnin else {
    currentWindowEnin = enin
    firstWindowEnin = enin        // unconditional
    return
  }
  ...
}
```

(`SensingCoordinator.swift:455-465`.) `firstWindowEnin`'s doc comment
(`SensingCoordinator.swift:67-71`) claims it is "set once... and not
touched again until the next session" — true **today** only because
nothing currently nils `currentWindowEnin` mid-session; the nil-branch
above is only ever reached once per session (right after
`resetSessionState()`). §3.4's checkpoint deliberately nils
`currentWindowEnin` mid-session (so the next detection starts a fresh
window rather than silently reusing the just-closed `enin`) — the moment
it does, the *next* detection would re-enter this nil-branch and
**overwrite `firstWindowEnin`** to the post-checkpoint value, corrupting
the self-proof's `eninStart` (silently narrowing it to "since the last
backgrounding," not "since the session began").

**Required companion fix**, one line:

```swift
guard let openEnin = currentWindowEnin else {
  currentWindowEnin = enin
  if firstWindowEnin == nil { firstWindowEnin = enin }
  return
}
```

Cheap, low-risk, and a prerequisite for §3.4's checkpoint design being
safe — called out explicitly rather than left for whoever implements this
to discover by a failing/wrong self-proof later.

### 3.6 Double-finalization safety, traced through concretely

The task asked what happens if finalization runs twice for the same
session (e.g. a background-checkpoint immediately followed by an explicit
stop in the same teardown). Traced through with the design above:

- **`stopSensing()`/`reset()` called twice in a row**: the first call's
  `resetSessionState()` (`SensingCoordinator.swift:263-274`) nils
  `currentWindowEnin`; the second call's `closeFinalWindowIfNeeded()` guard
  fails immediately — no duplicate report. This is the *existing*,
  already-tested pattern (`SelfProofTests.swift:219-226`,
  `testResetAfterASelfProofIsProducedDoesNotProduceASecondOne`, calling
  `stopSensing()` then `reset()` and asserting the second is a no-op) —
  §3.3's fix is written to compose with it identically, not introduce a
  new idempotency mechanism.
- **A backgrounding checkpoint immediately followed by an explicit stop**:
  this is exactly why §3.4's checkpoint nils `currentWindowEnin`
  (`= nil`) rather than leaving it unchanged. If it left `currentWindowEnin`
  set, a following `stopSensing()` would re-close the *same* `enin` a
  second time — with `currentWindowRpids` already cleared by the
  checkpoint, producing a spurious `peerCount: 0` duplicate report for an
  `enin` already reported. Nil-ing it makes the follow-up stop's guard
  fail the same way the double-`resetSessionState()` case above does — one
  design (guard-on-nil) covers both risk scenarios, not two separate
  idempotency mechanisms bolted on independently.
- **Recommended new test**: call `checkpointOpenWindowForBackgrounding()`
  then `stopSensing()` in the same test and assert
  `windowReportStore.reports.count` grew by exactly one, not two —
  extends `SelfProofTests.swift`'s existing pattern to the new method.

### 3.7 Short / no-window-boundary-crossed sessions

Per §2.2's decision text ("ウィンドウ観測塊 : 報告 = 基本1対1" — a
window-observed-chunk maps ~1:1 to a report), a session that never crosses
a window boundary but did observe at least one peer still has a real,
if single, window-observed-chunk (`currentWindowEnin` set,
`currentWindowRpids` non-empty — guaranteed non-empty whenever
`currentWindowEnin` is set, since `observe()` inserts the triggering
detection's `rpid` immediately after `advanceWindowIfNeeded` returns,
`SensingCoordinator.swift:163-166`). §3.3's fix means this chunk **is**
now reported on user-stop — resolving exactly the "極端な場合(ウィンドウ
を1つも跨がずに終了)は報告が丸ごとゼロになります" case gh#91's own body
names. A session that never observed *any* peer (`currentWindowEnin` still
`nil`) correctly produces nothing — there is no chunk to report, matching
`finalizeSelfProofIfNeeded`'s own existing "nothing observed → nil" answer
(`SelfProofTests.swift:185-187`).

## 4. Gap 2: precise restatement

Self-proof (`finalizeSelfProofIfNeeded`, `SensingCoordinator.swift:517-554`)
is signed **only** at session end, because `eninEnd` cannot be known
earlier — this is inherent to the self-proof design (`barnard-binding-
conformance.md` §2.2 already named this as a non-blocking TBD when
sub-slice B shipped), not a coding mistake in gh#88 sub-slice B.
`BindingRecord`, by contrast, is persisted the instant `completeBinding()`
succeeds (`SensingCoordinator.swift:399-429`), mid-session. A device kill
(force-quit or jetsam) after a binding completes but before session end —
per §2.3, offering the app no execution opportunity — leaves a
`BindingRecord` with no matching `SelfProofRecord`, permanently: `eninStart`/
`eninEnd` exist only in the coordinator's in-memory session state
(`currentWindowEnin`/`firstWindowEnin`, both cleared by
`resetSessionState()` and never durably written anywhere before session
end today) and cannot be reconstructed after the fact, while
`eventIdHash`/`eventSigningPublicKey` remain derivable from `eventCode`
alone at any time (`EventIdHash.compute`, `identity.signingPublicKey(eventCode:)`
— both pure functions of already-persisted inputs). No verifier/
presentation flow consumes self-proofs yet, so today's damage is one
missing record in a store nobody reads — gh#91's own body calls this a
"time bomb" for whoever builds that flow later, not a live break.

## 5. What must not change

- **`windowReportPayload`'s byte layout** (`SensingCoordinator.swift:486-494`)
  — unaffected. §3's fix changes *when* `closeWindow` is called, never
  what it signs.
- **`EventCommitment`** — unaffected; `activeCommit` is fixed at
  `beginEventFound` regardless of this spec.
- **The self-proof message format** (`barnard-self-proof:v1`, 135 bytes,
  `BarnardCoreSigning.buildSelfProofMessage`) — unaffected by Gap 1's fix.
  §7.1 confirms it is also unaffected by Gap 2's recommended fix (option
  B does not change what gets signed, only when and from what stored
  inputs); option C, if chosen instead, would change the *value*
  `eninEnd` holds for every session, not the wire format — called out
  explicitly in §7.1 rather than left implicit.
- **`SelfProofRecord`'s `Codable` shape** — unaffected by Gap 1. Gap 2's
  recommended fix (§7.1) does not add fields to it either; the new
  intermediate state it needs lives in a separate, new, small on-device
  file (§7.1), not on `SelfProofRecord` itself.

## 6. Are Gap 1 and Gap 2 one fix or two?

**Related, but not tightly coupled beyond one shared refactor — recommend
fixing both under gh#91 as ordered sub-slices, not a single change.**

Both gaps sit in the same "session-end finalization" family and the same
file, and gh#91 already bundles them under one issue with the same root
observation (`eninEnd`/window-close both depend on state that today only
exists transiently). Concretely:

- §3.2's `currentSessionEventCode` and the `closeFinalWindowIfNeeded()`/
  `checkpointOpenWindowForBackgrounding()` split are Gap 1's own fix and
  do not depend on Gap 2's resolution at all.
- **If Gap 2 is fixed via option A** (§7.1 — finalize self-proof at every
  plausible session-end point including backgrounding), it would
  literally reuse §3.4's backgrounding hook as its trigger — Gap 1's
  backgrounding-checkpoint sub-slice would become a hard prerequisite,
  not just a spiritual sibling.
- **If Gap 2 is fixed via option B** (§7.1's recommendation — incremental
  persistence, reconciled on next launch), it piggybacks on
  `advanceWindowIfNeeded`'s *existing* real window-rotation points, not on
  the new backgrounding hook at all — making it independent of Gap 1's
  backgrounding sub-slice (§3.4), buildable/reviewable in either order
  relative to it, only sharing Gap 1's lowest-risk explicit-stop sub-slice
  (§3.3) as common ground (both read `currentWindowEnin`/`firstWindowEnin`
  at the same points).

Since §7.1 recommends option B, the practical answer is: **Gap 1's
explicit-stop fix (§3.3, §3.5) first — lowest risk, unlocks both of the
following — then Gap 1's backgrounding checkpoint (§3.4) and Gap 2's fix
(§7.1) can proceed in either order or in parallel**, not strictly
sequential the way they would be under option A. This dependency shape is
itself one of the reasons §7.1 recommends B over A (fewer forced
sequencing constraints, more independently reviewable/shippable pieces) —
stated once here and referenced from §7.1 rather than duplicated.

## 7. Open decisions (blocking approval)

### 7.1 Gap 2's fix shape

**Background**: per §4, the missing input is `eninStart`/`eninEnd` — both
exist only in `SensingCoordinator`'s in-memory session state until
`finalizeSelfProofIfNeeded()` runs at session end, and per §2.3 a kill
from the suspended state gives the app zero opportunity to run that
function reactively. Three shapes, per the task's framing, evaluated with
real tradeoffs rather than a single pick presented as obvious.

**Option A — finalize self-proof at every plausible session-end point,
including the §3.4 backgrounding checkpoint.**

- *Mechanics*: call a self-proof-producing step from the same
  `scenePhase == .background` hook Gap 1 adds, using whatever
  `currentWindowEnin` holds at that instant as a provisional `eninEnd`.
- *For*: reuses infrastructure Gap 1 is already adding (§6); per §2.4's
  structural point (a foreground app cannot be force-quit directly), this
  actually closes the force-quit case more completely than the task's own
  framing suggested — since App Switcher invocation itself backgrounds
  the app first, a backgrounding checkpoint runs *before* any
  user-initiated force-quit can reach the app, not merely "before some"
  force-quits.
- *Against — real, not dismissed*: `SelfProofStore` is currently
  **append-only** (`SelfProofStore.swift:25-27`, `add()` only, no
  update/replace) — producing a self-proof at every backgrounding
  checkpoint and *again* at eventual true session end means either (a)
  accumulating multiple, superseding `SelfProofRecord`s per `proofId`
  (pushes complexity onto a future verifier that doesn't exist yet, and
  which per `barnard-binding-conformance.md` §2.2 shouldn't need to guess
  which of several records for one `proofId` is authoritative), or (b)
  changing the store to upsert-by-`proofId` (a real, non-trivial change to
  an already-shipped, tested store). Either way, this **invalidates an
  existing shipped test's stated invariant**:
  `SensingCoordinatorSelfProofTests.testSelfProofIsProducedOnlyWhenSessionEndsAfterRecordingBegan`
  (`SelfProofTests.swift:190-217`) asserts self-proof is produced "only
  when session ends" — under option A that becomes false by design (it
  would also be produced at every backgrounding checkpoint), requiring
  that test's premise to be revised, not just extended. Residual gap
  option A still doesn't close: a kill while the app is genuinely
  foreground/active (rare, but real under extreme memory pressure) — a
  backgrounding checkpoint that never gets to run because the app never
  transitioned through `.background` before being killed.

**Option B — persist `eninStart`/`eninEnd` incrementally, reconstruct on
next launch. Recommended.**

- *Mechanics*: a new small on-device JSON file (same pattern as
  `WindowReportStore`/`SelfProofStore`/`BindingRecordStore` — flat,
  atomic, on-device only), holding one in-progress checkpoint
  (`proofId`, `eventCode`, `eninStart`, `eninEnd`), **written on every real
  window rotation** — i.e. from inside `advanceWindowIfNeeded`
  (`SensingCoordinator.swift:455-465`), a point that *already* fires
  during normal sensing regardless of foreground/background state (§2.4 —
  BLE background modes are declared, so rotation continues while
  backgrounded), needing **no new lifecycle hook of its own**. On next
  cold launch, a new reconciliation step checks: does a checkpoint file
  exist whose `proofId` has no matching record in `SelfProofStore`? If so,
  sign and persist the missing `SelfProofRecord` from the checkpoint's
  last-known `eninStart`/`eninEnd` (both `identity.signingPublicKey(eventCode:)`
  and the owner key remain derivable/available at next-launch time — both
  are persisted independently of session state, confirmed in
  `barnard-binding-conformance.md` §2.1), then clear the checkpoint.
- *For*: **does not depend on any lifecycle callback firing at all** — the
  strongest guarantee of the three options, since it closes option A's one
  residual gap (a kill while genuinely foreground/active) for free: the
  last window-rotation write already reached disk before the kill,
  regardless of whether any termination-adjacent code ever got to run.
  Directly extends a pattern `DECISIONS.md`'s own 2026-07-26 entry already
  established for the sibling window-report data ("強制終了で未送信が残
  れば次回にまとめて送る" — flush what's pending on the next opportunity,
  §2.2) rather than inventing a new philosophy. Matches gh#91's own body,
  which independently proposed exactly this shape ("ウィンドウの逐次確定
  ... self-proof も中間状態を持てるようになるため2の緩和にもつながる可能
  性があります"). Reuses the *existing*, already golden-vector-tested
  `signSelfProof`/`buildSelfProofMessage` call unchanged (§8) — no new
  signed-byte format, only a new caller and new inputs sourced from disk
  instead of live session state. Independent of Gap 1's backgrounding
  sub-slice (§6) — no forced sequencing.
- *Against — real, not dismissed*: requires a genuinely new app capability
  with no existing precedent in this codebase — "detect and finish an
  abandoned session on cold launch." `WindowReportStore`/`SelfProofStore`'s
  `load()` (read persisted state at `init`) is a partial precedent, but
  the reconciliation *logic* (compare checkpoint against store, sign,
  clear) is new code, not a reuse of an existing shape. Adds one more
  small on-device store to the four that already exist
  (`ProofStore`/`WindowReportStore`/`SelfProofStore`/`BindingRecordStore`).
  If the user never relaunches the app after the kill, the gap stays open
  indefinitely (same acknowledged limitation `DECISIONS.md` already
  accepted for window reports — not a new weakness this option
  introduces).

**Option C — produce self-proof at the moment binding completes, mirroring
`BindingRecord`'s own timing.**

- *Mechanics*: move the `signSelfProof` call from `stopSensing()`/`reset()`
  into `completeBinding()` (`SensingCoordinator.swift:399-429`), using
  whatever `eninEnd` is known as of that instant.
- *Barnard-conformance check, not assumed*: read directly from the pinned
  spec (`levarac/barnard` `57a8a7df7...`, `specs/092-owner-key/spec.md:150,154`):
  "`eninStart` MUST be less than or equal to `eninEnd`... The self-proof
  binds control of the owner key to the named event signing key **for the
  stated ENIN range**." No normative text requires the stated range to
  equal the full session — a self-proof is a truthful attestation over
  whatever range is given it. **Option C is Barnard-conformant at the
  byte/protocol level.** The cost is semantic, not a spec violation: it
  changes what `eninEnd` *means* for every session (not just crashed
  ones) from "the full observed range" to "the range observed as of the
  binding moment" — silently under-representing any peer observation that
  happens *after* binding completes, for every session, to hedge against
  a risk (§4) that today only threatens sessions that both bind and then
  crash before the (still separately-needed) session-end path runs.
- *For*: simplest one-line-relocation mechanically; needs no new store, no
  new lifecycle hook.
- *Against*: pays a real, permanent completeness cost on every session to
  address a risk that only materializes on the intersection of "bound"
  and "then killed ungracefully" — the wrong trade when option B closes
  the same risk without narrowing what a self-proof asserts for anyone.
  Also does not by itself solve Gap 1's "session that never crosses a
  window boundary" case the way B's incremental-write point does — B's
  per-rotation write and Gap 1's per-rotation `closeWindow` call are the
  same kind of fix applied to sibling data; C is a one-off timing move
  specific to self-proof alone.

**Recommendation: Option B.** It provides the strongest actual guarantee
(covers the case A structurally cannot — a kill while foreground/active),
costs no completeness for any session (unlike C), doesn't force a
sequencing dependency on Gap 1's backgrounding sub-slice (unlike A, per
§6), and extends a design pattern (`DECISIONS.md` 2026-07-26,
"flush what's pending next time") this codebase has already committed to
for the sibling window-report data rather than introducing a new one. Its
real cost — a new reconciliation code path with no exact precedent in this
codebase — is accepted as the correct price for closing the gap
structurally rather than reactively.

**RESOLVED (user, 2026-08-06)**: Option B — persist `eninStart`/`eninEnd`
incrementally and reconstruct on next launch — matching this section's
recommendation exactly. Implementation proceeds as sub-slice 3 (§8.3).

## 8. Acceptance criteria and sub-slicing

**Split, three sub-slices**, matching the discipline
`barnard-binding-conformance.md` §7 and `scan-slice2-redesign.md` §10
both applied to their own scope: isolate lowest-risk first, respect the
real dependency shape from §6 rather than an assumed linear one.

### 8.1 Sub-slice 1 — explicit-stop window close (§3.3, §3.5)

Lowest risk: no new lifecycle wiring, mirrors an already-shipped,
already-tested pattern (self-proof's own `stopSensing()`/`reset()`
placement) exactly. Unblocks 2 and 3.

- `currentSessionEventCode` (§3.2) added; `closeFinalWindowIfNeeded()`
  called from both `stopSensing()` and `reset()` before
  `resetSessionState()`.
- `firstWindowEnin`'s guard fixed (§3.5) — one-line, bundled here since
  it's a prerequisite for sub-slice 2's checkpoint being safe, and cheap
  enough not to warrant its own sub-slice.
- New test: a session that observes ≥1 peer but never crosses a window
  boundary, then `reset()`, produces exactly one `WindowReport`
  (§3.7 — the case gh#91's own body names as "most affected").
  New test: the same for a session during `.eventFound` only (never
  reaches `.recording`) — proves §3.2's scoping fix, not just §3.3's
  wiring.
- New test: `checkpointOpenWindowForBackgrounding()` is unreachable in
  this sub-slice (added in 8.2) — not a criterion here, noted only so
  reviewers don't expect it yet.
- `xcodebuild -project ios/Beid.xcodeproj -scheme Beid -destination
  'platform=iOS Simulator,name=iPhone 17 Pro' clean build` = BUILD
  SUCCEEDED. `scripts/lint.sh` = 0 violations. Xcode Cloud PR CI
  (`BeidTests`) green — per §9's simulator-status note, this is the actual
  gate regardless of local availability.

### 8.2 Sub-slice 2 — backgrounding checkpoint (§3.4, §3.6)

Depends on 8.1 (`currentSessionEventCode`, the fixed `firstWindowEnin`
guard). New app-lifecycle wiring — the highest-risk piece of Gap 1's fix,
though still narrow (one new method, one extended existing `onChange`).

- `SensingCoordinator.checkpointOpenWindowForBackgrounding()` added;
  `ScanFlowView`'s existing `scenePhase` observer extended to call it on
  `newPhase == .background` (§3.4).
- Regression test per §3.6: checkpoint immediately followed by an
  explicit stop produces exactly one `WindowReport` for the checkpointed
  window, not two.
- Test: after a checkpoint, phase/`bindingState`/`distinctPeerRpids`/
  `activeProofId` are unchanged (checkpoint is not a session-end) — only
  `currentWindowRpids`/`currentWindowEnin` reset.
- Manual/on-device verification note (not a substitute for the automated
  tests above, but named per this task's instruction to plan real
  execution where it grounds a claim): backgrounding a live demo-mode
  session on-device or via `xcrun simctl` and confirming
  `window-reports.json`'s entry count increases on backgrounding, without
  the session ending, is worth doing once during implementation review —
  simulator availability confirmed working this session (§9), so this is
  not blocked by environment.
- `xcodebuild ... clean build` = BUILD SUCCEEDED. `scripts/lint.sh` = 0
  violations. Xcode Cloud PR CI green.

### 8.3 Sub-slice 3 — Gap 2 fix (§7.1 option B)

Depends on 8.1 (same window-rotation point the incremental write piggybacks
on). **Does not depend on 8.2** (§6) — reviewable/shippable independently
of it.

- New on-device checkpoint store (flat JSON, same pattern as
  `WindowReportStore`/`SelfProofStore`), written from
  `advanceWindowIfNeeded`'s real window-rotation point with the current
  `proofId`/`eventCode`/`eninStart`/`eninEnd`; cleared once
  `finalizeSelfProofIfNeeded()` succeeds through the normal session-end
  path (avoids a stale checkpoint being reconciled after a graceful end
  already produced the real record).
- New reconciliation step run once at startup (`AppCoordinator`/
  `SensingCoordinator` init path): if a checkpoint exists with no matching
  `SelfProofStore` record for its `proofId`, sign and persist one, then
  clear the checkpoint.
- **Golden-vector discipline, per `barnard-binding-conformance.md` §5,
  applied precisely rather than reflexively re-run**: the signing call
  itself (`OwnerKeyProvider.signSelfProof`/`BarnardCoreSigning
  .buildSelfProofMessage`) is unchanged and already golden-vector-tested
  (`SelfProofMessageLayoutTests`, `OwnerKeyProviderSelfProofTests` —
  `SelfProofTests.swift:38-150`) — those do not need re-creating. What
  needs a **new** test is the reconciliation *path* itself: given a
  checkpoint file with known `eninStart`/`eninEnd`, reconciliation
  produces a `SelfProofRecord` whose signature verifies via Barnard's own
  `BarnardCoreSigning.verifySelfProof` (the same pattern
  `OwnerKeyProviderSelfProofTests.testSignSelfProofProducesABarnardVerifiableSignature`
  already establishes, §5's "verifier is Barnard's own implementation, not
  beid's re-derivation" rule — exercised through the new reconciliation
  call site instead of the direct `stopSensing()` path).
- Test: reconciliation is a no-op when no checkpoint exists, and a no-op
  when a checkpoint exists but a matching `SelfProofStore` record already
  does too (graceful end already handled it — no duplicate).
- `xcodebuild ... clean build` = BUILD SUCCEEDED. `scripts/lint.sh` = 0
  violations. Xcode Cloud PR CI green.

## 9. Simulator status (as verified this session)

`xcrun simctl list devices available` was run directly at the start of
this task and returned 11 available, Shutdown (not broken) simulators
(iPhone 17 Pro, iPhone 17 Pro Max, iPhone 17e, iPhone Air, iPhone 17, and
six iPad models, iOS 26.4) — confirming the CoreSimulator external-volume
issue that affected most of this project's recent history remains fixed
as of 2026-08-04. This task did not itself need to execute anything (a
spec, not code), so this note only grounds §8's testability claims and
§8.2's manual-verification suggestion, both of which assume a working
simulator is available to whoever implements this spec.

## 10. Branch note

Base sub-slice 1 on `main`; base 2 and 3 on `main` after 1 merges (either
order between 2 and 3, per §6/§8's independence finding) — same
sequential-sub-slice convention `barnard-binding-conformance.md` §8 and
`scan-slice2-redesign.md` §12 both used. No in-flight branch work is known
to conflict with `SensingCoordinator.swift`/`ScanFlowView.swift` as of
this session.
