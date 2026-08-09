# Spec — Move ledger-family I/O off the main actor (gh#134)

Status: **Decisions 1 and 2 (§4, §5) are APPROVED — implementation may
proceed for those.** Decision 3 (§6) is **NOT approved as originally
recommended; the PM's ruling instead keeps Option 1 (status quo), deferred
with a stated revisit condition** — §6 records the ruling in full. This
document's other sections (§7 acceptance criteria, §8 both-OS note, §9
sequencing note) have been revised to match the Decision 3 ruling; §4 and §5
are unchanged from the original draft. Per this repo's standing "no code
before spec approval" rule (`DECISIONS.md` 2026-08-03 "コード先行禁止"), no
product code has been written or edited to produce this document or this
revision.

Author: Worker `a-20260809-023`, for SubPM `a-20260809-001`. Revised by
Worker `a-20260809-024` per the PM's Decision 3 ruling.

**Method note**: every claim about current code below is sourced from
reading the actual file at the cited line numbers this session, in the
`issue-134-main-thread-io` worktree after `git fetch origin` (the worktree
was already up to date with `origin/main` at `7b618be`, which includes
#131/#132/#133 — all three touch `SensingCoordinator.swift`'s init region
or the persistence stores this document covers). Where gh#134's own cited
line numbers (`SensingCoordinator.swift:141-160`, `:191-194`, `:695-698`)
no longer match, this document cites the current lines instead and says so
explicitly rather than repeating stale numbers as fact — the file has grown
substantially since the issue was filed. This document also reads PR #179
(`issue-91-selfproof-recovery`, open, **not yet merged** as of this
session), because it adds a fourth store to the same init path with the
same synchronous-I/O shape; its diff is read directly via `gh pr diff 179`,
not assumed from its title. Sources: `ios/Beid/Sensing/SensingCoordinator.swift`,
`ios/Beid/Persistence/WindowReportStore.swift`,
`ios/Beid/Persistence/UnsentWindowLedgerStore.swift`,
`ios/Beid/Persistence/UnsentWindowLedgerRuntime.swift`,
`ios/Beid/Navigation/AppCoordinator.swift`, `ios/Beid/App/BeidApp.swift`,
`shared/src/commonMain/kotlin/org/levarac/beid/shared/report/UnsentWindowLedgerSnapshot.kt`,
`android/app/src/main/kotlin/org/levarac/beid/persistence/UnsentWindowLedgerStore.kt`,
`gh issue view 134/132/133/136` (read directly), PR #179's diff (read
directly), `AGENTS.md`, `docs/kmp-shared-foundation.md`, `DECISIONS.md`
(read in full).

