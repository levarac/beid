// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Barnard
import BarnardCore
import BeidSharedKit
import Foundation
import os

struct WindowReportRedeliveryBuffer {
  private(set) var reports: [WindowReport] = []
  private let capacity: Int

  init(capacity: Int = 64) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  @discardableResult
  mutating func enqueue(_ report: WindowReport) -> WindowReport? {
    // Preserve the earlier session prefix: older artifacts are closer to
    // submission, and a full queue should not evict recoverable work already
    // waiting behind the same storage outage. This relies on ledger-side
    // terminal rejection being the only permanent head failure; revisit the
    // policy if WindowReportStore gains another permanent add failure, since
    // a stuck full head would then reject every later artifact indefinitely.
    guard reports.count < capacity else { return report }
    reports.append(report)
    return nil
  }

  mutating func removeFirst() {
    reports.removeFirst()
  }
}

/// The shared unsent-window ledger's operating state: whether
/// `unsentWindowLedgerRuntime` and the window-report/redelivery pipeline
/// feeding it can currently record — and if not, why and since when
/// (beid#131).
///
/// Exists because `unsentWindowLedgerRuntime` is a `let`: once construction
/// or relaunch reconciliation fails, it stays `nil` for the rest of the
/// process with no recovery path and, before this type, no record of when
/// or why. A later persistence failure on an otherwise-live runtime is the
/// same shape of invisible problem. Neither case previously left anything
/// queryable outside a device console log.
///
/// Same principle as `CorruptStoreQuarantine.Outcome`/
/// `persistenceSuspensionReason` on the proof-family stores: surface *why*
/// a store can't be trusted right now as a typed fact, not just a `print`.
enum LedgerHealth {
  case healthy
  /// `since` latches to the *first* observed failure and never moves once
  /// set — this process has no ledger recovery path, so a device that
  /// degrades once stays degraded for the rest of its life, and knowing how
  /// long that has been true matters more than the timestamp of whichever
  /// failure ran most recently. `reason` still reflects the most recent
  /// failure.
  case degraded(reason: Error, since: Date)

  var isDegraded: Bool {
    if case .degraded = self { return true }
    return false
  }

  var degradationReason: Error? {
    guard case let .degraded(reason, _) = self else { return nil }
    return reason
  }

  var degradedSince: Date? {
    guard case let .degraded(_, since) = self else { return nil }
    return since
  }
}

/// Observable checkpoints emitted while a named DemoEvent scenario is interpreted.
///
/// They are intentionally separate from production sensing state so tests can prove
/// that preview/demo behavior has not entered the durable-report path.
enum DemoInterpreterCheckpoint: Equatable {
  case step(Int, DemoScenario.Step)
  case renderTurnSettled(Int)
  case suspended(Int)
  case resumed(Int)
  case completed
}

/// Wraps `BarnardEngine` (scan+advertise) and one `SensingCryptography`
/// facade (per-event signing, owner-key signing) behind the app's `ScanPhase`
/// state machine. The facade — not `BarnardIdentity` directly — is what this
/// type holds, so tests can inject a deterministic signer; production injects
/// `BarnardSensingCryptography`.
///
/// In Debug builds, `useDemoEventMode` can drive a simulated peer sequence
/// (event found → recording) instead of real detections. Release builds
/// always use the real sensing path (see README).
@MainActor
final class SensingCoordinator: ObservableObject {
  @Published private(set) var phase: ScanPhase = .idle
  @Published private(set) var isScanning = false
  @Published private(set) var isAdvertising = false
  /// Wallet connect+binding lifecycle for the event currently being
  /// recorded — see `EventBindingState`. Sub-slice 2a only sets this to
  /// `.pendingConnect`; the interstitial that drives the rest is 2b.
  @Published private(set) var bindingState: EventBindingState = .none
  /// Event code most recently confirmed by `joinEvent(_:)`, if any. Feeds
  /// `startSensing(eventCode:)` once the user has joined manually via
  /// `EventCodeEntryView` — see `AppCoordinator.joinEvent(code:)`.
  @Published private(set) var joinedEventCode: String?
  /// Canonical registry Event ID returned by the code lookup for
  /// `joinedEventCode`. It is an untrusted routing hint until the dedicated
  /// event-definition resolution completes; event codes are not sufficient to
  /// derive this value locally.
  @Published private(set) var joinedCanonicalEventIdHex: String?
  /// Whether `RecordingView`'s one-time entrance ceremony (§5.5) has already
  /// played for the current session. Lives here rather than as view-local
  /// `@State` because `.recording` can be interrupted by `.signalLost` and
  /// resumed (`resumeSensing()`), which recreates `RecordingView` — a flag
  /// on the view itself would incorrectly replay the ceremony after every
  /// resume. Reset alongside the rest of per-session state in
  /// `resetSessionState()`.
  @Published private(set) var recordingCeremonyShown = false
  /// Whether `RecordingView`'s one-time entrance ceremony has finished
  /// dwelling (or never needed to run at all — see
  /// `markEntranceCeremonyFinished()`'s own doc comment) for the current
  /// session. `ScanFlowView` (beid#222) chains the wallet-binding sheet's
  /// auto-presentation to this rather than directly to `bindingState`
  /// becoming `.pendingConnect`, so the ceremony and the binding prompt are
  /// sequenced one after the other per §5.5, instead of the sheet's
  /// presentation animation starting on top of the ceremony's — which also
  /// closed a presentation-transaction race where a same-tick Close tap
  /// left both the scan flow and the sheet stuck on screen. Reset alongside
  /// the rest of per-session state in `resetSessionState()`.
  @Published private(set) var entranceCeremonyFinished = false
  /// Distinct devices observed so far this session — the value carried as
  /// `peersVerified` into `.recording` and the stored `Proof`, and so the
  /// number that ends up inside a signed artifact.
  ///
  /// It is **one of two** independent ways to confirm an event
  /// (`BeidSharedKit.sensing.hasEnoughDistinctDevicesToConfirmScanEvent`),
  /// never the only one: the other arm reads the current window's proximity
  /// identifiers, so a total display-id outage cannot stop a real event from
  /// being recorded. Confirmation and
  /// this value are therefore allowed to disagree — a session whose B003 reads
  /// all fail records with this at 0 and `unidentifiedRpidCount` above 0,
  /// which is the honest pair rather than a single number that would have to
  /// lie.
  ///
  /// Keyed on `detectedDisplayId`, not on the proximity identifier. The
  /// proximity identifier rotates every ENIN window by design, so a set of
  /// them counts (device × window) pairs: at the 300-second default, two
  /// people together for an hour would read as twelve. `detectedDisplayId`
  /// derives from the per-event key (`BarnardCoreCrypto.displayId4(from:tek:)`,
  /// which takes no `enin`) and is therefore stable for as long as the event
  /// lasts. See beid#154.
  ///
  /// Observations that arrive without a display id are never folded in here —
  /// they land in `unidentifiedRpidCount` instead.
  ///
  /// Sourced from `sessionAggregate?.deviceCount`
  /// (`BeidSharedKit.aggregation.SessionAggregate.deviceCount`, all-observation
  /// scope, beid#109/#162) rather than computed natively — this property is
  /// projected from that shared decision, not recomputed here.
  @Published private(set) var devicesVerified = 0
  /// The full shared session aggregate as of the most recent observation —
  /// all-observation and mutual scopes, plus the window series
  /// (`BeidSharedKit.aggregation.SessionAggregate`, beid#109/#142/#162).
  /// `devicesVerified` above is this aggregate's `deviceCount` projected to a
  /// plain `Int` for the confirmation-threshold arithmetic; UI that wants the
  /// mutual counts or the window-by-window buildup (`RecordingView`, #142)
  /// reads this property directly instead of a second native re-projection,
  /// so those values are provably shared-sourced by their own type. `nil`
  /// until the first observation of a session; recomputed and republished on
  /// every new observation (#109's "no subscription API, caller recomputes"
  /// contract — see `AggregationRuntime.sessionAggregate`).
  @Published private(set) var sessionAggregate: BeidSharedKit.aggregation.SessionAggregate?
  /// Distinct proximity identifiers observed this session that never arrived
  /// with a `detectedDisplayId`, and so could not be attributed to a device.
  ///
  /// The display id comes from a GATT characteristic read (Barnard B003) that
  /// can fail; Barnard still emits the detection, with a null display id.
  /// Silently dropping those understates what was around; silently counting
  /// them re-inflates the count this type exists to deflate. Neither is
  /// acceptable, so they are surfaced here for a caller that needs to judge
  /// coverage.
  ///
  /// This is a coverage signal, **not** a second device count: it dedupes by
  /// the rotating identifier, so it carries exactly the (device × window)
  /// inflation that `devicesVerified` no longer does. One device that never
  /// yields a display id therefore adds a fresh entry every window, so this
  /// number climbs with dwell time — alarming-looking for a reason that is not
  /// alarming. An identifier that later does arrive with a display id leaves
  /// this count; it turned out to be covered after all.
  ///
  /// **Deliberately not the same quantity as shared's
  /// `observationsWithoutDisplayIdCount`** (`ObservationAggregation.kt`, added
  /// in #109), which is a raw `count { displayId == null }` over persisted
  /// rows. Feed both the same traffic and they return different numbers, by
  /// design and at different layers. Shared aggregates a stored row set, where
  /// one row is one observation and a raw tally is meaningful. This counter
  /// sits on the live BLE callback path, where a raw tally would be dominated
  /// by advertisement rate — it would measure how chatty the radio is, not how
  /// much of the session the device count covers, which is the one question it
  /// exists to answer. Aligning it to shared's definition would make it
  /// useless rather than consistent. It is named apart from the shared field
  /// so the difference is visible at the call site rather than discovered by
  /// whoever first wires #109 to iOS.
  @Published private(set) var unidentifiedRpidCount = 0

  /// Fired once, the instant `.recording` begins and a `Proof` is created.
  var onProofCollected: ((Proof) -> Void)?
  /// Fired on every subsequent distinct-peer observation while
  /// `.recording`, so the caller can update the same `Proof` in place
  /// (`ProofStore.updatePeersVerified(for:to:)`) rather than re-creating it.
  var onPeersVerifiedChanged: ((UUID, Int) -> Void)?

  /// Test-only visibility into the deterministic DemoEvent interpreter.
  /// This does not represent an on-device sensing callback and never enters
  /// the ledger or report-submission paths.
  var onDemoInterpreterCheckpointForTesting: ((DemoInterpreterCheckpoint) -> Void)?

  var hasParkedDemoScenarioForTesting: Bool { demoInterpreterIsParked }

  var parkedDemoScenarioCursorForTesting: Int? {
    demoInterpreterIsParked ? demoInterpreterCursor : nil
  }

  /// The number of ENIN windows locally signed and stored for one event
  /// (beid#137's Transparency screen, "Recorded on device" row —
  /// `docs/specs/visibility-aggregation-ui.md` §5.1). Filters
  /// `WindowReportStore.reports` by `eventCode`, which is `WindowReport`'s
  /// own stable per-event field — not the shared unsent-window ledger,
  /// which has no event scoping (`openWindow` takes only an opaque UUID)
  /// and never drains today (no report-submission path exists yet), so a
  /// ledger-derived count would be lifetime-cumulative across every
  /// session ever run rather than scoped to this event.
  func recordedWindowCount(forEventCode eventCode: String) -> Int {
    windowReportStore.reports.filter { $0.eventCode == eventCode }.count
  }

  /// beid#292's Transparency screen ("Sent"/"Acceptance receipt" rows): the
  /// most-advanced report-submission state recorded for one event. Forwards
  /// to `reportSubmissionRuntime.submissionState(forEventCode:)` — a pure
  /// read of the durable `ReportSubmissionStore`, never a network call.
  /// `nil` both when the runtime itself is `nil` (report submission is
  /// gated off in production by `BeidReportSubmissionEnabled`) and when no
  /// submission for this event code has ever been queued — both render
  /// identically on the Transparency screen as an honest "not yet
  /// available," never a false negative.
  func submissionState(forEventCode eventCode: String) -> ReportSubmissionState? {
    reportSubmissionRuntime?.submissionState(forEventCode: eventCode)
  }

  /// beid#143's Participation summary screen entry point. Forwards to the
  /// privately-owned `sessionAggregateSnapshotStore` that
  /// `persistSessionAggregateSnapshotIfNeeded()` writes at session end
  /// (beid#166 Phase 2) — the same coordinator-owned instance, not a second
  /// copy, so a snapshot persisted moments ago in this same app run is
  /// visible immediately rather than only after the next launch's on-disk
  /// reload. `nil` means no snapshot was ever persisted for this proof —
  /// see `SessionAggregateSnapshotStore.snapshot(proofId:)`'s own doc
  /// comment for the three reasons that can happen.
  func sessionAggregateSnapshot(forProofId proofId: UUID) -> BeidSharedKit.aggregation.SessionAggregate? {
    sessionAggregateSnapshotStore.snapshot(proofId: proofId)
  }

  /// Field diagnostics for the counting split (beid#154). `os.Logger` rather
  /// than `print` on purpose: these lines have to be readable from a real
  /// device during a field run — Console.app, or a sysdiagnose collected after
  /// the fact — and `print` reaches neither. Every interpolation is
  /// `.public` because none of it is personal data: they are small integers,
  /// and no identifier is ever logged.
  private static let log = Logger(subsystem: "org.levarac.beid", category: "sensing")
  /// Ledger/window-report/redelivery failure diagnostics (beid#131). A
  /// separate category (`"ledger"`, not `"sensing"`) so this failure family
  /// filters on its own in Console.app/sysdiagnose, apart from `Self.log`'s
  /// device-counting diagnostics above. Every interpolation below is
  /// `.public` for the same reason `Self.log`'s are: none of it is personal
  /// data — sandbox-local file paths, session-scoped UUIDs, and error
  /// descriptions — and a `.private` interpolation would render as
  /// `<private>` in exactly the shipping-build device log this exists to
  /// populate.
  private static let ledgerLog = Logger(subsystem: "org.levarac.beid", category: "ledger")

