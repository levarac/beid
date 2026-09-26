# Issue #701 — storing which report belongs to which Proof / session

**Status:** approved by the PM 2026-09-27; implemented in phase 2. Written
against `design/flat-2b` at `62531fe` (the base of
`work/issue-701-report-link`). Every `file:line` below was re-read at that
commit. The PM's picks are recorded in §8.

**Binding limits this design must meet** (DECISIONS.md 2026-09-27, the
"見送っていた 3 件" entry, item (2) and lines (a)–(d)):

- Do not change what is sent or signed.
- The new data never enters submission, signing or public data (#145; the
  same treatment as rule 13).
- Do not reimplement Barnard protocol semantics (KMP-002).
- Do not create guessed values for old records.

## 0. Summary

- **What is stored:** one row per closed observation window, with two
  fields: `windowId` (the UUID the window already has) and `proofId` (the
  UUID of the Proof that was active when the window closed). Nothing else is
  stored.
- **Where:** a new native-only iOS file, `Documents/report-proof-links.json`,
  in a new `ReportProofLinkStore`. It is **not** a field on
  `ReportSubmissionRecord` or `ReportSubmissionCapture`, and it is never
  passed to `ReportSubmissionRuntime`. Nothing changes in `shared/`.
- **When:** `SensingCoordinator.closeWindow` writes the row immediately
  before it hands the window to the submission runtime. At that moment
  `activeProofId` is the current session's Proof, with no exceptions in
  production code (§A).
- **Old data:** no backfill. Every record written before this change stays
  unlinked, and screens 09, 11 and 12 show exactly what they show today for
  those records.
- **Screens:** 09 gains `FROM REPORTS`, 11 gains `INCLUDED IN REPORTS`, and 12
  gains a session row under `OBSERVATIONS INCLUDED` and a proof section,
  mapped to the measured Figma frames in §6. Each appears only when a link
  row exists **and** the linked Proof is present in `ProofStore`.
- **Android:** deferred, because Android has no 09, 11 or 12 surface yet. A
  follow-up issue is named in §5.

## Premises in the brief that the code contradicts or refines

