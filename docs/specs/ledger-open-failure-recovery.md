# Spec — Ledger open-failure recovery (gh#132)

Status: **DRAFT — open decision resolved by recommendation below; PM/user
approval still required before implementation begins**, per this repo's
standing "no code before spec approval" rule (`DECISIONS.md` 2026-08-03
"コード先行禁止"). No product code was written or edited to produce this
document.

Author: Worker `a-20260809-005`, for SubPM `a-20260809-001`.

**Method note**: every factual claim about current code below is sourced
from reading the actual file at the cited line numbers this session,
against `origin/main` after `git fetch` (working tree was already up to
date with `origin/main`). Where gh#132's own line-number citations
(`SensingCoordinator.swift:591-599`/`:707-715`) no longer match the current
file — the file has grown substantially since the issue was filed, adding
`WindowReportRedeliveryBuffer`, `checkpointOpenWindowForBackgrounding`, and
`currentSessionEventCode` per the already-shipped
`docs/specs/session-end-finalization.md` — this document cites the current
line numbers instead and says so explicitly rather than repeating stale
line numbers as fact. Sources: `ios/Beid/Sensing/SensingCoordinator.swift`,
`ios/Beid/Persistence/UnsentWindowLedgerRuntime.swift`,
`ios/Beid/Persistence/WindowReportStore.swift`,
`shared/src/commonMain/kotlin/org/levarac/beid/shared/report/UnsentWindowLedger.kt`,
`shared/src/commonMain/kotlin/org/levarac/beid/shared/report/UnsentWindowLedgerSnapshot.kt`,
`ios/BeidTests/UnsentWindowLedgerRuntimeTests.swift`,
`shared/src/commonTest/kotlin/org/levarac/beid/shared/report/UnsentWindowLedgerReducerTest.kt`,
`gh issue view 132` (read directly), `AGENTS.md`,
`docs/kmp-shared-foundation.md`, `DECISIONS.md` (read in full).

Builds on: `docs/kmp-shared-foundation.md` §1 (family classification: the
unsent-window ledger is Family **C / INVENT**, requiring "不変条件、仕様の
所有者、失敗時の扱い" fixed before implementation — this document is that
fixture for the one failure path gh#132 names) and §5 (the ledger's ten
minimum invariants, in particular invariant 4); `docs/specs/session-end-
finalization.md` §7.1 (this repo's own prior instance of choosing "flush
what's pending on the next opportunity" over "prevent the gap from
occurring," for a sibling gap in the same file family — cited as design
precedent in §5 below, not repeated).

Tracks: gh#132 ("台帳のウィンドウ登録に失敗すると、その回の報告が永久に送信
対象から漏れる" — a failed ledger-window registration permanently drops
that window's report from every future submission).

## 1. Scope

**IN**: what happens to a report whose ledger-window `open` call failed
(§2–§4), a choice among the issue's two named options plus one more found
during this session's reading (§4), a recommendation reasoned against the
working manual's invariants and vector discipline (§5), acceptance criteria
matching gh#132's own plus this document's additions (§6), and an explicit
both-OS note per `AGENTS.md`'s both-OS feature rule (§7).