  private let engine = BarnardEngine()
  private let sensingCryptography: any SensingCryptography
  private let reportSubmissionRuntime: (any WindowReportSubmissionRuntimeProtocol)?
  private let eventIdentityVerificationSource: (any EventIdentityVerificationSource)?
  private let randomSource: any BarnardCoreRandomSource = BeidSystemRandomSource()
  private var windowReportStore: WindowReportStore
  private var unsentWindowLedgerRuntime: (any UnsentWindowLedgerRuntimeProtocol)?
  /// Whether `unsentWindowLedgerRuntime` (and the window-report/redelivery
  /// pipeline feeding it) can currently record — and if not, why and since
  /// when. See `LedgerHealth`.
  private(set) var ledgerHealth: LedgerHealth = .healthy
  /// Whether the background load Decision 1 introduced
  /// (`docs/specs/ledger-async-io.md` §4) is still recovering
  /// `windowReportStore`/`unsentWindowLedgerRuntime`/
  /// `selfProofCheckpointStore` and reconciling crash-gap state. Deliberately
  /// **separate** from `LedgerHealth`: that type is a binary,
  /// permanent-once-degraded fact about the runtime specifically, while this
  /// is a transient fact about construction as a whole (§4.3) — conflating
  /// the two would force every consumer of `LedgerHealth` to also handle a
  /// transient case in what is otherwise a stable, tested binary contract.
  /// While this is `true`, `handleDetection` queues instead of processing —
  /// see `queuedDetectionsWhileLoading`.
  ///
  /// Defaults `false`: the designated initializer below keeps its
  /// synchronous, fully-loaded-stores contract unchanged, so any instance
  /// built through it (directly, or via the explicit-storage-seam
  /// convenience initializer `BeidTests` uses) is never "loading" by the
  /// time it exists. Only the async-loading initializer chain — the
  /// production `convenience init()` and the `loadingFromDirectory:` test
  /// seam — sets this `true` immediately after that designated initializer
  /// returns, then flips it back to `false` inside `beginLedgerLoad(...)`
  /// once the real load/reconcile work finishes, at the same moment
  /// `ledgerHealth` is assigned.
  @Published private(set) var isLedgerLoading = false
  private let bindingRecordStore: BindingRecordStore
  private let selfProofStore: SelfProofStore
  private var selfProofCheckpointStore: SelfProofCheckpointStore
  /// beid#166 Phase 2: on-device display-convenience store for computed
  /// session-aggregate snapshots. Loaded synchronously, like
  /// `selfProofStore`/`bindingRecordStore` and unlike
  /// `windowReportStore`/`unsentWindowLedgerRuntime`/
  /// `selfProofCheckpointStore` — it is never consulted during detection
  /// processing or crash-gap reconciliation at `init`, only written once at
  /// session end (`persistSessionAggregateSnapshotIfNeeded()`), so it has no
  /// stake in `docs/specs/ledger-async-io.md` §4's startup-latency problem
  /// and needs no placeholder/background-load treatment.
  private let sessionAggregateSnapshotStore: SessionAggregateSnapshotStore
  /// gh#156 Signal A (`docs/specs/owner-key-seed-read-failure.md` §8):
  /// non-nil once the owner key resolution behind `sensingCryptography` has
  /// quarantined an unreadable stored seed this session. `nil` both when
  /// nothing has been quarantined and when `sensingCryptography` isn't the
  /// production `BarnardSensingCryptography` implementation (e.g. a test
  /// fake) — mirrors `SelfProofStore.quarantinedFileURL`'s readable-property
  /// pattern. Computed, not cached at construction: reading `ownerKeyProvider
  /// .quarantinedSeedKey` here never itself calls into `sensingCryptography`
  /// (unlike Signal B below), so there is no resolution-ordering cost to
  /// evaluating this lazily, only to read after whatever already triggered
  /// key resolution (any self-proof/binding/wallet-ack call, or Signal B).
  var quarantinedOwnerKeySeedKey: String? {
    (sensingCryptography as? BarnardSensingCryptography)?.ownerKeyProvider.quarantinedSeedKey
  }
  /// gh#156 Signal B (`docs/specs/owner-key-seed-read-failure.md` §8): true
  /// when some self-proof/binding record already loaded by `selfProofStore`/
  /// `bindingRecordStore` has an owner public key that differs from the one
  /// currently active — evidence the owner key changed since that record
  /// was created, regardless of cause. Computed on demand rather than
  /// cached at construction: `sensingCryptography.ownerPublicKey()` forces
  /// owner-key resolution, and every other call into the facade already
  /// happens lazily, on first actual use — forcing it during `init` would
  /// change resolution timing for every coordinator, production and test
  /// alike, for a signal only meant to be checked once at startup by
  /// whoever wires that check (an `AppCoordinator`-level concern, per §8).
  var ownerPublicKeyMismatchDetected: Bool {
    OwnerKeyRegenerationDetector.ownerPublicKeyMismatchDetected(
      activeOwnerPublicKey: sensingCryptography.ownerPublicKey(),
      selfProofRecords: selfProofStore.records,
      bindingRecords: bindingRecordStore.records
    )
  }
  /// Detections `handleDetection` queued, in arrival order, instead of
  /// processing while `isLedgerLoading` was `true` — drained by
  /// `drainQueuedDetectionsAfterLoad()` the instant loading completes. See
  /// `handleDetection`'s guard and `docs/specs/ledger-async-io.md` §4.2 for
  /// why the whole raw detection is queued rather than only its
  /// store-touching calls.
  private var queuedDetectionsWhileLoading:
    [(enin: Int, rpid: String, detectedDisplayId: String?, reporterRpid: String?)] = []
  /// Decision 1's background load/reconcile task (`beginLedgerLoad(...)`).
  /// Held so tests can deterministically await it
  /// (`waitForLedgerLoadToFinish()`), mirroring `demoTask`/
  /// `waitForDemoSequenceToFinish()` below.
  private var ledgerLoadTask: Task<Void, Never>?
  private var demoTask: Task<Void, Never>?
  private var demoInterpreterScenario: DemoScenario?
  private var demoInterpreterCursor: Int?
  private var demoInterpreterIsParked = false
  private var demoInterpreterLastObservationChanged = false
  private var demoInterpreterStepDelayNanos: UInt64 = 700_000_000
  /// Generation and session identity protect the UI from a completion that
  /// belongs to a reset, leave, retry, or later session with the same raw code.
  private var eventIdentityVerificationGeneration = 0
  private var eventIdentityVerificationRequest: (any EventIdentityVerificationRequest)?
  private var eventIdentityVerificationSessionID: UUID?
  private var eventIdentityVerificationEventID: String?
  private var eventIdentityVerificationHint: String?
  /// Canonical Event ID carried from the code-lookup result until the first
  /// real event session is established. It is an untrusted routing hint and is
  /// never derived from event code.
  private var pendingCanonicalEventIdHex: String?
  /// Demo-only ENIN counter (`advanceDemoWindow()`) — never touches
  /// `closeWindow`/`WindowReportStore`, only stands in for the real path's
  /// `advanceWindowBookkeepingIfNeeded`-derived `firstWindowEnin`/
  /// `currentWindowEnin` so the self-proof layer (§2.2) is exercisable
  /// under demo mode too.
  private var demoWindowEnin = 0

  // MARK: - Per-session protocol state
  //
  // Reset at the start of every new event (`beginEventFound`) and on
  // `stopSensing()`/`reset()` so nothing leaks into the next session.

  /// Accumulates this session's observations and derives the device count
  /// from `BeidSharedKit.aggregation` (beid#109/#162) — the source of
  /// `peersVerified` (§4.3) on both the real path and, via
  /// `observeOneDemoDevice()`, the demo path. Backs `devicesVerified`; see
  /// its doc comment for why the underlying count is keyed on the display id
  /// rather than the rotating proximity identifier (beid#154).
  ///
  /// A display id is 4 bytes, so two devices at one event can in principle
  /// collide and be counted once. At event scale that is negligible and
  /// `BeidSharedKit.aggregation` deliberately does not defend against it: the
  /// alternative identifier available here is the one that rotates, and
  /// undercounting by a collision is a far smaller error than multiplying
  /// every device by its dwell time.
  private var aggregationRuntime = AggregationRuntime()
  /// Demo-only synthetic device counter backing `observeOneDemoDevice()`.
  /// Monotonically increasing so every call synthesizes a never-repeated
  /// rpid/displayId pair, guaranteeing each call grows the shared device
  /// count by exactly one.
  private var demoDeviceSequence = 0
  /// Demo-only stand-in for `currentWindowRpids` (beid#189), scoped to the
  /// demo script's own window concept (`demoWindowEnin`/
  /// `advanceDemoWindow()`) instead of a real ENIN boundary. Feeds
  /// `applyPhaseDecision`'s `coPresentDeviceCount` argument with an
  /// honestly-tracked value rather than a fabricated placeholder — see
  /// `applyPhaseDecision`'s own doc comment for why a fabricated count
  /// would itself violate DECISIONS 2026-08-01, not just an implementation
  /// detail. Demo's own confirm timing is still always actually driven by
  /// the distinct-device arm in practice (see `runDemoSequence`'s doc
  /// comment), since `devicesVerified` grows monotonically across the
  /// whole scripted session while this set resets every
  /// `advanceDemoWindow()` call — but the reducer receives a real count
  /// either way, never a stand-in chosen to force an outcome. Cleared by
  /// `advanceDemoWindow()` and `resetSessionState()`; inserted into by
  /// `observeOneDemoDevice()`.
  private var demoWindowRpids: Set<String> = []
  /// Backs `unidentifiedRpidCount`. Holds proximity identifiers seen
  /// without a display id; an identifier is removed once it does arrive with
  /// one.
  private var rpidsAwaitingDisplayId: Set<String> = []
  private var currentWindowEnin: Int?
  private var currentWindowId: UUID?
  private var currentWindowObservationReference: String?
  #if DEBUG
  /// Test seam for pre-seeding an already-durable observation artifact so
  /// ledger lifecycle tests do not benchmark the out-of-scope Barnard signer.
  var currentWindowIdForTesting: UUID? { currentWindowId }

  func enqueueWindowReportForRedeliveryForTesting(_ report: WindowReport) {
    _ = windowReportRedeliveryBuffer.enqueue(report)
  }

  func redeliverPendingWindowReportsForTesting() {
    redeliverPendingWindowReports()
  }
  #endif
  /// The session's first observed ENIN window — `eninStart` for the
  /// self-proof layer (§2.2). Set once, the first time `currentWindowEnin`
  /// is set (real path: `advanceWindowBookkeepingIfNeeded`; demo path:
  /// `advanceDemoWindow()`), and not touched again until the next session.
  private var firstWindowEnin: Int?
  /// The session's most recently observed ENIN window — `eninEnd` for the
  /// self-proof layer (§2.2). Unlike `currentWindowEnin`, this is never
  /// nil'd by `checkpointOpenWindowForBackgrounding()`
  /// (`docs/specs/session-end-finalization.md` §3.4): a backgrounding
  /// checkpoint deliberately nils `currentWindowEnin` mid-session (so the
  /// next detection opens a genuinely new window rather than reusing the
  /// checkpointed one, §3.6), but `finalizeSelfProofIfNeeded()` still needs
  /// the *last* window this session actually observed, even if the user
  /// stops without any further detection after the checkpoint — otherwise
  /// a checkpoint immediately followed by a stop with nothing new observed
  /// would silently fail to produce any self-proof at all, despite a
  /// complete, valid session. Mirrors `firstWindowEnin`'s own "must survive
  /// a mid-session currentWindowEnin nil" fix (§3.5) at the opposite end of
  /// the range.
  private var lastWindowEnin: Int?
  private var currentWindowRpids: Set<String> = []
  private var currentWindowReporterRpid: String?
  /// beid#114: whether the currently tracked window (`currentWindowId`) has
  /// had its ledger-runtime `openWindow` effect run yet — i.e. whether this
  /// window is eligible to be signed and durably persisted (via
  /// `windowReportStore.add`/`unsentWindowLedgerRuntime.closeWindow`) when it
  /// eventually closes. Reset `false` every time a new window starts
  /// (`openNewWindowState(enin:)`), set `true` by `ensureLedgerWindowOpen()`
  /// the moment `phase` first reaches `.recording` — which may be on the same
  /// detection that opened this window (confirming exactly at a boundary) or
  /// any later detection while this same window is still open (confirming
  /// mid-window). A window that closes with this still `false` produces no
  /// `WindowReport` and no ledger call at all: per
  /// `docs/specs/eventfound-window-signing.md` §4's accepted trade-off,
  /// windows observed before the mutual-sensing threshold is first crossed
  /// are withheld entirely, not retroactively signed.
  ///
  /// Deliberately independent of `phase` itself at close time: `phase` only
  /// ever moves forward (never back out of `.recording`), so gating window
  /// bookkeeping's own boundary-crossing logic
  /// (`advanceWindowBookkeepingIfNeeded(enin:eventCode:)`) on this flag,
  /// rather than re-reading `phase`, keeps that function decidable from
  /// purely local state without re-deriving what `phase` was at the moment
  /// the now-closing window opened.
  private var currentWindowLedgerOpened = false
  /// Policy-free, process-local redelivery of already-signed artifacts whose
  /// native durable write did not complete. Shared remains the sole owner of
  /// window/report status; this buffer stores no attempts, expiry, or backoff.
  private var windowReportRedeliveryBuffer = WindowReportRedeliveryBuffer()
  /// `commit = H(event signing key ‖ owner key ‖ salt)`, fixed once per
  /// event at the instant it's found (§5 — the owner key is a cross-event
  /// anchor "fixed at event time"). Carried on every window report signed
  /// during this session.
  private var activeCommit: Data?
  private var activeProofId: UUID?
  /// The in-flight binding attempt's fixed message, reused across the
  /// wallet `personal_sign` message and the later owner-key wallet-ack so
  /// both reference identical `nonce`/`issuedAt` (`BindingMessage`'s
  /// `issuedAt` must not be recomputed with a fresh `Date()` between the
  /// two steps).
  private var pendingBindingMessage: BindingMessage?