1. **"Report ↔ Proof is N:N"** (issue #641 body). This is false in the
   current code. A `ReportSubmissionRecord` is one window's single canonical
   Observation, and its `id` *is* the window id
   (`ReportSubmissionRuntime.swift:243-252`, `:354-355`). A window belongs to
   exactly one sensing session (§A). The relation is therefore **report → at
   most one Proof**, and **Proof → zero or more reports**. `PROOFS EARNED` on
   screen 12 has at most one row.
2. **"09 STATUS is always Sealed in v1.0"** (DECISIONS 2026-09-23). The code
   does not do this. `ItemDetailView.swift:28-34` shows `Sealed` only when a
   `SelfProofRecord` exists, and `Recorded on device` otherwise. The 08 proof
   row does the same (`EventDetailView.swift:388-401`). This design reuses the
   code's conditional state and does not change 09. The divergence is flagged
   for the PM in §8, OD-4.
3. **"Android may not have ReportSubmissionStore at all."** Android has an
   equivalent under another name: `SubmissionRecord` / `SubmissionRecordStore`
   (`android/app/src/main/kotlin/org/levarac/beid/persistence/SubmissionRecord.kt:37-50`,
   file `submission-records-v1.json` at `SubmissionRecordStore.kt:99`). It
   holds operator configuration, receipt and digest per `windowId`. The signed
   bytes themselves live in the shared unsent-window ledger. It is written at
   window **open**, not close (`WindowObservationAccumulator.kt:348-362`).
4. **"Is there any session ordinal?"** Yes, but it is not stored. Event
   Detail derives `Session N` at display time: it takes the event's Proofs
   sorted by `Proof.date` ascending and uses the 1-based position
   (`EventDetailView.swift:28-31`, `:106-108`, `:155-161`). It passes that
   number to screen 11 as `sessionNumber` (`EventDetailView.swift:126`,
   `ObservationDetailView.swift:52`, `:98-104`).
5. **"Pending captures survive process death."** True for *closed* windows
   (`ReportSubmissionStore.swift:268-269`, `:335-348`). An iOS window that is
   still **open** when the process dies is lost, because iOS keeps no draft
   of it (`closeWindow` is the only capture point,
   `SensingCoordinator.swift:4287`). Android does keep drafts (§5).
6. **The window id is not secret.** It is the Observation `id` inside the
   signed bytes (`ReportSubmissionRuntime.swift:315`), so the operator already
   receives it. The new information is the Proof id and the association.
   Today no code path sends a Proof id off the device (§3).

## A. When the link is known for certain

### The code path

1. **Proof creation.** A shared-reducer result of `confirmedEvent` calls
   `beginRecording` (`SensingCoordinator.swift:1944`). That function mints
   `proofId` and sets `activeProofId`, then emits the Proof
   (`SensingCoordinator.swift:3760-3763`). `AppCoordinator` persists the Proof
   with `proofStore.add` (`AppCoordinator.swift:194-196`).
2. **Window ledger opens only at `.recording`.** `observe` calls
   `ensureLedgerWindowOpen()` only when `result.resultingPhase == .RECORDING`
   (`SensingCoordinator.swift:1856-1857`). That call sets
   `currentWindowLedgerOpened = true` (`:4169`). This is DECISIONS 2026-08-09
   #114 Option B (DECISIONS.md:283).
3. **Every window close is gated on that flag.** There are three triggers,
   and all of them reach `closeWindow` only when `currentWindowLedgerOpened`
   is true:
   - ENIN boundary: `advanceWindowBookkeepingIfNeeded`, `:4121-4122`.
   - Explicit stop / `CLOSE`: `closeFinalWindowIfNeeded`, `:4194-4201`.
   - Backgrounding checkpoint: `checkpointOpenWindowForBackgrounding`,
     `:4239-4246`.
4. **The capture is created inside `closeWindow`.** `closeWindow` calls
   `reportSubmissionRuntime?.captureAndQueueWindow(id: currentWindowId, …)`
   (`:4287-4295`). The runtime persists a `ReportSubmissionCapture` with that
   `id` (`ReportSubmissionRuntime.swift:243-254`). The capture later becomes a
   `ReportSubmissionRecord` with the same `id`, either in the same process or
   after a relaunch (`:262-285`, `:354-378`).
5. **Session end clears both flags together.** `activeProofId` is set only at
   `:3761` and cleared only in `resetSessionState()` (`:2908`). The same
   function also clears `currentWindowLedgerOpened` (`:2894`) and the window
   id (`:2885`).
   - `endSensing`, which is the `CLOSE` path, closes the final window
     (`:2842`) **before** `resetSessionState()` (`:2853`). So
     `activeProofId` is still the session's Proof at that close.
   - `startSensing` (`:2422`) and `joinNearbyEvent` (`:3032`) reset without
     closing. That discards any open window, so no capture exists that could
     be linked to the wrong session.

### The certainty argument

For `closeWindow` to run, the flag must be true. The flag is set only after a
`.RECORDING` result in the same session. That result implies `beginRecording`
already ran in this session, either on this detection or on an earlier one.
Both values are cleared together at every session boundary. Therefore, in
production code, **when a capture is created, `activeProofId` is non-nil and
is the Proof of the session that owns the window.**

The window that crosses the threshold may contain RPIDs seen during
`.eventFound` in the same ENIN window. Those detections still belong to the
same session, so the link stays correct.

### Cases that must stay unlinked

| Case | Why | Rule |
| --- | --- | --- |
| `activeProofId == nil` at close | Unreachable in production. It is reachable in DEBUG fixtures that set `phase = .recording` directly without `beginRecording` (`SensingCoordinator.swift:398-400`, `:2992`). A real detection arriving afterwards would open and close a window with no Proof. | Write no link. |
| `reportSubmissionRuntime == nil` (submission build flag off, `ReportSubmissionRuntime.swift:193`, `:552-559`) | No capture or record will exist. | Write no link (data minimisation). |
| Capture finalised after a relaunch | The link was written before the capture in the old process (§2 ordering), so nothing needs to be known after the relaunch. | Nothing extra is needed. Captures that were closed **before this change ships** have no link and stay unlinked (§4). |
| Link write fails (I/O error, unreadable link file) | — | Continue with the capture. Submission must not depend on display metadata. The record stays unlinked permanently, with no retry and no inference. |
| Link exists, but the Proof is missing from `ProofStore` (`ProofStore.save` is best-effort `try?`, `ProofStore.swift:116-120`; persistence can be suspended, `:21-26`) | — | Screens show nothing for the link. Existing link rows are never changed. |
| Link's Proof `eventCode` differs from the record's `eventCode` after normalisation | Cannot happen, because both come from the same `EventSession.id` (`SensingCoordinator.swift:3762`; `closeWindow` receives `currentSessionEventCode`). | Treat as not linked for display (defensive). |
| Multiple sessions of the same event code, including the same ENIN value | Every window has a fresh `UUID()` (`SensingCoordinator.swift:4133`), and every session has a fresh `proofId`. | No ambiguity. This is exactly why eventCode or ENIN inference is forbidden. |
| `ReportSubmissionExclusion` (count-only window, `ReportSubmissionRuntime.swift:216-238`) | It is not a report. | A link row may exist for its window id. No screen reads it. |

## B. Where the link is stored — options compared

### Invariants the storage choice must respect

- `report-submissions.json` is an exact-byte queue. The runtime never
  re-encodes `signedObservationHex` (`ReportSubmissionStore.swift:99-103`).
- `add` is idempotent through `hasSameObservationAndConfiguration`, and a
  mismatch throws `conflictingObservation` (`:223-235`, `:318-332`).
- Any load failure latches and blocks every write, including submission state
  transitions (`:469-473`, `:537-549`).

### (1) Optional `proofId` on `ReportSubmissionCapture` and `ReportSubmissionRecord`

This follows the `Proof.eventCode` precedent (DECISIONS.md:311;
`Proof.swift:37`, `:91`).

- **Pros:**
  - The link is written in the same atomic rename as the capture, so there
    are no orphan links.
  - `decodeIfPresent` keeps old files readable. `ReportSubmissionCapture` uses
    synthesised `Codable`, which treats `Optional` properties as
    if-present automatically.
- **Cons:**
  - **(a)** The proof id must be passed through
    `WindowReportSubmissionRuntimeProtocol.captureAndQueueWindow`
    (`ReportSubmissionRuntime.swift:118-126`). That is the only type that
    builds evidence, signs and POSTs. The guarantee then becomes "nobody reads
    it" rather than "it is not there".
  - **(b)** A malformed `proofId` value would fail the whole queue decode and
    latch `loadError`. That **blocks all submissions** (`:469-473`), so a
    display-only field could stop delivery.
  - **(c)** `hasSameObservationAndConfiguration` would have to decide whether
    a local display fact is part of "the same Observation". Either answer
    blurs the rule.

### (2) A separate local table keyed by window id — **recommended**

- **Pros:**
  - `ReportSubmissionRecord`, `ReportSubmissionCapture`, their codecs and
    their equality rules are **byte-for-byte unchanged**.
  - The runtime's API is unchanged. The two existing protocol spies,
    `ReportSubmissionRuntimeSpy` (`ios/BeidTests/ReportSubmissionWiringTests.swift:9-58`)
    and `SignalStrengthContainmentSubmissionSpy`
    (`SignalStrengthNeverRecordedTests.swift`), compile untouched. That fact
    is itself a structural guard.
  - An unreadable link file affects only link display, never submission.
  - It matches the issue's own wording: "端末内の対応表だけを足す" (only add an
    on-device mapping table).
- **Cons:**
  - It is a second file, so a crash between the link write and the capture
    write leaves an orphan link with no record. That is harmless, because no
    screen reads a link without a record.
  - A failed link write leaves an unlinked record. That is honest.

### (3a) A list of record ids on `Proof`

Rejected, for three reasons:

- `Proof`'s "collected fields are immutable once added"
  (`ProofStore.swift:49-51`).
- `ProofStore.save` silently drops failures (`:116-120`).
- It would rewrite `proofs.json`, which holds every Proof, on each window
  close (every 300 s, `ClockPreflightController.swift:65`).

It would also widen the #155 surface (DECISIONS.md:328) for no gain.

### (3b) Links inside `SessionAggregateSnapshotRecord`

Rejected, for two reasons:

- The snapshot is written only at session end
  (`SensingCoordinator.swift:2841`), so every window closed before a process
  death would lose its link.
- `snapshotText` is a `shared/` codec
  (`SessionAggregateSnapshotRecord.swift:6-9`), so this would be a KMP schema
  change with Swift Export API impact, for native data.

**Recommendation: (2).**

## C. Session identity for frame 12 (`Session 3`)

A "session" in the current code **is a Proof**: one Proof per reach of
`.recording` (`SensingCoordinator.swift:3758-3765`). Event Detail already
numbers sessions at display time (`EventDetailView.swift:28-31`, `:155-161`).
No session number is stored, and this design stores none.

**Derivation.** Given the linked `proofId`:

- `proof = proofStore.proof(withId:)` (`ProofStore.swift:45-47`).
- `sessions = EventGrouping.sessions(for: proof, in: proofStore.proofs)`
  (`EventGrouping.swift:55-58`), sorted by `date` ascending.
- The ordinal is the 1-based index of `proof` in that list.

That is exactly the number 08 shows for the same Proof.

**Implementation requirement:** move this into one helper, e.g.
`EventGrouping.sessionOrdinal(of:in:)`, and have 08, 11 (through 08) and 12
call it, so the three screens cannot disagree. Add `id` as a tie-break when
two dates are equal. Today `sorted { $0.date < $1.date }` leaves equal-date
order to the input order.