Builds on: `docs/specs/session-end-finalization.md` §3–§4 (the
`closeWindow`/`checkpointOpenWindowForBackgrounding` call shapes this
document's Decision 2 reads against, unchanged here);
`docs/specs/ledger-open-failure-recovery.md` §5 (this repo's own prior
instance of choosing "durable data survives, format stays as-is" over a
format change, reused as direct precedent in Decision 2 below, not
repeated); `docs/kmp-shared-foundation.md` §1 (family classification: the
ledger snapshot codec is `shared/`-owned — load-bearing for Decision 3's
both-OS framing).

Tracks: gh#134 (`起動時とウィンドウ確定時に、メインスレッドで同期的にファイル
入出力をしている` — synchronous main-thread file I/O at startup and at every
window close).

## 0. Why this is a spec, not a direct fix

Each of the issue's three named directions is a real design choice with a
genuine for/against, not a mechanical refactor — moving startup load off the
main actor requires deciding what happens to a detection that arrives before
load finishes; changing the close-time write format is a persistence-format
decision; narrowing the canonicity check changes what a shared invariant
guarantees. This repo has already paid for treating a change in this exact
file as lower-risk than it was. `AGENTS.md`'s "Local and CI evidence traps"
section records it, quoted verbatim rather than paraphrased so the next
reader does not have to go find it:

> **Run the full covering suite for any file you modified. Target individual
> tests only when you did not modify the code beneath them.** A metered CI
> lane is a reason to iterate locally and batch pushes; it is not a reason
> to narrow regression coverage over changed code. During the ledger slice,
> targeted tests were selected under budget pressure even though the native
> coordinator had changed. Existing tests covered the resulting App Review
> demo regression and duplicate durable records, but review found them later
> because that suite was not run at the implementation gate.
>
> **A cost constraint quietly rewrote a correctness practice, and it looked
> reasonable at the time.**

This document's §7 acceptance criteria apply that lesson directly: the full
covering suite for every file this fix touches, not a targeted subset,
regardless of how narrow the actual code delta looks once the design is
chosen.

## 1. Scope

**IN**: what happens to a BLE detection that arrives before an async ledger
load resolves (§4 — the design question the SubPM's task framing calls "the
one that matters most"); whether `closeWindow`'s per-window full-array
rewrite should change format and/or move off the main actor (§5); whether
the shared canonicity re-encode-and-compare check needs to run on every
ledger persist, not just at load — evaluated in §6 and **deferred**, not
decided now (the PM's ruling keeps status quo; §6 records the analysis and a
revisit condition rather than making an active decision this document
implements); acceptance criteria restating gh#134's own two plus this
document's additions (§7); both-OS note (§8); a sequencing note for PR #179's
interaction with this fix, now resolved by #179's merge (§9).

**OUT**: the unsent-window ledger snapshot's wire format
(`encodeUnsentWindowLedgerSnapshot`'s byte layout) — per
`docs/kmp-shared-foundation.md` §1, "ledger snapshot codec" is a `shared/`
family already fixed; none of the options below change what gets encoded,
only when/how often decode's self-check runs and where native I/O executes.
`fsync` behavior — #133 (merged, `864d582`) just decided this; nothing here
touches `defaultSynchronizeStagedFile` on either store.
`WindowReportPayload`'s byte layout or the signer boundary — unaffected by
every option below; by the time any of them can act, a report is already
fully constructed and signed. `prepareNextUnsentWindowSubmission`'s
send-path timing (gh#132/#144 territory) — none of the options below change
selection logic, only how promptly/cheaply a write reaches disk. Active
pruning of `WindowReportStore`/the 100,000-record ledger cap — #133 (item 3,
`864d582`) already deferred this explicitly to the send-path work; Decision
2 below extends that same deferral rather than re-opening it. gh#136 (the
`revision == Long.MAX_VALUE` terminal-degradation issue) — unrelated
mechanism (decode already succeeds there; this document's Decision 3 is
about decode's *cost*, not its correctness), confirmed by reading gh#136
directly. Android production wiring — per `AGENTS.md`, deferred to Issue
#121; discussed in §8, not re-litigated.

## 2. Root cause, restated against current code

### 2.1 Startup: the actual call chain, and where it sits relative to first paint

```swift
convenience init() {
  var initialLedgerFailure: Error?
  let windowReportStore: WindowReportStore
  do {
    let recovery = try WindowReportStore.recoveringCorruptReports()  // sync decode
    ...
    windowReportStore = recovery.store
  } catch { ... }

  let runtime: UnsentWindowLedgerRuntime?
  do {
    let recovery = try UnsentWindowLedgerStore.recoveringCorruptSnapshot()  // sync decode
    ...
    runtime = try UnsentWindowLedgerRuntime(store: recovery.store)
  } catch { ... }
  self.init(windowReportStore:..., unsentWindowLedgerRuntime: runtime, ...)
}
```

(`SensingCoordinator.swift:339–376`.) The designated initializer it calls
then does the actual crash-gap reconciliation, synchronously, still on the
caller's context:

```swift
init(...) {
  if let runtime = recoveredRuntime {
    do {
      // TODO: Construction currently performs relaunch reconciliation even
      // for same-process coordinator replacement. Introduce an explicit
      // process-relaunch signal before narrowing this without weakening
      // crash-gap recovery. See beid#134.
      let durableReports = try windowReportStore.persistedReportsForLedgerRecovery()
      ...
      try runtime.reconcileAfterRelaunch(persistedObservations: persistedObservations)
    } catch { ... }
  }
  ...
}
```

(`SensingCoordinator.swift:401–440`, TODO at `:412–415`.) Confirms gh#134's
claim mechanically: `WindowReportStore.recoveringCorruptReports()` decodes
`window-reports.json` in full (`WindowReportStore.swift:64–91` →
`load()`, `:189–197`); `UnsentWindowLedgerStore.recoveringCorruptSnapshot()`
decodes the ledger snapshot (`UnsentWindowLedgerStore.swift:47–78` →
`durableRevision()` → `decodedDurableSnapshot()`, `:234–255`, which calls
shared's `decodeUnsentWindowLedgerSnapshot` — see §2.3); and
`reconcileAfterRelaunch` re-derives + persists a new snapshot if anything
changed (`UnsentWindowLedgerRuntime.swift:82–98` → `apply(_:)` →
`store.persist(transition)`, which itself decodes again — §2.3). All of it
is synchronous, all of it runs before `SensingCoordinator.init` returns.

**Where this sits relative to first paint, not assumed**:
`AppCoordinator.swift:22`, `let sensingCoordinator = SensingCoordinator()`,
is a stored-property initializer on `AppCoordinator`
(`AppCoordinator.swift:9`, `@MainActor final class AppCoordinator:
ObservableObject`). `AppCoordinator` itself is constructed via
`@StateObject private var coordinator = AppCoordinator()`
(`ios/Beid/App/BeidApp.swift`), inside `BeidApp`'s `WindowGroup { RootView()
... }`. `@StateObject`'s initial-value closure runs synchronously the first
time the view is instantiated, before `RootView`'s first `body` render. So
this chain is not "some background subsystem is slow" — it sits directly on
the critical path to the app's first frame. This is a stronger and more
precise claim than gh#134's own framing ("記録が増えるほど起動が重くなる
構造"), which describes the *shape* of the cost without locating it against
the render pipeline; §4 below designs against the located version.

### 2.2 Window close: the per-rotation full rewrite, still on the MainActor after any Decision 1 fix

```swift
private func closeWindow(enin: Int, eventCode: String) {
  ...
  } else {
    let payload = windowReportPayload(...)
    let signature = sensingCryptography.signWindowReport(...)
    let report = WindowReport(...)
    // TODO: This and the shared snapshot write below synchronously
    // rewrite whole files on the MainActor BLE path. Move the I/O off
    // actor in a follow-up while preserving report-before-ledger-close
    // durability ordering. See beid#134.
    do {
      observationReference = try windowReportStore.add(report)
      ...
    } catch { ... }
  }
  if let unsentWindowLedgerRuntime {
    do {
      try unsentWindowLedgerRuntime.closeWindow(...)  // also a full snapshot rewrite
    } catch { ... }
  }
  clearCurrentWindowState()
}
```

(`SensingCoordinator.swift:1042–1105`, TODO at `:1074–1077`, called from
`advanceWindowIfNeeded` on every real ENIN rotation, `:933–944`, and from
`closeFinalWindowIfNeeded`/`checkpointOpenWindowForBackgrounding` at
explicit-stop/backgrounding, `:980–1016` — all three call sites reachable
during a live, still-`.recording` session, not just at session boundaries.)
`WindowReportStore.add` confirms gh#134's claim precisely:

```swift
let updatedReports = reports + [report]
let data = try JSONEncoder().encode(updatedReports)
```

(`WindowReportStore.swift:153–154`.) Every close re-encodes **every window
report the device has ever produced**, not just the new one —
`WindowReportStore` has no pruning of its own (confirmed by reading the
whole file, `WindowReportStore.swift:1–198`: `add` only ever appends, `load`
only ever reads the whole array; no method removes an entry). #133's own
issue body already named this precisely: item 3, "`WindowReportStore` には
刈り取りが無いため、長く使われた端末はいずれこの上限に到達し" (gh#133, read
directly) — and #133's merge commit (`864d582`) explicitly deferred fixing
it: *"3. 10 万件上限での停止は修正しない... 能動的な刈り込みは送信確認済み
の報告だけが安全に刈れるため送信経路の作業に属する"* — active pruning
belongs with the send-path work, because only a report the send path has
confirmed delivered is safe to prune. This is direct, already-PM-approved
precedent for §5's recommendation.

### 2.3 The canonicity check runs on every open and close, not only at load — a fact the issue's own framing understates

```kotlin
public fun decodeUnsentWindowLedgerSnapshot(encoded: String): UnsentWindowLedgerLoadResult {
  if (encoded.encodeToByteArray().size > MAX_LEDGER_SNAPSHOT_BYTES) {
    return invalidSnapshot("snapshot_too_large")
  }
  return try {
    val state = parseSnapshot(encoded)
    val ledger = UnsentWindowLedger(state)
    if (encodeUnsentWindowLedgerSnapshot(ledger) != encoded) {
      invalidSnapshot("noncanonical_snapshot")
    } else {
      UnsentWindowLedgerLoadResult(ledger = ledger, isSuccess = true, ...)
    }
  } catch (_: Exception) { invalidSnapshot("invalid_snapshot") }
}
```

(`UnsentWindowLedgerSnapshot.kt:90–106`.) gh#134 frames this re-encode-and-
compare as a startup cost ("この復号は正準性を確認するためにスナップショット
全体を再エンコードして突き合わせます", in the 起動時 section). It is also
paid on **every successful ledger write**, not only at load: `iOS
UnsentWindowLedgerStore.persist(_:)` calls `decodeUnsentWindowLedgerSnapshot`
on the transition's own `snapshotText` as a self-check before writing
(`UnsentWindowLedgerStore.swift:145–154`), and `persist` is called from
`UnsentWindowLedgerRuntime.apply(_:)` for every changed transition
(`UnsentWindowLedgerRuntime.swift:113–120`) — i.e. every `openWindow` and
every `closeWindow` call that actually mutates ledger state. Android's own
native store (`android/app/src/main/kotlin/org/levarac/beid/persistence/
UnsentWindowLedgerStore.kt:39–48`) is exactly symmetric: `persist()` also
calls `decodeUnsentWindowLedgerSnapshot(snapshotText)` on its own
freshly-produced bytes before writing. §6 designs against this fuller,
per-operation picture, not just the startup instance gh#134 named.

### 2.4 PR #179 (open, unmerged) adds a fourth store to the same init path with the same shape

`gh pr diff 179` (`issue-91-selfproof-recovery`, tracks gh#91 sub-slice 3,
implementing `docs/specs/session-end-finalization.md` §7.1 Option B) adds:

- `SelfProofCheckpointStore` — a new `@MainActor` store, `init` calls `load()`
  synchronously (decodes `self-proof-checkpoint.json` if present).
- `reconcileSelfProofCheckpointIfNeeded()`, called once at the end of
  `SensingCoordinator.init` (added right after `engine.onEvent = ...`, the
  exact point this document's Decision 1 must also finish before) — reads
  the checkpoint, and if a stale one exists with no matching
  `SelfProofStore` record, **signs and persists a new `SelfProofRecord`**
  (`selfProofStore.add(record)`, another synchronous file write) before
  clearing the checkpoint.
- `checkpointSelfProofStateIfNeeded()`, called from `openWindow` on every
  real window rotation (mirroring §2.2's `closeWindow` call sites) —
  another synchronous file write, though a small single-record one, not a
  full-array rewrite.

This store does not exist in this worktree today (PR #179 is open, not
merged) — this document does not assume it, but treats it as certain enough
near-term context that Decision 1's design must not need rework the moment
it lands. §9 covers sequencing between the two PRs.

## 3. What must not change

- **The ledger snapshot's wire format** (`encodeUnsentWindowLedgerSnapshot`'s
  byte layout) — no option below touches it; per
  `docs/kmp-shared-foundation.md` §1 this is a fixed `shared/` family, out
  of this document's scope entirely (§1).
- **`fsync` calls #133 added** to both stores (`WindowReportStore.swift:48–52`,
  `UnsentWindowLedgerStore.swift:228–232`) — every option below either
  keeps the same write path or moves *when*/*where* it runs, never *whether*
  it fsyncs.
- **`windowReportPayload`'s byte layout and the signing call** inside
  `closeWindow` — unaffected; the report is already fully signed by the
  time any option here can act.
- **The explicit-storage-seam test initializer**
  (`SensingCoordinator.swift:381–399`, and the designated
  `init(windowReportStore:selfProofStore:unsentWindowLedgerRuntime:
  sensingCryptography:initialLedgerFailure:)` it and tests call directly,
  `:401–440`) — this document's Decision 1 (§4) is written to change only
  the **production** `convenience init()` (`:339–376`); the designated
  init's synchronous, fully-loaded-stores contract is exactly what
  `BeidTests` already relies on (its own doc comment: "keeps strict
  fail-closed loading and never quarantines the caller-provided file
  implicitly") and must not change shape.
- **`prepareNextUnsentWindowSubmission`'s selection/ordering logic** — none
  of the options below touch it, only how promptly a write it will later
  read reaches disk.

## 4. Design decision 1 — startup load + reconcile off the main actor

This is the decision that matters most: it is what AC1 (§7) actually
requires, and it is the one place a genuinely new race is introduced rather
than an existing cost relocated.

### 4.1 The concrete question

Per §2.1, moving construction off the main actor means `SensingCoordinator`
(or whatever constructs it) can no longer finish loading synchronously
before returning. The SubPM's framing names the real race directly: BLE
detection could plausibly fire (via `handleDetection`, reachable once
`startSensing()` has called `engine.startAuto()`) before that background
load resolves. Concretely, `startSensing()`
(`SensingCoordinator.swift:643–659`) requires either a real
`engine.requestPermissions` round trip (a native permission dialog — in
practice almost certainly slower than any plausible load time) or, in
`useDemoEventMode` (Simulator, or `-beid-demo-event` on device), an
immediate `runDemoSequence` with `demoStepDelayNanos` of 700ms
(2s under `-beid-ui-test`, `:307–314`) before any detection fires. Today,
this timing is irrelevant because construction is fully synchronous before
`AppCoordinator`/`RootView` ever exist. Once load is async, the demo-mode
timing (the tightest real case) is the one to design against, and AC1's own
requirement that startup cost become **record-count-independent**, not just
"fast today," means the margin against even 700ms cannot be assumed to hold
forever as record counts grow.

### 4.2 Three options, evaluated with real tradeoffs

**Option A — make the detection path itself `async`, await a stored "load
complete" `Task` at its entry.**

*Mechanics*: `init` kicks off `let loadTask = Task { ... }`, doing the
existing `convenience init()` file work off the main actor, then hopping
back to assign `self.windowReportStore`/`self.unsentWindowLedgerRuntime`.
`handle(_ event:)`/`handleDetection` become `async` and `await
loadTask.value` before doing anything else; `engine.onEvent`'s closure
already wraps its call in `Task { @MainActor in ... }`
(`SensingCoordinator.swift:436–439`), so this is a mechanical `await`
insertion at that call site.

*For*: no new queue data structure; every current and future caller of the
detection path is gated by construction, not by remembering to route
through a separate buffer.

*Against — real, not dismissed*: `handleDetection(enin:rpid:detectedDisplayId:)`
is deliberately **not** `private`, with a doc comment stating exactly why:
*"`BarnardDetectionEvent` has no public initializer... so `BeidTests` cannot
construct one to drive this path — taking the fields it actually needs as
plain arguments instead lets tests exercise the real (non-demo) detection
path directly"* (`SensingCoordinator.swift:458–469`). Making this `async`
breaks that seam's synchronous-call contract — every existing test calling
`handleDetection` directly needs an `await` added, which per §0's quoted
AGENTS.md passage is exactly the kind of change that must run the full
covering suite (`SensingCoordinatorTests.swift`, `WindowReportFinalizationTests.swift`,
and any test in PR #179 exercising this path once it lands), not a narrow
subset. Correctness under this option also leans on an *informal* property
of Swift's cooperative scheduler: multiple `Task`s suspended on the same
`await loadTask.value` resuming in the order they were created is a
well-established, commonly-relied-on pattern in practice, but it is not a
language-documented ordering guarantee the way a plain array queue's FIFO
behavior is structurally guaranteed. **Lost if this option is not chosen**:
avoiding the test-signature churn entirely (Option B keeps it) — this is
what B trades away by comparison. **Lost if this option is chosen instead of
B**: an explicit, structurally-guaranteed ordering (a queue you can read and
assert on directly) in exchange for an implicit one the runtime's scheduler
happens to provide.

**Option B — queue raw detections during load, drain them in original order
once load resolves. RECOMMENDED.**

*Mechanics*: `SensingCoordinator.init()` returns immediately.
`windowReportStore`/`unsentWindowLedgerRuntime` (and, once PR #179 lands,
`selfProofCheckpointStore`) become `private var` (from `private let`,
`SensingCoordinator.swift:210–211,217`), starting as empty/placeholder
values; a new `@Published private(set) var isLedgerLoading: Bool = true` is
added (kept **separate** from `LedgerHealth`, §4.3). `init` kicks off a
background `Task` performing exactly today's `convenience init()` work
(store recovery, `reconcileAfterRelaunch`, and PR #179's checkpoint
load/reconcile once merged) off the main actor, then hops back to assign the
real stores, set `ledgerHealth` (`.healthy` or `.degraded`, unchanged
contract — §4.3), set `isLedgerLoading = false`, and drain a small
in-memory queue of `(enin: Int, rpid: String, detectedDisplayId: String?)`
tuples that `handleDetection` appended (in arrival order, via a plain
`append`) instead of processing, for as long as `isLedgerLoading` was true —
replaying each queued tuple through the **unchanged**, still-synchronous
`handleDetection` in order.

*Why gate the whole detection, not just the store-touching calls inside it*:
a tempting narrower version only queues the `openWindow`/`closeWindow` calls
while letting `phase` transitions (`beginEventFound`/`beginRecording`)
happen immediately. Rejected: native in-memory state
(`currentWindowId`/`currentWindowRpids`) would then advance and a window
could be fully signed and durably written to `WindowReportStore` while
`unsentWindowLedgerRuntime` is still nil — and unlike gh#132's actual
trigger (a rare storage-write failure), this would reproduce gh#132's exact
shape (a durable, signed report with no matching ledger row) **on every cold
launch where any detection beats the load**, recoverable only at the *next*
relaunch per `docs/specs/ledger-open-failure-recovery.md`'s design (that
spec's reconciliation runs once per launch, not mid-process) — turning a
rare bug this repo just finished a whole spec fixing into a routine one.
Queuing the entire detection avoids this because every piece of
ledger-relevant state (`activeCommit`, `currentWindowEnin`, `activeProofId`)
only ever gets set as a *consequence* of processing a detection — if none
have been processed yet, none of that state exists, and every other method
that reads it (`closeFinalWindowIfNeeded`, `finalizeSelfProofIfNeeded`, both
gated on state that stays nil during the queueing window) degrades to its
existing, already-tested "nothing observed yet" no-op for free — no new
guards needed anywhere outside the queue/drain itself.

*For*: `handleDetection`'s signature and every existing call site
(production and test) stay exactly as-is — zero test-signature churn, the
opposite of Option A's cost. Ordering is a plain array, structurally FIFO,
not a scheduler-implementation-dependent property. `openWindow`'s existing
`if let unsentWindowLedgerRuntime` nil-check keeps meaning exactly one thing
— permanent failure — never "still loading," so no third state leaks into
code that already has to reason about the binary healthy/degraded case.
Blast radius is contained entirely inside `SensingCoordinator`: no view
reads `windowReportStore`/`unsentWindowLedgerRuntime` directly (confirmed by
grep across `ios/Beid/Views` and `ios/Beid/Navigation` — zero hits), so no
UI code changes.

*Against — real, not dismissed*: does not eliminate the race the way Option
D does — it manages it. A detection *can* still arrive before load resolves
(demo mode's 700ms margin is comfortable today but, per §4.1, is exactly the
margin AC1's record-count-independence requirement says must not be assumed
to hold forever); the visible cost is a delayed `phase` transition
(`.sensing → .eventFound`) for whatever fraction of the load time overlaps
with the first detection — bounded, but not zero, and not structurally
impossible the way it would be under Option D. Requires two `let → var`
property changes and one new small queue/drain implementation — a real,
if contained, piece of new code with its own test surface (§7).

**Option D — defer `SensingCoordinator`'s entire existence: make
`AppCoordinator.sensingCoordinator` optional, construct it only once loading
finishes.**

*Mechanics*: `AppCoordinator.sensingCoordinator` becomes `@Published
private(set) var sensingCoordinator: SensingCoordinator?`, starting `nil`;
`AppCoordinator.init` kicks off the background load, then constructs
`SensingCoordinator` via its **existing, unchanged** synchronous designated
initializer once loading completes.

*For*: structurally eliminates the race, not just manages it — `engine`
(`BarnardEngine()`, `SensingCoordinator.swift:207`) is a stored property of
`SensingCoordinator` itself, wired up only inside its `init`
(`:436–439`); if the object does not exist yet, no `BarnardEngine` exists,
`engine.onEvent` is not wired, and no detection can possibly fire — there is
no "before load resolves" window to design around at all, by construction,
not by careful gating. `SensingCoordinator`'s own internals (stores, queue)
need no new mutable state — it keeps its current fully-synchronous-once-
constructed shape entirely.

*Against — real, not dismissed*: `sensingCoordinator` is referenced 17 times
across 8 files outside its own definition (confirmed by grep:
`AppCoordinator.swift`, `RootView.swift`, `BluetoothOffView.swift`,
`SignalLostView.swift`, `ItemDetailView.swift`, `RecordingView.swift`,
`EventBindingSheetView.swift`, `ScanFlowView.swift`) — every one of those
call sites currently treats it as a guaranteed non-optional dependency and
would need explicit nil-handling (an `if let`, a loading placeholder view,
or both) once it becomes optional. This is a materially larger, riskier
change for an equivalent benefit: correctness under Option B is already
sufficient to satisfy AC1 and to avoid reintroducing gh#132's gap (per the
reasoning above); Option D's structural elimination of the race is a
genuinely stronger guarantee, but the SubPM's task framing did not ask this
document to also redesign `AppCoordinator`'s ownership of
`sensingCoordinator` or touch 8 view files, and doing so now would be new
scope beyond what AC1 requires.

### 4.3 What the app shows during the loading window

A new `@Published private(set) var isLedgerLoading: Bool = true` on
`SensingCoordinator`, flipped to `false` once the background task completes
(success or permanent failure — `ledgerHealth` is assigned at the same
moment, exactly as today). Kept deliberately separate from `LedgerHealth`
rather than adding a third case to it: `LedgerHealth`'s own doc comment
frames it specifically as "whether `unsentWindowLedgerRuntime`... can
currently record" (`SensingCoordinator.swift:36–46`) — a binary, permanent-
once-degraded fact about the runtime specifically — while "still loading" is
a transient fact about construction as a whole (covering
`windowReportStore` too, and PR #179's checkpoint store once merged), and
conflating the two would force every existing consumer of `LedgerHealth`
(currently only `UnsentWindowLedgerRuntimeTests.swift`, no production UI
surface yet — confirmed by grep, `.isDegraded`/`.degradationReason`/
`.degradedSince` have zero call sites outside tests today) to also handle a
transient case in what is currently a stable, tested binary contract.

No production UI currently surfaces `LedgerHealth` at all — the same is true
here: this document only requires `isLedgerLoading` be queryable/testable,
matching #131's own precedent of introducing `LedgerHealth` itself without a
UI consumer. Wiring either into a visible "ledger not yet ready" affordance
is a product/UX decision this document does not make.

### 4.4 Recommendation: Option B

Reasoned against the alternatives already laid out in §4.2, not repeated:
Option B satisfies AC1, keeps `handleDetection`'s test-relied-on synchronous
signature completely unchanged (unlike A), and confines its change to
`SensingCoordinator` internals with zero view-layer ripple (unlike D's
17-call-site/8-file surface). Its accepted cost — the race is managed, not
eliminated, and two properties move from `let` to `var` — is smaller than
either alternative's own cost and is not a correctness gap: §4.2's "why gate
the whole detection" analysis shows every other method already degrades
correctly to its existing no-op path during the queueing window, so nothing
new needs defending against outside the queue/drain logic itself.

## 5. Design decision 2 — the per-close full rewrite (§2.2)

Two genuinely separate sub-questions live inside gh#134's single "対応の
方向" bullet: should the **format** change (full-array rewrite vs.
incremental), and — per the TODO's own wording ("Move the I/O off actor in a
follow-up") — should the **execution context** change (still on MainActor,
mid-session, vs. moved off it like Decision 1)? Answered separately because
the honest tradeoffs differ.

### 5.1 Format: keep the full-array rewrite. RECOMMENDED (defer changing it).

**Option 1 — keep `WindowReportStore`'s full JSON-array rewrite as-is
(status quo). RECOMMENDED.**

*For*: directly extends #133's own already-PM-approved precedent
(`864d582`): item 3 of that fix explicitly declined to prune
`WindowReportStore` now, for the stated reason that safe pruning requires
knowing what the send path has confirmed delivered — the same reasoning
applies here, since a well-designed incremental/append-only format for this
store would ideally be informed by the same "what's safe to compact"
question the send path answers, not designed blind to it now. Zero new
format-versioning complexity, zero migration path for existing
`window-reports.json` files needed.

*Against — real, not dismissed*: the cost is genuinely unbounded over a
device's lifetime (no pruning exists anywhere in this store, confirmed by
reading the whole file), so "acceptable today" is not "acceptable forever."

**Option 2 — switch to an incremental/append-only format now.**

*For*: removes the O(n) cost as records accumulate, permanently, without
waiting on the send path.

*Against*: real format-versioning complexity for an existing shipped file
(`window-reports.json` readers must handle both the legacy full-array shape
and a new incremental shape, or a one-time migration step); and — the
stronger objection — an append-only format designed now, before the send
path exists, risks re-litigation the moment pruning is actually designed
(would an appended format need per-entry status tracking mirroring
`LedgerReportStatus`, which the shared ledger already owns? Designing that
twice, once blind and once send-path-informed, is worse than once.
**Lost if this option is chosen over Option 1**: the ability to design the
storage format together with the pruning/status question it will eventually
need to answer anyway — Option 1 preserves that opportunity by not spending
it now; Option 2 spends it.

**Option 3 — bound the cost with periodic batching (only pay the full-rewrite
cost every N closes).**

*Against, decisively*: this weakens the existing durability guarantee for no
real gain — a close that doesn't immediately write durably is a close whose
report could be lost to a crash/jetsam before the batched write ever
happens, reintroducing exactly the class of gap `docs/specs/session-end-
finalization.md` was written to close. **Lost if chosen**: the "every
signed report reaches durable storage before the call that produced it
returns" property every other option here preserves. Not recommended.

**Recommendation: Option 1 (defer).** Matches #133's own precedent exactly,
on the same file, for the same underlying reason (real pruning needs the
send path). Revisit trigger, stated explicitly rather than left open-ended:
when the send-path/pruning work (already-deferred by #133 item 3) is
designed, design `WindowReportStore`'s eventual format together with it,
not before.

### 5.2 Execution context: keep on the MainActor for now. RECOMMENDED (defer moving it off-actor).

**Option 1 — leave `closeWindow`'s I/O on the MainActor (status quo, still
synchronous mid-session). RECOMMENDED.**

*For*: AC1 (§7) only requires **startup** I/O to become main-actor-free or
record-count-independent — it does not require the same of the recurring
per-close write. `closeWindow` fires only once per real ENIN rotation (not
once per detection — `advanceWindowIfNeeded`'s guard, `:939–941`, only calls
it on an actual window-boundary crossing), so its frequency during a live
session is low even though its per-call cost grows with total accumulated
records. Moving it off-actor mid-session, unlike Decision 1's one-time
startup load, requires solving a genuinely new problem this document has
not needed to solve elsewhere: serializing potentially-overlapping writes to
the same file/snapshot across successive closes on a live, BLE-driven
detection path, where a mistake risks data races or out-of-order writes —
correctness classes this codebase's existing tests
(`WindowReportFinalizationTests.swift`, the redelivery-buffer/idempotency
tests in `session-end-finalization.md` §8) already show are easy to get
subtly wrong even without adding new concurrency.

*Against — real, not dismissed*: does not satisfy the TODO's own literal
request ("Move the I/O off actor in a follow-up"). A close during an active,
long-running session still blocks the MainActor for one full-array
JSON encode + two fsync'd atomic file replacements (report store + ledger
snapshot), on the same call stack that BLE detection callbacks arrive
through.

**Option 2 — move it off-actor now, reusing Decision 1's background
execution context.**

*For*: directly answers the TODO; reuses infrastructure Decision 1 already
introduces rather than inventing a second mechanism.

*Against*: requires `closeWindow`'s two writes to run on a **serial**
background executor (not merely "off-actor" — a second close arriving before
the first write finishes must queue behind it, or the two writes can race on
the same file) — new synchronization logic with no precedent in this
codebase to reuse, being added to the highest-frequency, highest-risk call
path (live BLE detections) rather than the once-per-launch path Decision 1
safely handles. **Lost if this option is chosen instead of Option 1**: the
lower-risk property of only ever introducing new concurrency on a
once-per-process code path (Decision 1) rather than on a path that recurs
throughout every session at a frequency this document has not needed to
reason carefully about congestion/ordering for before.

**Recommendation: Option 1 (defer).** The risk/benefit is asymmetric in the
wrong direction for now: AC1 doesn't require it, the felt cost is currently
low (§2.2's own "なぜ今すぐではないか" — gh#134 itself says there is no
current felt delay), and the correct fix likely wants to be designed
together with §5.1's format question and the send-path/pruning work in the
same follow-up, rather than rushed now to close out a TODO's wish-list
phrasing. The TODO comment itself should be narrowed in the same PR that
implements Decision 1, to state precisely that startup is resolved and the
per-close actor-location question is deferred to the pruning/send-path
follow-up — not left claiming a broader "follow-up" than what actually
ships.

## 6. Design decision 3 — canonicity re-encode-and-compare check frequency

Per §2.3, `decodeUnsentWindowLedgerSnapshot`'s full re-encode-and-compare
runs at both `load()` (once per launch) and `persist()` (every successful
open/close, on both iOS and Android's already-built native stores). This is
a `shared/` decision — `parseSnapshot` (the lighter, non-canonicity-checking
half of the function) is `private` in `UnsentWindowLedgerSnapshot.kt`, not
exported, so native cannot call a narrower check without a shared API
change; per `docs/kmp-shared-foundation.md` §1, "ledger snapshot codec" is
already a `shared/`-owned family.

**Option 1 — keep the full check everywhere it runs today (status quo).
RECOMMENDED (deferred — see ruling below).**

*For*: at `persist()` time, the check is genuinely doing double duty:
`UnsentWindowLedgerStore.persist`'s own same-revision-conflict guard
(`UnsentWindowLedgerStore.swift:162–169`) compares durable bytes to the
incoming snapshot **by raw byte equality** — that comparison is only
correct if the format is guaranteed canonical/deterministic, so the
canonicity check is not purely a load-time corruption defense; it is also a
live self-check that the encoder is still honoring the determinism property
a different piece of code already depends on.

*Against — real, not dismissed*: pays this cost on every window open and
close, growing with total accumulated records, for a property (encoder
determinism) that is a `shared/`-side coding invariant, not something that
can drift from external corruption the way load-time bytes can — `persist`
is checking bytes the *same process* just produced via the *same* encoder
function, moments earlier, not bytes read from disk.

**Option 2 — narrow to load-time only: keep the full check at `load()`;
`persist()` uses the parse-only path (structural validation, no
byte-for-byte round-trip compare) as its self-check, via a new shared
function/parameter. Not approved — see ruling below.**

*For*: preserves the exact defense `load()` needs (bytes are external,
persistence-boundary-crossing, and could be corrupted, migrated, or foreign)
at its current cost, paid once per launch. At `persist()`, still validates
structurally (every `require(...)` inside `parseSnapshot` still runs — an
`invalid_snapshot` transition is still rejected, `persist` still fails
closed on genuinely malformed bytes) — only the strict canonical-form
round-trip comparison is dropped from the hot, per-operation path. The
canonical-form invariant itself stays defended: it is already pinned by
existing golden-vector-style tests (`UnsentWindowLedgerSnapshotTest.kt`,
per `docs/specs/ledger-open-failure-recovery.md` §2.5's own citation of this
suite, and gh#136's own comment establishing this repo's convention of
testing canonical-form boundaries at the test level, not via a runtime
self-check on every call) — this repo already trusts tests, not a
per-operation runtime check, for exactly this class of invariant elsewhere
in the same file family (`docs/specs/barnard-binding-conformance.md` §5's
"golden-vector discipline, applied precisely rather than reflexively
re-run", reused as the same principle here).

*Against*: a genuine `shared/`-side API change (new function or parameter on
`decodeUnsentWindowLedgerSnapshot`) that both native stores' call sites must
adopt correctly (§8) — get the split wrong (e.g. accidentally use the
lighter path at `load()`) and load-time corruption defense silently weakens.

**Option 3 — remove the check from `persist()` entirely, no replacement.**

*Against, decisively*: removes not just the byte-comparison cost but the
structural parse validation too (a plain `require(...)` failure would no
longer be caught at all before disk), and `persist`'s own same-revision-
conflict guard would keep relying on byte-for-byte canonical-form equality
with **zero** independent verification that the encoder still produces it —
a latent future encoder-determinism regression (e.g. an accidental
`Set`/`Map` iteration-order dependency in a later refactor) would reach disk
undetected at runtime, not just untested. **Lost if chosen over Option 2**:
the structural fail-closed guarantee `persist()` currently provides against
genuinely malformed bytes — Option 2 keeps that; Option 3 gives it up
entirely for no additional benefit over Option 2 (both remove the same
expensive byte-comparison; only Option 3 also removes the cheap structural
check). Not recommended.

**Ruling: Option 1 (status quo), deferred — not Option 2.** This document's
own recommendation above was Option 2; the PM's ruling overrides it. The
analysis above stays in this document unchanged (the PM: "the analysis is
good and the next person should not have to redo it") — what changes is the
final call, for the reasons below, recorded here as given rather than
paraphrased.

The load-failure path decides this, verified directly rather than assumed:
`UnsentWindowLedgerStore.recoveringCorruptSnapshot` catches
`invalidSnapshot` at load, moves the file aside as
`corrupt-<milliseconds>-<uuid>`, and returns a store with an empty ledger
(`UnsentWindowLedgerStore.swift:47–78`, catch block `:65–77`).

**What Option 2 actually trades.** Today, an encoder-determinism regression
— the `Set`/`Map` iteration-order refactor Option 3's analysis above names —
is caught at `persist()`, before bad bytes reach disk, and the operation
fails closed. Under Option 2 it is not caught at write time. The
non-canonical bytes land on disk, and the failure surfaces at the *next
launch* as `invalid_snapshot` → the entire ledger is quarantined and the app
starts with an empty one. Every unsent report is gone from the send set.

So Option 2 does not merely relocate a cost. It converts a write-time
fail-closed into a next-launch data-loss event. Option 2's own *For* section
above says the invariant "stays defended" by golden-vector tests, and that
is true for the shapes the vectors cover — but the failure it is defending
against is precisely the one that escapes vectors, since an iteration-order
dependency manifests on data shapes nobody wrote a vector for.

**Why the cost side does not justify it.** Decision 2 (§5.2) keeps the
per-close full rewrite synchronous and on the MainActor. So the canonicity
check sits next to a full encode plus a full-file write that both remain.
Dropping it removes roughly one encode from an operation that still does an
encode and a synchronous write — a fraction of a path whose dominant cost is
untouched. That is a small gain for a changed failure mode.

**And the sequencing is wrong.** #155 is open and unresolved: quarantine
currently doubles as the migration path, with no migration. Weakening a
write-time guard whose failure mode routes straight into that same
quarantine, while that problem is still open, is the wrong order to do
things in.

**Revisit condition, so this is deferred rather than closed.** Bring
Decision 3 back when the per-close write actually moves off the MainActor
(§5.2's Option 2, itself deferred) — at that point the cost profile is
genuinely different and the check may be the dominant remaining term — and
when #155's migration story is settled so a load-time rejection is no
longer equivalent to data loss. Both conditions, not either alone: recorded
here so the next person does not have to redo the analysis above, only
re-check whether these two facts have changed.

This document therefore makes **no `shared/` change** — see §8.

## 7. Acceptance criteria

Matching gh#134's own two, plus this document's additions:

1. **(gh#134 AC 1)** Startup main-thread synchronous I/O is gone or
   independent of record count. Satisfied by Decision 1/Option B (§4.4):
   `SensingCoordinator.init()` returns without blocking on file I/O; the
   actual load/reconcile work (including PR #179's already-merged
   checkpoint reconciliation, §9) runs off the main actor via a background
   `Task`.
2. **(gh#134 AC 2)** The two existing TODOs reference this issue. **Already
   true today** — both `SensingCoordinator.swift:412–415` and `:1074–1077`
   already say "See beid#134." verbatim (confirmed by direct read this
   session). This document's implementation should narrow, not remove,
   the second TODO's wording per §5.2's recommendation (state precisely
   that startup is resolved, per-close actor-location remains deferred to
   the pruning/send-path follow-up).
3. **New**: a test proving a detection arriving during the loading window is
   not lost and is processed in original order once loading completes —
   extends `SensingCoordinatorTests.swift`'s existing construction/detection
   patterns; asserts the queued tuple(s) produce the same `phase`/window
   state as if `handleDetection` had been called directly after
   construction, once `isLedgerLoading` becomes `false`.
4. **New**: a test proving `stopSensing()`/`reset()`/
   `checkpointOpenWindowForBackgrounding()` called during the loading window
   (before any detection has been queued) remain no-ops, matching their
   existing nil-state guards — extends `WindowReportFinalizationTests.swift`.
5. **Full covering suite, not a targeted subset**, per §0's quoted AGENTS.md
   passage: `SensingCoordinatorTests.swift`, `WindowReportFinalizationTests.swift`,
   `UnsentWindowLedgerRuntimeTests.swift`, `UnsentWindowLedgerStoreTests.swift`,
   `WindowReportStoreDurabilityTests.swift`, `SelfProofTests.swift`,
   `BackgroundingCheckpointTests.swift`, and
   `SelfProofCheckpointRecoveryTests.swift` (all present in current
   `origin/main` since PR #179 merged, §9) must all pass — every one of
   these files exercises code this document's Decision 1 changes (the init
   path). Shared-side: `UnsentWindowLedgerReducerTest.kt`,
   `UnsentWindowLedgerSnapshotTest.kt` must pass unmodified — Decision 3 is
   deferred (§6), not implemented, so neither shared-side file changes.
6. **No change to `windowReportPayload`'s byte layout, the ledger snapshot's
   wire format, or `fsync` behavior** (§3) — verified by existing
   golden-vector/payload/fsync-injection tests continuing to pass unmodified.

## 8. Both-OS note

Per `AGENTS.md`'s both-OS feature rule: **Decisions 1 and 2 (§4, §5) are
iOS-only.** There is no Android production caller of any part of the
window-report/ledger family yet (`AGENTS.md`'s own current-state statement:
Android production wiring deferred to Issue #121); Decision 1's fix is
entirely inside `SensingCoordinator`'s init shape, which has no Android
counterpart to touch. Decision 2 is entirely about `WindowReportStore`
(iOS-only type; Android has no equivalent yet).

**Decision 3 (§6) is deferred, not implemented — so there is no `shared/`
change in this spec at all.** §6's original recommendation (Option 2) would
have been the one place this document touched `shared/` and both native
`decodeUnsentWindowLedgerSnapshot` call sites, iOS and Android's own
already-built `UnsentWindowLedgerStore.kt`
(`android/app/src/main/kotlin/org/levarac/beid/persistence/
UnsentWindowLedgerStore.kt`) alike. The PM's ruling keeps Option 1 (status
quo) instead (§6), and status quo is, by definition, no code change on
either platform's call site. With that, this document as a whole makes no
`shared/` change and has no cross-platform-adoption risk to flag: every
decision it actually implements (1 and 2) is iOS-only, for the reasons
already stated above, and Decision 3 implements nothing this round. Revisit
this note if and when Decision 3's revisit condition (§6) is met and Option
2 (or another option) is taken up again — at that point the both-native-
call-sites requirement §6 originally described becomes live again.

## 9. Sequencing note: PR #179 interaction (resolved)

This section originally flagged an open sequencing question between this
document's Decision 1 and PR #179. That question is now resolved: PR #179
(`issue-91-selfproof-recovery`) merged (`gh pr view 179` shows `mergedAt`
set, merge commit `5dfdfca`), and its tracking issue gh#91 is closed. PR
#179's `SelfProofCheckpointStore` and `reconcileSelfProofCheckpointIfNeeded()`
already exist in current `origin/main`
(`ios/Beid/Persistence/SelfProofCheckpointStore.swift`,
`ios/Beid/Persistence/SelfProofCheckpoint.swift`,
`ios/BeidTests/SelfProofCheckpointRecoveryTests.swift`), added to the exact
same `SensingCoordinator.init` region Decision 1 restructures (§2.4) — this
is no longer a future-tense description of an open PR's diff, it is the
current state of the init path Decision 1's implementation must fold into.

No rebase question remains, because there is no second PR left to land:
Decision 1's design (§4.2, Option B) was written so that folding in one
more store's load/reconcile step into the same background `Task` is
additive — one more `await`/hop inside the same task body — not a redesign,
regardless of merge order (§2.4). That property now simply describes how
Decision 1's implementation includes PR #179's checkpoint store's
load/reconcile alongside `WindowReportStore` and
`UnsentWindowLedgerStore`'s existing load/reconcile in the same background
`Task`. Nothing is left to sequence.