  private var demoStepDelayNanos: UInt64 {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-beid-ui-test") {
      return 2_000_000_000
    }
    #endif
    return 700_000_000
  }

  #if DEBUG
  /// Forced on for the simulator (no BLE radio); can be overridden for
  /// tests and controlled demo walkthroughs.
  var useDemoEventMode: Bool = {
    #if targetEnvironment(simulator)
    return true
    #else
    // Real devices default to the real sensing path; the launch argument
    // lets a driver (devicectl) run the scripted demo walkthrough on
    // device, e.g. to collect a proof for wallet-signing E2E.
    return ProcessInfo.processInfo.arguments.contains("-beid-demo-event")
    #endif
  }()
  #else
  /// Fabricated proof data must never enter a shipping build's sensing path.
  /// Keep the setter shape so Release-configured tests can prove assignments
  /// have no effect.
  var useDemoEventMode: Bool {
    get { false }
    set {}
  }
  #endif

  convenience init(
    registryClient: ExportedKotlinPackages.org.levarac.parallax.registry.RegistryClient? =
      RegistryDependencies.createClient()
  ) {
    let sensingCryptography = BarnardSensingCryptography()
    let allowInsecureLoopbackForTests: Bool
    #if DEBUG
    allowInsecureLoopbackForTests = ProcessInfo.processInfo.environment[
      "BEID_RUN_OPERATOR_SUBMISSION_TEST"
    ] == "1"
    #else
    allowInsecureLoopbackForTests = false
    #endif
    self.init(
      windowReportFileURL: nil,
      selfProofFileURL: nil,
      selfProofCheckpointFileURL: nil,
      bindingRecordFileURL: nil,
      sessionAggregateSnapshotFileURL: nil,
      unsentWindowLedgerFileURL: nil,
      sensingCryptography: sensingCryptography,
      reportSubmissionRuntime: ReportSubmissionRuntime.makeIfEnabled(
        eventSigningCryptography: sensingCryptography,
        definitionProvider: registryClient.map {
          RegistryEventDefinitionContextProvider(
            client: $0,
            allowInsecureLoopbackForTests: allowInsecureLoopbackForTests
          )
        },
        allowInsecureLoopbackForTests: allowInsecureLoopbackForTests
      ),
      eventIdentityVerificationSource: registryClient.map {
        RegistryEventIdentityVerificationSource(client: $0)
      }
    )
  }

  /// Test seam for beid#134 Decision 1 (`docs/specs/ledger-async-io.md` §4,
  /// Option B): exercises the exact async queue-during-load path the
  /// production `convenience init()` above uses — placeholder stores,
  /// `isLedgerLoading`, a background load/reconcile task, and the
  /// detection queue/drain — against an isolated directory instead of the
  /// default on-device paths, so `BeidTests` can construct a coordinator
  /// whose stores are still loading and exercise
  /// `handleDetection`/`isLedgerLoading` during that window. Unlike the
  /// explicit-storage-seam initializer below (which hands over
  /// already-loaded stores and never sets `isLedgerLoading`), this is what
  /// proves the queue/drain mechanism itself, not a stand-in for it.
  convenience init(
    loadingFromDirectory directory: URL,
    sensingCryptography: any SensingCryptography,
    reportSubmissionRuntime: (any WindowReportSubmissionRuntimeProtocol)? = nil,
    eventIdentityVerificationSource: (any EventIdentityVerificationSource)? = nil
  ) {
    self.init(
      windowReportFileURL: directory.appendingPathComponent("window-reports.json"),
      selfProofFileURL: directory.appendingPathComponent("self-proofs.json"),
      selfProofCheckpointFileURL: directory.appendingPathComponent("self-proof-checkpoint.json"),
      bindingRecordFileURL: directory.appendingPathComponent("binding-records.json"),
      sessionAggregateSnapshotFileURL: directory.appendingPathComponent("session-aggregate-snapshots.json"),
      unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
      sensingCryptography: sensingCryptography,
      reportSubmissionRuntime: reportSubmissionRuntime,
      eventIdentityVerificationSource: eventIdentityVerificationSource
    )
  }

  /// Shared by the production initializer and the loading-window test seam
  /// above. Synchronously constructs `self` through the unchanged
  /// designated initializer below using throwaway placeholder stores (so
  /// that initializer's own crash-gap reconciliation runs against empty
  /// placeholder data and is a no-op — the real reconciliation happens
  /// inside `beginLedgerLoad(...)` once the real stores are loaded), then
  /// kicks off Decision 1's background load. `nil` file URLs mean "use each
  /// store's own default on-device path" (the production shape); explicit
  /// URLs are the isolated-directory test seam. `selfProofFileURL`,
  /// `bindingRecordFileURL`, and `sessionAggregateSnapshotFileURL` are all
  /// loaded synchronously and for real, not deferred — Decision 1 does not
  /// move `selfProofStore`'s, `bindingRecordStore`'s, or
  /// `sessionAggregateSnapshotStore`'s own load off the critical path (only
  /// `windowReportStore`/`unsentWindowLedgerRuntime`/
  /// `selfProofCheckpointStore` do — see `sessionAggregateSnapshotStore`'s
  /// own doc comment for why beid#166 Phase 2 falls on this side of that
  /// split), so none of the three ever needs a placeholder.
  private convenience init(
    windowReportFileURL: URL?,
    selfProofFileURL: URL?,
    selfProofCheckpointFileURL: URL?,
    bindingRecordFileURL: URL?,
    sessionAggregateSnapshotFileURL: URL?,
    unsentWindowLedgerFileURL: URL?,
    sensingCryptography: any SensingCryptography,
    reportSubmissionRuntime: (any WindowReportSubmissionRuntimeProtocol)?,
    eventIdentityVerificationSource: (any EventIdentityVerificationSource)?
  ) {
    self.init(
      windowReportStore: WindowReportStore(fileURL: Self.unloadedPlaceholderFileURL()),
      selfProofStore: SelfProofStore(fileURL: selfProofFileURL),
      selfProofCheckpointStore: SelfProofCheckpointStore(fileURL: Self.unloadedPlaceholderFileURL()),
      bindingRecordStore: BindingRecordStore(fileURL: bindingRecordFileURL),
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(fileURL: sessionAggregateSnapshotFileURL),
      unsentWindowLedgerRuntime: nil,
      sensingCryptography: sensingCryptography,
      reportSubmissionRuntime: reportSubmissionRuntime,
      eventIdentityVerificationSource: eventIdentityVerificationSource,
      initialLedgerFailure: nil
    )
    // Only this initializer chain is actually loading — see
    // `isLedgerLoading`'s doc comment for why the default is `false`.
    isLedgerLoading = true
    beginLedgerLoad(
      windowReportFileURL: windowReportFileURL,
      unsentWindowLedgerFileURL: unsentWindowLedgerFileURL,
      selfProofCheckpointFileURL: selfProofCheckpointFileURL
    )
  }

  /// A file location guaranteed not to exist, so a placeholder store's own
  /// synchronous `load()` degenerates to a single `fileExists` check
  /// instead of a real read. Used only for the brief window before
  /// `beginLedgerLoad(...)` replaces the placeholder with the real,
  /// recovered store.
  private static func unloadedPlaceholderFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-sensing-coordinator-loading-placeholder-\(UUID().uuidString).json")
  }

  /// Decision 1's background load (`docs/specs/ledger-async-io.md` §4.2):
  /// reproduces today's production recovery work (`WindowReportStore`/
  /// `UnsentWindowLedgerStore` recovery, `reconcileAfterRelaunch`,
  /// `reconcileSelfProofCheckpointIfNeeded()`) off the `init()` critical
  /// path — the designated initializer below still performs the identical
  /// reconciliation sequence synchronously for its own (already-loaded,
  /// non-placeholder) callers, so this duplicates that shape deliberately
  /// rather than changing the designated initializer's contract, which
  /// `BeidTests` relies on staying synchronous and unchanged. Hops back to
  /// replace the placeholder stores with the real, recovered ones, sets
  /// `ledgerHealth` at the same moment as today, flips `isLedgerLoading`
  /// false, then drains whatever detections queued while it ran.
  private func beginLedgerLoad(
    windowReportFileURL: URL?,
    unsentWindowLedgerFileURL: URL?,
    selfProofCheckpointFileURL: URL?
  ) {
    ledgerLoadTask = Task {
      var loadFailure: Error?

      let recoveredWindowReportStore: WindowReportStore
      do {
        let recovery = try WindowReportStore.recoveringCorruptReports(fileURL: windowReportFileURL)
        if let quarantinedURL = recovery.quarantinedReportsURL {
          Self.ledgerLog.error("Quarantined corrupt window reports at \(quarantinedURL.path, privacy: .public)")
        }
        recoveredWindowReportStore = recovery.store
      } catch {
        recoveredWindowReportStore = WindowReportStore(fileURL: windowReportFileURL)
        loadFailure = error
        Self.ledgerLog.error("Unable to recover the window report store: \(error, privacy: .public)")
      }

      var recoveredRuntime: UnsentWindowLedgerRuntime?
      do {
        let recovery = try UnsentWindowLedgerStore.recoveringCorruptSnapshot(fileURL: unsentWindowLedgerFileURL)
        if let quarantinedURL = recovery.quarantinedSnapshotURL {
          Self.ledgerLog.error("Quarantined a corrupt shared unsent-window ledger at \(quarantinedURL.path, privacy: .public)")
        }
        recoveredRuntime = try UnsentWindowLedgerRuntime(store: recovery.store)
      } catch {
        recoveredRuntime = nil
        loadFailure = error
        Self.ledgerLog.error("Unable to load the shared unsent-window ledger: \(error, privacy: .public)")
      }

      if let runtime = recoveredRuntime {
        do {
          let durableReports = try recoveredWindowReportStore.persistedReportsForLedgerRecovery()
          let persistedObservations = durableReports.map { report -> (windowId: String, reference: String) in
            let reference = report.id.uuidString.lowercased()
            return (windowId: reference, reference: reference)
          }
          try runtime.reconcileAfterRelaunch(persistedObservations: persistedObservations)
        } catch {
          recoveredRuntime = nil
          loadFailure = error
          Self.ledgerLog.error("Unable to reconcile the shared unsent-window ledger: \(error, privacy: .public)")
        }
      }

      self.windowReportStore = recoveredWindowReportStore
      self.unsentWindowLedgerRuntime = recoveredRuntime
      self.selfProofCheckpointStore = SelfProofCheckpointStore(fileURL: selfProofCheckpointFileURL)
      if let loadFailure {
        self.ledgerHealth = .degraded(reason: loadFailure, since: Date())
      }
      self.reconcileSelfProofCheckpointIfNeeded()
      self.logOwnerKeyRegenerationSignalsIfNeeded()
      self.isLedgerLoading = false
      self.reportSubmissionRuntime?.submitPending()
      self.drainQueuedDetectionsAfterLoad()
    }
  }

  /// gh#156 regeneration-detectability (`docs/specs/owner-key-seed-read-failure.md`
  /// §8): checked once per launch, from inside `beginLedgerLoad(...)`'s
  /// background Task (beid#134 DECISIONS 2026-08-09 ruling) rather than
  /// synchronously from `AppCoordinator.init()` — this is the same point
  /// that already calls `reconcileSelfProofCheckpointIfNeeded()`, after the
  /// real stores are assigned and before `isLedgerLoading` flips `false` or
  /// the detection queue drains, so the check completes before any new
  /// detection-driven record could be created. Signal A/B are only
  /// informative at this scope — no UI/UX response is designed yet (§11) —
  /// so this only logs, the same posture `CorruptStoreQuarantine` and this
  /// type's own reconciliation failures already take for a
  /// detected-but-unsurfaced condition.
  private func logOwnerKeyRegenerationSignalsIfNeeded() {
    if let quarantinedSeedKey = quarantinedOwnerKeySeedKey {
      Self.ledgerLog.error("Owner key seed was quarantined and regenerated this session at \(quarantinedSeedKey, privacy: .public)")
    }
    if ownerPublicKeyMismatchDetected {
      Self.ledgerLog.error("Owner public key does not match some already-persisted self-proof/binding record")
    }
  }

  /// Explicit storage seam for tests and controlled hosts. Unlike the
  /// production default initializer, this keeps strict fail-closed loading
  /// and never quarantines the caller-provided file implicitly.
  convenience init(
    windowReportStore: WindowReportStore,
    selfProofStore: SelfProofStore,
    selfProofCheckpointStore: SelfProofCheckpointStore,
    bindingRecordStore: BindingRecordStore,
    sessionAggregateSnapshotStore: SessionAggregateSnapshotStore,
    unsentWindowLedgerFileURL: URL,
    sensingCryptography: any SensingCryptography,
    reportSubmissionRuntime: (any WindowReportSubmissionRuntimeProtocol)? = nil,
    eventIdentityVerificationSource: (any EventIdentityVerificationSource)? = nil
  ) {
    guard
      let store = try? UnsentWindowLedgerStore(fileURL: unsentWindowLedgerFileURL),
      let runtime = try? UnsentWindowLedgerRuntime(store: store)
    else {
      preconditionFailure("Unable to create isolated unsent-window ledger")
    }
    self.init(
      windowReportStore: windowReportStore,
      selfProofStore: selfProofStore,
      selfProofCheckpointStore: selfProofCheckpointStore,
      bindingRecordStore: bindingRecordStore,
      sessionAggregateSnapshotStore: sessionAggregateSnapshotStore,
      unsentWindowLedgerRuntime: runtime,
      sensingCryptography: sensingCryptography,
      reportSubmissionRuntime: reportSubmissionRuntime,
      eventIdentityVerificationSource: eventIdentityVerificationSource
    )
  }

  init(
    windowReportStore: WindowReportStore,
    selfProofStore: SelfProofStore,
    selfProofCheckpointStore: SelfProofCheckpointStore,
    bindingRecordStore: BindingRecordStore,
    sessionAggregateSnapshotStore: SessionAggregateSnapshotStore,
    unsentWindowLedgerRuntime: (any UnsentWindowLedgerRuntimeProtocol)?,
    sensingCryptography: any SensingCryptography,
    reportSubmissionRuntime: (any WindowReportSubmissionRuntimeProtocol)? = nil,
    eventIdentityVerificationSource: (any EventIdentityVerificationSource)? = nil,
    initialLedgerFailure: Error? = nil
  ) {
    var recoveredRuntime = unsentWindowLedgerRuntime
    var ledgerFailure = initialLedgerFailure
    if let runtime = recoveredRuntime {
      do {
        // TODO: Construction currently performs relaunch reconciliation even
        // for same-process coordinator replacement. Introduce an explicit
        // process-relaunch signal before narrowing this without weakening
        // crash-gap recovery. See beid#134.
        let durableReports = try windowReportStore.persistedReportsForLedgerRecovery()
        let persistedObservations = durableReports.map { report in
          let reference = report.id.uuidString.lowercased()
          return (windowId: reference, reference: reference)
        }
        try runtime.reconcileAfterRelaunch(persistedObservations: persistedObservations)
      } catch {
        recoveredRuntime = nil
        ledgerFailure = error
        Self.ledgerLog.error("Unable to reconcile the shared unsent-window ledger: \(error, privacy: .public)")
      }
    }

    self.windowReportStore = windowReportStore
    self.selfProofStore = selfProofStore
    self.selfProofCheckpointStore = selfProofCheckpointStore
    self.bindingRecordStore = bindingRecordStore
    self.sessionAggregateSnapshotStore = sessionAggregateSnapshotStore
    self.unsentWindowLedgerRuntime = recoveredRuntime
    self.sensingCryptography = sensingCryptography
    self.reportSubmissionRuntime = reportSubmissionRuntime
    self.eventIdentityVerificationSource = eventIdentityVerificationSource
    if let ledgerFailure {
      ledgerHealth = .degraded(reason: ledgerFailure, since: Date())
    }
    engine.onEvent = { [weak self] event in
      guard let self else { return }
      Task { @MainActor in self.handle(event) }
    }
    reconcileSelfProofCheckpointIfNeeded()
  }

  deinit {
    let request = eventIdentityVerificationRequest
    Task { @MainActor in
      request?.cancel()
    }
  }

  private func handle(_ event: BarnardEvent) {
    switch event {
    case .state(let state):
      isScanning = state.isScanning
      isAdvertising = state.isAdvertising
    case .detection(let detection):
      handleDetection(
        enin: detection.enin,
        rpid: detection.rpid,
        detectedDisplayId: detection.detectedDisplayId,
        reporterRpid: detection.reporterRpid
      )
    default:
      break
    }
  }

  /// Not `private`: `BarnardDetectionEvent` has no public initializer
  /// (Barnard module boundary), so `BeidTests` cannot construct one to
  /// drive this path — taking the fields it actually needs as plain
  /// arguments instead lets tests exercise the real (non-demo) detection
  /// path directly. Production code only ever reaches this via `handle(_:)`
  /// above, already MainActor-isolated via `engine.onEvent`'s
  /// `Task { @MainActor in }`.
  ///
  /// `detectedDisplayId` has no default on purpose: it is optional data, and
  /// a caller that omitted it would silently produce an observation that
  /// cannot be attributed to a device. Every caller must say what it
  /// observed.
  func handleDetection(
    enin: Int,
    rpid: String,
    detectedDisplayId: String?,
    reporterRpid: String? = nil
  ) {
    // beid#134 Decision 1: while the background load is still recovering
    // stores, queue the whole raw detection instead of processing it —
    // every ledger-relevant native state field this function's cases would
    // otherwise set is only ever set as a *consequence* of processing one,
    // so queuing whole keeps every other method's existing nil-state guard
    // correct for free. See `queuedDetectionsWhileLoading` and
    // `docs/specs/ledger-async-io.md` §4.2.
    guard !isLedgerLoading else {
      queuedDetectionsWhileLoading.append(
        (
          enin: enin,
          rpid: rpid,
          detectedDisplayId: detectedDisplayId,
          reporterRpid: reporterRpid
        )
      )
      return
    }
    switch phase {
    case .sensing:
      let eventCode = engine.getCurrentEventCode() ?? "Unknown Event"
      let session = EventSession(
        id: eventCode,
        name: eventCode,
        venue: nil,
        canonicalEventIdHex: pendingCanonicalEventIdHex
      )
      beginEventFoundSessionState(session)
      observe(
        enin: enin,
        rpid: rpid,
        detectedDisplayId: detectedDisplayId,
        reporterRpid: reporterRpid,
        for: session
      )
    case .eventFound(let session):
      observe(
        enin: enin,
        rpid: rpid,
        detectedDisplayId: detectedDisplayId,
        reporterRpid: reporterRpid,
        for: session
      )
    case .recording(let session, _):
      observe(
        enin: enin,
        rpid: rpid,
        detectedDisplayId: detectedDisplayId,
        reporterRpid: reporterRpid,
        for: session
      )
    case .idle, .signalLost:
      // `.signalLost` is frozen — real signal-loss *detection* doesn't
      // exist yet (only the demo-only manual trigger does), so this branch
      // is unreached today, but resuming is an explicit user action
      // (`resumeSensing()`), never automatic on the next detection. This
      // native-side gate decides only whether to run the side-effecting
      // window/device accounting below at all — the phase decision itself
      // (`BeidSharedKit.sensing.applyScanDetection` would also report these
      // two phases as "ignored") is not duplicated here.
      break
    }
  }

  /// Records the detection against the running device count and window, then
  /// asks `BeidSharedKit.sensing` (beid#116) what phase transition, if any,
  /// that observation implies, and projects its answer onto `phase` and the
  /// existing UI-facing callbacks. This adapter holds no threshold or
  /// transition-graph logic of its own — see `applyScanDetection`'s doc
  /// comment in `shared/.../sensing/ScanPhase.kt` for the full rule set.
  ///
  /// The within-window set (`currentWindowRpids`, which feeds
  /// `WindowReport.peerCount`) stays keyed on the proximity identifier and is
  /// deliberately untouched by beid#154: identifiers do not rotate *inside* a
  /// window, so counting them there already yields devices.
  ///
  /// beid#114: `advanceWindowBookkeepingIfNeeded(enin:eventCode:)` — the
  /// ENIN-boundary tracking that clears `currentWindowRpids` and feeds the
  /// co-presence threshold arm below — runs first and unconditionally,
  /// exactly like the pre-#114 `advanceWindowIfNeeded` did, regardless of
  /// `phase`. That ordering is required, not incidental: this call's own
  /// `coPresentDeviceCount` argument reads `currentWindowRpids.count` right
  /// after, so a boundary crossing must already have cleared it for *this*
  /// window before the threshold is evaluated, or a lingering device's
  /// rotated rpid from a previous window would still be counted (see
  /// `currentWindowLedgerOpened`'s doc comment and the shared reducer's own
  /// "cleared at every window boundary" invariant). Only the ledger-touching
  /// sign/persist side of window management
  /// (`ensureLedgerWindowOpen()`/the close half inside
  /// `advanceWindowBookkeepingIfNeeded`) is deferred to `.recording`, gated
  /// below on `result.resultingPhase` — which must be read from the
  /// reducer's *result* for this same detection, not from `phase` before the
  /// call, so the very detection that confirms the event is also the one
  /// allowed to open/use its own window immediately.
  private func observe(
    enin: Int,
    rpid: String,
    detectedDisplayId: String?,
    reporterRpid: String?,
    for session: EventSession
  ) {
    advanceWindowBookkeepingIfNeeded(enin: enin, eventCode: session.id)
    if currentWindowReporterRpid == nil {
      currentWindowReporterRpid = reporterRpid
    }
    currentWindowRpids.insert(rpid)

    let deviceCountChanged = recordDeviceIdentity(enin: enin, rpid: rpid, detectedDisplayId: detectedDisplayId)

    let result = applyPhaseDecision(
      coPresentDeviceCount: currentWindowRpids.count,
      distinctDeviceCountChanged: deviceCountChanged,
      for: session
    )

    if result.resultingPhase == .RECORDING {
      ensureLedgerWindowOpen()
    }
  }

  /// Calls the shared phase reducer (`BeidSharedKit.sensing.applyScanDetection`,
  /// beid#116) with the given counts for `session`'s current phase, and
  /// applies its result to `phase` and the existing UI-facing callbacks —
  /// the phase-decision half of what `observe(_:)` used to do entirely
  /// inline. Shared by the real detection path (`observe(_:)` above, which
  /// also runs the real ENIN-window/ledger-lifecycle half below it) and
  /// demo mode (`runDemoSequence`/`continueDemoRecording`, beid#189).
  ///
  /// Deliberately does not call `ensureLedgerWindowOpen()` — only
  /// `observe(_:)` does that, gated on `result.resultingPhase == .RECORDING`,
  /// exactly as before this was extracted. Demo mode legitimately has no
  /// ENIN window or ledger to open, and routing it through that half
  /// instead of stopping here is not an available design choice: DECISIONS
  /// 2026-08-01 ("Scan Slice-2 の検証は4台以上のグループセッションで行う") names this
  /// file's own "Fabricated proof data must never enter a shipping build's
  /// sensing path" comment as its reasoning for keeping demo paths out of
  /// any path that produces real attestation artifacts — `closeWindow`'s
  /// signed, persisted `WindowReport`s and `unsentWindowLedgerRuntime`'s
  /// ledger rows are exactly that, so demo mode calling only this half,
  /// never `observe(_:)` whole, is required by that decision, not a
  /// preference weighed against it.
  ///
  /// Callers must supply an honestly-tracked `coPresentDeviceCount` — never
  /// a stand-in value chosen to force a particular outcome. Feeding this
  /// function (which calls the real, shared reducer) a fabricated count
  /// would be its own form of the same violation the paragraph above
  /// describes, one level removed: DECISIONS 2026-08-01's concern is
  /// fabricated data reaching a real decision path, and this function *is*
  /// that path for phase decisions, even though it touches no store. See
  /// `demoWindowRpids`'s own doc comment for how the demo caller satisfies
  /// this.
  @discardableResult
  private func applyPhaseDecision(
    coPresentDeviceCount: Int,
    distinctDeviceCountChanged: Bool,
    for session: EventSession,
    startIdentityVerification: Bool = true
  ) -> BeidSharedKit.sensing.ScanDetectionResult {
    let result = BeidSharedKit.sensing.applyScanDetection(
      currentPhase: currentPhaseKind,
      coPresentDeviceCount: Int32(coPresentDeviceCount),
      distinctDeviceCount: Int32(devicesVerified),
      distinctDeviceCountChanged: distinctDeviceCountChanged,
      eventConfirmThreshold: Int32(BeidConfig.eventConfirmThreshold)
    )

    // `result.confirmedEvent` is checked first, ahead of
    // `transitionedToEventFound`: when both are true (the DEBUG
    // `-beid-threshold-override 1` edge case — see `ScanDetectionResult`'s
    // doc comment), `phase` moves straight from `.sensing` to `.recording`
    // and is never published as `.eventFound` in between. Pre-#116, native
    // code published the intermediate `.eventFound` value first (via the
    // old `beginEventFound` setting `phase` directly) before immediately
    // overwriting it with `.recording` in the same call — an artifact of
    // native's call sequence, not a documented behavior any test observed.
    // The final phase and every observable side effect (Proof creation,
    // callbacks) are identical either way. Demo mode reproduces this same
    // edge case for free now, since it calls this same function — before
    // this split it could not, since it always hardcoded a separate
    // `.eventFound` step first.
    let shouldStartIdentityVerification = startIdentityVerification
      && session.identityVerification == .notChecked
      && session.canonicalEventIdHex != nil
    let eventToPublish: EventSession
    if shouldStartIdentityVerification
    {
      // Publish `.checking` in the phase payload before starting the native
      // request. The same payload is then copied into pending binding state by
      // `beginRecording` when confirmation happens on this detection.
      eventToPublish = session.replacingIdentityVerification(.checking)
    } else {
      eventToPublish = session
    }

    if result.confirmedEvent {
      Self.log.notice(
        """
        Event confirmed via \(self.hasEnoughCoPresentDevicesToConfirm(coPresentDeviceCount) ? "co-presence" : "distinct devices", privacy: .public): \
        \(coPresentDeviceCount, privacy: .public) co-present this window, \
        \(self.devicesVerified, privacy: .public) identified this session, \
        \(self.unidentifiedRpidCount, privacy: .public) unidentified
        """
      )
      beginRecording(event: eventToPublish, peersVerified: devicesVerified)
    } else if result.transitionedToEventFound {
      phase = .eventFound(eventToPublish)
    } else if result.updatedRecording {
      updateRecording(event: eventToPublish, peersVerified: devicesVerified)
    }

    if shouldStartIdentityVerification {
      startEventIdentityVerificationIfNeeded(for: eventToPublish)
    }

    return result
  }

  /// Begins one eager lookup after the first real event payload is published.
  /// Demo callers pass `startIdentityVerification: false`, so a demo event can
  /// carry a fixture hint without ever reaching this seam.
  private func startEventIdentityVerificationIfNeeded(for event: EventSession) {
    guard event.identityVerification == .checking,
          let hint = event.canonicalEventIdHex,
          let currentEvent = currentEventSession,
          currentEvent.sessionID == event.sessionID,
          currentEvent.id == event.id,
          currentEvent.canonicalEventIdHex == hint
    else { return }

    eventIdentityVerificationGeneration &+= 1
    eventIdentityVerificationRequest?.cancel()
    eventIdentityVerificationRequest = nil
    let generation = eventIdentityVerificationGeneration
    eventIdentityVerificationSessionID = event.sessionID
    eventIdentityVerificationEventID = event.id
    eventIdentityVerificationHint = hint

    guard let source = eventIdentityVerificationSource else {
      handleEventIdentityVerificationResolution(
        EventIdentityVerificationResolution(
          isSuccess: false,
          context: nil,
          errorCode: nil,
          errorMessage: "registry client unavailable"
        ),
        generation: generation,
        sessionID: event.sessionID,
        eventID: event.id,
        hint: hint
      )
      return
    }

    let request = source.resolve(eventIdHex: hint) { [weak self] resolution in
      Task { @MainActor [weak self] in
        self?.handleEventIdentityVerificationResolution(
          resolution,
          generation: generation,
          sessionID: event.sessionID,
          eventID: event.id,
          hint: hint
        )
      }
    }
    eventIdentityVerificationRequest = request
  }

  /// Applies only a current completion. All live event-bearing state is
  /// updated synchronously on MainActor, while cancelled requests deliberately
  /// leave `.checking` unchanged.
  private func handleEventIdentityVerificationResolution(
    _ resolution: EventIdentityVerificationResolution,
    generation: Int,
    sessionID: UUID,
    eventID: String,
    hint: String
  ) {
    guard generation == eventIdentityVerificationGeneration,
          eventIdentityVerificationSessionID == sessionID,
          eventIdentityVerificationEventID == eventID,
          eventIdentityVerificationHint == hint,
          let currentEvent = currentEventSession,
          currentEvent.sessionID == sessionID,
          currentEvent.id == eventID,
          currentEvent.canonicalEventIdHex == hint
    else { return }

    guard let outcome = EventIdentityVerificationMapper.map(resolution) else {
      eventIdentityVerificationRequest = nil
      return
    }

    phase = phase.updatingIdentityVerification(
      forEventID: eventID,
      to: outcome
    )
    bindingState = bindingState.updatingIdentityVerification(
      forEventID: eventID,
      to: outcome
    )
    eventIdentityVerificationRequest = nil
  }

  /// Invalidates the current lookup before any lifecycle operation can expose
  /// a later session to its callback.
  private func invalidateEventIdentityVerification() {
    eventIdentityVerificationGeneration &+= 1
    eventIdentityVerificationRequest?.cancel()
    eventIdentityVerificationRequest = nil
    eventIdentityVerificationSessionID = nil
    eventIdentityVerificationEventID = nil
    eventIdentityVerificationHint = nil
  }

  /// `BeidSharedKit.sensing.ScanPhaseKind` mirroring `phase`, without its
  /// native-owned associated data (`EventSession`/`peersVerified`) — the
  /// conversion half of the adapter contract for every call into
  /// `BeidSharedKit.sensing`.
  private var currentPhaseKind: BeidSharedKit.sensing.ScanPhaseKind {
    switch phase {
    case .idle: return .IDLE
    case .sensing: return .SENSING
    case .eventFound: return .EVENT_FOUND
    case .recording: return .RECORDING
    case .signalLost: return .SIGNAL_LOST
    }
  }

  /// Maps a `BeidSharedKit.sensing.ScanPhaseKind` known to carry no payload
  /// (only ever `.IDLE`/`.SENSING`, from `scanPhaseAfterStartSensing()`/
  /// `scanPhaseAfterStopSensing()`) onto the matching native `ScanPhase`.
  /// Swift Export represents this Kotlin enum as a class of static members,
  /// not a native `enum`, so this compares by value (`==`) rather than
  /// `switch`-pattern-matching on it.
  private static func payloadlessNativePhase(_ kind: BeidSharedKit.sensing.ScanPhaseKind) -> ScanPhase {
    if kind == .IDLE {
      return .idle
    }
    if kind == .SENSING {
      return .sensing
    }
    preconditionFailure("scanPhaseAfterStartSensing/scanPhaseAfterStopSensing only ever return .IDLE or .SENSING")
  }

  /// Files this observation against the session's device identity accounting
  /// and reports whether `devicesVerified` moved.
  ///
  /// This is the display and signed-payload half of the split: it is keyed on
  /// the stable display id and is deliberately **not** what gates
  /// `.recording`.
  ///
  /// Every observation is recorded into `aggregationRuntime` — including one
  /// with no display id — so shared's accumulated input stays a complete row
  /// set. `unidentifiedRpidCount`/`rpidsAwaitingDisplayId` bookkeeping below
  /// is untouched from before beid#109/#162: it is a deliberately different
  /// quantity from anything `BeidSharedKit.aggregation` reports (see
  /// `unidentifiedRpidCount`'s doc comment), so it stays purely native.
  private func recordDeviceIdentity(enin: Int, rpid: String, detectedDisplayId: String?) -> Bool {
    // Canonicalization (lowercasing) is `BeidSharedKit.sensing
    // .normalizedDisplayIdOrNull` (beid#231) — the same `shared/` decision
    // Android's `ScanDeviceAccounting.record` applies, not a native
    // `.lowercased()` check owned here.
    let displayId = BeidSharedKit.sensing.normalizedDisplayIdOrNull(detectedDisplayId: detectedDisplayId)

    if displayId == nil {
      if rpidsAwaitingDisplayId.insert(rpid).inserted {
        unidentifiedRpidCount = rpidsAwaitingDisplayId.count
        Self.log.notice(
          """
          Observation with no display id (Barnard B003 unavailable): \
          \(self.unidentifiedRpidCount, privacy: .public) unidentified so far, \
          \(self.devicesVerified, privacy: .public) identified devices
          """
        )
      }
    } else if rpidsAwaitingDisplayId.remove(rpid) != nil {
      unidentifiedRpidCount = rpidsAwaitingDisplayId.count
    }

    aggregationRuntime.recordObservation(windowIndex: enin, peerKey: rpid, displayId: displayId)
    let aggregate = aggregationRuntime.sessionAggregate
    sessionAggregate = aggregate
    let updatedDeviceCount = Int(aggregate.deviceCount)
    guard updatedDeviceCount != devicesVerified else { return false }
    devicesVerified = updatedDeviceCount
    return true
  }

  /// Whether the co-presence arm is why an event just confirmed — used only
  /// to pick the right word in `applyPhaseDecision`'s log line. The confirm
  /// decision itself (both arms, and their disjunction) is
  /// `BeidSharedKit.sensing.shouldConfirmScanEvent` (beid#116); see that
  /// function's doc comment in `shared/.../sensing/ScanPhase.kt` for why
  /// each arm resists accumulation and why a single lingering device
  /// satisfies neither — this adapter keeps no comparison of its own that
  /// could drift from it.
  ///
  /// Takes `coPresentDeviceCount` as a parameter (beid#189) rather than
  /// reading `currentWindowRpids.count` directly, since `applyPhaseDecision`
  /// — this function's only call site — is shared by both the real path
  /// (whose co-presence count is `currentWindowRpids.count`) and demo mode
  /// (whose count is `demoWindowRpids.count`).
  private func hasEnoughCoPresentDevicesToConfirm(_ coPresentDeviceCount: Int) -> Bool {
    BeidSharedKit.sensing.hasEnoughCoPresentDevicesToConfirmScanEvent(
      coPresentDeviceCount: Int32(coPresentDeviceCount),
      eventConfirmThreshold: Int32(BeidConfig.eventConfirmThreshold)
    )
  }

  /// Calls the Barnard SDK's join API (`BarnardEngine.joinEvent`)
  /// with a manually entered event code — the wallet-optional fallback path
  /// (`EventCodeEntryView`) for choosing which event to sense, since there
  /// is no BLE auto-discovery yet. Returns whether the code took effect.
  @discardableResult
  func joinEvent(_ code: String, canonicalEventIdHex: String? = nil) -> Bool {
    engine.joinEvent(code)
    let confirmed = engine.getCurrentEventCode()
    joinedEventCode = confirmed
    joinedCanonicalEventIdHex = confirmed == code ? canonicalEventIdHex : nil
    return confirmed == code
  }

  /// Calls the Barnard SDK's leave API (`BarnardEngine.leaveEvent`) to clear
  /// a manually joined event code, symmetric with `joinEvent(_:)`.
  func leaveEvent() {
    invalidateEventIdentityVerification()
    engine.leaveEvent()
    joinedEventCode = engine.getCurrentEventCode()
    joinedCanonicalEventIdHex = nil
  }

  /// Retries the current real event's registry lookup only after a terminal
  /// `.unavailable` or `.notFound` result. There is no view-level automatic
  /// retry loop; the registry client's own retry remains the only automatic
  /// retry in this slice.
  func retryEventIdentityVerification() {
    guard let event = currentEventSession,
          event.canonicalEventIdHex != nil
    else { return }
    guard event.identityVerification == .unavailable
      || event.identityVerification == .notFound
    else { return }

    invalidateEventIdentityVerification()
    let checkingEvent = event.replacingIdentityVerification(.checking)
    phase = phase.updatingIdentityVerification(
      forEventID: event.id,
      to: .checking
    )
    bindingState = bindingState.updatingIdentityVerification(
      forEventID: event.id,
      to: .checking
    )
    startEventIdentityVerificationIfNeeded(for: checkingEvent)
  }

  func startSensing(
    eventCode: String? = nil,
    eventIdHex: String? = nil,
    demoEvent: EventSession? = nil,
    demoScenario: DemoScenario? = nil
  ) {
    let eventCode = eventCode ?? joinedEventCode ?? "beid-demo-event"
    let canonicalEventIdHex = eventIdHex ?? joinedCanonicalEventIdHex
    resetSessionState()
    pendingCanonicalEventIdHex = canonicalEventIdHex
    reportSubmissionRuntime?.submitPending()
    phase = Self.payloadlessNativePhase(BeidSharedKit.sensing.scanPhaseAfterStartSensing())
    if useDemoEventMode {
      var selectedScenario = demoScenario ?? BeidConfig.demoScenario()
      if let demoEvent {
        selectedScenario = selectedScenario.replacingEvent(demoEvent)
      }
      runDemoScenario(selectedScenario, stepDelayNanos: demoStepDelayNanos)
    } else {
      engine.requestPermissions { [weak self] status in
        guard let self else { return }
        Task { @MainActor in
          guard status.canScan, status.canAdvertise else { return }
          self.engine.configure(eventCode: eventCode)
          self.engine.startAuto()
        }
      }
    }
  }

  @discardableResult
  func stopSensing() -> SelfProofRecord? {
    endSensing(stopEngine: true)
  }

  /// Manual trigger so the Signal Lost screen is reachable from the demo
  /// flow (the golden EventSession path itself keeps recording
  /// indefinitely otherwise). `BeidSharedKit.sensing.scanPhaseAfterSignalLost`
  /// (beid#116) is the sole authority on whether this applies; the
  /// `case .recording` match below only extracts the payload it has already
  /// confirmed is there, it does not re-decide.
  func simulateSignalLost() {
    let result = BeidSharedKit.sensing.scanPhaseAfterSignalLost(currentPhase: currentPhaseKind)
    guard result.applied, case .recording(let event, let peersVerified) = phase else { return }
    demoTask?.cancel()
    clearDemoInterpreterState()
    phase = .signalLost(event: event, peersVerified: peersVerified)
  }

  /// Resumes the same `EventSession`/count in place — never a restart, so
  /// nothing already recorded (the stored `Proof`, queued window reports)
  /// is discarded (D4, §5.4). Real BLE signal-loss *detection* (vs. this
  /// demo-only manual trigger) is still unimplemented, so on a real device
  /// this only clears the frozen UI state — scanning was never stopped, so
  /// `handle(_:)` keeps updating `peersVerified` in place regardless.
  /// `BeidSharedKit.sensing.scanPhaseAfterResumeSensing` (beid#116) is the
  /// sole authority on whether this applies.
  func resumeSensing() {
    let result = BeidSharedKit.sensing.scanPhaseAfterResumeSensing(currentPhase: currentPhaseKind)
    guard result.applied, case .signalLost(let event, let peersVerified) = phase else { return }
    phase = .recording(event: event, peersVerified: peersVerified)
    if resumeParkedDemoScenarioIfNeeded() {
      return
    }
    if useDemoEventMode {
      continueDemoRecording(event: event, stepDelayNanos: demoStepDelayNanos)
    }
  }

  /// Marks the one-time entrance ceremony consumed so it never replays —
  /// called once by `RecordingView` the first time it appears for this
  /// session (including across a `resumeSensing()` cycle, since this flag
  /// outlives the view instance).
  func markRecordingCeremonyShown() {
    recordingCeremonyShown = true
  }

  /// Marks the entrance ceremony's on-screen dwell as over — called by
  /// `RecordingView` either once its 2-second "Proof Collected" dwell
  /// timer completes, or immediately if there was no ceremony to show at
  /// all this time (`recordingCeremonyShown` already `true`, e.g. after a
  /// `resumeSensing()` cycle). Both paths converge here because
  /// `ScanFlowView` only cares whether the ceremony is done occupying the
  /// screen, not which of the two reasons made that true right now.
  func markEntranceCeremonyFinished() {
    entranceCeremonyFinished = true
  }

  @discardableResult
  func reset() -> SelfProofRecord? {
    endSensing(stopEngine: false)
  }

  private func endSensing(stopEngine: Bool) -> SelfProofRecord? {
    let selfProof = finalizeSelfProofIfNeeded()
    persistSessionAggregateSnapshotIfNeeded()
    closeFinalWindowIfNeeded()
    demoTask?.cancel()
    demoTask = nil
    if stopEngine {
      engine.stopAuto()
    }
    resetSessionState()
    phase = Self.payloadlessNativePhase(BeidSharedKit.sensing.scanPhaseAfterStopSensing())
    reportSubmissionRuntime?.submitPending()
    return selfProof
  }

  private func resetSessionState() {
    invalidateEventIdentityVerification()
    aggregationRuntime = AggregationRuntime()
    sessionAggregate = nil
    demoDeviceSequence = 0
    rpidsAwaitingDisplayId = []
    devicesVerified = 0
    unidentifiedRpidCount = 0
    currentWindowEnin = nil
    currentWindowId = nil
    currentWindowObservationReference = nil
    firstWindowEnin = nil
    lastWindowEnin = nil
    demoWindowEnin = 0
    demoWindowRpids = []
    clearDemoInterpreterState()
    currentWindowRpids = []
    currentWindowReporterRpid = nil
    currentWindowLedgerOpened = false
    pendingCanonicalEventIdHex = nil
    activeCommit = nil
    activeProofId = nil
    pendingBindingMessage = nil
    bindingState = .none
    recordingCeremonyShown = false
    entranceCeremonyFinished = false
  }

  // MARK: - Shared phase transitions
  //
  // Called synchronously from the real detection path (`observe`) and from
  // explicitly MainActor-isolated demo tasks below.

  /// Computes and fixes this session's `commit` (§5 — "fixed at event
  /// time") for a newly detected session and resets prior-session state
  /// first so nothing leaks across events. Does not itself set `phase` —
  /// used by both the real detection path (`handleDetection`'s `.sensing`
  /// case, where `observe`, immediately after, asks
  /// `BeidSharedKit.sensing.applyScanDetection` (beid#116) to decide the
  /// `.sensing -> .eventFound` transition for this same detection) and demo
  /// mode (`runDemoSequence`, beid#189, whose first synthesized device
  /// drives the same transition through the same shared reducer via
  /// `applyPhaseDecision`).
  private func beginEventFoundSessionState(_ session: EventSession) {
    resetSessionState()
    let eventSigningKey = sensingCryptography.eventSigningPublicKey(eventCode: session.id)
    let ownerKey = sensingCryptography.ownerPublicKey()
    let salt = Data(randomSource.randomBytes(count: 16))
    activeCommit = EventCommitment.compute(eventSigningKey: eventSigningKey, ownerKey: ownerKey, salt: salt)
  }

  /// Threshold-confirm (D3, §4.3): creates the `Proof` the instant
  /// `.recording` begins and marks the event `.pendingConnect` for the next
  /// foreground wallet-binding opportunity (2b builds the interstitial that
  /// consumes this; 2a only sets the state).
  private func beginRecording(event: EventSession, peersVerified: Int) {
    phase = .recording(event: event, peersVerified: peersVerified)
    let proofId = UUID()
    activeProofId = proofId
    let proof = Proof(id: proofId, eventName: event.name, date: Date(), peersVerified: peersVerified, eventCode: event.id)
    onProofCollected?(proof)
    bindingState = .pendingConnect(event)
  }

  /// Updates the already-created `Proof` in place as more distinct peers
  /// are observed (§4.6) — never re-created.
  private func updateRecording(event: EventSession, peersVerified: Int) {
    phase = .recording(event: event, peersVerified: peersVerified)
    if let activeProofId {
      onPeersVerifiedChanged?(activeProofId, peersVerified)
    }
  }

  // MARK: - Wallet connect+binding (beid#33, sub-slice 2b, §5.6; Barnard
  // conformance sub-slice C, `docs/specs/barnard-binding-conformance.md`
  // §2.3/§2.4)
  //
  // The interstitial (`EventBindingSheetView`) drives these; this type owns
  // the message/signing/persistence side so the view only ever handles the
  // wallet connector's `connect()`/`requestPersonalSign(messageHex:)` calls.

  private var currentEventSession: EventSession? {
    switch phase {
    case .eventFound(let event), .recording(let event, _), .signalLost(let event, _):
      return event
    case .idle, .sensing:
      return nil
    }
  }

  private var currentBindingEvent: EventSession? {
    switch phase {
    case .recording(let event, _), .signalLost(let event, _):
      return event
    case .idle, .sensing, .eventFound:
      return nil
    }
  }

  /// Broader than `currentBindingEvent`: also covers `.eventFound`, which
  /// has no `Proof` yet (self-proof correctly stays gated on
  /// `currentBindingEvent`) but can still have a real open window
  /// (`currentWindowEnin`/`currentWindowRpids`) worth reporting at session
  /// end — a session that observes peers below the confirm threshold and
  /// never reaches `.recording` still has a real window-observed-chunk
  /// (`docs/specs/session-end-finalization.md` §3.2). Used only by the
  /// window-close path below.
  private var currentSessionEventCode: String? {
    switch phase {
    case .eventFound(let session), .recording(let session, _), .signalLost(let session, _):
      return session.id
    case .idle, .sensing:
      return nil
    }
  }

  private var currentSessionEventIdHex: String? {
    switch phase {
    case .eventFound(let session), .recording(let session, _), .signalLost(let session, _):
      return session.canonicalEventIdHex
    case .idle, .sensing:
      return nil
    }
  }

  /// Starts (or resumes) this attempt, moving to `.connecting` and
  /// returning the `0x`-prefixed hex the wallet's `personal_sign` must
  /// sign — the UTF-8 bytes of the literal `barnard-account-binding:v1`
  /// canonical text (`docs/specs/barnard-binding-conformance.md` §2.3), not
  /// a digest of it. Reuses `pendingBindingMessage` if one was already
  /// handed out for this attempt — recomputing with a fresh `Date()`/nonce
  /// would desync the wallet signature and the later wallet-ack. `nil` if
  /// not currently recording, or if `walletAddress`/`chainId` aren't in the
  /// shape Barnard's own validation requires (defensive; the sheet only
  /// calls this while `bindingState` implies `.recording`/`.signalLost`,
  /// with a real connector's already-connected address/chain, §6.b).
  func beginBinding(walletAddress: String, chainId: String) -> String? {
    guard currentBindingEvent != nil else { return nil }

    let message: BindingMessage
    if let pending = pendingBindingMessage {
      message = pending
    } else {
      guard
        let walletAddressBytes = Data(hexEncoded: walletAddress),
        let numericChainId = Self.numericChainId(fromCaip2: chainId)
      else {
        return nil
      }
      message = BindingMessage(
        walletAddress: walletAddressBytes,
        ownerPublicKey: sensingCryptography.ownerPublicKey(),
        chainId: numericChainId,
        nonce: Data(randomSource.randomBytes(count: 16)),
        issuedAt: BindingMessage.canonicalIssuedAt(Date())
      )
    }
    guard let messageHex = message.walletMessageHex() else { return nil }
    bindingState = .connecting
    pendingBindingMessage = message
    return messageHex
  }

  /// Parses the numeric suffix of a CAIP-2 chain identifier (e.g.
  /// `"eip155:1"` → `1`) — `WalletConnector.chainId`'s own format
  /// (§6.b) — into the `UInt64` `BarnardCoreSigning.buildAccountBindingText`
  /// expects. `nil` if `caip2` isn't in that shape.
  private static func numericChainId(fromCaip2 caip2: String) -> UInt64? {
    guard let colonIndex = caip2.firstIndex(of: ":") else { return nil }
    return UInt64(caip2[caip2.index(after: colonIndex)...])
  }

  /// Called once the wallet request has been dispatched (`onDispatched` on
  /// `WalletConnector.requestPersonalSign`) — moves the ambient status from
  /// "connecting" to "waiting on the wallet". No-op if a decline/failure
  /// already raced it.
  func markBindingAwaitingApproval() {
    guard case .connecting = bindingState else { return }
    bindingState = .awaitingApproval
  }

  /// Completes the round trip: has the owner key countersign a
  /// `barnard-wallet-ack:v1` message referencing the wallet's own signature
  /// bytes (§2.4 — the mutual-signature requirement, §4/§6: neither
  /// signature alone is a valid binding), builds and persists the
  /// `BindingRecord`, and moves to `.bound`. `nil` (no state change) if
  /// there is no in-flight attempt to complete, or `walletSignatureHex`
  /// isn't valid hex — defensive against a stale callback racing a
  /// decline, or a malformed transport response.
  @discardableResult
  func completeBinding(walletAddress: String, walletSignatureHex: String) -> BindingRecord? {
    guard
      let message = pendingBindingMessage,
      let proofId = activeProofId,
      let event = currentBindingEvent,
      let walletSignatureBytes = Data(hexEncoded: walletSignatureHex),
      let ackSignature = sensingCryptography.signWalletAcknowledgement(
        walletAddress: message.walletAddress,
        walletSignature: walletSignatureBytes
      )
    else {
      return nil
    }

    let record = BindingRecord(
      proofId: proofId,
      eventCode: event.id,
      walletAddress: walletAddress,
      eventSigningPublicKey: sensingCryptography.eventSigningPublicKey(eventCode: event.id),
      ownerPublicKey: message.ownerPublicKey,
      chainId: message.chainId,
      nonce: message.nonce,
      issuedAt: message.issuedAt,
      walletSignatureHex: walletSignatureHex,
      deviceSignature: BarnardCoreRecoverableSignature(
        r: Array(ackSignature.r),
        s: Array(ackSignature.s),
        v: ackSignature.v
      )
    )
    bindingRecordStore.add(record)
    bindingState = .bound(record)
    pendingBindingMessage = nil
    return record
  }

  /// The wallet declined, or a transport/timeout error occurred. Distinct
  /// from `declineBinding()`: this is the round trip failing, not the user
  /// dismissing the sheet before starting one.
  func failBinding(reason: String) {
    pendingBindingMessage = nil
    bindingState = .failed(reason: reason)
  }

  /// The user closed the sheet without completing a binding (decline,
  /// swipe-dismiss, or backing out of a failure) — wallet is optional
  /// (DESIGN.md §1), so this only resets `bindingState`, never `phase`;
  /// recording keeps running untouched. Re-offered next foreground per
  /// §5.6, never re-shown mid-session on its own.
  func declineBinding() {
    pendingBindingMessage = nil
    if let event = currentBindingEvent {
      bindingState = .pendingConnect(event)
    } else {
      bindingState = .none
    }
  }

  // MARK: - Per-window report signing (Q9, §4.5; deferred to `.recording`,
  // beid#114 / `docs/specs/eventfound-window-signing.md`)
  //
  // Two concerns that used to be fused into one unconditional
  // `advanceWindowIfNeeded` are now deliberately split:
  //
  // 1. Window-boundary *bookkeeping* — `advanceWindowBookkeepingIfNeeded`,
  //    `openNewWindowState` below — tracks ENIN boundaries, clears
  //    `currentWindowRpids`, and maintains `firstWindowEnin`/`lastWindowEnin`
  //    for the self-proof layer. Runs on every detection, unconditionally,
  //    regardless of `phase`, exactly as before beid#114. This must stay
  //    unconditional: `currentWindowRpids` is the co-presence threshold arm's
  //    own input (`hasEnoughCoPresentDevicesToConfirm`), and that arm's
  //    invariant — cleared at every window boundary, so a lingering device
  //    contributes exactly 1 to every window forever — depends on this
  //    clearing never being skipped. The proximity identifier rotates every
  //    ENIN window by design (beid#154), so if this bookkeeping were instead
  //    gated on `.recording`, a single lingering device observed across
  //    several pre-confirmation windows would insert a fresh rotated rpid
  //    into a `currentWindowRpids` that nothing ever emptied, reproducing
  //    beid#154's (device × window) inflation shape inside the co-presence
  //    arm — see `testOneLingeringDeviceAcrossManyPreConfirmationWindowsNeverInflatesCoPresenceCount`.
  //
  // 2. The ledger/report window *lifecycle* — signing and durably persisting
  //    a `WindowReport`, and the corresponding `unsentWindowLedgerRuntime`
  //    open/close calls — only runs once `phase` has reached `.recording`.
  //    `currentWindowLedgerOpened` tracks, per currently-tracked window,
  //    whether that lifecycle has started; `ensureLedgerWindowOpen()` starts
  //    it (called from `observe(_:)` the instant `result.resultingPhase ==
  //    .RECORDING`, which may be mid-window), and
  //    `advanceWindowBookkeepingIfNeeded`'s boundary-crossing branch finishes
  //    it (signs + persists) only for a window that was actually started.
  //    Because concern 1 keeps `currentWindowRpids` correctly scoped to
  //    "just this window's peers" at all times, the first ledger window
  //    concern 2 ever opens is already seeded with an accurate, correctly
  //    scoped peer set — no special-casing needed for the confirming
  //    detection itself.

  /// Concern 1 (see above): ENIN-boundary bookkeeping, unconditional on
  /// `phase`. Closes the outgoing window's ledger lifecycle
  /// (sign + persist) only if it was ever started
  /// (`currentWindowLedgerOpened`); otherwise the outgoing window is
  /// discarded with no report, per §4's accepted trade-off.
  ///
  /// The boundary test itself is `BeidSharedKit.sensing
  /// .coPresenceWindowBoundaryCrossed` (beid#231) — the same `shared/`
  /// decision Android's `ScanDeviceAccounting.record` applies, not a native
  /// `!=` comparison owned here. Everything else in this function (the
  /// ledger-open/self-proof orchestration below) remains native effect
  /// scope.
  private func advanceWindowBookkeepingIfNeeded(enin: Int, eventCode: String) {
    redeliverPendingWindowReports()
    guard let openEnin = currentWindowEnin else {
      openNewWindowState(enin: enin)
      return
    }
    guard
      BeidSharedKit.sensing.coPresenceWindowBoundaryCrossed(
        lastEnin: Int64(openEnin), enin: Int64(enin)
      )
    else {
      return
    }
    if currentWindowLedgerOpened {
      closeWindow(enin: openEnin, eventCode: eventCode)
    } else {
      clearCurrentWindowState()
    }
    openNewWindowState(enin: enin)
  }

  /// Starts tracking a new window natively — self-proof bookkeeping only;
  /// never touches the ledger runtime or `WindowReportStore`. See
  /// `ensureLedgerWindowOpen()` for the ledger-lifecycle half.
  private func openNewWindowState(enin: Int) {
    let windowId = UUID()
    currentWindowId = windowId
    currentWindowEnin = enin
    lastWindowEnin = enin
    // Not unconditional: a background checkpoint can open another window
    // in the same session, but the self-proof start remains the first one.
    if firstWindowEnin == nil {
      firstWindowEnin = enin
    }
    currentWindowLedgerOpened = false
    currentWindowReporterRpid = nil
    checkpointSelfProofStateIfNeeded()
  }

  /// Concern 2 (see above): starts the ledger lifecycle for the currently
  /// tracked window, if it has not already started. No-op if already
  /// started (every detection while already `.recording` calls this
  /// idempotently) or if no window is currently tracked (shouldn't happen —
  /// `observe(_:)` always runs bookkeeping first — but defensive rather than
  /// force-unwrapped). A ledger-runtime failure here still marks the window
  /// started: `unsentWindowLedgerRuntime` degradation is best-effort
  /// bookkeeping, not a gate on whether `WindowReportStore` signs and
  /// persists at close time (mirrors `closeWindow`'s own best-effort
  /// ledger-runtime handling below).
  private func ensureLedgerWindowOpen() {
    guard !currentWindowLedgerOpened, let windowId = currentWindowId else { return }
    if let unsentWindowLedgerRuntime {
      do {
        try unsentWindowLedgerRuntime.openWindow(
          windowId: windowId.uuidString.lowercased()
        )
      } catch {
        Self.ledgerLog.error("Unable to persist an open shared-ledger window: \(error, privacy: .public)")
        recordLedgerDegradation(error)
      }
    }
    currentWindowLedgerOpened = true
  }

  /// Closes whatever window is still open at explicit-stop time
  /// (`stopSensing()`/`reset()`), before `resetSessionState()` clears the
  /// state this reads — mirroring exactly where `finalizeSelfProofIfNeeded()`
  /// already sits in both functions
  /// (`docs/specs/session-end-finalization.md` §3.3). A no-op if no window
  /// is open (`currentWindowEnin == nil`) — true both for a session that
  /// never observed a peer, and, once this is called a second time in a
  /// row, for the case right after the first call already closed the
  /// window and `resetSessionState()` nil'd `currentWindowEnin`. This native
  /// guard only says there is no lifecycle input to forward; shared remains
  /// authoritative if duplicate close inputs race (§3.6).
  ///
  /// beid#114: if the open window's ledger lifecycle never started
  /// (`currentWindowLedgerOpened == false` — the session never reached
  /// `.recording`), this clears native state without ever calling
  /// `closeWindow`, so no report is signed or persisted for it.
  private func closeFinalWindowIfNeeded() {
    redeliverPendingWindowReports()
    guard let enin = currentWindowEnin else { return }
    // DemoEvent updates ENIN bookkeeping for self-proof coverage but never
    // opens a real native report window.
    guard currentWindowId != nil else { return }
    guard currentWindowLedgerOpened else {
      clearCurrentWindowState()
      return
    }
    guard let eventCode = currentSessionEventCode else {
      Self.ledgerLog.error("Unable to close the native window without an active event code")
      return
    }
    closeWindow(enin: enin, eventCode: eventCode)
  }

  /// Checkpoints (does not end) an in-progress session when the app
  /// backgrounds — called from `ScanFlowView`'s existing `scenePhase`
  /// observer (`docs/specs/session-end-finalization.md` §3.4). Closes
  /// whatever window is currently open, exactly like `closeFinalWindowIfNeeded`,
  /// but deliberately does **not** call `resetSessionState()` and does not
  /// touch `phase`/`bindingState`: this app declares
  /// `bluetooth-central`/`bluetooth-peripheral` background modes (§2.4), so
  /// sensing may keep running after `.background` — this is a checkpoint of
  /// what has been observed so far, not a session-end. Also does **not**
  /// produce a self-proof (§7.1 Option A was considered and rejected; that
  /// is sub-slice 3's concern, not this one).
  ///
  /// Nils `currentWindowEnin`/clears `currentWindowRpids` (rather than
  /// leaving the just-closed `enin` in place) for two reasons: (1) so the
  /// next detection opens a genuinely new window instead of silently
  /// reusing the closed one, and (2) so a following
  /// `stopSensing()`/`reset()` has no stale lifecycle input to forward.
  /// Shared still owns duplicate-close handling if callbacks race (§3.6).
  ///
  /// beid#114: same `currentWindowLedgerOpened` gate as
  /// `closeFinalWindowIfNeeded()` — a checkpoint that lands before the
  /// session ever reached `.recording` still clears native window state
  /// (so the next detection starts a genuinely new window), but signs and
  /// persists nothing.
  func checkpointOpenWindowForBackgrounding() {
    redeliverPendingWindowReports()
    guard let enin = currentWindowEnin, let eventCode = currentSessionEventCode else {
      reportSubmissionRuntime?.submitPending()
      return
    }
    guard currentWindowId != nil else {
      reportSubmissionRuntime?.submitPending()
      return
    }
    guard currentWindowLedgerOpened else {
      clearCurrentWindowState()
      reportSubmissionRuntime?.submitPending()
      return
    }
    closeWindow(enin: enin, eventCode: eventCode)
    reportSubmissionRuntime?.submitPending()
  }

  /// Marks `ledgerHealth` degraded for an operational persist failure (as
  /// opposed to the construction-time failure `init` threads in directly).
  /// See `LedgerHealth.since` for why this latches to the first failure
  /// rather than overwriting it on every subsequent one.
  private func recordLedgerDegradation(_ error: Error) {
    if case let .degraded(_, since) = ledgerHealth {
      ledgerHealth = .degraded(reason: error, since: since)
    } else {
      ledgerHealth = .degraded(reason: error, since: Date())
    }
  }

  private func clearCurrentWindowState() {
    currentWindowRpids = []
    currentWindowReporterRpid = nil
    currentWindowEnin = nil
    currentWindowId = nil
    currentWindowObservationReference = nil
  }

  /// Signs the legacy closing-window report with the event signing key and
  /// queues it locally. When enabled, the canonical submission runtime is
  /// called at the same boundary before this legacy payload is cleared or
  /// reconstructed; it owns exact Observation bytes and HTTPS delivery.
  private func closeWindow(enin: Int, eventCode: String) {
    guard
      let commit = activeCommit,
      let currentWindowId
    else {
      Self.ledgerLog.error("Unable to close a native window without its commitment and identifier")
      clearCurrentWindowState()
      return
    }

    // Snapshot every lossless input before either the legacy report path or
    // clearCurrentWindowState() can discard the current RPID set. The new
    // submission runtime is independent of the legacy WindowReport bytes.
    let closingPeerRpids = currentWindowRpids
    let closingReporterRpid = currentWindowReporterRpid
    reportSubmissionRuntime?.captureAndQueueWindow(
      id: currentWindowId,
      eventCode: eventCode,
      eventIdHex: currentSessionEventIdHex,
      enin: enin,
      peerRpids: closingPeerRpids,
      reporterRpid: closingReporterRpid,
      participantCommitment: commit
    )

    let observationReference: String
    if let currentWindowObservationReference {
      observationReference = currentWindowObservationReference
    } else if let persisted = windowReportStore.report(id: currentWindowId) {
      observationReference = persisted.id.uuidString.lowercased()
      currentWindowObservationReference = observationReference
    } else {
      let payload = windowReportPayload(
        eventCode: eventCode,
        enin: enin,
        peerRpids: closingPeerRpids,
        commit: commit
      )
      let signature = sensingCryptography.signWindowReport(eventCode: eventCode, bytes: payload)
      let report = WindowReport(
        id: currentWindowId,
        eventCode: eventCode,
        enin: enin,
        peerCount: closingPeerRpids.count,
        commit: commit,
        signature: signature
      )
      // TODO: This and the shared snapshot write below still synchronously
      // rewrite whole files on the MainActor BLE path on every real window
      // close. Startup's synchronous I/O is resolved by beid#134 Decision 1
      // (docs/specs/ledger-async-io.md §4); *this* per-close write's format
      // and actor location are deferred, by design, to the pruning/
      // send-path follow-up that will also decide WindowReportStore's
      // eventual format (same document, §5.1/§5.2's stated revisit
      // trigger) — not a broader "follow-up" left open-ended. See
      // beid#134.
      do {
        observationReference = try windowReportStore.add(report)
        currentWindowObservationReference = observationReference
      } catch {
        if let dropped = windowReportRedeliveryBuffer.enqueue(report) {
          Self.ledgerLog.error("Dropped the newest pending window report after reaching redelivery capacity: \(dropped.id, privacy: .public)")
        } else {
          Self.ledgerLog.error("Parked a native window report for redelivery after persistence failed: \(error, privacy: .public)")
        }
        recordLedgerDegradation(error)
        clearCurrentWindowState()
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
        Self.ledgerLog.error("Unable to persist a closed shared-ledger window: \(error, privacy: .public)")
        recordLedgerDegradation(error)
      }
    }
    clearCurrentWindowState()
  }

  private func redeliverPendingWindowReports() {
    while let report = windowReportRedeliveryBuffer.reports.first {
      do {
        let observationReference = try windowReportStore.add(report)
        if let unsentWindowLedgerRuntime {
          try unsentWindowLedgerRuntime.closeWindow(
            windowId: report.id.uuidString.lowercased(),
            persistedObservationReference: observationReference
          )
        }
        windowReportRedeliveryBuffer.removeFirst()
      } catch UnsentWindowLedgerRuntimeError.rejectedTransition(let errorCode)
        where errorCode == "unknown_window_id" {
        // The native artifact is durable but cannot ever enter a submission
        // because shared has no corresponding window. Remove only this
        // terminal rejection so later recoverable artifacts can still drain.
        windowReportRedeliveryBuffer.removeFirst()
        Self.ledgerLog.error("Discarded a pending native window report absent from the shared ledger: \(report.id, privacy: .public)")
      } catch {
        Self.ledgerLog.error("Unable to redeliver a pending native window report: \(error, privacy: .public)")
        recordLedgerDegradation(error)
        return
      }
    }
  }

  private func windowReportPayload(eventCode: String, enin: Int, peerRpids: Set<String>, commit: Data) -> Data {
    var payload = Data(eventCode.utf8)
    payload.append(contentsOf: withUnsafeBytes(of: Int64(enin).bigEndian) { Array($0) })
    payload.append(commit)
    for rpid in peerRpids.sorted() {
      payload.append(contentsOf: Array(rpid.utf8))
    }
    return payload
  }

  // MARK: - Self-proof (owner-key attestation, §2.2)
  //
  // A structurally separate mechanism from the per-window report path just
  // above — same boundary §4 draws for `EventCommitment`/`activeCommit`: no
  // self-proof byte ever feeds `windowReportPayload` or any other on-wire
  // path (self-proofs are a "holder-held artifact", never placed on
  // Advertise/GATT/anchors/witness blobs). `eninEnd` can only be known once
  // the session's last observed ENIN window is known, which — per this
  // type's actual lifecycle, not assumed — is only true at session end
  // (`stopSensing()`/`reset()`, both call `finalizeSelfProofIfNeeded()`
  // before `resetSessionState()` clears the state it reads), never at
  // `beginEventFound` (where only `activeCommit` is fixed).

  /// Builds and signs (`OwnerKeyProvider.signSelfProof`) one self-proof for
  /// the given inputs, without persisting it — the persistence/checkpoint
  /// decision differs at each caller (`finalizeSelfProofIfNeeded()` reads
  /// live session state and clears the checkpoint; reconciliation reads a
  /// durable checkpoint and clears it under different gating, §8.3), but the
  /// build-and-sign step itself is identical. `nil` only if signing fails
  /// (Barnard's own shape validation on `eventIdHash`/`eventSigningPublicKey`).
  private func makeSelfProofRecord(
    proofId: UUID,
    eventCode: String,
    eninStart: UInt64,
    eninEnd: UInt64
  ) -> SelfProofRecord? {
    let eventIdHash = EventIdHash.compute(eventCode: eventCode)
    let eventSigningPublicKey = sensingCryptography.eventSigningPublicKey(eventCode: eventCode)
    let ownerPublicKey = sensingCryptography.ownerPublicKey()
    guard
      let signature = sensingCryptography.signSelfProof(
        eventIdHash: eventIdHash,
        eventSigningPublicKey: eventSigningPublicKey,
        eninStart: eninStart,
        eninEnd: eninEnd
      )
    else {
      return nil
    }

    return SelfProofRecord(
      proofId: proofId,
      eventCode: eventCode,
      eventIdHash: eventIdHash,
      eventSigningPublicKey: eventSigningPublicKey,
      eninStart: eninStart,
      eninEnd: eninEnd,
      ownerPublicKey: ownerPublicKey,
      signature: BarnardCoreRecoverableSignature(
        r: Array(signature.r),
        s: Array(signature.s),
        v: signature.v
      )
    )
  }

  /// Builds, signs, and persists this session's self-proof, if one is due.
  /// `nil` if there is no `Proof` for this session (`activeProofId` unset —
  /// never reached `.recording`) or no ENIN window was ever observed
  /// (`firstWindowEnin`/`lastWindowEnin` unset). A session gated on
  /// `activeProofId` mirrors `BindingRecord.proofId`'s linkage: a session
  /// that stayed in `.eventFound` without meeting the peer threshold
  /// produced no `Proof`, so there is nothing to attest.
  ///
  /// Reads `lastWindowEnin`, not `currentWindowEnin`, for `end`: the latter
  /// is nil'd mid-session by `checkpointOpenWindowForBackgrounding()`
  /// (`docs/specs/session-end-finalization.md` §3.4) without ending the
  /// session, so a stop that follows a checkpoint with no further detection
  /// would otherwise find `currentWindowEnin == nil` here and silently
  /// return `nil` for a session that was, in fact, complete and valid.
  ///
  /// Clears `selfProofCheckpointStore` on success (§7.1 Option B, §8.3): the
  /// real record now exists, so the in-progress checkpoint standing in for
  /// it is stale and must not be reconciled again on a later launch.
  @discardableResult
  private func finalizeSelfProofIfNeeded() -> SelfProofRecord? {
    guard
      let proofId = activeProofId,
      let eventCode = currentBindingEvent?.id,
      let start = firstWindowEnin,
      let end = lastWindowEnin
    else {
      return nil
    }

    guard
      let record = makeSelfProofRecord(
        proofId: proofId,
        eventCode: eventCode,
        eninStart: UInt64(start),
        eninEnd: UInt64(end)
      )
    else {
      return nil
    }

    selfProofStore.add(record)
    selfProofCheckpointStore.clear()
    return record
  }

  // MARK: - Session aggregate snapshot (beid#166 Phase 2)

  /// Persists this session's final `sessionAggregate` for display later, if
  /// one is due. Gated on `activeProofId`/`sessionAggregate` exactly like
  /// `finalizeSelfProofIfNeeded()`'s own `activeProofId` gate, for the same
  /// reason (beid#166's Class-C invariant: a snapshot is produced once, at
  /// session end, only for sessions that produced a `Proof`) — a session
  /// that stayed in `.eventFound` without meeting the peer threshold
  /// produced no `Proof`, so there is nothing to snapshot. Must run before
  /// `resetSessionState()` clears both gating properties to `nil`, in the
  /// same position `finalizeSelfProofIfNeeded()` already occupies in
  /// `endSensing(stopEngine:)`.
  ///
  /// `sessionAggregateSnapshotStore.persist(aggregate:proofId:)` is
  /// best-effort, exactly like the ledger/window-report writes above: a
  /// failure here must not interrupt session-end teardown, since this store
  /// is a display convenience layer over already-durable evidence (`Proof`/
  /// `WindowReport`/`SelfProofRecord`), never the evidence itself (see
  /// `SessionAggregateSnapshotStore`'s own doc comment). Logged via
  /// `Self.ledgerLog`, the same category `ensureLedgerWindowOpen()`/
  /// `closeWindow(enin:eventCode:)` already use for other best-effort
  /// store failures — this failure does not affect `ledgerHealth`
  /// (`recordLedgerDegradation` is not called): that type is specifically
  /// about `unsentWindowLedgerRuntime`'s own operating state, and this store
  /// is unrelated to it.
  private func persistSessionAggregateSnapshotIfNeeded() {
    guard let proofId = activeProofId, let aggregate = sessionAggregate else { return }
    do {
      try sessionAggregateSnapshotStore.persist(aggregate: aggregate, proofId: proofId)
    } catch {
      Self.ledgerLog.error("Unable to persist the session aggregate snapshot: \(error, privacy: .public)")
    }
  }

  /// Persists this session's current `eninStart`/`eninEnd` on every real
  /// window rotation (`openNewWindowState`, called from
  /// `advanceWindowBookkeepingIfNeeded`), so a device kill after binding
  /// completes but before session end can still be reconciled into a real
  /// `SelfProofRecord` on next launch (`reconcileSelfProofCheckpointIfNeeded()`,
  /// §7.1 Option B, §8.3). Gated on `activeProofId`/`currentBindingEvent`
  /// exactly like `finalizeSelfProofIfNeeded()` itself — there is nothing to
  /// checkpoint before `.recording` begins.
  ///
  /// Demo mode never reaches this: `advanceDemoWindow()` deliberately never
  /// calls `openNewWindowState` (its own doc comment — demo mode produces no
  /// window reports), so a demo session's self-proof stays reachable only
  /// through the graceful `stopSensing()`/`reset()` path, unchanged by this
  /// sub-slice.
  private func checkpointSelfProofStateIfNeeded() {
    guard
      let proofId = activeProofId,
      let eventCode = currentBindingEvent?.id,
      let start = firstWindowEnin,
      let end = lastWindowEnin
    else {
      return
    }
    selfProofCheckpointStore.save(
      SelfProofCheckpoint(
        proofId: proofId,
        eventCode: eventCode,
        eninStart: UInt64(start),
        eninEnd: UInt64(end)
      )
    )
  }

  /// Runs once, at the end of `init` — i.e. once per cold launch, on both
  /// `AppCoordinator`'s production `SensingCoordinator` and any test-
  /// constructed instance. If a checkpoint survived from a session that
  /// never reached a graceful end (§7.1 Option B: a device kill after
  /// binding completed but before `stopSensing()`/`reset()` ran), signs and
  /// persists the missing `SelfProofRecord` from the checkpoint's
  /// last-known `eninStart`/`eninEnd`, then clears the checkpoint.
  ///
  /// No-op if no checkpoint exists. Also a no-op (but still clears the
  /// checkpoint) if `selfProofStore` already holds a record for the
  /// checkpoint's `proofId` — a graceful session end already produced the
  /// real record before the checkpoint's own clear could complete, so this
  /// checkpoint is stale and must not be reconciled into a duplicate.
  private func reconcileSelfProofCheckpointIfNeeded() {
    guard let checkpoint = selfProofCheckpointStore.checkpoint else { return }
    guard selfProofStore.record(forProofId: checkpoint.proofId) == nil else {
      selfProofCheckpointStore.clear()
      return
    }

    guard
      let record = makeSelfProofRecord(
        proofId: checkpoint.proofId,
        eventCode: checkpoint.eventCode,
        eninStart: checkpoint.eninStart,
        eninEnd: checkpoint.eninEnd
      )
    else {
      return
    }

    selfProofStore.add(record)
    selfProofCheckpointStore.clear()
  }

  // MARK: - Demo sequence
  //
  // Pure state advancement is separated from timing so tests can drive it
  // with a zero delay and await completion via
  // `waitForDemoSequenceToFinish()`. Demo mode has no real `BarnardEvent`
  // stream, so it synthesizes its own detections and folds each one into
  // `applyPhaseDecision(coPresentDeviceCount:distinctDeviceCountChanged:for:)`
  // (beid#189) — the same shared-reducer-consuming half `observe(_:for:)`
  // uses for the real path, so a future change to
  // `BeidSharedKit.sensing.applyScanDetection`'s rules applies to demo mode
  // automatically instead of silently drifting from a parallel hardcoded
  // script. Demo mode never calls `observe(_:for:)` itself and so never
  // reaches `advanceWindowBookkeepingIfNeeded`/`ensureLedgerWindowOpen`/
  // `closeWindow` — the only functions that touch `windowReportStore`/
  // `unsentWindowLedgerRuntime`, and the only functions `openNewWindowState`
  // (which is what sets `currentWindowId` non-nil) is reachable from. Demo
  // mode's own `advanceDemoWindow()` below never calls `openNewWindowState`
  // either, so `currentWindowId` stays `nil` for a demo session's entire
  // lifetime — this is not a coincidence to preserve carefully, it is
  // required by DECISIONS 2026-08-01 ("Scan Slice-2 の検証は4台以上のグループ
  // セッションで行う"), which names this file's own "Fabricated proof data
  // must never enter a shipping build's sensing path" comment as its
  // reasoning for keeping demo mode out of any path that produces real,
  // signed attestation artifacts. Device growth goes through
  // `observeOneDemoDevice()` -> `recordDeviceIdentity(enin:rpid:detectedDisplayId:)`,
  // the same `aggregationRuntime` accumulator the real path uses
  // (beid#109/#162): DemoEvent is App Review's demo path (see
  // `ios/README.md` "DemoEvent mode") and the only path exercisable on the
  // Simulator, so its `devicesVerified` growth comes from the same source a
  // real session uses rather than a bare loop counter.

  /// Retains the historical test/preview seam while making the App Review
  /// primitive sequence data rather than a second scripted implementation.
  func runDemoSequence(demoEvent: EventSession, stepDelayNanos: UInt64 = 700_000_000) {
    runDemoScenario(
      DemoScenario.appReviewGolden.replacingEvent(demoEvent),
      stepDelayNanos: stepDelayNanos
    )
  }

  /// Runs a named deterministic DemoEvent scenario without calling the real
  /// BLE observation, ledger, report, or submission-capture paths.
  func runDemoScenario(_ scenario: DemoScenario, stepDelayNanos: UInt64 = 700_000_000) {
    demoTask?.cancel()
    let session = EventSession(
      id: scenario.event.id,
      name: scenario.event.name,
      venue: scenario.event.venue,
      canonicalEventIdHex: scenario.event.canonicalEventIdHex ?? pendingCanonicalEventIdHex,
      sessionID: scenario.event.sessionID,
      identityVerification: .notChecked
    )

    // `runDemoScenario` remains callable from tests and previews without
    // `startSensing()`, so make its `.sensing` precondition explicit.
    phase = Self.payloadlessNativePhase(BeidSharedKit.sensing.scanPhaseAfterStartSensing())
    beginEventFoundSessionState(session)
    phase = Self.payloadlessNativePhase(BeidSharedKit.sensing.scanPhaseAfterStartSensing())

    let resolvedScenario = scenario.replacingEvent(session)
    demoInterpreterScenario = resolvedScenario
    demoInterpreterCursor = 0
    demoInterpreterIsParked = false
    demoInterpreterLastObservationChanged = false
    demoInterpreterStepDelayNanos = stepDelayNanos
    runDemoInterpreter(resolvedScenario, cursor: 0, stepDelayNanos: stepDelayNanos)
  }

  private func runDemoInterpreter(
    _ scenario: DemoScenario,
    cursor: Int,
    stepDelayNanos: UInt64
  ) {
    demoTask = Task { @MainActor [weak self] in
      guard let self else { return }

      for index in cursor..<scenario.steps.count {
        guard !Task.isCancelled else { return }
        let step = scenario.steps[index]
        self.onDemoInterpreterCheckpointForTesting?(.step(index, step))

        var shouldPark = false
        switch step {
        case .pause:
          guard await self.delay(stepDelayNanos), !Task.isCancelled else { return }
        default:
          shouldPark = self.applyDemoScenarioStep(step, event: scenario.event)
        }

        guard !Task.isCancelled else { return }
        await Task.yield()
        guard !Task.isCancelled else { return }
        self.onDemoInterpreterCheckpointForTesting?(.renderTurnSettled(index))
        self.demoInterpreterCursor = index + 1

        if shouldPark {
          self.demoInterpreterIsParked = true
          self.onDemoInterpreterCheckpointForTesting?(.suspended(index + 1))
          return
        }
      }

      self.clearDemoInterpreterState()
      self.onDemoInterpreterCheckpointForTesting?(.completed)
    }
  }

  private func applyDemoScenarioStep(
    _ step: DemoScenario.Step,
    event: EventSession
  ) -> Bool {
    switch step {
    case .pause:
      return false
    case let .observeOneDemoDevice(displayId, rpid, enin):
      demoInterpreterLastObservationChanged = observeOneDemoDevice(
        displayId: displayId,
        rpid: rpid,
        enin: enin
      )
    case .applyPhaseDecision:
      applyPhaseDecision(
        coPresentDeviceCount: demoWindowRpids.count,
        distinctDeviceCountChanged: demoInterpreterLastObservationChanged,
        for: event,
        startIdentityVerification: false
      )
    case .advanceDemoWindow:
      advanceDemoWindow()
    case .simulateSignalLost:
      return applyDemoSignalLost()
    }
    return false
  }

  private func applyDemoSignalLost() -> Bool {
    let result = BeidSharedKit.sensing.scanPhaseAfterSignalLost(currentPhase: currentPhaseKind)
    guard result.applied, case .recording(let event, let peersVerified) = phase else { return false }
    phase = .signalLost(event: event, peersVerified: peersVerified)
    return true
  }

  private func resumeParkedDemoScenarioIfNeeded() -> Bool {
    guard demoInterpreterIsParked,
          let scenario = demoInterpreterScenario,
          let cursor = demoInterpreterCursor
    else {
      return false
    }

    demoInterpreterIsParked = false
    onDemoInterpreterCheckpointForTesting?(.resumed(cursor))
    runDemoInterpreter(
      scenario,
      cursor: cursor,
      stepDelayNanos: demoInterpreterStepDelayNanos
    )
    return true
  }

  private func clearDemoInterpreterState() {
    demoInterpreterScenario = nil
    demoInterpreterCursor = nil
    demoInterpreterIsParked = false
    demoInterpreterLastObservationChanged = false
    demoInterpreterStepDelayNanos = 700_000_000
  }

  /// Continues the demo growth loop from where `devicesVerified` was frozen
  /// at signal-loss — `resumeSensing()`'s demo-mode counterpart to
  /// `runDemoSequence`. Reads `devicesVerified` (via `applyPhaseDecision`,
  /// which reads it internally) rather than taking a `peersVerified`
  /// parameter: `observeOneDemoDevice()` already keeps it and the frozen
  /// `phase` value in lockstep, so a separate starting point would be a
  /// second copy of the same number. `phase` is already `.recording` here
  /// (set by `resumeSensing()` before this is called), so each
  /// `applyPhaseDecision` call below only ever exercises
  /// `ScanDetectionResult.updatedRecording`.
  private func continueDemoRecording(event: EventSession, stepDelayNanos: UInt64) {
    demoTask?.cancel()
    demoTask = Task { @MainActor [weak self] in
      guard let self else { return }
      for _ in 0..<2 {
        guard await self.delay(stepDelayNanos), !Task.isCancelled else { return }
        let changed = self.observeOneDemoDevice()
        self.applyPhaseDecision(
          coPresentDeviceCount: self.demoWindowRpids.count,
          distinctDeviceCountChanged: changed,
          for: event,
          startIdentityVerification: false
        )
        self.advanceDemoWindow()
      }
    }
  }

  /// Synthesizes one new demo device observation through the exact same
  /// `recordDeviceIdentity`/`aggregationRuntime` path the real detection path
  /// uses, so demo growth and real growth share one source of truth for
  /// `devicesVerified` (beid#109/#162's iOS wiring). Each call uses a
  /// never-repeated synthetic id, so it always grows the shared device count
  /// by exactly one. Also inserts into `demoWindowRpids` (beid#189),
  /// mirroring how `observe(_:for:)` inserts into `currentWindowRpids` for
  /// the real path. Returns whether `devicesVerified` moved, so callers can
  /// feed it into `applyPhaseDecision`'s `distinctDeviceCountChanged`.
  @discardableResult
  private func observeOneDemoDevice() -> Bool {
    let syntheticId = "demo-device-\(demoDeviceSequence + 1)"
    return observeOneDemoDevice(
      displayId: syntheticId,
      rpid: syntheticId,
      enin: demoWindowEnin
    )
  }

  @discardableResult
  private func observeOneDemoDevice(displayId: String, rpid: String, enin: Int) -> Bool {
    demoDeviceSequence += 1
    demoWindowEnin = enin
    demoWindowRpids.insert(rpid)
    return recordDeviceIdentity(enin: enin, rpid: rpid, detectedDisplayId: displayId)
  }

  /// Demo-only stand-in for the real path's `advanceWindowBookkeepingIfNeeded` —
  /// advances just enough ENIN-window state
  /// (`firstWindowEnin`/`currentWindowEnin`/`lastWindowEnin`) for the
  /// self-proof layer (§2.2) to be exercisable under demo mode, since there
  /// is no real BLE path to drive it with on the simulator, and clears
  /// `demoWindowRpids` for the next demo window (beid#189). Deliberately
  /// never calls `openNewWindowState`/`closeWindow`/touches
  /// `WindowReportStore` — demo mode intentionally produces no window
  /// reports (see this section's own doc comment above), and this must not
  /// change that.
  private func advanceDemoWindow() {
    demoWindowEnin += 1
    if firstWindowEnin == nil {
      firstWindowEnin = demoWindowEnin
    }
    currentWindowEnin = demoWindowEnin
    lastWindowEnin = demoWindowEnin
    demoWindowRpids = []
  }

  func waitForDemoSequenceToFinish() async {
    await demoTask?.value
  }

  /// Preview/test seam: a scenario is settled only after each primitive has
  /// yielded one render turn, or it has deliberately parked at Signal Lost.
  func waitForDemoScenarioPreviewToSettle() async {
    await demoTask?.value
  }

  /// Test seam mirroring `waitForDemoSequenceToFinish()` above: awaits
  /// Decision 1's background load/reconcile task
  /// (`docs/specs/ledger-async-io.md` §4) so tests can deterministically
  /// observe post-load state without polling or sleeping. `nil` (an
  /// immediate no-op) if this instance was built via the fully-synchronous
  /// explicit-storage-seam initializer, which never sets `ledgerLoadTask`.
  func waitForLedgerLoadToFinish() async {
    await ledgerLoadTask?.value
  }

  /// Replays, in arrival order, every detection `handleDetection` queued
  /// instead of processing while `isLedgerLoading` was `true` — called once,
  /// immediately after `isLedgerLoading` flips `false`. See
  /// `handleDetection`'s guard and `docs/specs/ledger-async-io.md` §4.2 for
  /// why the whole raw detection was queued rather than only its
  /// store-touching calls.
  private func drainQueuedDetectionsAfterLoad() {
    let queued = queuedDetectionsWhileLoading
    queuedDetectionsWhileLoading = []
    for detection in queued {
      handleDetection(
        enin: detection.enin,
        rpid: detection.rpid,
        detectedDisplayId: detection.detectedDisplayId,
        reporterRpid: detection.reporterRpid
      )
    }
  }

  private nonisolated func delay(_ nanos: UInt64) async -> Bool {
    guard nanos > 0 else { return !Task.isCancelled }
    try? await Task.sleep(nanoseconds: nanos)
    return !Task.isCancelled
  }
}

private extension Data {
  /// Decodes a `0x`-prefixed (or bare) hex string into raw bytes; `nil` if
  /// malformed (odd length, non-hex characters) — used to turn the wallet
  /// address/signature strings the connector layer hands over as opaque
  /// hex into the raw bytes Barnard's owner-key API requires.
  init?(hexEncoded string: String) {
    let stripped = string.hasPrefix("0x") || string.hasPrefix("0X")
      ? String(string.dropFirst(2))
      : string
    guard stripped.count.isMultiple(of: 2) else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(stripped.count / 2)
    var index = stripped.startIndex
    while index < stripped.endIndex {
      let next = stripped.index(index, offsetBy: 2)
      guard let byte = UInt8(stripped[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    self = Data(bytes)
  }
}
