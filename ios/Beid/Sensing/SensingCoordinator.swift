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

#if DEBUG
private func diagnosticEventIdPrefix(_ value: String?) -> String {
  guard let value else { return "unknown" }
  let normalized = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
  guard normalized.count == 64,
    normalized == normalized.lowercased(),
    normalized.allSatisfy({ $0.isHexDigit })
  else { return "unknown" }
  return String(normalized.prefix(8))
}
#endif

private func emitJoinStageDiagnostic(
  _ log: (String) -> Void,
  eventIdHex: String?,
  stage: String,
  outcome: String,
  attempt: String? = nil,
  retryAtEpochMillis: Int64? = nil
) {
#if DEBUG
  log(
    "join_stage event_id=\(diagnosticEventIdPrefix(eventIdHex)) " +
      "stage=\(stage) outcome=\(outcome) " +
      "attempt=\(attempt ?? "none") " +
      "retry_at_epoch_ms=\(retryAtEpochMillis.map(String.init) ?? "none")"
  )
#endif
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

/// User-facing outcome of the two owner-key restoration signals detected at
/// startup (beid#311). The three non-nil cases keep Signal A, Signal B, and
/// their overlap distinct without exposing storage keys or cryptographic
/// implementation details in the UI.
enum OwnerKeyRestorationNotice: String, Identifiable, Equatable {
  case identityWasReset
  case savedRecordsUsePreviousIdentity
  case identityWasResetWithSavedRecords

  var id: String { rawValue }

  static func classify(
    quarantinedSeedKey: String?,
    ownerPublicKeyMismatchDetected: Bool
  ) -> Self? {
    switch (quarantinedSeedKey != nil, ownerPublicKeyMismatchDetected) {
    case (true, true):
      return .identityWasResetWithSavedRecords
    case (true, false):
      return .identityWasReset
    case (false, true):
      return .savedRecordsUsePreviousIdentity
    case (false, false):
      return nil
    }
  }

  var title: String {
    switch self {
    case .identityWasReset:
      return String(
        localized: "ownerKeyRestoration.identityReset.title",
        defaultValue: "Proof identity was reset",
        comment: "Alert title shown when beid could not restore the device identity used to sign proofs and created a new one."
      )
    case .savedRecordsUsePreviousIdentity:
      return String(
        localized: "ownerKeyRestoration.savedRecordsMismatch.title",
        defaultValue: "Some proof records use a previous identity",
        comment: "Alert title shown when saved proof-related records refer to an owner identity different from the device's current identity."
      )
    case .identityWasResetWithSavedRecords:
      return String(
        localized: "ownerKeyRestoration.identityResetWithRecords.title",
        defaultValue: "Proof identity could not be restored",
        comment: "Alert title shown when beid both replaced an unreadable proof-signing identity and found saved records that use the previous identity."
      )
    }
  }

  var message: String {
    switch self {
    case .identityWasReset:
      return String(
        localized: "ownerKeyRestoration.identityReset.message",
        defaultValue: "beid could not restore the identity this device used to sign proofs, so it created a new one. This device can no longer use the previous identity.",
        comment: "Alert message explaining that an unreadable proof-signing identity was replaced and the previous identity is no longer usable on this device."
      )
    case .savedRecordsUsePreviousIdentity:
      return String(
        localized: "ownerKeyRestoration.savedRecordsMismatch.message",
        defaultValue: "Some saved proof records were created with a different identity. They still exist, but this device can no longer sign as that identity.",
        comment: "Alert message explaining that saved proof-related records remain on disk but refer to an owner identity this device no longer controls."
      )
    case .identityWasResetWithSavedRecords:
      return String(
        localized: "ownerKeyRestoration.identityResetWithRecords.message",
        defaultValue: "beid created a new identity because the saved one could not be restored. Some saved proof records still refer to the previous identity; they still exist, but this device can no longer sign as that identity.",
        comment: "Alert message explaining both the replacement of an unreadable proof-signing identity and the effect on saved proof-related records."
      )
    }
  }
}

enum OwnerKeyOperationFailure: Identifiable, Equatable {
  case unavailable
  var id: String { "owner-key-unavailable" }
  var title: String { String(localized: "ownerKeyFailure.title", defaultValue: "Proof key is unavailable") }
  var message: String { String(localized: "ownerKeyFailure.message", defaultValue: "beid could not access the key used for proofs. Proof-key operations are paused. Try again when your device is available.") }
}

#if DEBUG
/// Screenshot-only screen selection. Requires both launch arguments; no
/// Release build can select one, and none is written to persistent state.
enum SensingScreenshotFixture: String {
  case sensing = "05"
  case detecting = "05a"
  case detectingLong = "05a2"
  case detectingFirstTime = "05a3"
  case cantJoin = "05d"
  case stopConfirm = "05e"
  case sealed = "06"
  case proofCollected = "07"

  static var selected: SensingScreenshotFixture? {
    let arguments = ProcessInfo.processInfo.arguments
    guard arguments.contains("-beid-ui-test"),
      let flagIndex = arguments.firstIndex(of: "-beid-sensing-shot"),
      arguments.indices.contains(flagIndex + 1)
    else { return nil }
    return SensingScreenshotFixture(rawValue: arguments[flagIndex + 1])
  }
}
#endif

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
  /// Latched after startup checks finish so an alert presenter can observe it
  /// even when the asynchronous load completed before that UI appeared.
  /// Cleared only by explicit user acknowledgement.
  @Published private(set) var ownerKeyRestorationNotice: OwnerKeyRestorationNotice?
  @Published private(set) var ownerKeyOperationFailure: OwnerKeyOperationFailure?
  /// Wallet connect+binding lifecycle for the event currently being
  /// recorded — see `EventBindingState`. Sub-slice 2a only sets this to
  /// `.pendingConnect`; the interstitial that drives the rest is 2b.
  @Published private(set) var bindingState: EventBindingState = .none
  /// Barnard join code selected for the current event, if any. Manual entry
  /// stores the normalized user code here before `startSensing(eventCode:)`;
  /// a successful nearby capability stores its canonical Event ID here at the
  /// join boundary because that evidence shape uses the ID as `joinCode`.
  @Published private(set) var joinedEventCode: String?
  /// Why the most recent real-path join attempt was refused, or nil when the
  /// last attempt was not refused (beid#410).
  ///
  /// Published because a refusal previously produced a log line and nothing
  /// else: `phase` was already `.sensing` before the permission request and
  /// was never moved back, so a user whose registry read failed sat on a
  /// sensing screen with the radio off, indefinitely. A gate that refuses
  /// silently is indistinguishable from one that is broken.
  @Published private(set) var joinRefusal: EventJoinRefusal?
  /// Canonical registry Event ID for `joinedEventCode`. On manual entry it is
  /// the code lookup's untrusted routing hint until the dedicated definition
  /// resolution completes. On nearby join it comes from the freshly issued
  /// `RegistryVerifiedJoinContext`. This display/session field is never itself
  /// authority for joining.
  @Published private(set) var joinedCanonicalEventIdHex: String?
  /// The recording surface has mounted. Binding sheet auto-presentation waits
  /// for this signal so its animation does not race the recording transition.
  @Published private(set) var recordingSurfaceReady = false
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
  /// First Barnard detection timestamp for this session. Presentation only:
  /// it never enters a record, signature, or submission. A direct test/demo
  /// detection without a timestamp leaves this nil instead of inventing one.
  @Published private(set) var firstSightingAt: Date?
  /// Stable display IDs actually resolved during this live session. The radar
  /// needs the IDs even before a usable RSSI arrives; neither this set nor
  /// signal strength is persisted. All peers remain detected-only until a
  /// reciprocal observation source exists (DECISIONS 2026-09-26).
  @Published private(set) var detectedDisplayIDs: Set<String> = []
  /// Read-only linkage to the Proof created at the recording threshold.
  /// A phase alone cannot establish that a durable Proof actually exists.
  var currentProofID: UUID? { activeProofId }

  /// Uses the live wall clock for display. A guarded screenshot fixture may
  /// substitute a fixed instant so elapsed copy cannot race capture.
  func sensingPresentationNow(_ liveNow: Date) -> Date {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-beid-ui-test"), let sensingScreenshotNow {
      return sensingScreenshotNow
    }
    #endif
    return liveNow
  }

  #if DEBUG
  private var sensingScreenshotNow: Date?
  private(set) var sensingScreenshotFixture: SensingScreenshotFixture?
  private(set) var sensingScreenshotEvent: EventSession?

  /// Deliberate UI-test fixture for the Figma screenshot tour. It injects
  /// synthetic observations into the in-memory display aggregate only; no
  /// Barnard, ledger, signature, proof store, or network path runs. Each
  /// sample signal is display-only. Production uses Barnard timestamps and
  /// actual RSSI and never calls this method.
  @discardableResult
  func injectSensingScreenshotFixture() -> Bool {
    guard let fixture = SensingScreenshotFixture.selected else { return false }
    resetSessionState()
    sensingScreenshotFixture = fixture

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let start = calendar.date(from: DateComponents(
      year: 2026, month: 9, day: 26, hour: 10, minute: 0
    )) ?? Date(timeIntervalSince1970: 1_800_000_000)
    let elapsedSeconds: TimeInterval
    switch fixture {
    case .sensing, .stopConfirm: elapsedSeconds = 25 * 60
    case .detecting: elapsedSeconds = 10
    case .detectingFirstTime: elapsedSeconds = 2 * 60
    case .detectingLong: elapsedSeconds = 24
    case .cantJoin: elapsedSeconds = 0
    case .sealed, .proofCollected: elapsedSeconds = 30 * 60
    }
    firstSightingAt = fixture == .cantJoin || fixture == .proofCollected ? nil : start
    sensingScreenshotNow = start.addingTimeInterval(elapsedSeconds)

    if fixture != .cantJoin && fixture != .proofCollected {
      let peerCounts = fixture == .sensing || fixture == .stopConfirm || fixture == .sealed
        ? [1, 4, 6, 9, 8, 13]
        : [5]
      for (window, peerCount) in peerCounts.enumerated() {
        for peer in 0..<peerCount {
          let displayID = String(format: "%08x", peer + 1)
          _ = recordDeviceIdentity(
            enin: 6_000_000 + window,
            rpid: "tour-rpid-\(window)-\(peer)",
            detectedDisplayId: displayID
          )
          // Screen capture has no radio; these illustrative negative
          // values only place fixture nodes across the field. They cannot
          // enter a record and are never used by the production path.
          nodeSignalStrengths[displayID] = .measured(dBm: Double(-45 - peer * 3))
        }
      }
    }

    let event = EventSession(
      id: "ETH-TOKYO-26",
      name: "ETH Tokyo 2026",
      venue: "Tokyo Big Sight",
      identityVerification: fixture == .cantJoin ? .verified : .notChecked
    )
    sensingScreenshotEvent = event
    switch fixture {
    case .sensing, .stopConfirm, .sealed:
      recordingSurfaceReady = true
      phase = .recording(event: event, peersVerified: devicesVerified)
    case .proofCollected:
      phase = .idle
    case .detecting, .detectingLong, .detectingFirstTime:
      phase = .eventFound(event)
    case .cantJoin:
      phase = .sensing
    }
    return true
  }
  #endif
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

  // MARK: - Radar node signal strength (beid#652, display only)

  /// Sensing-time signal strength per node, keyed by normalized display id —
  /// the same id the drawing's angle uses, so a node's radius and its angle
  /// cannot end up describing two different devices.
  ///
  /// **Display only. No record, signing, or submission path reads this**, and
  /// that is structural rather than promised: its only writer,
  /// `handleSignalStrength`, is a sibling of `handleDetection` and not
  /// reachable from it, so no RSSI value is ever in lexical scope inside the
  /// recording call tree. See `NodeSignalStrength`.
  ///
  /// Republished at most once per `BeidConfig.nodeSignalRedrawMinimumInterval`
  /// (see `handleSignalStrength`), so this is a *coalesced view* of
  /// `smoothedNodeSignalDbm` below rather than its live value. Read it through
  /// `signalStrength(forNodeId:)`, which is the one place that turns "no entry"
  /// and "not measured yet" into a single answer.
  ///
  /// A node never appears here as `.unmeasured`: an entry exists only once a
  /// usable sample has been smoothed into it. `.unmeasured` is what
  /// `signalStrength(forNodeId:)` says about a key that is absent.
  @Published private(set) var nodeSignalStrengths: [String: NodeSignalStrength] = [:]
  /// Live smoothed dBm per node — updated on **every** usable sample, unlike
  /// `nodeSignalStrengths`, which only republishes on the coalescing schedule.
  /// Keeping the two apart is what lets the smoother stay accurate while the
  /// redraw stays cheap; `nodeSignalStrengths` is a total projection of this
  /// dictionary, so the two cannot drift.
  private var smoothedNodeSignalDbm: [String: Double] = [:]
  /// Event timestamp of the most recent `nodeSignalStrengths` republish, or
  /// `nil` if none has happened this session. Sourced from the caller's
  /// timestamp, never `Date()` — see `handleSignalStrength`.
  private var lastNodeSignalPublishAt: Date?

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

  /// Count-only windows durably marked as ineligible for canonical report
  /// submission. A disabled runtime remains an honest unavailable value.
  func excludedWindowCount(forEventCode eventCode: String) -> Int? {
    reportSubmissionRuntime?.excludedWindowCount(forEventCode: eventCode)
  }

  /// Read-only Lab projection of durable submission metadata. No network call or write.
  func labRecordProjection() -> Result<[LabRecordMetadata], ReportSubmissionStore.LabRecordProjectionError> {
    if let runtime = reportSubmissionRuntime {
      return runtime.labRecordProjection()
    }
    return ReportSubmissionStore().labRecordProjection()
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
  private static let log = Logger(subsystem: "BeidRuntimeDiagnostics", category: "sensing")
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

  private static func defaultJoinDiagnosticLog(_ message: String) {
#if DEBUG
    log.debug("\(message, privacy: .public)")
#endif
  }

  /// The Barnard participation operations this coordinator drives (beid#410).
  ///
  /// Deliberately `any EventJoinControlling` rather than a `BarnardEngine`.
  /// That protocol has no `joinEvent(String)` and no argumentless
  /// `startAuto()` on it, so this type cannot join or start sensing without a
  /// `RegistryVerifiedJoinContext` — not because a check refuses, but because
  /// there is no method to call. Holding the concrete engine here is what
  /// previously left both doors open.
  private let engine: any EventJoinControlling

  /// The Barnard relay operations this coordinator drives. Defaults to the
  /// same Barnard engine `engine` forwards to; injected in tests, which
  /// cannot construct a `BarnardEngine` they can observe.
  private let relayControl: any ParticipantRelayControlling

  /// The spec 134 relay verifier (beid#367). Held for the whole lifetime and
  /// republished as discovery state moves, rather than rebuilt per session:
  /// Barnard may call it from another queue at any moment while configured,
  /// and swapping the object under that call buys nothing.
  private let relayVerifier: ParticipantRelayVerifier

  /// Repeating 30-second wake-up that runs the relay's lease decisions.
  private var relayCadenceTask: Task<Void, Never>?

  /// How long that wake-up waits. Spec 134's `T` in production; injectable
  /// only so a test need not spend thirty real seconds watching one tick.
  private let relayCadenceNanoseconds: UInt64

  /// The gate's current event id, as the verifier would read it. Exposed so a
  /// test can assert the gate stays shut for an event whose definition has not
  /// been verified; nothing in the app reads it.
  var relayGateJoinedEventIdHexForTesting: String? { relayGateEventIdHex }

  /// The canonical event id the relay gate is open for, which is deliberately
  /// not `joinedCanonicalEventIdHex`.
  ///
  /// That property holds what `AppCoordinator.resolveCanonicalEventIdHex`
  /// returned: a code-to-id lookup, with no reading of the event's definition.
  /// Spec 134 step 3 wants the authoritative definition before re-broadcast,
  /// so this holds the `eventIdHex` of the `RegistryVerifiedJoinContext` the
  /// join gate admitted — the definition's own id, established by this host's
  /// own authenticated read before the join. That is the same bar and the same
  /// wiring Android applies (beid#374, `EventJoinCoordinator.beginVerifiedJoin`).
  ///
  /// Opened in exactly one place (beid#437) — `applyJoinGateDecision` on admit
  /// — and closed in exactly one, `closeRelayGate`. Where that helper is
  /// called from, and why each caller closes the gate, is documented on
  /// `closeRelayGate` itself.
  ///
  /// It used to be written by the `EventIdentityVerification` lifecycle
  /// instead. That made the gate depend on a second registry read's outcome
  /// when the join gate had already established the same fact, so a
  /// legitimately joined device could be left unable to relay with nothing
  /// shown to explain it. **The second read still happens** — #437 removed the
  /// gate's dependency on it, not the read, which has its own user-visible
  /// consumer.
  private var relayGateEventIdHex: String?

  /// The most recent spec 134 decision, for visibility only. It never feeds a
  /// card, a tally, or a phase: hop counts and relay volume say nothing about
  /// an event (spec 134, "Security and abuse considerations").
  ///
  /// Deliberately not `@Published`, unlike almost everything else here. A
  /// published property is one a SwiftUI view can bind to and redraw from,
  /// and the one fact this carries that no screen may ever show is the hop
  /// count. Diagnostics read it; the interface cannot observe it.
  private(set) var lastRelayDecision: ParticipantRelayDecision?
  private let sensingCryptography: any SensingCryptography
  private let reportSubmissionRuntime: (any WindowReportSubmissionRuntimeProtocol)?
  private let eventIdentityVerificationSource: (any EventIdentityVerificationSource)?
  private let ownerKeyRestorationAcknowledgementDefaults: UserDefaults
  private var ownerKeyRestorationIdentityFingerprint: Data?
  private static let acknowledgedOwnerKeyRestorationIdentityKey =
    "beid.acknowledgedOwnerKeyRestorationIdentity"
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
    guard let activeOwnerPublicKey = resolvedOwnerPublicKey() else { return false }
    return OwnerKeyRegenerationDetector.ownerPublicKeyMismatchDetected(
      activeOwnerPublicKey: activeOwnerPublicKey,
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
    [(enin: Int, rpid: String, detectedDisplayId: String?, reporterRpid: String?, observedAt: Date?)] = []
  /// Decision 1's background load/reconcile task (`beginLedgerLoad(...)`).
  /// Held so tests can deterministically await it
  /// (`waitForLedgerLoadToFinish()`), mirroring `demoTask`/
  /// `waitForDemoSequenceToFinish()` below.
  private var ledgerLoadTask: Task<Void, Never>?
  private var demoTask: Task<Void, Never>?
  private var demoInterpreterScenario: DemoScenario?
  /// Preview seam (beid#399): the screen at which to stop this scenario.
  ///
  /// Deliberately a *screen*, resolved from the live phase through the same
  /// `ScanFlowContent.route(for:)` the app renders with, rather than a step
  /// index. A step index would put the reducer's confirm decision into the
  /// caller — the preview would encode an assumption about the code and keep
  /// rendering a stale screen after any reducer change. Here the reducer runs
  /// and the interpreter stops when the resulting screen is the requested one,
  /// so the reducer stays the only authority on where a scenario gets to.
  private var demoInterpreterStopRoute: ScanFlowContent.Route?
  /// Whether the run actually reached `demoInterpreterStopRoute`.
  ///
  /// Not every scenario reaches every screen — `crowdSurge` never goes to
  /// Signal Lost — and a preview that silently rendered the terminal screen
  /// under another screen's name would be a fixture lying about what it shows.
  /// Callers read this to say "not reachable" instead of showing the wrong
  /// screen confidently.
  private(set) var demoScenarioReachedRequestedRoute = false
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
  /// Identifies the current join attempt so a completion that lands after the
  /// user moved on cannot act (beid#410).
  ///
  /// Bumped by `resetSessionState()` and `leaveEvent()`, so stopping,
  /// restarting or leaving all invalidate anything still in flight. Both the
  /// permission completion and the registry completion re-check it.
  ///
  /// Without this, the sequence startSensing, user stops, permission grant
  /// lands, read succeeds, joinAndStart runs — with `phase` already `.idle`.
  /// The capability's own documentation names carrying a request identity
  /// through a permission wait as a *host* obligation, and Android discharges
  /// it with `isCurrentJoinVerification`. The first version of this gate cited
  /// that reason for issuing the capability late and then did not implement
  /// the guard the reason calls for.
  private var joinAttemptGeneration = 0
  /// The in-flight join-time registry read, cancelled when an attempt is
  /// abandoned rather than left to answer into a session that has moved on.
  private var joinRegistryRequest: (any EventIdentityVerificationRequest)?
  /// The event code this sensing session was started for, carried the same way
  /// and for the same span as `pendingCanonicalEventIdHex`.
  ///
  /// Held here rather than read back from Barnard (beid#410). The session's
  /// name used to come from `getCurrentEventCode()`, which worked only because
  /// `joinEvent` pushed the code into Barnard the instant the user typed it.
  /// Now that joining waits for a verified capability, Barnard knows no code
  /// until the join actually happens — so asking it during `.sensing` returned
  /// nothing and the session was named `"Unknown Event"`. That name is not
  /// cosmetic: it becomes `EventSession.id`, and it reaches the durable
  /// records a session produces.
  ///
  /// The coordinator owns the selection now, so the selection is the honest
  /// source. Barnard's copy is derived from this one, never the reverse.
  private var pendingEventCode: String?
  /// Demo-only ENIN counter (`advanceDemoWindow()`) — never touches
  /// `closeWindow`/`WindowReportStore`, only stands in for the real path's
  /// `advanceWindowBookkeepingIfNeeded`-derived `firstWindowEnin`/
  /// `currentWindowEnin` so the self-proof layer (§2.2) is exercisable
  /// under demo mode too.
  private var demoWindowEnin = 0

  // MARK: - Nearby event discovery state (B005 pre-join hints, gh#100 Stage 1)
  //
  // Deliberately *not* per-session protocol state: a B005 hint is an
  // unauthenticated pre-join observation, so it is owned here rather than in
  // `resetSessionState()`, which also runs mid-session (`startSensing`,
  // `beginEventFoundSessionState`) and would wrongly discard candidates the
  // user is still choosing from. Cleared only by `endSensing(stopEngine:)`.

  /// Observer-local discovery state. Every decision about grouping,
  /// deduplication, expiry, and ordering lives in `shared/`
  /// (`org.levarac.parallax.discovery`) so iOS and Android answer
  /// "what is nearby" identically; this file only performs effects.
  private let nearbyDiscoveryStore:
    ExportedKotlinPackages.org.levarac.parallax.discovery.NearbyEventDiscoveryStore

  /// Immutable snapshot of the current discovery session.
  ///
  /// A candidate's `registryStatus` now moves: this host runs the operator
  /// lookup that resolves an 8-byte B005 event-code hash to a 32-byte registry
  /// Event ID, and the shared reducer records the outcome. What has not
  /// changed is why that lookup exists at all -- the hash is not an Event ID
  /// and must never be padded, truncated, or otherwise coerced into one.
  @Published private(set) var nearbyEventCandidates:
    ExportedKotlinPackages.org.levarac.parallax.discovery.NearbyEventCandidates

  /// Epoch-milliseconds source, injected so tests drive expiry deterministically.
  private let nearbyDiscoveryClock: () -> Int64

  /// At most one in-flight expiry wake-up, rescheduled on every publish.
  private var nearbyDiscoveryExpiryTask: Task<Void, Never>?
  /// True only while this coordinator has started a Central-only scan for
  /// the pre-join surface. Joining transfers the already-running scan to
  /// Barnard's automatic operation without stopping it; dismissing before a
  /// join stops only when this flag proves the flow owns that scan.
  private var discoveryOnlyScanOwned = false
  private let nearbyRegistryClient:
    ExportedKotlinPackages.org.levarac.parallax.registry.RegistryClient?
  /// The join gate's registry read, behind a protocol a test can answer
  /// (beid#410). Defaults to a production adapter over `nearbyRegistryClient`,
  /// so production wiring is unchanged and only tests inject.
  ///
  /// The gate read through the Kotlin client directly at first. No test can
  /// build one, so every gate test ran with no client and stopped at the first
  /// guard — the suite could not reach the read, the issuer, or any refusal
  /// past "none configured", and deleting the method body left it green.
  private let eventJoinRegistry: (any EventJoinRegistry)?
  private var nearbyRegistryRequests:
    [ExportedKotlinPackages.org.levarac.parallax.registry.RegistryRequest] = []
  private var nearbyEventDefinitionRequests: [any EventIdentityVerificationRequest] = []
  /// Invalidates registry callbacks already queued on MainActor when a
  /// discovery session ends; cancelling the underlying request cannot recall
  /// a completion that was delivered before cancellation.
  private var nearbyDiscoveryCallbackGeneration: UInt64 = 0

  /// Barnard's `registryAgreement` for the radio-self-verified envelope last
  /// seen for an event-code hash, held as a closure because
  /// `BarnardB005VerifiedEnvelope` has no public initializer and so cannot be
  /// carried across a test seam. This file never re-implements the
  /// comparison; it decides only *when* barnard is asked for it, and asks
  /// only with a definition this host read from the registry itself.
  private var nearbyEnvelopeAgreements: [String: (BarnardEventDefinitionV1) -> Bool] = [:]

  /// The definition this host's own authenticated registry read returned,
  /// kept so an envelope arriving *after* a hash's single registry resolution
  /// completed still has something to be compared against.
  private var nearbyVerifiedDefinitions: [String: BarnardEventDefinitionV1] = [:]

  /// Canonical Event IDs carried by Barnard's radio-self-verified B005 v2
  /// envelopes, keyed by the same hash as the discovery reducer.
  private var nearbyVerifiedEventIds: [String: String] = [:]

  /// Opaque selectors for Lab control. The Lab host may choose one of these
  /// values, but never derives an event ID or registry result itself.
  func labJoinableEventCodeHashHexes() -> [String] {
    (0..<nearbyEventCandidates.candidateCount).compactMap { index in
      guard let candidate = nearbyEventCandidates.candidateAt(index: index) else { return nil }
      let hash = candidate.eventCodeHashHex
      guard nearbyVerifiedDefinitions[hash] != nil || nearbyVerifiedEventIds[hash] != nil else { return nil }
      return hash
    }
  }

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
  /// rpid/displayId pair. That guarantees a call grows the shared device
  /// count by exactly one only when a display id is actually supplied: since
  /// beid#395 a scenario may pass `nil`, and such a call is counted here
  /// (the id space is still consumed) while deliberately leaving
  /// `devicesVerified` untouched.
  private var demoDeviceSequence = 0
  /// Demo-only stand-in for `currentWindowRpids` (beid#189), scoped to the
  /// demo script's own window concept (`demoWindowEnin`/
  /// `advanceDemoWindow()`) instead of a real ENIN boundary. Feeds
  /// `applyPhaseDecision`'s `coPresentDeviceCount` argument with an
  /// honestly-tracked value rather than a fabricated placeholder — see
  /// `applyPhaseDecision`'s own doc comment for why a fabricated count
  /// would itself violate DECISIONS 2026-08-01, not just an implementation
  /// detail. Every scenario before beid#395 confirmed through the
  /// distinct-device arm in practice, since `devicesVerified` grows
  /// monotonically across the whole scripted session while this set resets
  /// every `advanceDemoWindow()` call. `unidentifiedHeavy` is the first that
  /// does not: nothing it observes resolves a display id, so the
  /// distinct-device arm can never fire and co-presence is the only arm
  /// left — which is why that scenario keeps all of its observations inside
  /// one demo window. The reducer receives a real count either way, never a
  /// stand-in chosen to force an outcome. Cleared by `advanceDemoWindow()`
  /// and `resetSessionState()`; inserted into by `observeOneDemoDevice()`.
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

  /// The registry error code from the code-to-id lookup that produced (or
  /// failed to produce) `joinedCanonicalEventIdHex`.
  private var joinedLookupErrorCode: String?

  /// Test-replaceable sink for the Debug-only join path diagnostics.
  private let joinDiagnosticLog: (String) -> Void

  /// Why the last join attempt was refused, as
  /// `BeidSharedKit.event.eventJoinFailureReasonKey`'s value, or nil when
  /// nothing has been refused.
  ///
  /// `joinRefusal` already existed and no view ever read it, so a refusal was
  /// visible only in the log: "nothing is happening" looked identical whether
  /// the radio had never started or was simply alone in the room. That is the
  /// state the owner spent a field session in on 2026-09-10 (beid#472).
  ///
  /// A key rather than the shared enum, because Swift Export gives a Kotlin
  /// enum no name, no description and no equality — see
  /// `eventJoinFailureReasonKey`'s own doc for the other half of that.
  @Published private(set) var joinRefusalReasonKey: String?

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
      },
      nearbyRegistryClient: registryClient
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
    eventIdentityVerificationSource: (any EventIdentityVerificationSource)? = nil,
    eventJoinControl: (any EventJoinControlling)? = nil,
    ownerKeyRestorationAcknowledgementDefaults: UserDefaults = .standard
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
      eventIdentityVerificationSource: eventIdentityVerificationSource,
      eventJoinControl: eventJoinControl,
      ownerKeyRestorationAcknowledgementDefaults: ownerKeyRestorationAcknowledgementDefaults
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
    eventIdentityVerificationSource: (any EventIdentityVerificationSource)?,
    eventJoinControl: (any EventJoinControlling)? = nil,
    ownerKeyRestorationAcknowledgementDefaults: UserDefaults = .standard,
    nearbyRegistryClient:
      ExportedKotlinPackages.org.levarac.parallax.registry.RegistryClient? = nil
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
      ownerKeyRestorationAcknowledgementDefaults: ownerKeyRestorationAcknowledgementDefaults,
      initialLedgerFailure: nil,
      nearbyRegistryClient: nearbyRegistryClient,
      eventJoinControl: eventJoinControl
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
  /// detection-driven record could be created. Signal A/B remain logged for
  /// device diagnostics, and the same facts are latched as one user-facing
  /// notice (beid#311). The notice stays queryable until acknowledged; this
  /// slice deliberately adds no restoration operation.
  private func logOwnerKeyRegenerationSignalsIfNeeded() {
    // Resolve the owner key before reading Signal A. Quarantine happens
    // during that resolution, so reading `quarantinedOwnerKeySeedKey` first
    // can miss the event that this very startup check triggers.
    guard let activeOwnerPublicKey = resolvedOwnerPublicKey() else { return }
    let mismatchDetected = OwnerKeyRegenerationDetector.ownerPublicKeyMismatchDetected(
      activeOwnerPublicKey: activeOwnerPublicKey,
      selfProofRecords: selfProofStore.records,
      bindingRecords: bindingRecordStore.records
    )
    let quarantinedSeedKey = quarantinedOwnerKeySeedKey
    let detectedNotice = OwnerKeyRestorationNotice.classify(
      quarantinedSeedKey: quarantinedSeedKey,
      ownerPublicKeyMismatchDetected: mismatchDetected
    )
    let acknowledgedIdentity = ownerKeyRestorationAcknowledgementDefaults.data(
      forKey: Self.acknowledgedOwnerKeyRestorationIdentityKey
    )
    if detectedNotice != nil, acknowledgedIdentity != activeOwnerPublicKey {
      ownerKeyRestorationNotice = detectedNotice
      ownerKeyRestorationIdentityFingerprint = activeOwnerPublicKey
    }

    if let quarantinedSeedKey {
      Self.ledgerLog.error("Owner key seed was quarantined and regenerated this session at \(quarantinedSeedKey, privacy: .public)")
    }
    if mismatchDetected {
      Self.ledgerLog.error("Owner public key does not match some already-persisted self-proof/binding record")
    }
  }

  private func resolvedOwnerPublicKey() -> Data? {
    do {
      let key = try sensingCryptography.ownerPublicKey()
      ownerKeyOperationFailure = nil
      return key
    } catch {
      ownerKeyOperationFailure = .unavailable
      Self.ledgerLog.error("Owner key operation failed: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  func retryOwnerKeyOperation() {
    guard resolvedOwnerPublicKey() != nil else { return }
    logOwnerKeyRegenerationSignalsIfNeeded()
  }

  func acknowledgeOwnerKeyRestorationNotice() {
    if let ownerKeyRestorationIdentityFingerprint {
      // This is a public key, not secret key material. Using it as the
      // acknowledgement fingerprint suppresses repeat alerts only while the
      // same current identity remains active; a later replacement gets a new
      // public key and therefore surfaces a fresh warning.
      ownerKeyRestorationAcknowledgementDefaults.set(
        ownerKeyRestorationIdentityFingerprint,
        forKey: Self.acknowledgedOwnerKeyRestorationIdentityKey
      )
    }
    ownerKeyRestorationNotice = nil
    ownerKeyRestorationIdentityFingerprint = nil
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
    eventIdentityVerificationSource: (any EventIdentityVerificationSource)? = nil,
    eventJoinControl: (any EventJoinControlling)? = nil,
    eventJoinRegistry: (any EventJoinRegistry)? = nil,
    nearbyDiscoveryStore:
      ExportedKotlinPackages.org.levarac.parallax.discovery.NearbyEventDiscoveryStore? = nil,
    nearbyDiscoveryClock: @escaping () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    },
    joinDiagnosticLog: @escaping (String) -> Void = SensingCoordinator.defaultJoinDiagnosticLog,
    participantRelayControl: (any ParticipantRelayControlling)? = nil,
    relayCadenceNanoseconds: UInt64 = SensingCoordinator.relayDecisionBoundaryNanoseconds
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
      eventIdentityVerificationSource: eventIdentityVerificationSource,
      nearbyDiscoveryClock: nearbyDiscoveryClock,
      eventJoinControl: eventJoinControl,
      eventJoinRegistry: eventJoinRegistry,
      nearbyDiscoveryStore: nearbyDiscoveryStore,
      joinDiagnosticLog: joinDiagnosticLog,
      participantRelayControl: participantRelayControl,
      relayCadenceNanoseconds: relayCadenceNanoseconds
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
    ownerKeyRestorationAcknowledgementDefaults: UserDefaults = .standard,
    initialLedgerFailure: Error? = nil,
    nearbyDiscoveryClock: @escaping () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1000).rounded())
    },
    nearbyRegistryClient:
      ExportedKotlinPackages.org.levarac.parallax.registry.RegistryClient? = nil,
    eventJoinControl: (any EventJoinControlling)? = nil,
    eventJoinRegistry: (any EventJoinRegistry)? = nil,
    nearbyDiscoveryStore injectedNearbyDiscoveryStore:
      ExportedKotlinPackages.org.levarac.parallax.discovery.NearbyEventDiscoveryStore? = nil,
    joinDiagnosticLog: @escaping (String) -> Void = SensingCoordinator.defaultJoinDiagnosticLog,
    participantRelayControl: (any ParticipantRelayControlling)? = nil,
    relayCadenceNanoseconds: UInt64 = SensingCoordinator.relayDecisionBoundaryNanoseconds
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
    self.ownerKeyRestorationAcknowledgementDefaults = ownerKeyRestorationAcknowledgementDefaults
    self.nearbyDiscoveryClock = nearbyDiscoveryClock
    self.nearbyRegistryClient = nearbyRegistryClient
    self.joinDiagnosticLog = joinDiagnosticLog
    self.eventJoinRegistry = eventJoinRegistry
      ?? nearbyRegistryClient.map { RegistryEventJoinRegistry(client: $0) }
    let nearbyDiscoveryStore = injectedNearbyDiscoveryStore
      ?? ExportedKotlinPackages.org.levarac.parallax.discovery.createNearbyEventDiscoveryStore()
    self.nearbyDiscoveryStore = nearbyDiscoveryStore
    self.nearbyEventCandidates = nearbyDiscoveryStore.snapshot
    self.relayVerifier = ParticipantRelayVerifier(
      state: ParticipantRelayGateState(
        candidates: nearbyDiscoveryStore.snapshot,
        verifiedDefinitionsByHash: [:],
        joinedEventIdHex: nil
      )
    )
    // One Barnard engine backs both seams by default, so production keeps the
    // single instance it has always had. Either seam can be injected on its
    // own; a test that injects only one still gets the real engine behind the
    // other, exactly as before.
    let barnardEngine = BarnardEngine()
    self.engine = eventJoinControl ?? barnardEngine
    self.relayControl = participantRelayControl ?? barnardEngine
    self.relayCadenceNanoseconds = relayCadenceNanoseconds
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
    let expiryTask = nearbyDiscoveryExpiryTask
    let eventJoinControl = engine
    let stopOwnedDiscoveryScan = discoveryOnlyScanOwned
    // Mirrors Android's `dispose()`. Barnard's engine outlives nothing here,
    // but the relay is the one thing this object switched on that keeps a
    // radio busy, so it is switched off on the way out rather than left to a
    // caller remembering to stop sensing first. Captured as locals because
    // `deinit` cannot hand `self` to a task.
    let relayControl = self.relayControl
    let cadenceTask = relayCadenceTask
    Task { @MainActor in
      request?.cancel()
      expiryTask?.cancel()
      cadenceTask?.cancel()
      if stopOwnedDiscoveryScan {
        eventJoinControl.stopDiscoveryScan()
      }
      relayControl.setParticipantRelayVerifier(nil)
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
        reporterRpid: detection.reporterRpid,
        observedAt: detection.timestamp
      )
      // A SIBLING call, deliberately — not an extra argument to
      // `handleDetection` above (beid#652). A detection carries an `rssi`
      // this app used to drop here; routing it through its own function
      // instead of into the recording call tree is what keeps signal
      // strength out of lexical scope everywhere a record is built. Note it
      // is not given `detection.enin`: the window index is record
      // vocabulary. See `NodeSignalStrength`.
      //
      // Called AFTER `handleDetection`, and that order is load-bearing: a
      // detection arriving in `.sensing` runs `beginEventFoundSessionState`
      // synchronously, which calls `resetSessionState()` and clears the
      // signal-strength state with the rest of the session. Applying this
      // sample first would throw it away at the very transition where the
      // radar most needs a radius for the device that caused it.
      handleSignalStrength(
        rssi: detection.rssi,
        detectedDisplayId: detection.detectedDisplayId,
        at: detection.timestamp
      )
    case .eventInfoEnvelopeV2(let envelopeEvent):
      handleObservedEventInfoEnvelopeV2(envelopeEvent)
    case .relayDecision(let relay):
      handleRelayDecision(
        decision: relay.decision,
        payloadDigestHex: relay.payloadDigest.lowercaseHexString,
        hop: relay.hop,
        reason: relay.reason
      )
    case .eventInfoHint(let hint):
      handleEventInfoHint(
        peripheralId: hint.peripheralId.uuidString,
        eventDisplayName: hint.eventInfo.eventDisplayName,
        eventCodeHash: hint.eventInfo.eventCodeHash,
        census: hint.eventInfo.census,
        additionalNamesOmitted: hint.additionalNamesOmitted,
        additionalEventsOmitted: hint.additionalEventsOmitted
      )
    // The remaining cases are deliberately ignored, and they are named rather
    // than swept up by `default:` so that this switch is exhaustive over
    // `BarnardEvent`. Exhaustiveness is the point: with a `default:` here,
    // deleting any one of the handled cases above compiles and silently stops
    // handling that event, which is how beid#571's contract test could stay
    // green with the `.eventInfoEnvelopeV2` case removed. Barnard is an SPM
    // source dependency without library evolution, so the compiler treats this
    // enum as frozen and needs no `@unknown default`.
    //
    // The cost, accepted on purpose: a barnard version that adds a case breaks
    // this build. That is the intended prompt to decide what the new event
    // means here, instead of dropping it without anyone noticing.
    //
    // Why each is ignored today: `.constraint` and `.error` are barnard's own
    // diagnostics, which this app surfaces through its sensing state rather
    // than by reacting per event, and reacting to them one at a time would
    // duplicate that state machine.
    //
    // `.rssiUpdate` used to be in this list. It no longer is (beid#652): it
    // is handled below, and it is handled by the same sibling function the
    // `.detection` case calls, because it is the same kind of value — signal
    // strength, used for display only, never for any decision. What has not
    // changed is the part that mattered: no beid *decision* reads it. Being
    // handled is not the same as being trusted, and nothing that records,
    // signs, or submits may start reading it now that it has a home.
    case .constraint, .error:
      break
    case .rssiUpdate(let update):
      handleSignalStrength(
        rssi: update.rssi,
        detectedDisplayId: update.detectedDisplayId,
        at: update.timestamp
      )
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
    reporterRpid: String? = nil,
    observedAt: Date? = nil
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
          reporterRpid: reporterRpid,
          observedAt: observedAt
        )
      )
      return
    }
    #if DEBUG
    let phaseTag: String
    switch phase {
    case .sensing: phaseTag = "sensing"
    case .eventFound: phaseTag = "event_found"
    case .recording: phaseTag = "recording"
    case .signalLost: phaseTag = "signal_lost"
    case .idle: phaseTag = "idle"
    }
    Self.log.debug("peer_detection phase=\(phaseTag, privacy: .public)")
    #endif
    switch phase {
    case .sensing:
      let eventCode = pendingEventCode ?? engine.currentJoinedEventCode() ?? "Unknown Event"
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
      rememberFirstSighting(at: observedAt)
    case .eventFound(let session):
      observe(
        enin: enin,
        rpid: rpid,
        detectedDisplayId: detectedDisplayId,
        reporterRpid: reporterRpid,
        for: session
      )
      rememberFirstSighting(at: observedAt)
    case .recording(let session, _):
      observe(
        enin: enin,
        rpid: rpid,
        detectedDisplayId: detectedDisplayId,
        reporterRpid: reporterRpid,
        for: session
      )
      rememberFirstSighting(at: observedAt)
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

  private func rememberFirstSighting(at timestamp: Date?) {
    guard firstSightingAt == nil, let timestamp else { return }
    firstSightingAt = timestamp
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
    // This lifecycle no longer touches the relay gate (beid#437). It used to
    // open the gate on `.verified` and close it on every other outcome, which
    // made the gate depend on *this* read's answer even though the join gate
    // had already obtained the same fact. A device that had legitimately
    // joined a verified event was then unable to relay, with no reason shown,
    // whenever this read failed. The gate now opens from the capability the
    // join gate admitted, and closes in `closeRelayGate`.
    //
    // **This read itself is deliberately kept.** #437 removes the gate's
    // dependency on it, not the read: its other consumer is the verification
    // status this function publishes just above, which
    // `EventIdentityVerificationRow` shows to the user. Whether that surface
    // should exist at all belongs to #141/#100, not here.
    //
    // The republish below stays. It rebuilds the gate state from the current
    // candidate snapshot and cached definitions, which this outcome may have
    // changed, and carries the gate's existing id forward unchanged.
    republishRelayGateState()
    eventIdentityVerificationRequest = nil
  }

  /// Invalidates the current lookup before any lifecycle operation can expose
  /// a later session to its callback.
  private func invalidateEventIdentityVerification() {
    // Does not close the relay gate (beid#437). Replacing this lookup says
    // nothing about whether this device is still joined, and the join is what
    // the gate is about. `closeRelayGate` documents what does close it.
    republishRelayGateState()
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

    if let displayId, !detectedDisplayIDs.contains(displayId) {
      detectedDisplayIDs.insert(displayId)
    }

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

  // MARK: - Radar node signal strength (beid#652, display only)

  /// The signal strength to draw for `nodeId`. **Always answers; never
  /// returns `nil`.**
  ///
  /// This is THE decision point for "no signal yet". A node with no entry in
  /// `nodeSignalStrengths` and a node explicitly not measured are the same
  /// thing to every caller, and collapsing them here is the whole reason this
  /// function exists: without it there would be two ways to say "no signal"
  /// — an absent key and `.unmeasured` — and each consumer would have to know
  /// which one it was looking at. One named function, one answer.
  ///
  /// `nodeId` must already be normalized
  /// (`BeidSharedKit.sensing.normalizedDisplayIdOrNull`), like every other id
  /// in this dictionary; an unknown id is not an error, it is `.unmeasured`.
  func signalStrength(forNodeId nodeId: String) -> NodeSignalStrength {
    nodeSignalStrengths[nodeId] ?? .unmeasured
  }

  /// Folds one RSSI sample into the display-only per-node signal strength.
  ///
  /// **A sibling of `handleDetection`, never a step inside it.** Both the
  /// `.detection` and `.rssiUpdate` Barnard events route here, and nothing on
  /// the recording path calls this or is called by it. That separation — not
  /// this comment — is what guarantees signal strength never reaches a
  /// record, a signature, or a submission. Do not add an `rssi` parameter to
  /// `handleDetection`, `observe`, or `recordDeviceIdentity` to "simplify"
  /// this away; the guarantee is the shape.
  ///
  /// **Takes no `enin`, deliberately.** The window index is record
  /// vocabulary, and a display path that cannot name the window it belongs to
  /// cannot be folded into a per-window record even by accident. Do not add
  /// it back for symmetry with `handleDetection`.
  ///
  /// Not `private` for the same reason `handleDetection` is not: Barnard's
  /// event structs have no public initializer, so `BeidTests` drives this
  /// path by calling it with plain arguments.
  ///
  /// **Gated to the sensing phases**, mirroring `handleDetection`'s own
  /// `.idle, .signalLost` branch rather than inventing a second shape. The
  /// reason a reader will not reconstruct is `.signalLost`: that phase is a
  /// *frozen* count, resumed only by an explicit `resumeSensing()`, and
  /// `simulateSignalLost()` does not call `resetSessionState()`. Without this
  /// gate the radar would keep its nodes moving while the count printed
  /// beside them was frozen — one screen telling the user two different
  /// things about whether anything is still happening. `.idle` is the same
  /// argument with less at stake: nothing is drawn, so folding samples in is
  /// at best wasted work and at worst state for the next session to inherit
  /// if a reset is ever missed. It is also what makes the acceptance
  /// criterion's "**sensing-time** signal strength" literally true rather
  /// than approximately true.
  ///
  /// **This gate runs in the opposite direction to the one DESIGN.md §2
  /// forbids, and must not be "fixed" by deleting it.** The Non-Negotiable is
  /// that signal strength may not influence a decision. Here the *phase*
  /// decides whether the *display* updates; signal strength still decides
  /// nothing, and nothing downstream of it decides anything. Information
  /// flows phase → display, never display → phase.
  ///
  /// Three things happen here, in order, and only the third is gated:
  ///
  /// 1. **Usability.** A sample is a measurement only if it is below
  ///    `BeidConfig.nodeSignalUsableUpperBoundDbm`. `0` (Barnard's proven
  ///    `discoveredRssi[id] ?? 0` sentinel), any positive value, and `127`
  ///    (CoreBluetooth's unavailable marker) are not measurements: the node
  ///    stays `.unmeasured` and the smoother never sees them. A rejected
  ///    sample creates no entry at all, so it cannot later be mistaken for a
  ///    measured one.
  /// 2. **Smoothing**, on every usable sample. An exponential moving average,
  ///    `new = previous + alpha * (sample - previous)`. The first usable
  ///    sample seeds the value *directly* rather than ramping from zero — a
  ///    ramp from 0 dBm would walk a node inward from the radar's centre,
  ///    which is `NodeSignalStrength.unmeasured`'s failure mode in motion.
  /// 3. **Republishing**, at most once per
  ///    `BeidConfig.nodeSignalRedrawMinimumInterval`, decided purely from the
  ///    `timestamp` the caller passes — not `Date()`, not a `Timer`, not a
  ///    `Task`. No clock seam, no async, so the whole path is deterministic
  ///    under test. A node's first transition out of `.unmeasured` always
  ///    publishes immediately regardless of the interval: a node appearing is
  ///    not jitter, and delaying it would leave a device visible in
  ///    `devicesVerified` but missing a radius. That forced publish *does*
  ///    rearm the interval, so a burst of arrivals can push an established
  ///    node's next update back by up to one interval per new node. Chosen
  ///    deliberately, not overlooked: a burst of arrivals is exactly when an
  ///    extra redraw costs most, and the established nodes are meanwhile
  ///    sitting at a radius that is at most one EMA step stale.
  ///
  /// The accepted trade-off of coalescing without a timer: **the last sample
  /// before a node goes quiet may never be published.** That is deliberate. A
  /// single sample moves an EMA by only `alpha`, and a node that stops
  /// advertising expires shortly afterwards anyway, so the cost is a
  /// marginally stale radius on a node that is already leaving — paid to
  /// avoid a timer, and with it a second clock this path would have to stay
  /// correct against.
  func handleSignalStrength(rssi: Int, detectedDisplayId: String?, at timestamp: Date) {
    switch phase {
    case .sensing, .eventFound, .recording:
      break
    case .idle, .signalLost:
      // See this function's doc comment: `.signalLost` is a frozen count, and
      // a radar that kept moving underneath it would contradict the number
      // next to it. The phase gates the display; the display gates nothing.
      return
    }

    // Same `shared/` canonicalization `recordDeviceIdentity` uses (beid#231),
    // so the radius and the angle key on one identity rather than two. A null
    // display id (Barnard B003 unavailable) is not a node: it cannot be
    // attributed to a device, so there is nothing to draw it on.
    guard let nodeId = BeidSharedKit.sensing.normalizedDisplayIdOrNull(
      detectedDisplayId: detectedDisplayId
    ) else { return }
    guard rssi < BeidConfig.nodeSignalUsableUpperBoundDbm else { return }

    let sample = Double(rssi)
    let isFirstMeasurement = smoothedNodeSignalDbm[nodeId] == nil
    let smoothed: Double
    if let previous = smoothedNodeSignalDbm[nodeId] {
      smoothed = previous + BeidConfig.nodeSignalSmoothingFactor * (sample - previous)
    } else {
      smoothed = sample
    }
    smoothedNodeSignalDbm[nodeId] = smoothed

    guard isFirstMeasurement || shouldRepublishNodeSignalStrengths(at: timestamp) else { return }
    lastNodeSignalPublishAt = timestamp
    nodeSignalStrengths = smoothedNodeSignalDbm.mapValues { NodeSignalStrength.measured(dBm: $0) }
  }

  /// Whether enough event time has passed since the last republish. Compares
  /// the caller's event timestamps only, so it holds no clock of its own.
  ///
  /// A timestamp at or before the last publish — which a reordered or
  /// replayed Barnard event can produce — yields a non-positive elapsed value
  /// and so does not republish. That is the safe direction: it withholds a
  /// redraw rather than admitting an out-of-order one.
  private func shouldRepublishNodeSignalStrengths(at timestamp: Date) -> Bool {
    guard let last = lastNodeSignalPublishAt else { return true }
    return timestamp.timeIntervalSince(last) >= BeidConfig.nodeSignalRedrawMinimumInterval
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

  /// Selects a manually entered event code through the wallet-optional
  /// `EventCodeEntryView` path. Nearby-card selection does not call this
  /// method; `joinNearbyEvent` instead reissues shape (a) evidence directly
  /// from the current discovery snapshot. Returns whether the typed code was
  /// accepted as a pending manual selection.
  ///
  /// **Selecting is not joining (beid#410).** Barnard is told nothing here.
  /// This used to call `BarnardEngine.joinEvent` on its very next line, which
  /// meant the app joined an event before any registry read had verified it,
  /// and the verification that followed only *annotated* a session that had
  /// already begun. The join now happens in `startSensing`, and only if the
  /// shared issuer grants a `RegistryVerifiedJoinContext` at that moment.
  ///
  /// What is retained is the *evidence* a capability can be issued from — a
  /// code and a canonical id — never a capability. The capability's own
  /// documentation is explicit that one held across an await is not evidence
  /// after it, and the gap between this call and the permission grant is
  /// exactly such an await.
  ///
  /// Returning `true` therefore no longer means Barnard accepted anything. It
  /// means the selection was recorded and a join will be *attempted*, under
  /// the gate, when sensing starts.
  @discardableResult
  func joinEvent(
    _ code: String,
    canonicalEventIdHex: String? = nil,
    lookupErrorCode: String? = nil
  ) -> Bool {
    guard !code.isEmpty else { return false }
    joinedEventCode = code
    joinedCanonicalEventIdHex = canonicalEventIdHex
    // Kept so a later refusal can say *why* there is no canonical id. The
    // registry's own error code is the only thing that separates "you are
    // offline" from "no event is registered for that code", and selecting a
    // code is where that answer arrived — the gate refuses much later, with
    // no access to it (beid#472).
    joinedLookupErrorCode = lookupErrorCode
    // Selecting deliberately does not open the relay gate, and does not join:
    // it records the choice and nothing else. The id above came from a
    // code-to-id lookup, whereas both joining and relaying require the
    // definition read and agreed with first — which is what
    // `beginRegistryVerifiedJoin` does, and what issues the context the gate
    // is opened from. See `relayGateEventIdHex`.
    return true
  }

  /// Calls the Barnard SDK's leave API (`BarnardEngine.leaveEvent`) to clear
  /// whichever manual or nearby join code is current.
  func leaveEvent() {
    invalidateEventIdentityVerification()
    // Leaving invalidates an in-flight join the same way stopping does: a
    // permission grant or registry read still outstanding must not join an
    // event the user has just left (beid#410).
    joinAttemptGeneration &+= 1
    joinRegistryRequest?.cancel()
    joinRegistryRequest = nil
    joinRefusal = nil
    engine.leaveJoinedEvent()
    stopParticipantRelay()
    joinedEventCode = engine.currentJoinedEventCode()
    joinedCanonicalEventIdHex = nil
    // Mirrors Android's `EventJoinCoordinator.leaveEvent()`: candidates
    // observed before a join are stale once that join is given up, and
    // clearing them must not depend on a separate discovery-stop call.
    clearNearbyEventDiscovery()
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
    // No `?? "beid-demo-event"` any more (beid#410, gh#101). That fallback let
    // a host that had never joined anything start its radio on a hardcoded
    // event code — an ungated path with a built-in destination. The real path
    // below now starts nothing at all when no event has been selected, which
    // is the correct answer to "sense what?" with no answer.
    let selectedEventCode = eventCode ?? joinedEventCode
    let canonicalEventIdHex = eventIdHex ?? joinedCanonicalEventIdHex
    resetSessionState()
    // Starting a session ends whatever event the previous one was joined to, so
    // the gate closes here (beid#437). Explicitly here rather than inside
    // `resetSessionState`, because that function is also how the *phase*
    // advances inside a session — see `closeRelayGate`.
    closeRelayGate()
    pendingCanonicalEventIdHex = canonicalEventIdHex
    pendingEventCode = selectedEventCode
    // Captured after the reset, which bumped it. Everything downstream of the
    // permission request is checked against this value, so an attempt the user
    // has since abandoned cannot join.
    let joinGeneration = joinAttemptGeneration
    reportSubmissionRuntime?.submitPending()
    phase = Self.payloadlessNativePhase(BeidSharedKit.sensing.scanPhaseAfterStartSensing())
    if useDemoEventMode {
      // Untouched by the gate. Demo mode never reaches Barnard at all and is
      // available only for Debug walkthroughs; Release builds hardwire it off,
      // so it is not a shipping App Review path. It also never read
      // `selectedEventCode`, before or now.
      var selectedScenario = demoScenario ?? BeidConfig.demoScenario()
      if let demoEvent {
        selectedScenario = selectedScenario.replacingEvent(demoEvent)
      }
      runDemoScenario(selectedScenario, stepDelayNanos: demoStepDelayNanos)
    } else {
      engine.requestJoinPermissions { [weak self] canScan, canAdvertise in
        guard let self else { return }
        Task { @MainActor in
          // The grant can land after the user stopped, left, or started a
          // different session. Without this the sequence start, stop, grant
          // joins with `phase` already `.idle`.
          guard self.isCurrentJoinAttempt(joinGeneration) else { return }
          guard canScan, canAdvertise else {
            self.stopParticipantRelay()
            // Undo the optimistic `.sensing` set above. Without this the
            // screen keeps saying it is sensing over a radio that never
            // started — a reading a user cannot tell apart from sensing that
            // has simply found nobody yet. `joinNearbyEvent` already did
            // this; the two entry points had drifted apart (beid#470).
            self.phase = Self.payloadlessNativePhase(
              BeidSharedKit.sensing.scanPhaseAfterStopSensing()
            )
            return
          }
          guard let selectedEventCode else {
            Self.log.error("Sensing was asked to start with no event selected; starting nothing.")
            self.stopParticipantRelay()
            // Same reason as the refusal above: nothing was started, so the
            // screen must not keep claiming otherwise.
            self.phase = Self.payloadlessNativePhase(
              BeidSharedKit.sensing.scanPhaseAfterStopSensing()
            )
            return
          }
          self.beginRegistryVerifiedJoin(
            joinCode: selectedEventCode,
            canonicalEventIdHex: canonicalEventIdHex,
            generation: joinGeneration
          )
        }
      }
    }
  }

  /// Verifies the selected event against the registry and, only if the shared
  /// issuer grants a capability, joins it and starts sensing (beid#410).
  ///
  /// This is where the verification moved *in front of* the join. It runs
  /// after the permission grant rather than at code entry because the
  /// capability must be issued close to its use: `RegistryVerifiedJoinContext`
  /// establishes that an event was verified a moment ago, not that it still is
  /// at some later moment, and the permission wait is exactly the kind of gap
  /// that invalidates a stale one. Android's `beginVerifiedJoin` carries a
  /// request identity through its own permission wait for the same reason.
  ///
  /// iOS now wires both evidence shapes into one capability-only boundary.
  /// Typed `EventCodeEntryView` input takes shape (b): operator lookup followed
  /// by this live definition read and `fromOperatorLookup`. A nearby-card tap
  /// takes shape (a): `joinNearbyEvent` re-reads the current, locally promoted
  /// candidate snapshot after permission and calls `fromNearbyCandidate`.
  /// Neither path can reach Barnard through this coordinator unless its shared
  /// issuer returns a `RegistryVerifiedJoinContext`; both converge on
  /// `applyJoinGateDecision(.admit)` and `EventJoinControlling.joinAndStart`.
  ///
  /// Every refusal below starts nothing. There is deliberately no fallback
  /// branch that joins anyway on a failed or unavailable read: that is the
  /// exact shape of the defect this replaces.
  private func beginRegistryVerifiedJoin(
    joinCode: String,
    canonicalEventIdHex: String?,
    generation: Int
  ) {
    switch joinGatePreflight(canonicalEventIdHex: canonicalEventIdHex) {
    case .refuse(let refusal, let message):
      applyJoinGateDecision(.refuse(refusal, message))
    case .read(let registry, let eventIdHex):
      joinRegistryRequest = registry.resolveEventDefinition(
        eventIdHex: eventIdHex,
        nowEpochSeconds: nearbyDiscoveryClock() / 1000
      ) { [weak self] resolution, failureErrorCode in
        // Hopped to the main actor the same way `EventIdentityVerificationSource`
        // does for the identical read, rather than annotating the completion.
        Task { @MainActor in
          guard let self else { return }
          // The read can answer after the user stopped or left. Checked here as
          // well as at the permission grant, because the two waits are separate
          // and either can outlive the attempt that started it.
          guard self.isCurrentJoinAttempt(generation) else { return }
          self.joinRegistryRequest = nil
          self.applyJoinGateDecision(
            self.joinGateDecision(
              joinCode: joinCode,
              resolution: resolution,
              readFailureErrorCode: failureErrorCode,
              nowEpochSeconds: self.nearbyDiscoveryClock() / 1000
            )
          )
        }
      }
    }
  }

  /// What the gate decided, as a value rather than as an effect already
  /// performed (beid#410).
  ///
  /// Every branch below *returns* one of these instead of each remembering to
  /// call `refuseJoin` before returning. That is a structural property, not a
  /// tidier spelling: a `guard ... else` whose body must produce a
  /// `JoinGateDecision` cannot have its refusal deleted and still compile, so
  /// the mutation "drop one refusal and see whether anything notices" stops
  /// being writable. Before this, four separate branches each had to remember,
  /// and a checker's mutation proved one of them was unguarded by any test.
  ///
  /// This is the same by-type argument the join itself already rests on —
  /// `EventJoinControlling` offers no way to join without a capability — moved
  /// one level in, to the decision about whether to grant one.
  /// Not `private`, for the same test-seam reason as `startParticipantRelay()`
  /// and `handleRelayDecision`: `EventDefinitionResolution` carries an
  /// `internal` Kotlin constructor, so no Swift test can build the successful
  /// resolution that `joinGateDecision` needs to return `.admit`. Reaching the
  /// admit branch at all therefore requires handing the decision in.
  enum JoinGateDecision {
    case admit(ExportedKotlinPackages.org.levarac.parallax.discovery.RegistryVerifiedJoinContext)
    /// The third value is `shared/`'s reason key when the decision site knew
    /// more than the refusal case alone can carry, and nil when it did not.
    ///
    /// `definitionNotEligible` is the case that needs it: the gate already
    /// asked `operatorLookupJoinEligibility` *why*, and that verdict
    /// separates "that event isn't open to join right now" from "beid
    /// couldn't verify that event" — a distinction a participant can act on.
    /// Carrying the verdict itself is not an option, because Swift Export
    /// gives it no equality and `EventJoinRefusal` is `Equatable`.
    case refuse(EventJoinRefusal, String, String? = nil)
  }

  /// What the gate can settle before spending a registry read.
  private enum JoinGatePreflight {
    case read(any EventJoinRegistry, String)
    case refuse(EventJoinRefusal, String)
  }

  private func joinGatePreflight(canonicalEventIdHex: String?) -> JoinGatePreflight {
    guard let registry = eventJoinRegistry else {
      return .refuse(.noRegistryConfigured, "No registry configured; refusing to join unverified.")
    }
    guard let eventIdHex = canonicalEventIdHex else {
      // A code with no canonical id never had a registry answer, so there is
      // nothing to issue a capability from.
      return .refuse(.noCanonicalEventId, "Selected event has no canonical id; refusing to join.")
    }
    return .read(registry, eventIdHex)
  }

  /// The post-read half of the same decision. Pure: it reads the clock value
  /// it is handed and touches no coordinator state, so what it decides is a
  /// function of the registry's answer alone.
  private func joinGateDecision(
    joinCode: String,
    resolution: ExportedKotlinPackages.org.levarac.parallax.registry.EventDefinitionResolution?,
    readFailureErrorCode: String? = nil,
    nowEpochSeconds: Int64
  ) -> JoinGateDecision {
    guard let resolution else {
      // The read's own error code, classified by the same `shared/` function
      // the code-to-id lookup uses. Without it this branch could only say
      // `UNKNOWN`, which tells a participant nothing they can act on
      // (beid#472).
      let reason = readFailureErrorCode == nil
        ? ExportedKotlinPackages.org.levarac.beid.shared.event
          .EventJoinFailureReason.UNKNOWN
        : BeidSharedKit.event.eventJoinFailureReasonForRegistryErrorCode(
          errorCode: readFailureErrorCode
        )
      return .refuse(
        .registryReadFailed,
        "Registry read produced no definition (\(readFailureErrorCode ?? "no error code")); starting nothing.",
        BeidSharedKit.event.eventJoinFailureReasonKey(reason: reason)
      )
    }
    // Issued from the live resolution, and re-checked against the clock now
    // rather than when the read was requested.
    //
    // `Companion.shared`, not `companion`: Swift Export emits a Kotlin
    // companion object as a nested `Companion` class reached through a
    // static `shared` accessor. Read out of beid's own generated
    // `BeidSharedKit.swift` rather than assumed.
    guard let context = ExportedKotlinPackages.org.levarac.parallax.discovery
      .RegistryVerifiedJoinContext.Companion.shared.fromOperatorLookup(
        joinCode: joinCode,
        resolution: resolution,
        nowEpochSeconds: nowEpochSeconds
      )
    else {
      // Ask the shared decision *why*, so the refusal is diagnosable rather
      // than merely a refusal. The verdict is logged rather than mapped to a
      // case: its generated Swift surface has no name, description or
      // equality — see `EventJoinRefusal`.
      let verdict = ExportedKotlinPackages.org.levarac.parallax.discovery
        .operatorLookupJoinEligibility(
          joinCode: joinCode,
          resolution: resolution,
          nowEpochSeconds: nowEpochSeconds
        )
      return .refuse(
        .definitionNotEligible,
        "Registry did not verify the selected event (\(String(describing: verdict))); starting nothing.",
        BeidSharedKit.event.eventJoinFailureReasonKey(
          reason: BeidSharedKit.event.eventJoinFailureReasonForJoinEligibility(
            eligibility: verdict
          )
        )
      )
    }
    return .admit(context)
  }

  /// Performs the decision. The **only** place a refused join is recorded, so
  /// deleting that one call turns every refusal test red rather than one.
  ///
  /// Not `private`, for the reason given on `JoinGateDecision`.
  func applyJoinGateDecision(_ decision: JoinGateDecision) {
    switch decision {
    case .admit(let context):
      joinRefusal = nil
      emitJoinStageDiagnostic(
        joinDiagnosticLog,
        eventIdHex: context.eventIdHex,
        stage: "admission",
        outcome: "admitted"
      )
      // `startAuto()` keeps an already-running Central scan alive and adds
      // advertising. From this instant it is automatic-operation transport,
      // not a discovery-only scan this pre-join flow may later stop.
      discoveryOnlyScanOwned = false
      engine.joinAndStart(context)
      // The relay gate opens here, from the capability the gate just admitted,
      // in the same shape as Android's `EventJoinCoordinator.beginVerifiedJoin`
      // (beid#437). The id is the definition's own `eventIdHex`, not the
      // code-to-id `hint`. It is stored rather than handed straight to
      // `republishRelayGateState` because every later republish — a candidate
      // snapshot arriving, a definition being cached — reads this property and
      // would otherwise close the gate that was just opened.
      relayGateEventIdHex = context.eventIdHex
      startParticipantRelay()
    case .refuse(let refusal, let message, let reasonKey):
      refuseJoin(refusal, message, reasonKey: reasonKey)
    }
  }

  /// Whether the join attempt identified by `generation` is still the one this
  /// coordinator is running, and the session is still waiting to start.
  ///
  /// Both conditions matter. The generation catches a stop or a leave; the
  /// phase check catches a session that has already moved on, which a
  /// generation bump alone would not express.
  private func isCurrentJoinAttempt(_ generation: Int) -> Bool {
    guard generation == joinAttemptGeneration else { return false }
    guard case .sensing = phase else { return false }
    return true
  }

  /// Records a refused join, returns the session to idle, and says why.
  ///
  /// Returning to `.idle` is the point: `phase` was set to `.sensing` before
  /// the permission request and, before this, was never moved back — so every
  /// refusal left the user on a sensing screen with the radio off, forever.
  /// Maps a native refusal onto the reason vocabulary `shared/` already owns
  /// and Android already renders, so one situation does not get two
  /// explanations across the two apps.
  ///
  /// Only `definitionNotEligible` has a verdict of its own; the rest are
  /// classified from what was available when the read was attempted.
  ///
  /// `registryReadFailed` is `UNKNOWN` rather than `NETWORK_REQUIRED`, which
  /// is the tempting answer: the definition read only runs once the
  /// code-to-id lookup already succeeded, so a device that cannot reach the
  /// network fails earlier and arrives here as `noCanonicalEventId` carrying
  /// the lookup's own error code. Reaching this branch means an answer came
  /// back carrying no definition. Carrying the *definition* read's error code
  /// through as well would let it say more; the adapter currently collapses a
  /// failed read to nil, and changing that is its own change.
  private static func sharedReason(
    for refusal: EventJoinRefusal,
    lookupErrorCode: String?
  ) -> ExportedKotlinPackages.org.levarac.beid.shared.event.EventJoinFailureReason {
    switch refusal {
    case .noRegistryConfigured:
      // Broken for everyone on this build, and not fixed by finding Wi-Fi.
      return ExportedKotlinPackages.org.levarac.beid.shared.event
        .EventJoinFailureReason.VERIFICATION_FAILED
    case .noCanonicalEventId:
      guard let lookupErrorCode else {
        return ExportedKotlinPackages.org.levarac.beid.shared.event
          .EventJoinFailureReason.VERIFICATION_FAILED
      }
      return BeidSharedKit.event.eventJoinFailureReasonForRegistryErrorCode(
        errorCode: lookupErrorCode
      )
    case .registryReadFailed:
      return ExportedKotlinPackages.org.levarac.beid.shared.event
        .EventJoinFailureReason.UNKNOWN
    case .definitionNotEligible:
      // Reached only if a caller refused for ineligibility without passing
      // the verdict's own key, which the gate always does.
      return ExportedKotlinPackages.org.levarac.beid.shared.event
        .EventJoinFailureReason.VERIFICATION_FAILED
    }
  }

  private func refuseJoin(
    _ refusal: EventJoinRefusal,
    _ message: String,
    reasonKey: String? = nil
  ) {
    Self.log.error("\(message, privacy: .public)")
    let outcome: String
    switch refusal {
    case .noRegistryConfigured:
      outcome = "no_registry_configured"
    case .noCanonicalEventId:
      outcome = "no_canonical_event_id"
    case .registryReadFailed:
      outcome = "registry_read_failed"
    case .definitionNotEligible:
      outcome = "definition_not_eligible"
    }
    emitJoinStageDiagnostic(
      joinDiagnosticLog,
      eventIdHex: pendingCanonicalEventIdHex ?? joinedCanonicalEventIdHex,
      stage: "admission",
      outcome: "rejected_\(outcome)"
    )
    joinRefusal = refusal
    joinRefusalReasonKey = reasonKey ?? BeidSharedKit.event.eventJoinFailureReasonKey(
      reason: Self.sharedReason(for: refusal, lookupErrorCode: joinedLookupErrorCode)
    )
    joinRegistryRequest = nil
    stopParticipantRelay()
    phase = Self.payloadlessNativePhase(BeidSharedKit.sensing.scanPhaseAfterStopSensing())
  }

  @discardableResult
  func stopSensing() -> SelfProofRecord? {
    let selfProof = endSensing(stopEngine: true)
#if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-beid-continuous-sensing-fixture") {
      isScanning = false
      isAdvertising = false
    }
#endif
    return selfProof
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

  /// Called by RecordingView after its first render in this session.
  func markRecordingSurfaceReady() {
    recordingSurfaceReady = true
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
    // Both stop and reset end relay. Relay is a property of an active sensing
    // session, not of the engine's transport, so a reset that leaves scanning
    // running must still stop re-broadcasting.
    stopParticipantRelay()
    clearNearbyEventDiscovery()
    if stopEngine {
      engine.stopAutomaticOperation()
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
    firstSightingAt = nil
    detectedDisplayIDs = []
    #if DEBUG
    sensingScreenshotNow = nil
    sensingScreenshotFixture = nil
    sensingScreenshotEvent = nil
    #endif
    demoDeviceSequence = 0
    rpidsAwaitingDisplayId = []
    devicesVerified = 0
    unidentifiedRpidCount = 0
    // beid#652: display-only, but still per-session. A radius measured at
    // last night's event must not be on screen at this morning's, and a
    // stale `lastNodeSignalPublishAt` must not suppress the first redraw of
    // the new session. All three fields are the same state and are cleared
    // together; keeping the published projection and its source in step is
    // what makes `nodeSignalStrengths` a total projection of
    // `smoothedNodeSignalDbm` rather than a cache that can drift.
    nodeSignalStrengths = [:]
    smoothedNodeSignalDbm = [:]
    lastNodeSignalPublishAt = nil
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
    // Cleared with its sibling. `startSensing` resets first and assigns both
    // afterwards, so a new session never inherits the previous one's name.
    pendingEventCode = nil
    // Invalidates any join attempt still waiting on a permission grant or a
    // registry read, and cancels the read rather than letting it answer into a
    // session that no longer exists (beid#410).
    joinAttemptGeneration &+= 1
    joinRegistryRequest?.cancel()
    joinRegistryRequest = nil
    joinRefusal = nil
    joinRefusalReasonKey = nil
    activeCommit = nil
    activeProofId = nil
    pendingBindingMessage = nil
    bindingState = .none
    recordingSurfaceReady = false
  }

  // MARK: - Nearby event discovery (B005 pre-join hints, gh#100 Stage 1)

  /// Starts Central-only B005 discovery while no event has been selected.
  ///
  /// `AppCoordinator.startScan()` called `startSensing()` with no selected
  /// event until beid#141. Once beid#410 correctly removed the hardcoded
  /// fallback and made that request start nothing, the Collection button had
  /// become a no-op on a real device. Scan-only Barnard operation restores
  /// the button's intended meaning without reopening either string join door.
  /// Simulator Debug keeps its established scripted DemoEvent path because it
  /// has no BLE radio; that path never reaches Barnard.
  func startNearbyEventDiscovery() {
    guard case .idle = phase else { return }
    if useDemoEventMode {
      startSensing()
      return
    }
    guard !discoveryOnlyScanOwned, !isScanning, !isAdvertising else { return }
    discoveryOnlyScanOwned = true
    engine.startDiscoveryScan()
  }

#if DEBUG
  /// Seeds the real pre-join surface with a representative gate refusal for
  /// UI-test runtime verification. This is deliberately an app-side fixture:
  /// it does not call Barnard, the registry, or any production join path.
  func injectJoinRefusalForUITesting() {
    guard ProcessInfo.processInfo.arguments.contains("-beid-join-refusal-fixture") else {
      return
    }
    joinRefusal = .registryReadFailed
    // Classified through the real `shared/` function rather than by writing a
    // key here, so the fixture cannot drift from what production would say
    // about the same failure. A transport code is used because that is the
    // case a participant actually hits, and the one whose wrong answer
    // ("check the code") sent the owner looking at a correct code for an hour
    // (beid#472).
    joinRefusalReasonKey = BeidSharedKit.event.eventJoinFailureReasonKey(
      reason: BeidSharedKit.event.eventJoinFailureReasonForRegistryErrorCode(
        errorCode: "timeout"
      )
    )
    phase = .idle
  }

  /// Seeds the transport state used by the home-surface runtime acceptance.
  /// Production state still comes only from Barnard `.state` callbacks.
  func injectContinuousSensingForUITesting() {
    guard ProcessInfo.processInfo.arguments.contains("-beid-continuous-sensing-fixture") else {
      return
    }
    isScanning = true
    isAdvertising = true
  }
#endif

  /// Ends the pre-join discovery session and stops the Central scan only when
  /// this flow started it. Once a join transfers scanning to `startAuto()`,
  /// `discoveryOnlyScanOwned` is false and dismissing this surface cannot stop
  /// the joined session's automatic operation.
  func stopNearbyEventDiscovery() {
    let shouldStopOwnedScan = discoveryOnlyScanOwned && !isAdvertising
    discoveryOnlyScanOwned = false
    clearNearbyEventDiscovery()
    if shouldStopOwnedScan {
      engine.stopDiscoveryScan()
    }
  }

  /// Applies the shared time-based refresh immediately. Production's scheduled
  /// wake-up and race tests use the same entry so expired sources and due
  /// registry retries are reflected in the current join authority together.
  func refreshNearbyEventDiscovery() {
    let refreshedAt = nearbyDiscoveryClock()
    let update = ExportedKotlinPackages.org.levarac.parallax.discovery
      .refreshNearbyEventDiscovery(
        store: nearbyDiscoveryStore,
        nowEpochMillis: refreshedAt
      )
    publishNearbyEventDiscovery(update.snapshot, asOf: refreshedAt)
    resolveNearbyCandidates(update.snapshot)
  }

  /// One-tap nearby join (beid#141). The action carries only the stable B005
  /// hash. After the permission wait resumes, this method re-reads the
  /// coordinator's current snapshot and asks the shared issuer for a fresh
  /// capability; a displayed Event ID, list position, selected state, or
  /// display-only validity window is never join authority.
  func joinNearbyEvent(eventCodeHashHex: String) {
    guard case .idle = phase else { return }
    resetSessionState()
    let generation = joinAttemptGeneration
    reportSubmissionRuntime?.submitPending()
    phase = Self.payloadlessNativePhase(BeidSharedKit.sensing.scanPhaseAfterStartSensing())
    engine.requestJoinPermissions { [weak self] canScan, canAdvertise in
      guard let self else { return }
      Task { @MainActor in
        guard self.isCurrentJoinAttempt(generation) else { return }
        guard canScan, canAdvertise else {
          self.stopParticipantRelay()
          self.phase = Self.payloadlessNativePhase(
            BeidSharedKit.sensing.scanPhaseAfterStopSensing()
          )
          return
        }
        // Consume this permission completion before issuing. If an engine
        // incorrectly answers the same callback twice, only the first answer
        // can reach Barnard.
        self.joinAttemptGeneration &+= 1
        let nowEpochSeconds = self.nearbyDiscoveryClock() / 1_000
        guard let context = ExportedKotlinPackages.org.levarac.parallax.discovery
          .RegistryVerifiedJoinContext.Companion.shared.fromNearbyCandidate(
            candidates: self.nearbyEventCandidates,
            eventCodeHashHex: eventCodeHashHex,
            nowEpochSeconds: nowEpochSeconds
          )
        else {
          let verdict = ExportedKotlinPackages.org.levarac.parallax.discovery
            .nearbyCandidateJoinEligibility(
              candidates: self.nearbyEventCandidates,
              eventCodeHashHex: eventCodeHashHex,
              nowEpochSeconds: nowEpochSeconds
            )
          self.refuseJoin(
            .definitionNotEligible,
            "Current nearby candidate is not eligible (\(String(describing: verdict))); starting nothing."
          )
          return
        }
        // On the nearby evidence shape the canonical Event ID is Barnard's
        // join code. Keep native session naming and later verification routed
        // to that same identity; the capability, not this assignment, is what
        // authorizes the engine call below.
        self.joinedEventCode = context.joinCode
        self.joinedCanonicalEventIdHex = context.eventIdHex
        self.pendingEventCode = context.joinCode
        self.pendingCanonicalEventIdHex = context.eventIdHex
        self.applyJoinGateDecision(.admit(context))
      }
    }
  }

  /// Not `private`: `BarnardEventInfoHintEvent` has no public initializer
  /// (Barnard module boundary), so `BeidTests` cannot construct one to drive
  /// this path — taking the fields it actually needs as plain arguments
  /// instead lets tests exercise the real hint path directly. Mirrors the
  /// same seam `handleDetection(enin:rpid:detectedDisplayId:reporterRpid:)`
  /// already uses, and the JVM seam Android's `EventJoinCoordinator` uses.
  /// Production code only ever reaches this via `handle(_:)`, already
  /// MainActor-isolated by `engine.onEvent`'s `Task { @MainActor in }`.
  ///
  /// This converts native fields once, calls the shared reducer once, and
  /// publishes what it returns. It deliberately does none of the following:
  /// call `joinEvent`, read or write `phase`/`bindingState`/`activeCommit`/
  /// `activeProofId`/window/report/self-proof state, or start a scan. A hint
  /// is only ever an observation that a nearby event *might* exist.
  ///
  /// `observedAtEpochMillis` defaults to `nearbyDiscoveryClock()`; tests pass
  /// it explicitly so expiry is deterministic rather than wall-clock bound.
  func handleEventInfoHint(
    peripheralId: String,
    eventDisplayName: String,
    eventCodeHash: Data,
    census: Data?,
    additionalNamesOmitted: Bool,
    additionalEventsOmitted: Bool,
    observedAtEpochMillis: Int64? = nil
  ) {
    emitJoinStageDiagnostic(
      joinDiagnosticLog,
      eventIdHex: nil,
      stage: "detection",
      outcome: "detected"
    )
    // One time value drives both the record and the expiry schedule below.
    // Reading the clock a second time for scheduling would let a caller-
    // supplied `observedAtEpochMillis` disagree with "now", which collapses
    // every delay to zero and immediately expires what was just recorded.
    let observedAt = observedAtEpochMillis ?? nearbyDiscoveryClock()
    let update = ExportedKotlinPackages.org.levarac.parallax.discovery.recordNearbyEventHintFromHex(
      store: nearbyDiscoveryStore,
      peripheralId: peripheralId,
      eventDisplayName: eventDisplayName,
      eventCodeHashHex: eventCodeHash.lowercaseHexString,
      censusHex: census?.lowercaseHexString,
      additionalNamesOmitted: additionalNamesOmitted,
      additionalEventsOmitted: additionalEventsOmitted,
      observedAtEpochMillis: observedAt
    )
    publishNearbyEventDiscovery(update.snapshot, asOf: observedAt)
    resolveNearbyCandidates(update.snapshot)
  }

  /// Handles one B005 v2 envelope receipt: the whole of what `handle(_:)`'s
  /// `.eventInfoEnvelopeV2` case used to do inline.
  ///
  /// Not `private`, and taking `ObservedEventInfoEnvelopeV2` rather than
  /// barnard's `BarnardEventInfoEnvelopeV2Event`, because that event type has
  /// no public initializer: with the case written inline, no test could enter
  /// it, and the contract test had to start at
  /// `handleEventInfoEnvelopeV2(peripheralId:...)` with its own copy of the
  /// agreement closure below — so a regression in that closure stayed green
  /// (beid#571). Everything the case decided now lives here, where a test
  /// drives it with barnard's own verified envelope; what remains above is a
  /// single forwarding line the compiler checks against the conformance.
  /// Production still only ever reaches this from `handle(_:)`, already
  /// MainActor-isolated by `engine.onEvent`'s `Task { @MainActor in }`.
  func handleObservedEventInfoEnvelopeV2(_ event: some ObservedEventInfoEnvelopeV2) {
    guard let envelope = event.verifiedEnvelope else {
      // An unverified receipt carries no parsed identity: barnard's
      // `verify` returns nothing for both a malformed container and a bad
      // signature, so there is no event-code hash to key a candidate on.
      // Counting it keeps the drop observable rather than silent.
      handleUnverifiedEventInfoEnvelopeV2()
      return
    }
    handleEventInfoEnvelopeV2(
      peripheralId: event.peripheralId.uuidString,
      eventDisplayName: envelope.eventDisplayName,
      eventCodeHash: Data(envelope.eventCodeHash),
      rawContainer: event.rawContainer,
      verifiedEventIdHex: "0x" + Data(envelope.eventId).lowercaseHexString,
      registryAgreement: { definition in
        BarnardB005EnvelopeV2.registryAgreement(envelope, definition: definition) == .agrees
      }
    )
  }

  /// Records a B005 v2 envelope barnard reported as `RADIO_SELF_VERIFIED`.
  ///
  /// Not `private`, and taking plain fields plus an agreement closure rather
  /// than barnard's event type, for the reason
  /// `handleEventInfoHint(peripheralId:...)` records. Production reaches it
  /// only from `handleObservedEventInfoEnvelopeV2(_:)` just above, which is
  /// where the mapping from the event's fields and the agreement closure now
  /// live; tests that only need a hash and a container still call this
  /// directly. Both entries are MainActor-isolated by `engine.onEvent`'s
  /// `Task { @MainActor in }`.
  ///
  /// This records an observation and raises the hash's receiver tier. It never
  /// joins, never touches session state, and never assigns REGISTRY_VERIFIED
  /// itself -- the shared reducer owns that, and only once this host's own
  /// registry read agrees.
  func handleEventInfoEnvelopeV2(
    peripheralId: String,
    eventDisplayName: String,
    eventCodeHash: Data,
    rawContainer: Data,
    verifiedEventIdHex: String? = nil,
    registryAgreement: @escaping (BarnardEventDefinitionV1) -> Bool,
    observedAtEpochMillis: Int64? = nil
  ) {
    let observedAt = observedAtEpochMillis ?? nearbyDiscoveryClock()
    let hash = eventCodeHash.lowercaseHexString
    // Asked before recording, because the reducer needs this envelope's own
    // verdict to decide whether it may replace the container retained for a
    // hash that is already REGISTRY_VERIFIED.
    let agrees = nearbyVerifiedDefinitions[hash].map(registryAgreement) ?? false
    let update = ExportedKotlinPackages.org.levarac.parallax.discovery
      .recordNearbyEventRadioSelfVerifiedEnvelopeFromHex(
        store: nearbyDiscoveryStore,
        peripheralId: peripheralId,
        eventDisplayName: eventDisplayName,
        eventCodeHashHex: hash,
        rawContainerHex: rawContainer.lowercaseHexString,
        agreesWithRegistry: agrees,
        additionalNamesOmitted: false,
        additionalEventsOmitted: false,
        observedAtEpochMillis: observedAt
      )
    guard update.acceptedHint else { return }
    emitJoinStageDiagnostic(
      joinDiagnosticLog,
      eventIdHex: verifiedEventIdHex,
      stage: "envelope_verification",
      outcome: "success"
    )
    if let verifiedEventIdHex {
      nearbyVerifiedEventIds[hash] = verifiedEventIdHex
    }
    nearbyEnvelopeAgreements[hash] = registryAgreement
    // No second call for the late-arrival order: the record above already
    // acted on `agrees`, under the same guard the standalone agreement entry
    // uses.
    publishNearbyEventDiscovery(update.snapshot, asOf: observedAt)
    resolveNearbyCandidates(update.snapshot)
  }

  /// Records that barnard could not verify a container this session saw.
  ///
  /// There is nothing else to record -- an unverified receipt has no parsed
  /// identity at all -- so this tally is the only trace the drop leaves.
  /// Not `private`, for the same test-seam reason as the two handlers above.
  func handleUnverifiedEventInfoEnvelopeV2() {
    emitJoinStageDiagnostic(
      joinDiagnosticLog,
      eventIdHex: nil,
      stage: "envelope_verification",
      outcome: "rejected_unverified"
    )
    // Publishes the snapshot so the tally is observable, and stops there.
    // Deliberately not `publishNearbyEventDiscovery`: no candidate, source or
    // expiry time moved, so rebuilding from it and re-arming the expiry
    // wake-up would let a peer transmitting garbage drive both on every
    // received packet.
    nearbyEventCandidates = ExportedKotlinPackages.org.levarac.parallax.discovery
      .recordNearbyEventUnverifiedEnvelope(store: nearbyDiscoveryStore)
      .snapshot
  }

  /// Publishes one snapshot and rearms the single wake-up for the earliest of
  /// source TTL, a registry retry, or the first millisecond after a retained
  /// definition's inclusive validity window. This mirrors Android's native
  /// scheduling effect: shared remains the authority on joinability, while
  /// native wakes SwiftUI when that time-dependent answer can change.
  private func publishNearbyEventDiscovery(
    _ snapshot: ExportedKotlinPackages.org.levarac.parallax.discovery.NearbyEventCandidates,
    asOf now: Int64
  ) {
    nearbyEventCandidates = snapshot
    // Mirrors the Android session's prune: a hash whose sources have expired
    // keeps neither its cached agreement nor its cached definition, so neither
    // map grows without bound across a long discovery session.
    var liveHashes = Set<String>()
    for index in 0..<snapshot.candidateCount {
      if let candidate = snapshot.candidateAt(index: index) {
        liveHashes.insert(candidate.eventCodeHashHex)
      }
    }
    nearbyEnvelopeAgreements = nearbyEnvelopeAgreements.filter { liveHashes.contains($0.key) }
    nearbyVerifiedDefinitions = nearbyVerifiedDefinitions.filter { liveHashes.contains($0.key) }
    nearbyVerifiedEventIds = nearbyVerifiedEventIds.filter { liveHashes.contains($0.key) }
    republishRelayGateState()
    nearbyDiscoveryExpiryTask?.cancel()
    nearbyDiscoveryExpiryTask = nil

    var nextWakeAtEpochMillis = snapshot.nextExpiryAtEpochMillis
    let nowEpochSeconds = now / 1_000
    for index in 0..<snapshot.candidateCount {
      guard
        let validUntilEpochSeconds = snapshot.candidateAt(index: index)?
          .definitionValidUntilEpochSeconds,
        validUntilEpochSeconds >= nowEpochSeconds
      else { continue }
      let definitionExpiryAt = Self.firstEpochMillisAfter(validUntilEpochSeconds)
      nextWakeAtEpochMillis = min(nextWakeAtEpochMillis ?? definitionExpiryAt, definitionExpiryAt)
    }
    if let registryRetryAt = snapshot.nextRegistryRetryAtEpochMillis {
      nextWakeAtEpochMillis = min(nextWakeAtEpochMillis ?? registryRetryAt, registryRetryAt)
    }
    guard let nextWakeAtEpochMillis else { return }
    let delayMillis = nextWakeAtEpochMillis <= now ? 0 : nextWakeAtEpochMillis - now
    // `expiryAt` saturates at `Long.MAX_VALUE` in shared, so the nanosecond
    // conversion is done saturating rather than trapping.
    let delayNanos = UInt64(clamping: delayMillis).multipliedReportingOverflow(by: 1_000_000)
    nearbyDiscoveryExpiryTask = Task { @MainActor [weak self] in
      try? await Task.sleep(
        nanoseconds: delayNanos.overflow ? UInt64.max : delayNanos.partialValue
      )
      guard !Task.isCancelled, let self else { return }
      self.nearbyDiscoveryExpiryTask = nil
      self.refreshNearbyEventDiscovery()
    }
  }

  /// Android's `NearbyEventDiscoverySession.firstEpochMillisAfter`, including
  /// its saturation rule. Definition validity is inclusive at whole-second
  /// precision, so the UI answer can first change at this millisecond.
  private static func firstEpochMillisAfter(_ epochSecond: Int64) -> Int64 {
    let latestConvertibleSecond = Int64.max / 1_000
    guard epochSecond < latestConvertibleSecond else { return Int64.max }
    return (epochSecond + 1) * 1_000
  }

  /// Rebuilds the immutable value the relay verifier reads. Main actor only.
  ///
  /// The joined id is an explicit argument rather than a read of
  /// `joinedCanonicalEventIdHex`, so a caller that is closing the gate says
  /// so. A teardown that inherited the property would only fail closed while
  /// the property happened to have been cleared first, which makes the safety
  /// of the whole thing a question about statement order at each call site.
  private func republishRelayGateState(joinedEventIdHex: String?) {
    relayVerifier.update(
      ParticipantRelayGateState(
        candidates: nearbyEventCandidates,
        verifiedDefinitionsByHash: nearbyVerifiedDefinitions,
        joinedEventIdHex: joinedEventIdHex
      )
    )
  }

  /// Republishes with whatever event is joined right now, for the callers
  /// that are following discovery state rather than changing the gate.
  private func republishRelayGateState() {
    republishRelayGateState(joinedEventIdHex: relayGateEventIdHex)
  }

  /// Records the latest spec 134 decision so relay is observable at all.
  ///
  /// Visibility only. Nothing downstream reads it, and nothing may: a relayed
  /// candidate is an ordinary card, its hop count is never shown, and relay
  /// volume is never evidence about an event. Not `private`, for the same
  /// test-seam reason as the envelope handlers above:
  /// `BarnardRelayDecisionEvent` has no public initializer.
  func handleRelayDecision(
    decision: BarnardRelayDecision,
    payloadDigestHex: String,
    hop: Int,
    reason: String
  ) {
    lastRelayDecision = ParticipantRelayDecision(
      decision: decision,
      payloadDigestHex: payloadDigestHex,
      hop: hop,
      reason: reason
    )
  }

  /// Turns relay on for this session.
  ///
  /// Called only once permissions allow both scanning and advertising: a
  /// device that cannot advertise cannot re-broadcast anything, and
  /// configuring a relay it could never serve would misreport what a peer
  /// reading B005 would actually get.
  /// Demo mode never arms the relay, and that is checked here rather than
  /// only in `startSensing`'s control flow. Demo candidates are fabricated,
  /// relay puts bytes on a real radio, and the two must not meet. Leaving the
  /// guarantee to the caller would make it a property of one branch in one
  /// function, while this method, `runDemoScenario` and `useDemoEventMode`
  /// are all reachable from outside this file. `SensingCoordinatorTests`
  /// asserts it for every scenario.
  ///
  /// Not `private`: the simulator forces demo mode, so `startSensing` never
  /// reaches the permission branch that calls this, and a test could otherwise
  /// not observe the cadence at all. Production reaches it only from there.
  func startParticipantRelay() {
    guard !useDemoEventMode else {
      Self.log.debug("relay not armed: demo mode fabricates candidates and must not reach a radio")
      return
    }
    republishRelayGateState()
    relayControl.setParticipantRelayVerifier(relayVerifier)
    relayCadenceTask?.cancel()
    relayCadenceTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: self?.relayCadenceNanoseconds ?? Self.relayDecisionBoundaryNanoseconds)
        guard !Task.isCancelled, let self else { return }
        self.relayControl.advanceParticipantRelay()
      }
    }
  }

  /// Turns relay off. Idempotent, and called from every exit: leaving the
  /// event, ending the session, and a permission refusal. Passing no verifier
  /// is what makes Barnard drop the lease, the density handles, and the
  /// cached envelope.
  /// Not `private`, for the same reason as `startParticipantRelay()`.
  func stopParticipantRelay() {
    relayCadenceTask?.cancel()
    relayCadenceTask = nil
    relayControl.setParticipantRelayVerifier(nil)
    closeRelayGate()
  }

  /// Closes the relay gate: clears the stored id *and* publishes the closure.
  ///
  /// One helper with two callers rather than two copies, because the property
  /// and the published value have to move together (beid#437). Clearing only
  /// the published one leaves the id behind for the next no-argument
  /// `republishRelayGateState` — a candidate snapshot arriving, a definition
  /// being cached, the relay re-arming — to put straight back on the air.
  ///
  /// Called from exactly two places, and both are session boundaries:
  /// `stopParticipantRelay`, and `startSensing` immediately after its reset.
  /// Neither implies the other, so both are needed — `startSensing` begins a
  /// new session without passing through `stopParticipantRelay`.
  ///
  /// **A phase transition does not close the gate.** This is deliberately
  /// *not* called from `resetSessionState`, even though that is where
  /// `startSensing` clears the rest of its state, because `resetSessionState`
  /// is also reached from `beginEventFoundSessionState` — the
  /// sensing-to-eventFound transition *inside* the joined event, at the first
  /// peer detection. Closing there shut the gate at the exact moment relay
  /// starts to matter, and nothing reopened it: the only opener is the join
  /// admit, which had already happened. beid#437 shipped that regression for
  /// one revision on the strength of the word "boundary" being applied to a
  /// transition, so the distinction is stated here rather than left implied.
  ///
  /// The clearing itself is a construction, not a reachability argument.
  /// Whether a no-argument republish can actually fire between a session
  /// boundary and the next admit is beside the point: a stale event id must
  /// not cross one. (It can, in fact — a probe on beid#437 measured the
  /// admitted id surviving both `startSensing` and a subsequent nearby-hint
  /// delivery — but the rule does not depend on that measurement.)
  private func closeRelayGate() {
    relayGateEventIdHex = nil
    republishRelayGateState(joinedEventIdHex: nil)
  }

  /// Spec 134's `T`, taken from Barnard rather than restated, so the two
  /// cannot drift. Barnard self-ticks as well, so this cadence is
  /// belt-and-braces rather than the only thing keeping a lease honest.
  static let relayDecisionBoundaryNanoseconds =
    UInt64(BarnardEngine.relayDecisionBoundaryMilliseconds) * 1_000_000

  /// Ends the current discovery session: cancels the pending expiry wake-up
  /// and clears candidates together with the global omission/eviction facts.
  /// Named to avoid being confused with the shared free function it calls.
  private func clearNearbyEventDiscovery() {
    nearbyDiscoveryCallbackGeneration &+= 1
    nearbyRegistryRequests.forEach { $0.cancel() }
    nearbyRegistryRequests.removeAll()
    nearbyEventDefinitionRequests.forEach { $0.cancel() }
    nearbyEventDefinitionRequests.removeAll()
    nearbyEnvelopeAgreements.removeAll()
    nearbyVerifiedDefinitions.removeAll()
    nearbyVerifiedEventIds.removeAll()
    nearbyDiscoveryExpiryTask?.cancel()
    nearbyDiscoveryExpiryTask = nil
    nearbyEventCandidates = ExportedKotlinPackages.org.levarac.parallax.discovery
      .resetNearbyEventDiscovery(store: nearbyDiscoveryStore)
      .snapshot
    republishRelayGateState()
  }

  private func resolveNearbyCandidates(
    _ snapshot: ExportedKotlinPackages.org.levarac.parallax.discovery.NearbyEventCandidates
  ) {
    for index in 0..<snapshot.candidateCount {
      guard let candidate = snapshot.candidateAt(index: index) else { continue }
      let hash = candidate.eventCodeHashHex
      let verifiedEventId = nearbyVerifiedEventIds[hash]
      let canResolveCandidate = verifiedEventId != nil
        ? eventJoinRegistry != nil
        : nearbyRegistryClient != nil
      guard canResolveCandidate else {
        emitJoinStageDiagnostic(
          joinDiagnosticLog,
          eventIdHex: verifiedEventId,
          stage: "registry_resolution",
          outcome: "rejected_no_registry",
          attempt: "none"
        )
        continue
      }
      guard let attempt = ExportedKotlinPackages.org.levarac.parallax.discovery
        .beginNearbyEventRegistryResolutionFromHex(store: nearbyDiscoveryStore, eventCodeHashHex: hash)
      else { continue }
      let attemptNumber = candidate.registryResolutionFailureCount + 1
      emitJoinStageDiagnostic(
        joinDiagnosticLog,
        eventIdHex: nearbyVerifiedEventIds[hash],
        stage: "registry_resolution",
        outcome: "started",
        attempt: String(describing: attemptNumber)
      )
      let generation = nearbyDiscoveryCallbackGeneration
      if let verifiedEventId {
        // B005 v2 already carried Barnard's verified canonical Event ID.
        // Route it directly to the definition read; the legacy operator hash
        // lookup remains the v1 hint path below.
        resolveNearbyEventDefinition(
          eventIdHex: verifiedEventId,
          hash: hash,
          attempt: attempt,
          attemptNumber: attemptNumber,
          generation: generation
        )
      } else {
        guard let client = nearbyRegistryClient else { continue }
        let lookup = client.resolveEventIdByCodeHash(hashHex: hash) { [weak self] resolution in
          Task { @MainActor in
            guard let self else { return }
            guard generation == self.nearbyDiscoveryCallbackGeneration else { return }
            guard ExportedKotlinPackages.org.levarac.parallax.discovery
              .isNearbyEventRegistryResolutionAttemptActive(
                store: self.nearbyDiscoveryStore,
                attempt: attempt
              )
            else { return }
            guard resolution.isSuccess, let eventID = resolution.eventIdHex else {
              let result: ExportedKotlinPackages.org.levarac.parallax.discovery
                .NearbyEventRegistryResolutionResult = resolution.errorCode == "event_code_lookup_not_found"
                ? .NOT_REGISTERED : .LOOKUP_UNAVAILABLE
              _ = ExportedKotlinPackages.org.levarac.parallax.discovery
                .completeNearbyEventRegistryResolutionFromHex(
                  store: self.nearbyDiscoveryStore, attempt: attempt,
                  result: result, resolvedEventIdHex: nil,
                  verifiedDefinitionJoinMode: nil,
                  verifiedDefinitionEventIdHex: nil,
                  verifiedDefinitionEventCodeHashHex: nil,
                  envelopeAgreesWithRegistry: false,
                  verifiedDefinitionHashHex: nil,
                  registryBlockHashHex: nil,
                  verifiedDefinitionValidFromEpochSeconds: nil,
                  verifiedDefinitionValidUntilEpochSeconds: nil
                )
              let completedAt = self.nearbyDiscoveryClock()
              let armed = ExportedKotlinPackages.org.levarac.parallax.discovery
                .refreshNearbyEventDiscovery(
                  store: self.nearbyDiscoveryStore,
                  nowEpochMillis: completedAt
                )
              self.publishNearbyEventDiscovery(armed.snapshot, asOf: completedAt)
              self.logNearbyRegistryOutcome(
                snapshot: armed.snapshot,
                hash: hash,
                eventIdHex: nil,
                outcome: self.nearbyRegistryOutcome(result),
                attempt: String(describing: attemptNumber)
              )
              self.resolveNearbyCandidates(armed.snapshot)
              return
            }
            self.resolveNearbyEventDefinition(
              eventIdHex: eventID,
              hash: hash,
              attempt: attempt,
              attemptNumber: attemptNumber,
              generation: generation
            )
          }
        }
        nearbyRegistryRequests.append(lookup)
      }
    }
  }

  private func resolveNearbyEventDefinition(
    eventIdHex: String,
    hash: String,
    attempt: ExportedKotlinPackages.org.levarac.parallax.discovery.NearbyEventRegistryResolutionAttempt,
    attemptNumber: Int32,
    generation: UInt64
  ) {
    guard let eventJoinRegistry else { return }
    let verification = eventJoinRegistry.resolveEventDefinition(
      eventIdHex: eventIdHex,
      nowEpochSeconds: nearbyDiscoveryClock() / 1000
    ) { [weak self] verified, _ in
      Task { @MainActor in
        guard let self else { return }
        guard generation == self.nearbyDiscoveryCallbackGeneration else { return }
        guard ExportedKotlinPackages.org.levarac.parallax.discovery
          .isNearbyEventRegistryResolutionAttemptActive(
            store: self.nearbyDiscoveryStore,
            attempt: attempt
          )
        else { return }
        let result: ExportedKotlinPackages.org.levarac.parallax.discovery
          .NearbyEventRegistryResolutionResult = verified?.isSuccess == true
          ? .VERIFIED : .VERIFICATION_UNAVAILABLE
        let definition = verified?.context.flatMap(Self.barnardDefinition(from:))
        if result == .VERIFIED, let definition {
          self.nearbyVerifiedDefinitions[hash] = definition
        } else {
          self.nearbyVerifiedDefinitions.removeValue(forKey: hash)
        }
        let agrees = definition.map { self.nearbyEnvelopeAgreements[hash]?($0) ?? false } ?? false
        _ = ExportedKotlinPackages.org.levarac.parallax.discovery
          .completeNearbyEventRegistryResolutionFromHex(
            store: self.nearbyDiscoveryStore, attempt: attempt,
            result: result, resolvedEventIdHex: eventIdHex,
            verifiedDefinitionJoinMode: verified?.context?.joinMode,
            verifiedDefinitionEventIdHex: verified?.context?.eventIdHex,
            verifiedDefinitionEventCodeHashHex: verified?.context?.eventCodeHashHex,
            envelopeAgreesWithRegistry: agrees,
            verifiedDefinitionHashHex: verified?.definitionHashHex,
            registryBlockHashHex: verified?.blockHashHex,
            verifiedDefinitionValidFromEpochSeconds: verified?.context?.validFrom.value,
            verifiedDefinitionValidUntilEpochSeconds: verified?.context?.validUntil.value
          )
        let completedAt = self.nearbyDiscoveryClock()
        let armed = ExportedKotlinPackages.org.levarac.parallax.discovery
          .refreshNearbyEventDiscovery(
            store: self.nearbyDiscoveryStore,
            nowEpochMillis: completedAt
          )
        self.publishNearbyEventDiscovery(armed.snapshot, asOf: completedAt)
        self.logNearbyRegistryOutcome(
          snapshot: armed.snapshot,
          hash: hash,
          eventIdHex: eventIdHex,
          outcome: self.nearbyRegistryOutcome(result),
          attempt: String(describing: attemptNumber)
        )
        self.resolveNearbyCandidates(armed.snapshot)
      }
    }
    nearbyEventDefinitionRequests.append(verification)
  }

  private func nearbyRegistryOutcome(
    _ result: ExportedKotlinPackages.org.levarac.parallax.discovery.NearbyEventRegistryResolutionResult
  ) -> String {
    switch result {
    case .VERIFIED:
      return "success"
    case .LOOKUP_UNAVAILABLE:
      return "rejected_lookup_unavailable"
    case .NOT_REGISTERED:
      return "rejected_not_registered"
    case .VERIFICATION_UNAVAILABLE:
      return "rejected_verification_unavailable"
    default:
      return "rejected_unknown"
    }
  }

  private func logNearbyRegistryOutcome(
    snapshot: ExportedKotlinPackages.org.levarac.parallax.discovery.NearbyEventCandidates,
    hash: String,
    eventIdHex: String?,
    outcome: String,
    attempt: String
  ) {
    var retryAtEpochMillis: Int64?
    for index in 0..<snapshot.candidateCount {
      guard let candidate = snapshot.candidateAt(index: index), candidate.eventCodeHashHex == hash else { continue }
      retryAtEpochMillis = candidate.registryRetryAtEpochMillis
      break
    }
    emitJoinStageDiagnostic(
      joinDiagnosticLog,
      eventIdHex: eventIdHex,
      stage: "registry_resolution",
      outcome: outcome,
      attempt: attempt,
      retryAtEpochMillis: retryAtEpochMillis
    )
  }

  /// Builds barnard's `BarnardEventDefinitionV1` from a verified registry read.
  ///
  /// `joinMode` is the wire value the Event Definition CBOR carries (`0` open,
  /// `1` gated), not an enum ordinal that happens to match. Any missing or
  /// malformed field yields nil, which can only ever withhold promotion.
  private static func barnardDefinition(
    from context: ExportedKotlinPackages.org.levarac.parallax.registry.EventDefinitionContext
  ) -> BarnardEventDefinitionV1? {
    barnardDefinition(
      eventIdHex: context.eventIdHex,
      keySetDigestHex: context.definition.keySetDigestHex,
      eventCodeHashHex: context.eventCodeHashHex,
      joinMode: context.joinMode,
      validFromUnixSeconds: context.validFrom.value,
      validUntilUnixSeconds: context.validUntil.value
    )
  }

  /// The whole decision, split out from the context reader above so it can be
  /// tested: `EventDefinitionContext` has an internal Kotlin initializer and
  /// cannot be constructed from a test, which left every rule here — the
  /// join-mode wire mapping most of all — unexercised.
  ///
  /// `joinMode` is the wire value the Event Definition CBOR carries (`0` open,
  /// `1` gated), not an enum ordinal that happens to line up with it.
  /// Internal rather than private for the same test-seam reason; nothing
  /// outside this type calls it.
  static func barnardDefinition(
    eventIdHex: String,
    keySetDigestHex: String,
    eventCodeHashHex: String?,
    joinMode: ExportedKotlinPackages.org.levarac.parallax.registry.EventJoinMode?,
    validFromUnixSeconds: Int64,
    validUntilUnixSeconds: Int64
  ) -> BarnardEventDefinitionV1? {
    guard let eventId = eventIdHex.hexBytes(count: 32),
      let keySetDigest = keySetDigestHex.hexBytes(count: 32),
      let eventCodeHashHex,
      let eventCodeHash = eventCodeHashHex.hexBytes(count: 8),
      let joinMode
    else { return nil }
    let mode: UInt8
    switch joinMode {
    case .OPEN: mode = 0
    case .GATED: mode = 1
    default: return nil
    }
    return BarnardEventDefinitionV1(
      eventId: eventId,
      keySetDigest: keySetDigest,
      joinMode: mode,
      eventCodeHash: eventCodeHash,
      validFromUnixSeconds: validFromUnixSeconds,
      validUntilUnixSeconds: validUntilUnixSeconds
    )
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
    guard let ownerKey = resolvedOwnerPublicKey() else { return }
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
      guard let ownerPublicKey = resolvedOwnerPublicKey() else { return nil }
      message = BindingMessage(
        walletAddress: walletAddressBytes,
        ownerPublicKey: ownerPublicKey,
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
  /// `BindingRecord`, and moves to `.bound`. Returns a
  /// `BindingCompletionResult` — `.notVerified` if there is no in-flight
  /// attempt to complete, `walletSignatureHex` isn't valid hex (defensive
  /// against a stale callback racing a decline, or a malformed transport
  /// response), or either verification below fails for a reason other than
  /// an unsupported smart-contract wallet; `.smartWalletUnsupported` if the
  /// wallet signature is ERC-6492-shaped (beid#359 — this must not collapse
  /// into the same reason a corrupt signature gets, since retrying can
  /// never succeed for this reason, unlike the others).
  ///
  /// Two checks guard against a `BindingRecord` whose stored
  /// `walletAddress` disagrees with what was actually signed (beid#316):
  ///
  /// (a) — cheap, no cryptography: `walletAddress` (the caller's claim)
  /// must byte-for-byte equal `message.walletAddress` (the address embedded
  /// in, and covered by, the signed canonical text). Catches a caller-side
  /// mixup — e.g. a stale `pendingBindingMessage` reused for a different
  /// address (see `beginBinding`'s reuse behavior) — without touching
  /// Barnard. Must short-circuit before (b) ever runs.
  ///
  /// (b) — delegated to Barnard (KMP-002): `BarnardCoreSigning
  /// .verifyWalletBinding` recovers the wallet signature's actual signer
  /// and checks it against `expectedWalletAddress`, and separately checks
  /// the device acknowledgement against `expectedOwnerPublicKey`. Catches a
  /// wallet/connector that signed with a different key than the address it
  /// reported. Before (b)'s cryptography ever runs, `BarnardCoreSigning
  /// .classifyWalletSignature` classifies the raw wallet-signature bytes
  /// (beid#357): a signature that isn't 65 bytes is rejected right there,
  /// before the owner key ever signs anything over it, and a smart-wallet-
  /// shaped signature is routed to `.smartWalletUnsupported` instead of
  /// falling into the generic `.notVerified` bucket (beid#359) — one
  /// classification call serving both issues. (b)'s own verification now
  /// yields three distinguishable outcomes instead of a boolean.
  func completeBinding(walletAddress: String, walletSignatureHex: String) -> BindingCompletionResult {
    guard
      let message = pendingBindingMessage,
      let proofId = activeProofId,
      let event = currentBindingEvent,
      let walletAddressBytes = Data(hexEncoded: walletAddress),
      walletAddressBytes == message.walletAddress,
      let walletSignatureBytes = Data(hexEncoded: walletSignatureHex),
      let canonicalText = message.canonicalText()
    else {
      return .notVerified
    }

    switch BarnardCoreSigning.classifyWalletSignature(Array(walletSignatureBytes)) {
    case .smartWalletUnsupported:
      return .smartWalletUnsupported
    case .invalid:
      return .notVerified
    case .validEoaShape:
      break
    }

    let acknowledgement: SensingRecoverableSignature?
    do {
      acknowledgement = try sensingCryptography.signWalletAcknowledgement(
        walletAddress: message.walletAddress,
        walletSignature: walletSignatureBytes
      )
    } catch {
      ownerKeyOperationFailure = .unavailable
      return .notVerified
    }
    guard let ackSignature = acknowledgement else {
      return .notVerified
    }

    let deviceSignature = BarnardCoreRecoverableSignature(
      r: Array(ackSignature.r),
      s: Array(ackSignature.s),
      v: ackSignature.v
    )

    switch BarnardCoreSigning.verifyWalletBinding(
      text: canonicalText,
      walletSignature: Array(walletSignatureBytes),
      expectedWalletAddress: Array(walletAddressBytes),
      expectedOwnerPublicKey: Array(message.ownerPublicKey),
      acknowledgement: deviceSignature
    ) {
    case .invalid:
      return .notVerified
    case .smartWalletUnsupported:
      // Unreachable via this call site in practice — classifyWalletSignature
      // above already routed this shape, and it's a pure function of the same
      // bytes, so verifyWalletBinding cannot independently reclassify it here.
      // Handled for exhaustiveness, not because this path is expected to run.
      return .smartWalletUnsupported
    case .valid:
      break
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
      deviceSignature: deviceSignature
    )
    bindingRecordStore.add(record)
    bindingState = .bound(record)
    pendingBindingMessage = nil
    return .bound(record)
  }

  /// Discards the pending binding message without changing `bindingState`.
  /// The only sanctioned caller is a mid-attempt rebuild for a different
  /// wallet address than the attempt started with (beid#315: the
  /// restored-hint one-trip path can discover the wallet actually
  /// connected a different account than the cached guess after signing
  /// completes; the signed text embedded the guess, so that signature
  /// cannot be reused for the corrected address — it must be discarded
  /// and rebuilt). Unlike `failBinding`/`declineBinding`, the caller here
  /// is still mid-`.connecting` and must stay there, so `bindingState` is
  /// left untouched — the very next `beginBinding` call re-sets it anyway.
  func discardPendingBindingMessage() {
    pendingBindingMessage = nil
  }

  /// The binding attempt failed: the wallet declined, a transport/timeout
  /// error occurred, or the returned signature did not verify. Distinct
  /// from `declineBinding()`: this is the round trip failing, not the user
  /// dismissing the sheet before starting one. `retryable` is `false` only
  /// when retrying cannot succeed (the ERC-6492 smart-wallet result,
  /// beid#382), so the sheet offers Close instead of Try Again.
  func failBinding(reason: String, retryable: Bool) {
    pendingBindingMessage = nil
    bindingState = .failed(reason: reason, retryable: retryable)
  }

  /// The user closed the sheet without completing a binding (decline,
  /// swipe-dismiss, or backing out of a failure) — wallet is optional
  /// (DESIGN.md §1), so this only touches `bindingState`, never `phase`;
  /// recording keeps running untouched. Re-offered next foreground per
  /// §5.6, never re-shown mid-session on its own.
  ///
  /// Narrowing of §5.6: a non-retryable failure is not re-offered for the
  /// rest of the session (beid#591).
  ///
  /// Backing out of a non-retryable failure (beid#382's Close, the Cancel
  /// toolbar button, or the sheet's `onDisappear`; beid#591) leaves
  /// `bindingState` as is. `ScanFlowView` only re-presents the sheet from
  /// `.pendingConnect`, so the sheet is not re-offered for the rest of the
  /// session; `resetSessionState()` clears it at session end. A retryable
  /// failure still goes straight to `.pendingConnect`, never through
  /// `.none`. Idempotent, so Close followed by the sheet's `onDisappear`
  /// lands on the same state as a single call.
  ///
  /// `pendingBindingMessage` is always discarded first, even when
  /// `bindingState` is left as is (beid#316).
  func declineBinding() {
    pendingBindingMessage = nil
    if case .failed(_, retryable: false) = bindingState {
      return
    }
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
        #if DEBUG
        Self.ledgerLog.debug("window_close outcome=failure_report_persist")
        #endif
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
        #if DEBUG
        Self.ledgerLog.debug("window_close outcome=failure_ledger_persist")
        #endif
        Self.ledgerLog.error("Unable to persist a closed shared-ledger window: \(error, privacy: .public)")
        recordLedgerDegradation(error)
      }
    }
    #if DEBUG
    Self.ledgerLog.debug("window_close outcome=report_saved peer_count=\(closingPeerRpids.count, privacy: .public)")
    #endif
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
    guard let ownerPublicKey = resolvedOwnerPublicKey() else { return nil }
    let signature: SensingRecoverableSignature?
    do {
      signature = try sensingCryptography.signSelfProof(
        eventIdHash: eventIdHash,
        eventSigningPublicKey: eventSigningPublicKey,
        eninStart: eninStart,
        eninEnd: eninEnd
        )
      } catch {
      ownerKeyOperationFailure = .unavailable
      return nil
    }
    guard let signature else {
      return nil
    }
    #if DEBUG
    Self.ledgerLog.debug("self_proof outcome=signature_created")
    #endif

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
  /// Preview/test overload: runs `scenario` and stops as soon as the screen
  /// the app would render equals `stopWhenPhaseReaches`.
  ///
  /// This is a stop, not a park. `simulateSignalLost`'s park suspends a run
  /// that a user resumes; nothing resumes a preview, and reusing
  /// `demoInterpreterIsParked` here would make `hasParkedDemoScenarioForTesting`
  /// mean two different things and leave `resumeSensing()` — which only acts
  /// from `.signalLost` — unable to clear a stop taken at `.recording`.
  func runDemoScenario(
    _ scenario: DemoScenario,
    stepDelayNanos: UInt64 = 700_000_000,
    stopWhenPhaseReaches route: ScanFlowContent.Route
  ) {
    runDemoScenario(scenario, stepDelayNanos: stepDelayNanos, stopRoute: route)
  }

  func runDemoScenario(_ scenario: DemoScenario, stepDelayNanos: UInt64 = 700_000_000) {
    runDemoScenario(scenario, stepDelayNanos: stepDelayNanos, stopRoute: nil)
  }

  private func runDemoScenario(
    _ scenario: DemoScenario,
    stepDelayNanos: UInt64,
    stopRoute: ScanFlowContent.Route?
  ) {
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
    demoInterpreterStopRoute = stopRoute
    demoScenarioReachedRequestedRoute = false
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

        // The reducer has now run for this step, so `phase` is its answer and
        // this asks the production router which screen that answer renders.
        // Nothing here decides where a scenario gets to; it only notices.
        if let stopRoute = self.demoInterpreterStopRoute,
           ScanFlowContent.route(for: self.phase) == stopRoute {
          self.demoScenarioReachedRequestedRoute = true
          // Same teardown as running off the end of the step list: the run is
          // over, nothing resumes it, and leaving interpreter state behind
          // would make a later `resumeSensing()` look at a finished scenario.
          self.clearDemoInterpreterState()
          self.onDemoInterpreterCheckpointForTesting?(.completed)
          return
        }

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
    case let .observeOneUnidentifiedRpid(rpid, enin):
      // Same helper, `nil` display id: one observation path, not two.
      demoInterpreterLastObservationChanged = observeOneDemoDevice(
        displayId: nil,
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
    demoInterpreterStopRoute = nil
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

  /// `displayId` is optional so the `unidentifiedHeavy` scenario (beid#395)
  /// can file an observation that never resolves, exactly as the real path
  /// does when Barnard B003 is unavailable. A `nil` display id still records
  /// the observation into `aggregationRuntime` and still inserts the rpid
  /// into `demoWindowRpids`; what it does not do is grow `devicesVerified`,
  /// so this returns `false` and the identifier lands in
  /// `rpidsAwaitingDisplayId`/`unidentifiedRpidCount` instead. The branch
  /// belongs to `recordDeviceIdentity`, which both the demo and real paths
  /// already share — this parameter only stops the demo vocabulary from
  /// being unable to say it.
  @discardableResult
  private func observeOneDemoDevice(displayId: String?, rpid: String, enin: Int) -> Bool {
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
        reporterRpid: detection.reporterRpid,
        observedAt: detection.observedAt
      )
    }
  }

  private nonisolated func delay(_ nanos: UInt64) async -> Bool {
    guard nanos > 0 else { return !Task.isCancelled }
    try? await Task.sleep(nanoseconds: nanos)
    return !Task.isCancelled
  }
}

private extension String {
  /// Decodes exactly [count] bytes of `0x`-prefixed or bare hex; nil for any
  /// other length or a non-hex character. Used to turn the registry's hex
  /// fields into the raw byte arrays barnard's definition value requires.
  func hexBytes(count: Int) -> [UInt8]? {
    guard let data = Data(hexEncoded: self), data.count == count else { return nil }
    return [UInt8](data)
  }
}

private extension Data {
  var lowercaseHexString: String {
    map { String(format: "%02x", $0) }.joined()
  }

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