**Caveats** (the same ones 08 has today):

- The ordinal is relative to the Proofs currently in the store. No production
  path deletes a Proof (§1), so ordinals do not shift, except when a later
  session gets an earlier `Date()` because the device clock was set back.
- A Proof with `nil` `eventCode` forms a singleton group
  (`EventGrouping.swift:55-56`). A linked Proof can never be one of these,
  because new Proofs always carry `event.id`.

## D. `PROOFS EARNED` truthfulness

A Proof existing means only that the session crossed the confirm threshold on
this device. It does not mean the proof was verified, sent or mutual
(DECISIONS 2026-08-20 "Verified をやめ", 2026-09-23 "VERIFYING も出さない",
2026-08-09 and 2026-09-26 on mutual).

**For each linked Proof** — there is at most one per report (premise 1) —
screen 12 shows:

- the mini Sigil slot for that Proof id (`RecordSigilSlot`, as the 08 proof
  row does at `EventDetailView.swift:341-345`);
- the title `Session K proof`, where K is the derived ordinal from §C (the
  same string key as `EventDetailView.swift:380-386`);
- a subtitle with a state from **the same function 08 uses**
  (`EventDetailView.swift:388-401`), followed by the short record id
  (`RecordIDDisplay.abbreviated`):
  - the state is `SEALED` if and only if a `SelfProofRecord` exists for that
    Proof id, and `RECORDED ON DEVICE` otherwise;
  - never `VERIFIED` (Figma shows `VERIFIED · 9c41…e2a7`, which is forbidden;
    see §6) or `VERIFYING`;
  - never a mutual count;
  - never a sent or accepted claim for the Proof;
- a tap that opens `ItemDetailView(proof:)`.

**The heading word "EARNED"** implies the report caused the proof. In the
code, the Proof is created when recording starts, independently of whether
this report was prepared, sent or accepted. See OD-3 in §8.

## E. Why the link can never leave the device (evidence)

See §3.

---

## 1. What exactly is stored

**Row type** (native Swift, `Codable`, `Equatable`):

| Field | Type | Meaning | Size |
| --- | --- | --- | --- |
| `windowId` | `UUID` | Equals `ReportSubmissionCapture.id` = `ReportSubmissionRecord.id` = `WindowReport.id` = the ledger `windowId`. All are the same `currentWindowId` (`SensingCoordinator.swift:4287-4288`, `:4312`). | 36-char JSON string |
| `proofId` | `UUID` | `Proof.id` of the session active at close (`SensingCoordinator.swift:3760-3761`). | 36-char JSON string |

**Excluded on purpose:**
- no `createdAt`;
- no event code, which is derivable from either end;
- no ENIN;
- no ordinal (§C);
- no copy of anything in the signed bytes.