**OUT**: when or how the send path itself calls
`prepareNextUnsentWindowSubmission` — gh#132's own body frames this as
"currently latent... send のスライスが入った瞬間に実害になる" (currently
latent, becomes real damage the moment the send slice lands), i.e. no
native caller of that function exists yet; this document only decides what
happens to the report before that caller exists, not how or when the
caller is built. Android production wiring for any part of this family —
per `AGENTS.md`, deferred to Issue #121, discussed but not re-litigated in
§7. Any change to `windowReportPayload`'s byte layout, `WindowReport`'s
`Codable` shape, or the report signer boundary (KMP-002/facilitator-spec
territory) — none of the options below touch what gets signed, only ledger
bookkeeping around an artifact that is already fully signed by the time
this gap can manifest (§2). The sibling, largely-already-solved gap where
the ledger *close* call fails after a *successful* open (crash between
report-write and ledger-close) — distinguished precisely from gh#132's
actual gap in §2, because current tests already cover it and it is not
what this issue is about. The other ledger-correctness issues named
alongside gh#132 in `DECISIONS.md` 2026-08-09's critical-path list
(gh#131/#133/#134/#136/#91-3/#155/#156) — each is a separate gap; nothing
in this session's reading made any of them load-bearing for gh#132's fix.

## 2. Root cause, restated precisely against the current code

### 2.1 The current open call and why `currentWindowId` stays set

```swift
private func openWindow(enin: Int) {
  let windowId = UUID()
  currentWindowId = windowId
  currentWindowEnin = enin
  lastWindowEnin = enin
  if firstWindowEnin == nil {
    firstWindowEnin = enin
  }

  if let unsentWindowLedgerRuntime {
    do {
      try unsentWindowLedgerRuntime.openWindow(
        windowId: windowId.uuidString.lowercased()
      )
    } catch {
      print("Unable to persist an open shared-ledger window: \(error)")
    }
  }
}
```

(`SensingCoordinator.swift:844-864`, called only from `advanceWindowIfNeeded`,
`SensingCoordinator.swift:831-842`.) `currentWindowId`/`currentWindowEnin`
are set **before** the ledger call, and the ledger call's failure path
(`catch`) only prints — it never rolls either back. This confirms gh#132's
claim #1 mechanically, against the current code rather than the issue's
stale line numbers: a failed `openWindow` call leaves native believing a
window is open when the shared ledger has no record of it.

### 2.2 The current close call and what actually happens to the report

```swift
private func closeWindow(enin: Int, eventCode: String) {
  guard let commit = activeCommit, let currentWindowId else {
    print("Unable to close a native window without its commitment and identifier")
    clearCurrentWindowState()
    return
  }

  let observationReference: String
  if let currentWindowObservationReference {
    observationReference = currentWindowObservationReference
  } else if let persisted = windowReportStore.report(id: currentWindowId) {
    observationReference = persisted.id.uuidString.lowercased()
    currentWindowObservationReference = observationReference
  } else {
    let payload = windowReportPayload(...)
    let signature = sensingCryptography.signWindowReport(eventCode: eventCode, bytes: payload)
    let report = WindowReport(id: currentWindowId, ...)
    do {
      observationReference = try windowReportStore.add(report)
      currentWindowObservationReference = observationReference
    } catch {
      // report-write failure: queued for redelivery, a different failure mode (§2.4)
      ...
      return
    }
  }

  if let unsentWindowLedgerRuntime {
    do {
      try unsentWindowLedgerRuntime.closeWindow(
        windowId: currentWindowId.uuidString.lowercased(),
        persistedObservationReference: observationReference
      )
    } catch {
      print("Unable to persist a closed shared-ledger window: \(error)")
    }
  }
  clearCurrentWindowState()
}
```

(`SensingCoordinator.swift:927-988`, elided for space; full text read this
session.) The critical fact: `windowReportStore.add(report)` — the durable,
signed, on-disk write — does **not** depend on the ledger having
successfully opened this window. It succeeds or fails purely on its own
disk I/O. So when `openWindow` failed earlier (§2.1) but `closeWindow`'s
own disk write succeeds, the sequence is: **a fully signed `WindowReport`
becomes durable on disk, and only then does the ledger `closeWindow` call
discover there is no matching open window** — `unsentWindowLedgerRuntime
.closeWindow` throws `UnsentWindowLedgerRuntimeError.rejectedTransition
("unknown_window_id")`, which this call site (unlike
`redeliverPendingWindowReports`, `SensingCoordinator.swift:1001-1007`,
which explicitly discards on this exact error code) just prints and
discards via `clearCurrentWindowState()`. This confirms gh#132's claim #2
against the current code: the report is durable, signed, and now
permanently disconnected from the ledger.

### 2.3 Why relaunch reconciliation does not rescue it

```kotlin
/**
 * Atomically reconciles the complete durable artifact set after relaunch.
 * Matching open windows close, unmatched open windows are discarded because
 * their in-memory observations died with the process, unrelated old artifacts
 * are ignored, and conflicts with already-closed windows fail closed.
 */
public fun reconcileUnsentWindowLedgerAfterRelaunch(
    ledger: UnsentWindowLedger,
    recoveryInput: UnsentWindowObservationRecoveryInput,
): UnsentWindowLedgerTransition {
    ...
    return ledger.persistenceRequired(
        ledger.state.copy(
            revision = revision,
            windows = ledger.state.windows.mapNotNull { window ->
                if (window.closedRevision != null) {
                    window
                } else {
                    recoveryInput.observations[window.windowId]?.let { reference ->
                        window.copy(closedRevision = revision, observationReference = reference)
                    }
                }
            },
        ),
    )
}
```

(`UnsentWindowLedger.kt:219-263`, doc comment included verbatim.) The
traversal is over `ledger.state.windows` — it can only ever close or
discard windows that **already have a `LedgerWindow` row**. A `windowId`
present in `recoveryInput.observations` (i.e. a durable artifact exists)
but absent from `ledger.state.windows` (because `openUnsentWindow` was
never successfully called for it) is never visited by this `mapNotNull` at
all. It is not "discarded" in the sense the doc comment means for
genuinely-lost windows (§2.4 below) — it is simply invisible to the
function, forever. This is the doc comment's own third clause, "unrelated
old artifacts are ignored," applying — by construction, not by any
special-case check — to an artifact this issue considers very much
related. `prepareNextUnsentWindowSubmission`'s candidate filter (`UnsentWindowLedger.kt:317-327`)
only ever selects from `ledger.state.windows`, so an artifact that never
gets a `LedgerWindow` row can never be selected, at this relaunch or any
future one. gh#132's claim #3 is confirmed exactly.

### 2.4 Distinguishing this from the sibling gap that is already handled

A different failure — the ledger **open succeeds**, but the process dies
before the corresponding **close** — is already correctly recovered by the
same reconciliation function, and is *not* gh#132's gap. Proven by an
existing, passing test:
`testRelaunchRecoversAReportWrittenBeforeLedgerCloseAndDiscardsAnEmptyOpenWindow`
(`UnsentWindowLedgerRuntimeTests.swift:559-621`) opens two windows
successfully, durably writes a report for only one of them (simulating a
crash before either close call), relaunches a fresh
`SensingCoordinator`/`UnsentWindowLedgerRuntime`, and asserts the window
*with* a report closes via reconciliation while the window *without* one
is correctly discarded (nothing was ever observable to recover — the
in-memory `currentWindowRpids` for that window died with the process, per
the doc comment's second clause). This is invariant-4-correct behavior
today, and none of the options below change it.

gh#132's actual gap requires the **open** call itself to have failed — the
window never gets a `LedgerWindow` row in the first place, so there is
nothing for the doc comment's first or second clause to apply to; the
third clause ("unrelated old artifacts are ignored") swallows it instead.

### 2.5 An existing test that currently pins the bug as expected behavior

`testUnknownWindowAtRedeliveryHeadIsDiscardedBeforeLaterArtifact`
(`UnsentWindowLedgerRuntimeTests.swift:375-434`) already reproduces gh#132's
exact mechanism in-process: it calls `blockLedgerWrites()`
(`UnsentWindowLedgerRuntimeTests.swift:804-806`, which makes the ledger's
parent directory unwritable, causing any ledger persist — including the
open call — to throw) *before* a detection, so the resulting window's
`openWindow` call fails exactly as in §2.1. The test then restores ledger
writes, blocks *report* writes, drives more detections, restores report
writes, and lets `redeliverPendingWindowReports` (`SensingCoordinator.swift
:990-1013`) drain the buffer — which durably writes the orphaned window's
report (`windowReportStore.add` succeeds once report writes are restored)
and then hits the exact `"unknown_window_id"` terminal rejection at close
time, matching §2.2. The test's own assertions:

```swift
XCTAssertFalse(orphanedClose.isSuccess)
XCTAssertEqual(orphanedClose.errorCode, "unknown_window_id")
```

pin this as the currently-correct outcome — the test's purpose today is to
prove the redelivery buffer's *head* doesn't get stuck behind one
unrecoverable artifact, not to prove the artifact itself eventually gets
recovered. Whichever option is implemented from this spec, this specific
test's assertions describe **in-process, pre-relaunch** behavior against a
ledger that has never gone through `reconcileAfterRelaunch` — nothing in
§4 changes what a live, still-running coordinator sees immediately after a
rejected close. Only a **subsequent cold relaunch** is where any of the
options below can act. This distinction matters enough to restate in §6.4
so an implementer does not mistake "fix gh#132" for "make `closeUnsentWindow`
itself tolerate unknown windows," which is a different, larger change this
document does not recommend.

The shared-side reducer test suite already contains a related but
unexercised vector: `relaunchRecoveryClosesDurableObservationsAndDiscardsOnlyUnrecoverableOpenWindows`
(`UnsentWindowLedgerReducerTest.kt:485-578`) adds a recovery-input entry
keyed `"not-in-this-ledger"` (line 507) — an artifact with no matching
`LedgerWindow`, exactly gh#132's shape — but the test never asserts what
happens to that key afterward; it exists only to prove reconciliation
tolerates an extra, unrelated key without erroring. This is useful
groundwork for whichever option is chosen (§5.2, §6.3).

## 3. What must not change

- **`windowReportPayload`'s byte layout** and the signing call inside
  `closeWindow` — unaffected by every option in §4; by the time any of
  them can act, the report is already fully constructed and signed. The
  gap is entirely about ledger bookkeeping *after* signing.
- **`WindowReport`'s `Codable` shape** and `WindowReportStore`'s add/load
  contract (`WindowReportStore.swift:77-133`) — unaffected.
- **The sibling gap in §2.4** (open-succeeded, close-never-ran) — its
  existing, tested recovery path is untouched by every option in §4.
- **`prepareNextUnsentWindowSubmission`'s selection ordering and
  idempotency** (`UnsentWindowLedger.kt:265-362`) — every option in §4
  only changes which `LedgerWindow` rows can exist going into this
  function, never its own logic.

## 4. Options

### Option A — native-only: do not hold onto an unregistered window

**Mechanics**: in `openWindow(enin:)`, attempt
`unsentWindowLedgerRuntime.openWindow(windowId:)` *before* setting
`currentWindowId`/`currentWindowEnin`/`lastWindowEnin`/`firstWindowEnin`,
and only set them on success. On failure, none of that state is set —
`currentWindowEnin` stays whatever it was (`nil`, for the common case of a
window that was about to open fresh). Because `advanceWindowIfNeeded`'s
guard is `guard let openEnin = currentWindowEnin else { openWindow(enin:
enin); return }` (`SensingCoordinator.swift:831-842`), every subsequent
detection *within the same ENIN* would retry `openWindow` again — a
transient failure has a real chance of self-healing within the ENIN. A
failure that persists for the ENIN's entire duration means: no
`currentWindowRpids` ever accumulates for it (there is no window state to
hold them), `closeWindow` is never called for it (nothing to close), and
that ENIN's peer observations are never signed or written anywhere — they
are dropped at the moment of the last failed retry, not merely
unregistered.

**For**: fully native, no shared/`AGENTS.md` KMP-001 contract change; the
invariant "every durable `WindowReport` has a ledger window" becomes true
by construction, since native never signs or persists a report without
first confirming ledger registration; matches gh#132's own framing of this
option and requires the smallest code delta of the three.

**Against — real, not dismissed**: this is a real data-loss path, not a
data-hygiene fix. It intentionally discards actual BLE peer observations —
attendance evidence that was genuinely collected — purely because of a
local storage hiccup unrelated to whether the attendance happened. If the
failure is not transient (exactly the condition `blockLedgerWrites`
already models in tests — an unwritable parent directory, which persists
until something external fixes it), **every** ENIN for the rest of the
session drops its window report, silently, with only a `print()` line as
signal — turning a local storage blip into an unbounded reporting
blackout. This also creates a new asymmetry with self-proof: per
`session-end-finalization.md` §7.1/§8.3 (already-approved, sub-slice 3),
self-proof's `eninStart`/`eninEnd` bookkeeping does not depend on
`currentWindowId` at all, so a self-proof could end up attesting to an
ENIN range with no window reports underneath it for the same session — a
new inconsistency between two derived artifacts that does not exist today.
Working-manual invariant 4 (§5.1 below) is directly in tension with this
option's persistent-failure tail.

### Option B — shared contract change: reconcile adopts unmatched artifacts

**Mechanics**: change `reconcileUnsentWindowLedgerAfterRelaunch`
(`UnsentWindowLedger.kt:225-263`) so that, in addition to its existing
traversal over `ledger.state.windows`, it also considers
`recoveryInput.observations` entries whose `windowId` has **no**
corresponding `LedgerWindow` row at all, and synthesizes one — already
closed, in the same reconciliation transition — instead of silently
ignoring it. Concretely, as a delta to the existing function body:

```kotlin
val existingIds = ledger.state.windows.map { it.windowId }.toHashSet()
val matchedWindows = ledger.state.windows.mapNotNull { window ->
    /* unchanged existing logic from :249-259 */
}
val orphanIds = recoveryInput.observations.keys
    .filter { it !in existingIds }
    .sorted() // deterministic order; native never assigns a real sequence to these
val synthesizedWindows = orphanIds.mapIndexed { offset, windowId ->
    LedgerWindow(
        windowId = windowId,
        openedSequence = ledger.state.nextWindowSequence + offset,
        closedRevision = revision,
        observationReference = recoveryInput.observations.getValue(windowId),
    )
}
if (matchedWindows.size + synthesizedWindows.size... /* capacity check, see vectors */)
return ledger.persistenceRequired(
    ledger.state.copy(
        revision = revision,
        nextWindowSequence = ledger.state.nextWindowSequence + synthesizedWindows.size,
        windows = matchedWindows + synthesizedWindows,
    ),
)
```

This also requires widening the early-exit guard at `UnsentWindowLedger.kt
:238` (`if (ledger.state.windows.none { it.closedRevision == null }) return
ledger.unchanged()`) — today this guard no-ops reconciliation whenever
there is no currently-open `LedgerWindow` row, which is exactly the state
after a failed open with nothing else pending (zero open rows). Under
Option B the guard must also check whether `recoveryInput` contains any
`windowId` absent from `ledger.state.windows`, or the fix does not fire
for gh#132's own case even after adding the synthesis logic above.
`reconciledSnapshotFits` (`UnsentWindowLedger.kt:600-641`) — the pre-check
against `MAX_LEDGER_SNAPSHOT_BYTES` (8 MiB) and `MAX_LEDGER_RECORD_COUNT`
(100,000, both `UnsentWindowLedgerSnapshot.kt:4-5`) — must extend to
account for synthesized rows' encoded size too, or a large batch of
orphans discovered at once could pass a stale pre-check and then fail
encoding, or the reverse.

**Vectors needed** (per `docs/kmp-shared-foundation.md` §4 Step 1's null /
missing / empty / boundary / duplicate / unknown-field discipline):

1. Exactly one `recoveryInput` `windowId` absent from `ledger.state
   .windows`, ledger otherwise has zero windows → it is synthesized as
   already-closed and becomes selectable by `prepareNextUnsentWindowSubmission`.
   Reuses the existing `"not-in-this-ledger"` key already present in
   `relaunchRecoveryClosesDurableObservationsAndDiscardsOnlyUnrecoverableOpenWindows`
   (§2.5) — add the missing assertion to that test rather than duplicating
   its setup in a new one.
2. Same, but `ledger.state.windows` is already at `MAX_LEDGER_RECORD_COUNT`
   — boundary: must fail closed (`ledger_capacity_exceeded`), not silently
   drop the orphan or exceed the cap.
3. Two orphaned `windowId`s in the same `recoveryInput`, with no real
   chronological order recoverable (native never recorded an
   `openedSequence` for either, since `openUnsentWindow` never ran) — must
   assign `openedSequence`/ordering deterministically so repeated
   reconciliation of the same input is idempotent, not merely
   non-crashing.
4. An orphaned `windowId` that collides with a `windowId` already present
   as a currently-open (`closedRevision == null`) `LedgerWindow` row —
   should not be reachable given native always mints a fresh UUID per
   window, but the reducer cannot assume a native invariant it does not
   itself enforce; needs an explicit decision (documented failure, e.g.
   `duplicate_window_id`-shaped, rather than silently picking one).
5. Empty `recoveryInput` with existing unclosed `LedgerWindow` rows present
   — regression boundary: must remain exactly today's discard-if-unmatched
   behavior (§2.4), unaffected by this option.
6. A batch of orphans large enough to approach `MAX_LEDGER_SNAPSHOT_BYTES`
   on its own — `reconciledSnapshotFits`'s incremental size accounting
   must include the synthesized rows, not only the existing matched-window
   delta it already accounts for.

**Invariants touched** (`docs/kmp-shared-foundation.md` §5):

- **Invariant 4** ("crash 後の復元で pending / in-flight を失わない") — this
  is the invariant Option B satisfies that Option A's persistent-failure
  tail does not; the orphaned artifact is a durably-captured, signed
  observation by any reasonable reading of "pending," and today's
  reconcile function fails to preserve it (§2.3).
- **Invariant 5** ("...各 window の所属は一意である") — vector 4 above exists
  specifically to keep this true under the new synthesis path.
- **Invariant 9** ("ledger snapshot は shared codec で round-trip し...") — a
  synthesized `LedgerWindow` reuses the exact same data class and the
  exact same `persistenceRequired`/snapshot-codec path as a naturally
  opened-then-closed one, so round-tripping should hold by construction;
  `UnsentWindowLedgerSnapshotTest.kt` must still be run to confirm this
  rather than assumed.
- Does **not** touch invariant 8 (facilitator-spec canonical encoding —
  §3) or invariant 10 (signer boundary — §3).

**For**: the only option that closes the gap for both halves of the
problem at once — the report is never dropped, and it re-enters
`prepareNextUnsentWindowSubmission`'s selection. No native change, no
change to what gets signed. Generalizes: it also protects any *future*
caller path that could produce a durable artifact whose ledger
registration failed for a reason other than gh#132's specific one, since
the fix is in the one shared function every recovery path already funnels
through, rather than a fix scoped to this one native call site.

**Against — real, not dismissed**: a genuine `shared`/KMP-001 contract
change to a function every current and future platform inherits (including
Android once #121 lands — §7). The synthesis logic (deterministic ordering
for simultaneous orphans, capacity accounting) is new complexity in code
whose current contract is deliberately simple ("only touch what's already
there"). It also **reverses a documented invariant**, not just extends
one: the doc comment's own third clause, "unrelated old artifacts are
ignored," becomes false — Option B's whole point is that some previously
"unrelated" artifacts are now adopted. Today, a `LedgerWindow` existing in
`ledger.state.windows` is proof that `openUnsentWindow` succeeded at some
point (an explicit, checked event); after Option B, a `LedgerWindow` can
also come into existence purely from a native-supplied
`(windowId, reference)` pair with no corresponding successful open call
ever having happened. Every future reader of this module has to know
about this second path into existence. Reversing a documented invariant is
exactly the class of change `docs/kmp-shared-foundation.md`'s review gate
(independent-review requirement) exists for.

### Option C — native retry-and-defer, found during this session's reading

Neither gh#132 nor the SubPM's task framing names this option; it emerged
from tracing §2.1–§2.2 closely and noticing that Option A's real cost (data
loss) and Option B's real cost (a reversed shared invariant) both stem from
treating a failed open as final at the moment it happens, when the
existing codebase already has a working pattern for exactly this shape of
problem one call away: `windowReportRedeliveryBuffer`
(`SensingCoordinator.swift:9-34`, already used to retry *report-write*
failures on the next detection, `SensingCoordinator.swift:966-974`).

**Mechanics**: track whether the currently-open window's ledger
registration actually succeeded (a `windowIsLedgerRegistered: Bool`
alongside `currentWindowId`, or equivalently treat "ledger open still
outstanding" as its own state). While unregistered, keep accumulating
`currentWindowRpids` as normal (nothing is lost yet), and retry
`unsentWindowLedgerRuntime.openWindow` on every subsequent detection within
the same ENIN — cheap, and gives a transient failure many chances to
self-heal before the ENIN boundary is reached, unlike Option A's plain
non-retrying version. At the ENIN boundary (or explicit stop/checkpoint)
while still unregistered, attempt the open one more time synchronously
immediately before `closeWindow`; if it still fails at that point, fall
back to Option A's drop-and-log for that one window only (a bounded,
single-window loss instead of an unbounded one).

**For**: strictly narrows Option A's real cost for the presumably-more-
common transient case (every detection is a retry opportunity, not just
the ENIN boundary), without any shared contract change or reversed
invariant.

**Against**: does not eliminate Option A's core problem, only shrinks its
likelihood — a failure that persists across an entire ENIN (the same
condition `blockLedgerWrites` models) still drops that window's data, so
this option does not fully satisfy invariant 4 the way Option B does. Adds
new native state and retry-timing complexity: retrying on every detection
inside a synchronous BLE callback path risks masking a persistent problem
behind many rapid, silently-failing attempts, and introduces a *third*
distinct "why did this window's report never appear" code path (clean
report / report-write redelivery / now also open-retry-then-drop) for
future readers to reason about, on top of the two that already exist.

## 5. Recommendation: Option B

Reasoned against the alternatives, not asserted:

1. **Only Option B fully satisfies invariant 4 without a residual
   persistent-failure tail.** Options A and C both drop real, durably-
   observable attendance data when the underlying storage failure outlasts
   their retry window (A: immediately; C: across one ENIN) — a difference
   of degree, not of kind. Option B has no such tail: whatever got durably
   signed is recoverable at the next relaunch, unconditionally.
2. **The report is already fully produced by the time the gap
   manifests.** §2.2 shows `closeWindow` signs and durably writes the
   `WindowReport` independently of the ledger's own state — the expensive,
   security-relevant work (signing real attendance evidence) has already
   happened by the time any option's logic runs. Discarding that report
   (A's and C's fallback) throws away completed, valid work for a reason —
   a local ledger bookkeeping hiccup — that has nothing to do with whether
   the attendance itself was real. That is a harder outcome to justify to
   a user or a future verifier than "recovered one launch late."
3. **This repo has already chosen this exact shape once, for a sibling
   gap.** `docs/specs/session-end-finalization.md` §7.1 chose "persist
   incrementally, reconcile on next launch" (Option B there) over
   "finalize proactively at every lifecycle point" specifically because it
   "does not depend on any lifecycle callback firing at all" and matches
   `DECISIONS.md`'s 2026-07-26 precedent ("強制終了で未送信が残れば次回に
   まとめて送る" — flush what's pending on the next opportunity). This
   spec's Option B is the same shape applied to a sibling problem in the
   same file family: catch up durably-captured data on the next cold
   launch rather than trying to prevent every way the live path can fail.
4. **The cost is real but bounded and contained.** It touches one
   function's contract and one existing call site
   (`reconcileAfterRelaunch`), reuses the existing `LedgerWindow` data
   class and the existing capacity/snapshot-size guards (extended, not
   replaced), and does not introduce a new subsystem, store, or
   lifecycle hook. Its real cost — the reversed "unrelated artifacts are
   ignored" doc-comment clause (§4, Option B "Against") — is a
   documentation/invariant-statement cost future readers must absorb, not
   a behavioral risk to any currently-shipped path: the existing
   matched-window reconcile logic is untouched, and the new path only ever
   produces windows that are immediately closed, never a new "half-open
   recovered window" state for other code to reason about.

## 6. Acceptance criteria

Matching gh#132's own three criteria, plus this document's additions:

1. **(gh#132 AC 1)** A report whose ledger-window `open` call failed must
   end up in the ledger's eventual send set
   (`prepareNextUnsentWindowSubmission`'s candidate selection) after the
   next relaunch. This spec's answer: **included**, via Option B's
   relaunch-time reconciliation — never explicitly discarded.
2. **(gh#132 AC 2)** The choice must be recorded in a shared-side contract
   document. This document is that record. In the same PR that implements
   Option B, `reconcileUnsentWindowLedgerAfterRelaunch`'s doc comment
   (`UnsentWindowLedger.kt:219-224`) must be rewritten to state the new
   contract ("artifacts with no matching `LedgerWindow` are adopted as
   already-closed windows, not ignored") — a stale doc comment
   contradicting shipped behavior would fail this criterion even if the
   code itself is correct.
3. **(gh#132 AC 3 + this document)** A test proving a report from a
   failed-open window does not stay orphaned across a relaunch:
   - Shared: extend `relaunchRecoveryClosesDurableObservationsAndDiscardsOnlyUnrecoverableOpenWindows`
     (`UnsentWindowLedgerReducerTest.kt:485-578`) with an assertion on its
     existing, currently-unused `"not-in-this-ledger"` key — after
     reconciliation, it must be closeable/selectable rather than
     `unknown_window_id` — reusing the existing vector setup per this
     repo's own reuse-over-duplication practice, rather than a wholly new
     test class. Add the capacity-boundary vector (§4 Option B, vector 2)
     as a new test, since no existing test approaches
     `MAX_LEDGER_RECORD_COUNT`.
   - iOS: new test extending the `RecoverableReportFailureFixture` pattern
     already used by `testUnknownWindowAtRedeliveryHeadIsDiscardedBeforeLaterArtifact`
     (`UnsentWindowLedgerRuntimeTests.swift:375-434`) — block ledger
     writes, drive a detection so `openWindow` fails while `currentWindowId`
     stays set (§2.1), restore writes, let the window close and durably
     write its report while the ledger close is rejected
     `"unknown_window_id"` (§2.2, exactly as the existing test already
     demonstrates in-process), then construct a **fresh**
     `SensingCoordinator`/`UnsentWindowLedgerRuntime` pair against the same
     files (simulating relaunch, the same pattern
     `testRelaunchRecoversAReportWrittenBeforeLedgerCloseAndDiscardsAnEmptyOpenWindow`
     already uses, `UnsentWindowLedgerRuntimeTests.swift:559-621`) and
     assert the previously-orphaned window is now closeable/selectable.
4. **`testUnknownWindowAtRedeliveryHeadIsDiscardedBeforeLaterArtifact`'s
   existing assertions must not be weakened.** Per §2.5, that test
   describes in-process, pre-relaunch behavior against a ledger that has
   never gone through `reconcileAfterRelaunch`; Option B only changes what
   the *next cold launch's* reconciliation does, not what a live
   coordinator sees immediately after a rejected close. Its existing
   `orphanedClose.errorCode == "unknown_window_id"` assertions remain
   correct and must still pass unmodified.
5. **Full covering suite, not a targeted subset**, per
   `docs/kmp-shared-foundation.md` §6 "test scope": all of
   `UnsentWindowLedgerReducerTest.kt`, `UnsentWindowLedgerSnapshotTest.kt`,
   `UnsentWindowLedgerRuntimeTests.swift`, `UnsentWindowLedgerStoreTests.swift`,
   `WindowReportFinalizationTests.swift`, and
   `WindowReportStoreDurabilityTests.swift` must pass unmodified except for
   the one reconcile test's added assertion (criterion 3).
6. **No change to `windowReportPayload`'s byte layout, `WindowReport`'s
   `Codable` shape, or the signer boundary** (§3) — verified by the
   existing golden-vector/payload tests continuing to pass unmodified.

## 7. Both-OS note

Per `AGENTS.md`'s both-OS feature rule and its own standing statement that
"Android currently has only the Event Join screen, and
`EventJoinCoordinator` stops at `Idle`, `RequestingPermission`, `Sensing`,
or `PermissionDenied`" — there is no Android production caller of any part
of the window-report/ledger family yet; Android production wiring for this
entire family remains deferred to Issue #121. This document's fix (Option
B) lands entirely in `shared/` (the reducer function and its doc comment)
plus the iOS-only native call sites that already exist
(`UnsentWindowLedgerRuntime`, `SensingCoordinator`). There is no Android
call path to update because none exists yet for this family — this is the
already-accepted gap `AGENTS.md` documents, restated here rather than
re-litigated, per this task's instruction. Acceptance criteria and tests
in §6 are therefore iOS + shared only, with no new Android UI required.
One consequence worth noting explicitly: because the fix lives in
`shared/` rather than in a native call site, whoever eventually wires
Android's own ledger runtime for #121 inherits this corrected reconcile
contract automatically — they will not need to discover or re-fix gh#132's
gap a second time on the Android side, which Option A or C (both entirely
native-only, and thus both iOS-only fixes with no shared-side effect)
would not have guaranteed.