**File:**
- Location: `Documents/report-proof-links.json`.
- Format: wrapped in `RecordSchemaEnvelope` with `schemaVersion` 1
  (`RecordSchemaEnvelope.swift:57`), as the other new-ish stores do. This
  gives the file a version from day one (#155).
- Write method: a staged write plus `fsync` plus `rename`, the same as
  `ReportSubmissionStore.persistEncoded` (`ReportSubmissionStore.swift:499-535`).

**Keys and semantics:**
- Unique by `windowId`.
- `add(windowId:proofId:)` is idempotent for the same pair.
- A different `proofId` for an existing `windowId` throws
  `conflictingLink`, and the stored row is kept (fail-closed; unreachable by
  §A).
- Error cases carry **no associated values**, so logging
  `String(describing: error)` cannot print an id.

**Load failure:**
- Latch the error. Never overwrite the file, and never treat it as empty
  (the same pattern as `ReportSubmissionStore.swift:537-549`).
- Reads return `.unreadable`, and screens then show no link-derived content.
- Writes throw.

**Size estimate:**
- About 90–100 bytes per row.
- ENIN is 300 s (`ClockPreflightController.swift:65`), so there are at most
  12 closed windows per hour of recording.
- A 10-hour event adds about 12 KB.
- The file is **cumulative** over the app's lifetime, with no pruning, the
  same as `window-reports.json` and `report-submissions.json`. For example,
  100 hours of recording in total is about 1,200 rows, or about 115 KB.
- The whole file is rewritten on each close, the same cost class as the
  existing per-close writes flagged in the TODO at
  `SensingCoordinator.swift:4319-4327`.

**Retention and deletion:**
- **No production path deletes a Proof or a `ReportSubmissionRecord` today.**
  - `ProofStore` has only add and update (`ProofStore.swift:40-67`). Its only
    removal is `resetForUITesting()` (`:131-136`), which is reachable only
    under `-beid-ui-test` in DEBUG (`AppCoordinator.swift:189-193`).
  - `ReportSubmissionStore` removes pending captures only
    (`ReportSubmissionStore.swift:365-372`).
- There is no in-app reset. The Account "leave" was removed (DECISIONS
  2026-09-23).
- The link therefore lives exactly as long as the records it joins, and is
  removed with them when the app is uninstalled (Documents container).
- **Backup (OD-5 (b)):** the link file is excluded from device backup with
  `URLResourceValues.isExcludedFromBackup`. Each write replaces the file by
  `rename`, which drops the flag, so it is set again after every successful
  rename, and once more after a successful load. A failure to set it does
  not fail the write, because the row is already durable: it is logged with
  a fixed string, recorded in `isBackupExclusionPending`, and retried on the
  next write or launch. The other Documents stores are unchanged; whether
  they should also be excluded is #704.
- **Rule for the future:** any change that adds deletion of a Proof or a
  report record must delete the matching link rows in the same change. The
  implementation PR adds a doc comment on the store stating this. No unused
  delete API is added now.
- The DEBUG UI-test reset (`AppCoordinator.swift:189-193`) and the isolated
  fixture file pattern (`AppCoordinator.swift:119-127`) must also cover the
  link file.

## 2. Where

### iOS

- **Store:** new `ios/Beid/Persistence/ReportProofLinkStore.swift`,
  `@MainActor final class ReportProofLinkStore: ObservableObject`, with
  `init(fileURL: URL? = nil)`.
- **Construction:** `AppCoordinator` constructs it next to
  `ReportSubmissionStore` and injects it into `SensingCoordinator`.
- **Writer:** `SensingCoordinator.closeWindow` is the only writer, placed
  immediately **before** `reportSubmissionRuntime?.captureAndQueueWindow`
  (`SensingCoordinator.swift:4287`), and guarded by
  `reportSubmissionRuntime != nil` and `let proofId = activeProofId`.
- **Order:** link first, then capture. A crash between the two leaves an
  orphan link (invisible). The reverse order could leave a capture whose link
  can no longer be known after a relaunch.
- **Failure handling:** a write failure is logged with a fixed message and no
  ids, and the capture proceeds.
- **Cost:** this is **one more synchronous whole-file rewrite on the MainActor
  BLE path per window close.** It is the same class as the writes the TODO at
  `SensingCoordinator.swift:4319-4327` already names. The same close already
  rewrites, synchronously:
  - `window-reports.json`;
  - the unsent-window ledger snapshot;
  - `report-submissions.pending.json` (`addPendingCapture`,
    `ReportSubmissionStore.swift:335-348`);
  - `report-submissions.json`, when the record is added.

  The added cost is one staged write, `fsync` and `rename` of the link file,
  at most once per 300 s ENIN window. The file is small per event, but it
  grows with lifetime use (§1: about 115 KB after 100 recorded hours).
- **This does not change the #134 deferral.** DECISIONS 2026-08-09
  (gh#134 Decision 2) kept the per-close whole-file rewrite, both its format
  and its actor, until the pruning / send-path follow-up. The link store
  follows whatever that follow-up decides for its siblings, and this proposal
  does not pre-empt it.
- **Readers:** `ItemDetailView` (09), `ObservationDetailView` (11, through
  `EventDetailView`) and `ReportDetailView` (12).
- **`ReportSubmissionRuntime` never receives the store or the id.**

### Android

Android has `SubmissionRecordStore` (premise 3) but **no Flat 2b 08, 09, 11
or 12 surfaces**. The screens are `RecordsScreen` and `RecordDetailScreen`,
under `android/app/src/main/kotlin/org/levarac/beid/ui/screens/`. The
Both-OS reason for leaving Android untouched in the iOS PR is the "Android
production flow does not exist yet" boundary. `issue-627-flat-2b.md` states
"iOS first; Android later". What Android must do is in §5.

### `shared/`

- **Class:** per `docs/kmp-shared-foundation.md` §1, this is a C / INVENT
  native persistence fact with **no shared symbol**.
- **Why not shared:**
  - The value comes from native lifecycle state. `activeProofId` is native on
    both OSes: `SensingCoordinator.swift:1088` and `EventJoinCoordinator.kt:294`.
  - The file is read by one platform on one device. This is the reasoning
    already recorded for the sibling stores at
    `RecordSchemaEnvelope.swift:12-31`: a second platform persisting its own
    format is not a second reader.
  - Nothing here is a decision both apps must compute identically from the
    same input.
- **No Swift Export package or name changes** (AGENTS.md "Swift Export
  package names are API").
- **The only candidate for later sharing** is the session-ordinal rule (§C),
  once Android gets an Event Detail. It should be classified then (§5), not
  now.

## 3. What never leaves the device

The link (Proof id + association) must never reach any of the following.
Each is shown from the code.

1. **Submission POST body.** `SubmissionClient.submitOnce` sends
   `body = observation.signedBytes` with two constant headers
   (`shared/src/commonMain/kotlin/org/levarac/parallax/submission/SubmissionClient.kt:64-84`).
   - `observation` comes only from
     `restoreStoredObservation(record.signedObservationHex)`
     (`ReportSubmissionRuntime.swift:406-407`).
   - The configuration comes only from the seven named record fields
     (`:536-550`).
   - The receipt lookup is a GET with the digest in the URL (`SubmissionClient.kt:86-100`).
   - Neither the link store nor a `proofId` is reachable from
     `ReportSubmissionRuntime`, because the design never passes either in.
2. **Signed bytes (COSE Observation).** The evidence is built only from
   capture fields (`ReportSubmissionRuntime.swift:313-326`). The signature
   input is `eligible.prepared.signatureStructure` (`:341-347`).
   `ReportSubmissionCapture` is unchanged and has no proof field. The legacy
   `WindowReport` signed payload is `eventCode ‖ ENIN ‖ commit ‖ sorted
   RPIDs` (`SensingCoordinator.swift:4392-4400`) and is also unchanged.
3. **Public data.** There is no publication schema or publication code
   (`docs/decisions/issue-145-privacy-schema.md` §1). Nothing in this design
   adds any.
4. **Lab host.** `LabRecordMetadata` has six fixed fields
   (`ReportSubmissionRuntime.swift:21-28`). It is built at
   `ReportSubmissionStore.swift:279-292` and sent by
   `ios/Lab/LabControlBootstrap.swift:236`. The link must not be added there.
   The byte-scan test in §7 T5 covers it.
5. **Logs.** New log lines use fixed strings. The link store's errors carry
   no payload, so the existing `\(String(describing: error), privacy: .public)`
   pattern (`ReportSubmissionRuntime.swift:256`) cannot print a UUID. This is
   a review item: `os_log` output is not practically testable in unit tests.
6. **Analytics.** None exists. `git grep -i
   'analytics\|telemetry\|crashlytics\|firebase\|sentry' -- ios/Beid
   ios/project.yml` returns 0 hits.
7. **Share / pasteboard.** There is no share sheet. Pasteboard writes are the
   wallet address, Event ID and WalletConnect URI only
   (`AccountSheetView.swift:264`, `:284`; `VenueSignedServingView.swift:310`;
   `WalletConnectView.swift:251`).
8. **Legacy `WindowReportStore` and the shared unsent-window ledger.**
   Neither receives the link:
   - **`window-reports.json`** (`WindowReportStore.swift:56`) stores
     `WindowReport`, whose fields are id, eventCode, enin, peerCount,
     commitHex and the signature parts, plus signedAt
     (`WindowReport.swift:12-23`). `closeWindow` builds it from
     `currentWindowId`, `eventCode`, `enin`, the peer count, `commit` and the
     signature (`SensingCoordinator.swift:4311-4318`). There is no proof
     field, and the link write does not touch this code.
   - **`unsent-window-ledger.snapshot`** (`UnsentWindowLedgerStore.swift:209`)
     is written by the shared codec. Its runtime API accepts only `windowId`
     and `persistedObservationReference`
     (`UnsentWindowLedgerRuntime.swift:14-23`, `:61-75`). The reference is
     the `WindowReport` id string, and the link store is never passed in.
   - Both files are added to the byte scan in T5.
9. **Device backup — excluded (OD-5 (b)).** `Documents` is included in
   iCloud/device backup, and before #701 `isExcludedFromBackup` appeared
   nowhere in `ios/`. The link file is excluded from backup (§1, "Backup").
   `proofs.json` and `report-submissions.json` are still backed up; that
   broader question is #704. Android sets `allowBackup="true"` with no rules
   (`android/app/src/main/AndroidManifest.xml:16`); the Android follow-up
   (§5) must decide the same for its link file.

## 4. Existing records

- **No inference and no backfill.** No migration writes link rows. This
  applies to existing `report-submissions.json` records and to pending
  captures that were closed before the upgrade and finalised after it. Link
  rows are written only inside `closeWindow`, at the moment of certainty.
- **Decode of old files is untouched.** Under option (2),
  `ReportSubmissionRecord.init(from:)` (`ReportSubmissionStore.swift:176-199`)
  and the synthesised `ReportSubmissionCapture` decoding are not modified. An
  old queue file decodes byte-for-byte as today.
- **A missing link file** (every existing install) loads as an empty table,
  following `guard FileManager.default.fileExists … else { return }` as at
  `ReportSubmissionStore.swift:538`. Every existing record is therefore
  "unlinked".
- **What users see for unlinked records** is today's state:
  - 12 shows no session row and no proof section.
  - 09 and 11 show no `FROM REPORTS` / `INCLUDED IN REPORTS` section.
  - There is no "link unavailable" notice.
- **Downgrade** (an older build reading a newer install): the older build
  ignores the unknown file. There is no supported downgrade path
  (`RecordSchemaEnvelope.swift:33-43`).

## 5. Both OSes

- **iOS:** implement now as in §1–§2.
- **Android — deferred.** Open (not opened by me) an issue titled, for
  example, "Android: store report ↔ Proof link at window open (follow-up to
  #701)". It should state:
  1. **Write at window open, not close.** Android's durable submission row is
     written at open (`WindowObservationAccumulator.kt:348-362`), and a
     crash-recovered draft is promoted without ever reaching close
     (`:698-728`). `activeProofId` is set by `onPhaseDecided` **before**
     `windowAccumulator?.observe(recording = …)` in the same call
     (`EventJoinCoordinator.kt:884-891`, `:912-913`). So the recording
     session's Proof id is known when the window first opens.
  2. **Windows re-created from a draft by `restoreDurableDraftEvidence`**
     (`WindowObservationAccumulator.kt:726-728`) have no live session. They
     must stay unlinked unless the open-time link row already exists.
  3. **Verify the process-scoped accumulator.**
     `ProcessWindowObservationRuntimeOwner` (`EventJoinCoordinator.kt:152`,
     `:276-286`) can outlive one coordinator instance. The follow-up must
     prove, with a test, that a window opened under coordinator A is never
     linked to coordinator B's Proof, for example after Activity recreation.
  4. **Session end already closes the window before clearing the Proof id**
     (`EventJoinCoordinator.kt:983`, then `:991` → `:1034`).
  5. **Storage:** use a separate `JsonRecordFileStore` file, e.g.
     `report-proof-links-v1.json`, for the same reasons as iOS option (2). Do
     not add a field to `SubmissionRecord`, whose `init` invariant is about
     configuration (`SubmissionRecord.kt:51-55`).
  6. **UI** lands with Android's Flat 2b 08, 09, 11 and 12. Classify the
     session-ordinal rule (§C) for `shared/` at that point.
  7. **Run `scripts/mutation_check.py`** on the new Kotlin store and
     accumulator change.

## 6. UI — what changes and exactly what is shown

### Figma as measured

**Source.** SubPM a-20260927-002 read file `xf2uFHceIYg0h0gJndUkmI`, node
`183:2` ("Flat 2b — Screens") with Figma `get_metadata` on 2026-09-27 and
relayed the text nodes in document order. I did not read Figma myself; the
record below is the SubPM's measurement.

- **09 Proof Detail (`184:353`):**
  - `Attendance Proof`
  - KV rows: METHOD `Bluetooth sensing` | RECORD ID `9c41…e2a7` | STATUS
    `Sealed` | SIGNATURE `Bound to wallet` | WITH `15 peers · 6 windows`
  - section `FROM REPORTS`
  - row `Report #1` / `8f2c…4a91 · SESSIONS 1, 2` / `→`
  - row `Report #2` / `3d1a…77c2 · SESSION 3` / `→`
  - The report rows carry no status text, and the heading carries no count.
- **11 Observation Detail (`188:2`):**
  - `Session 1`
  - `MAR 26 · 10:02 – 10:44 · 6 WINDOWS`
  - … SENSING DATA …
  - section `INCLUDED IN REPORTS`
  - row `Report #1` / `8f2c…4a91 · SESSIONS 1, 2` / `ACCEPTED`
  - The heading carries no count.
- **12 Report Detail (`188:50`):**
  - `Report #2`
  - `SUBMITTED MAR 26, 17:30`
  - RECORD rows: REPORT ID `3d1a…77c2` | RECORDED ON DEVICE `6 WINDOWS` | NOT
    SUBMITTABLE `1 WINDOW · COUNT ONLY` | MUTUAL OBSERVATION `NOT YET
    AVAILABLE` | SENT `MAR 26 · 17:30` | ACCEPTANCE RECEIPT `RECEIVED` |
    PUBLISHED `NOT YET AVAILABLE`
  - section `OBSERVATIONS INCLUDED`, row `Session 3` / `16:30 – 17:11` /
    `31 PEERS` (no arrow)
  - section `PROOFS EARNED · 2`, with two rows:
    - [mini sigil] `Attendance Proof` / `VERIFIED · 9c41…e2a7` / `→`
    - [mini sigil] `Contributor Proof` / `VERIFIED · 9c42…b118` / `→`
  - `WHAT WE SEND →`
- **08 Event Detail (`184:227`), for context:**
  - report rows `Report #1` / `8f2c…4a91 · SESSIONS 1, 2` / `ACCEPTED`
  - proof rows `Attendance Proof` / `SEALED · FROM R1, R2` / `→`

### Where Figma's model and the code's model differ

**Figma draws a report as a batch that can span sessions and earn several
proofs. In the code a report is one window's single Observation.**

- `ReportSubmissionRecord.id` is the window id (`ReportSubmissionRuntime.swift:354-355`).
- `ReportDetailView` already states `1 OBSERVATION`
  (`ReportDetailView.swift:125-128`).
- A window belongs to exactly one session (§A).

Therefore:

- **`SESSIONS 1, 2` cannot occur.** A report maps to at most one session.
- **`PROOFS EARNED · 2` cannot occur.** A report maps to at most one Proof.
- **`Contributor Proof` has no counterpart in code.** `git grep -i
  contributor -- ios/Beid shared/src/commonMain android/app/src/main` returns
  0 hits. The only proof type is `Proof`, one per session (§C).

Every deviation listed below follows from this difference, or from a
decision that forbids a Figma value. The deviations are deliberate.

### The `8f2c…4a91` slot is the observation digest

In Figma's report rows, `8f2c…4a91` sits in the slot where today's 08 row
shows `shortDigest(record.observationDigestHex)`
(`EventDetailView.swift:279-280`, `:317-320`). That value is the first 4 and
last 4 hex characters of the **Observation digest**, not a record id.

The record id appears only on 12, as REPORT ID, through
`RecordIDDisplay.abbreviated(record.id)` (`ReportDetailView.swift:114-123`).
This design keeps the digest in that slot on 08, 09 and 11, so the same
report shows the same characters on every screen.

### Common rules

- Show only measured values.
- Show no absence notice when a section has nothing to show: the section is
  simply not rendered.
- Never claim sent, verified or mutual beyond what `ReportDetailPresentation`
  (`ReportDetailView.swift:9-49`) and the proof state (§D) already establish.
- Link-derived content appears only when all three hold:
  - the link row exists;
  - the Proof exists in `ProofStore`;
  - the normalised event codes match.
- Headings on `FROM REPORTS` and `INCLUDED IN REPORTS` carry **no count**,
  as measured in Figma (see OD-6).

### Per frame

**09 Proof Detail — `FROM REPORTS`.** Today `ItemDetailView`
(`ItemDetailView.swift:87-163`) has no such section, and the UI test asserts
its absence (`FlatScreenshotTourC.swift:109`).

After #701:

- The rows are the records whose link `proofId == proof.id`, in Event
  Detail's report order (`ReportSubmissionStore.eventRecords`,
  `ReportSubmissionStore.swift:297-311`).
- **Each row reuses the 08 report row exactly** (`EventDetailView.swift:231-258`):
  - the title `Report #n`, where n is the event-wide ordinal, i.e. the same
    number 08 shows (`:193-195`);
  - the 08 status text (`:268-277`);
  - the 08 metadata line: short digest plus the local state phrase
    (`:279-315`).
- The row opens `ReportDetailView(recordID:reportIndex:…)`.
- **Deviations from Figma:**
  - no `· SESSION K` suffix;
  - a status text is shown, where Figma 09 shows only `→`.

  Both are open under OD-8. The implementation should extract the 08 row
  into one shared row view so that 08, 09 and 11 cannot drift apart.
- The section is not rendered when there are zero linked records or the link
  store is unreadable.

**11 Observation Detail — `INCLUDED IN REPORTS`.** Today
`ObservationDetailView` (`ObservationDetailView.swift:50-189`) has no such
section, and the UI test asserts its absence (`FlatScreenshotTourC.swift:37`).

After #701, it shows the same list and the same row view as 09 for this
session's Proof, because 11 is one session, which is one Proof. The rules
are the same as 09.

**12 Report Detail.** Today `ReportDetailView` (`ReportDetailView.swift:54-251`)
shows `Report #n`, a status caption, the RECORD rows and `OBSERVATIONS
INCLUDED`, which holds only `1 signed observation · <digest>`
(`:159-179`). It has no session and no proof section.

After #701:

- **(a) Session row, when linked.** The session sits as a **row inside
  `OBSERVATIONS INCLUDED`**, placed below today's `1 signed observation` row
  and matching Figma's position. It is not a caption. The content matches
  the 08 session row (`EventDetailView.swift:123-153`):
  - `Session K`, with K from §C;
  - the start time `proof.date` in shortened time format (`:134`);
  - `sessionMeasurements` from the persisted aggregate: `N devices · W
    windows` (`:163-172`).

  **Deviations from Figma:**
  - **Start time only, not `16:30 – 17:11`.** No session end time is stored
    anywhere:
    - `Proof` has only `date`, set at recording start
      (`Proof.swift:13`; `SensingCoordinator.swift:3762`).
    - `SessionAggregate` has no time field
      (`shared/src/commonMain/kotlin/org/levarac/beid/shared/aggregation/ObservationAggregation.kt:136-147`).
    - Two sources are **rejected**:
      - `SessionAggregateSnapshotRecord.createdAt`
        (`SessionAggregateSnapshotRecord.swift:21`) is the moment the file
        row was written. It exists only for sessions that ended through
        `endSensing` (`SensingCoordinator.swift:2841`), and
        `snapshot(proofId:)` does not expose it
        (`SessionAggregateSnapshotStore.swift:88-101`).
      - `SelfProofRecord.eninEnd` is an ENIN index. Turning it into a
        wall-clock time would reimplement Barnard interval semantics
        (KMP-002), and it exists only when a self-proof was signed.
    - Adding a real end time would be a new stored field, which is outside
      #701.
  - **`N devices · W windows` instead of `31 PEERS`,** so that the row reads
    exactly like 08.
  - **When no aggregate snapshot exists** (for example, the process died
    before session end), the measurements line is **omitted** on 12, per the
    no-absence-notice rule. 08 keeps its existing `Measurements unavailable`
    text, which is not changed by #701.

  **Navigation:** the row is **not** a link, as in Figma (no arrow). A link
  would create an unbounded 11 → 12 → 11 → … push cycle, because 11's
  `INCLUDED IN REPORTS` opens 12. The session is already reachable from 08.

  **Keep `1 signed observation · <digest>`.** It is the record's actual,
  measured content: one Observation and the digest of exactly what was
  signed, which is the value the operator receipt binds to. Figma's
  `6 WINDOWS` model has no row that tells the reader which bytes this report
  is.
- **(b) Proof section, when linked.**
  - Heading: see OD-3.
  - Exactly one row:
    - the mini `RecordSigilSlot` (as `EventDetailView.swift:341-345`);
    - the title `Session K proof` (the 08 key, `EventDetailView.swift:380-386`);
    - the subtitle `<state> · <RecordIDDisplay.abbreviated(proof.id)>`,
      where the state comes from the 08 function (`EventDetailView.swift:388-401`:
      `SEALED` or `RECORDED ON DEVICE`) and the id display is the helper at
      `ios/Beid/DesignSystem/RecordIDDisplay.swift:8` (the same form as 09's
      RECORD ID, `ItemDetailView.swift:134`);
    - `→`, which opens `ItemDetailView(proof:)`.

  **Deviations from Figma:**
  - **`VERIFIED` is forbidden** (DECISIONS 2026-09-22: VERIFIED only after
    third-party verification; 2026-09-23: no VERIFYING, 09 STATUS Sealed).
    Nothing on the device is verified.
  - **`Attendance Proof` becomes `Session K proof`,** to match the code's 08
    proof row. (Figma's 08 also says `Attendance Proof`; the code already
    deviated there.)
  - **No `Contributor Proof` row,** because no such type exists.
  - **No count in the heading,** because it would always be 1 (OD-3).
- **Unchanged by #701:** Figma's other 12 differences — `SUBMITTED …` caption,
  RECORDED ON DEVICE `6 WINDOWS`, NOT SUBMITTABLE, SENT time, `RECEIVED`,
  `WHAT WE SEND →` (which already has a `TODO(#646)` at
  `ReportDetailView.swift:156-158`). They follow the same one-window model
  and are not link data.
- **Injection:** `ReportDetailView` needs `ProofStore` and a SelfProofRecord
  lookup injected. Today it takes only `submissionStore`
  (`ReportDetailView.swift:59-67`).
- **Unlinked records:** neither (a) nor (b) is rendered, which is exactly
  today's screen.

**08 Event Detail.** Figma's 08 also shows the linkage: `SESSIONS 1, 2` on
report rows and `SEALED · FROM R1, R2` on proof rows. The PM scoped #701 to
09, 11 and 12, so 08 stays unchanged in this proposal apart from its
now-stale header comment (`EventDetailView.swift:7-8`), which the
implementation PR corrects. Whether to add the 08 linkage now is **OD-9, a
scope question for the PM.**

**A partial-link edge case.** A Proof whose windows were linked only in part
(some link writes failed) lists only the linked reports. With no counts in
the headings, the screens make no claim about how many reports the session
has.

## 7. Test plan and mutation targets

These are XCTest unless marked otherwise. All run on a freshly erased
simulator, as AGENTS.md requires.

- **T1 `ReportProofLinkStoreTests`**
  - round trip across reload;
  - same-pair idempotence;
  - conflicting `proofId` for an existing `windowId` throws, and the stored
    row is unchanged;
  - an unreadable file latches: reads `.unreadable`, writes throw, and the
    file bytes are unchanged afterwards;
  - an absent file is empty;
  - `schemaVersion` 1 is emitted.
- **T2 Wiring (`ReportSubmissionWiringTests` style)**, using the real
  coordinator with `ReportSubmissionRuntimeSpy` and an injected link store:
  - For each of the three close triggers (ENIN boundary, background
    checkpoint, `stopSensing`/CLOSE), assert that
    `link[spy.captures[i].id] == currentProofID` as observed while
    `.recording`.
  - Run two sequential sessions of the **same event code and same ENIN**, and
    assert that the two captures link to two different Proof ids, each its
    own.
  - With a nil runtime, assert that no link rows are written.
  - With an injected link-store write failure, assert that the capture is
    still forwarded exactly once and that no link exists.
  - A session that never reaches `.recording` writes no link and no capture.
- **T3 Byte identity (`ReportProofLinkByteIdentityTests`)**
  - **Placement.** `TestSecp256k1` (`ReportSubmissionOperatorIntegrationTests.swift:129`),
    `StubOperatorServer` (`:221`) and `TestSensingCryptography` (`:76`) are
    all `private` to that file. T3 therefore either:
    - lives in `ReportSubmissionOperatorIntegrationTests.swift` as new test
      methods; or
    - moves those three types into a shared test-helper file under
      `ios/BeidTests/`. This is a test-only change with no production code.

    The first is the smaller change.
  - **Golden provenance.** Add T3 first **on unmodified `62531fe` production
    code**. Run it once to capture (a)–(c), write the values in as constants
    with the commit SHA in a comment, and only then start the implementation.
    Constants derived after the change would pin the new behaviour, not the
    old one.
  - **As implemented (phase 2).** The three types, with the ones they depend
    on and `StaticEventDefinitionContextProvider`, moved to
    `ios/BeidTests/Support/ReportSubmissionOperatorTestSupport.swift`. The
    fixed scenario and the golden constants are in
    `ReportSubmissionGoldenBytesTests.swift`, which uses no symbol added by
    #701, so it compiles on `62531fe`. The implementation was written before
    the goldens were recorded, so the constants ship as placeholders that
    fail with the measured value in the message. They are recorded by
    running that file, together with the support file and the trimmed
    `ReportSubmissionOperatorIntegrationTests.swift`, on a throwaway checkout
    of unmodified `62531fe`. The with-link half is
    `ReportProofLinkByteIdentityTests.swift`.
  - Seed a pending capture with fixed `id`, `finalizedAt`, RPIDs, reporter
    RPID and commitment in `report-submissions.pending.json`.
  - Run `runtime.submitPending()` against `StubOperatorServer`
    (`ReportSubmissionOperatorIntegrationTests.swift:221-342`) with the
    deterministic fixed-nonce signer (`TestSecp256k1`, `:123-149`) wrapped to
    record the signature input.
  - Assert that the following equal **golden hex constants recorded at
    `62531fe` before any implementation change**, with the provenance written
    in a comment:
    - (a) the signature input bytes;
    - (b) `record.signedObservationHex`;
    - (c) the POST body.
  - Run the scenario twice, once with an empty link store and once with a link
    row for that id. Both runs must produce identical bytes, equal to the
    golden values.
  - This is the "before/after identical for the same inputs" pin.
- **T4 Structural key scan** (modelled on
  `SignalStrengthNeverRecordedTests.testPersistedRecordTypesHaveNoFieldNamedForSignalStrength`,
  `:1124`): the encoded key sets of `ReportSubmissionRecord`,
  `ReportSubmissionCapture`, `ReportSubmissionExclusion` and `WindowReport`,
  and the `LabRecordMetadata` property list, contain no key matching
  `/proof/i`. Each type must emit a known own key (non-vacuous).
- **T5 Byte scan** (modelled on #652's `containsByteSequence`): after a linked
  session, search for the Proof UUID's 16 raw bytes, and its
  lower/upper-case string, with and without dashes, in:
  - the signed Observation bytes;
  - every POST body and GET URL seen by the stub;
  - the three `report-submissions*.json` files;
  - `window-reports.json` and `unsent-window-ledger.snapshot`;
  - every field of the lab projection.
  None may be found. Assert a positive control first: the link file itself
  must contain the id.
- **T6 Old files:** load a fixture `report-submissions.json` in `62531fe`
  format with no link file present. Assert that the records are identical to
  the fixture and all unlinked, and that the presentations for 09, 11 and 12
  render no link content.
- **T7 Presentation units** (next to `ReportDetailPresentationTests` and
  `ProofDetailPresentationTests`). Cover these cases:
  - linked;
  - unlinked;
  - link store unavailable;
  - Proof missing from store;
  - event-code mismatch;
  - with and without a `SelfProofRecord`, where the state must match the 08
    function.
  Also assert that the §C ordinal equals 08's ordinal for the same Proof,
  including an equal-date tie.
- **T8 UI (`FlatScreenshotTourC`)**
  - Keep the two absence assertions (`:37`, `:109`) on the existing unlinked
    fixtures. They become the "old records" guard.
  - Add a linked fixture in which 09 shows `FROM REPORTS`, 11 shows
    `INCLUDED IN REPORTS`, and 12 shows the session row and the proof row.
  - Assert that no `VERIFIED` text appears on 12, and that the 12 session row
    is not a button.
  - The fixture writes links only into an isolated DEBUG file, in the same
    way as `AppCoordinator.swift:119-127`.

**Suite to run for the implementation PR:** the full `BeidTests` and
`BeidUITests` covering suites for every modified file, following AGENTS.md
("Run the full covering suite for any file you modified"). No Kotlin changes
are made, so the Android and shared Gradle lanes are unaffected, and
`mutation_check.py` (Kotlin only) does not apply.

**Manual Swift mutations** for the reviewer. Apply each one, run the listed
test, and confirm it goes red.

| # | Mutation | Must go red |
| --- | --- | --- |
| M1 | In `closeWindow`, write `UUID()` instead of `activeProofId`. | T2 (all three triggers) |
| M2 | Move the link write into `openNewWindowState` (before `.recording`) and take the Proof id from a cached "last proof" not cleared by `resetSessionState`. | T2 two-session same-ENIN test |
| M3 | In `ReportProofLinkStore.add`, overwrite on a conflicting `proofId`. | T1 conflict test |
| M4 | In `load()`, on a decode error set the table to empty and clear the latch. | T1 unreadable test |
| M5 | Add `proofId` to `ReportSubmissionCapture` (or pass it into `captureAndQueueWindow`). | T4 (and the spies stop compiling) |
| M6 | Fold the Proof id into `participantCommitmentHex` or `idHex` in `prepareAndQueueWindow`. | T3 and T5 |
| M7 | On a link-write failure, `return` from `closeWindow` before the capture. | T2 failure-injection test |
| M8 | In 12, fall back to "newest Proof with the same event code" when the record is unlinked. | T7 unlinked case, T6 |
| M9 | Drop the "Proof exists in `ProofStore`" guard. | T7 Proof-missing case |
| M10 | Make the 12 proof state always `SEALED`. | T7 no-`SelfProofRecord` case |
| M11 | Sort the ordinal helper descending, or drop the tie-break. | T7 ordinal / tie test |
| M12 | Add the Proof id to `LabRecordMetadata`. | T4 and T5 |
| M13 | Render the 12 proof state as `VERIFIED`. | T7 and T8 |
| M14 | Make the 12 session row a `NavigationLink` to 11. | T8 |

## 8. Open decisions

**PM decisions, 2026-09-27.** The PM approved this design with these picks.
Where a pick differs from the recommendation below, the pick governs and the
sections above were updated to match.

- **OD-1:** (2), a separate link table.
- **OD-2:** (a), write links only when the submission runtime exists.
- **OD-3:** (b), heading `SESSION PROOF`, no count.
- **OD-4:** (a), the conditional state function shared with 08.
- **OD-5:** (b), **exclude the link file from backup**
  (`isExcludedFromBackup`); the existing stores are unchanged, and whether
  they should also be excluded is owned by #704. This differs from the
  recommendation below.
- **OD-6:** no counts.
- **OD-7:** the Android issue is opened later.
- **OD-8:** (a), reuse the 08 report row exactly, with no session suffix.
- **OD-9:** (b), the 08 linkage is deferred; what 08 shows does not change.
- Moving `TestSecp256k1`, `StubOperatorServer` and `TestSensingCryptography`
  (with the types they depend on) into a shared test helper is approved
  (§7 T3, "Placement").

The options and recommendations as proposed are kept below for the record.

- **OD-1 Storage shape.**
  - Options: (1) an optional field on capture and record; (2) a separate
    link table; (3) the Proof or snapshot side.
  - **Recommendation: (2)** — §B. It is the only option that leaves the
    submission queue's bytes, codec, equality and runtime API untouched, and
    keeps a display-only failure out of the submission path.
- **OD-2 Write links when submission is disabled?**
  - Options: (a) only when `reportSubmissionRuntime != nil`; (b) always.
  - **Recommendation: (a).** With no runtime there are no records to join,
    so writing links would store data with no use.
- **OD-3 Heading of the 12 proof section.** This is a Flat 2b wording
  decision, inside the 2026-09-26 delegation. Figma shows
  `PROOFS EARNED · 2` (§6). In the code a report has at most one Proof, so
  any count would always be `· 1`.
  - Options:
    - (a) Figma's wording with the true count: `PROOFS EARNED · 1`;
    - (b) a neutral singular heading with no count, such as `SESSION PROOF`;
    - (c) `PROOF` with no count.
  - **Recommendation: (b).**
    - "EARNED" asserts that the report produced the proof, which the code
      contradicts: the Proof is created at recording start, independently of
      the report's delivery state.
    - A count that can only ever be 1 carries no information.
- **OD-4 Proof state: code (conditional) vs DECISIONS 2026-09-23 (always
  Sealed).**
  - The code shows `SEALED` only when a `SelfProofRecord` exists and
    `RECORDED ON DEVICE` otherwise, on 08 (`EventDetailView.swift:388-401`)
    and 09 (`ItemDetailView.swift:28-34`).
  - DECISIONS 2026-09-23 says 09 STATUS is always `Sealed` in v1.0.
  - Options for #701's new 12 proof row: (a) use the code's conditional
    function; (b) always `SEALED`.
  - **Recommendation: (a) for #701,** so the 12 row reads the same as the 08
    row for the same Proof. This proposal does not propose changing 09. The
    divergence between the code and DECISIONS is recorded here for the PM to
    resolve separately.
- **OD-5 Backup.**
  - Options: (a) back up the link file like the other stores; (b) exclude
    only the link file.
  - **Recommendation: (a).** After a restore, the records and Proofs come
    back, and excluding only the links would turn every restored report into
    "unlinked" for no privacy gain relative to the files beside it.
  - Whether any Documents store should be excluded from backup is a broader
    question, outside #701, and is flagged for the PM.
- **OD-6 Counts on `FROM REPORTS` / `INCLUDED IN REPORTS` — settled: no
  count.** Figma measures no count on either heading (§6). Leaving the count
  out also avoids the partial-link problem: a count would silently mean
  "linked reports", not "all reports of the session". There is nothing left
  to decide.
- **OD-7 Android follow-up.**
  - The issue text is in §5. Opening it is the PM's call.
  - **Recommendation:** open it when #701 merges into `design/flat-2b`.
- **OD-8 Report rows on 09 / 11: session suffix and status.**
  - Figma shows `<digest> · SESSIONS 1, 2` / `SESSION 3`, with an arrow only
    on 09 and `ACCEPTED` on 11.
  - Options:
    - (a) reuse the 08 row exactly: `Report #n`, 08 status text, 08 metadata,
      and no session suffix, on both 09 and 11;
    - (b) (a) plus `· SESSION K`;
    - (c) follow each Figma frame literally (09 without a status, 11 with
      one).
  - **Recommendation: (a).**
    - On 09 and 11, `SESSION K` would always repeat the screen's own session.
      Figma needs the suffix only because its reports span sessions, which
      the code's reports cannot.
    - Showing the status on 09 as well means one report reads identically on
      08, 09 and 11, and a delivery state is a measured value.
    - If OD-9 brings the session suffix to 08, switch to (b) so the three
      screens stay identical.
- **OD-9 Scope question for the PM: add the 08 linkage in #701?**
  - Figma 08 shows `SESSIONS 1, 2` on report rows and `SEALED · FROM R1, R2`
    on proof rows. Both are now derivable from the link table.
  - Options: (a) include 08 in #701; (b) defer 08 to a follow-up.
  - **Recommendation: (b), defer.**
    - The PM scoped #701 to 09, 11 and 12.
    - `FROM R1, R2` needs its own design. A session produces one report per
      300 s window, which is 12 per hour, so a real proof row would read
      `FROM R1, R2, … R24` unless it is compressed to a range or a count.
      That is a new wording decision, not a mapping.
  - **This is the PM's scope call,** not a delegation-level wording choice.
