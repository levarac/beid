// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Barnard
import BarnardCore
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
  /// Whether `RecordingView`'s one-time entrance ceremony (§5.5) has already
  /// played for the current session. Lives here rather than as view-local
  /// `@State` because `.recording` can be interrupted by `.signalLost` and
  /// resumed (`resumeSensing()`), which recreates `RecordingView` — a flag
  /// on the view itself would incorrectly replay the ceremony after every
  /// resume. Reset alongside the rest of per-session state in
  /// `resetSessionState()`.
  @Published private(set) var recordingCeremonyShown = false
  /// Distinct devices observed so far this session — the value carried as
  /// `peersVerified` into `.recording` and the stored `Proof`, and so the
  /// number that ends up inside a signed artifact.
  ///
  /// It is **one of two** independent ways to confirm an event
  /// (`hasEnoughDistinctDevicesToConfirm`), never the only one: the other arm
  /// reads the current window's proximity identifiers, so a total display-id
  /// outage cannot stop a real event from being recorded. Confirmation and
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
  @Published private(set) var devicesVerified = 0
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

  /// Field diagnostics for the counting split (beid#154). `os.Logger` rather
  /// than `print` on purpose: these lines have to be readable from a real
  /// device during a field run — Console.app, or a sysdiagnose collected after
  /// the fact — and `print` reaches neither. Every interpolation is
  /// `.public` because none of it is personal data: they are small integers,
  /// and no identifier is ever logged.
  private static let log = Logger(subsystem: "org.levarac.beid", category: "sensing")

  private let engine = BarnardEngine()
  private let sensingCryptography: any SensingCryptography
  private let randomSource: any BarnardCoreRandomSource = BeidSystemRandomSource()
  private let windowReportStore: WindowReportStore
  private let unsentWindowLedgerRuntime: (any UnsentWindowLedgerRuntimeProtocol)?
  private let bindingRecordStore = BindingRecordStore()
  private let selfProofStore: SelfProofStore
  private var demoTask: Task<Void, Never>?
  /// Demo-only ENIN counter (`advanceDemoWindow()`) — never touches
  /// `closeWindow`/`WindowReportStore`, only stands in for the real path's
  /// `advanceWindowIfNeeded`-derived `firstWindowEnin`/`currentWindowEnin`
  /// so the self-proof layer (§2.2) is exercisable under demo mode too.
  private var demoWindowEnin = 0

  // MARK: - Per-session protocol state
  //
  // Reset at the start of every new event (`beginEventFound`) and on
  // `stopSensing()`/`reset()` so nothing leaks into the next session.

  /// Distinct device display ids observed so far this session — the real-path
  /// equivalent of the demo sequence's loop counter, and the source of
  /// `peersVerified` (§4.3). Backs `devicesVerified`; see its doc comment for
  /// why this is keyed on the display id rather than the rotating proximity
  /// identifier (beid#154).
  ///
  /// A display id is 4 bytes, so two devices at one event can in principle
  /// collide and be counted once. At event scale that is negligible and this
  /// deliberately does not defend against it: the alternative identifier
  /// available here is the one that rotates, and undercounting by a collision
  /// is a far smaller error than multiplying every device by its dwell time.
  private var distinctPeerDisplayIds: Set<String> = []
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
  /// is set (real path: `advanceWindowIfNeeded`; demo path:
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

  convenience init() {
    let windowReportStore: WindowReportStore
    do {
      let recovery = try WindowReportStore.recoveringCorruptReports()
      if let quarantinedURL = recovery.quarantinedReportsURL {
        print("Quarantined corrupt window reports at \(quarantinedURL.path)")
      }
      windowReportStore = recovery.store
    } catch {
      windowReportStore = WindowReportStore()
      print("Unable to recover the window report store: \(error)")
    }

    let runtime: UnsentWindowLedgerRuntime?
    do {
      let recovery = try UnsentWindowLedgerStore.recoveringCorruptSnapshot()
      if let quarantinedURL = recovery.quarantinedSnapshotURL {
        print("Quarantined a corrupt shared unsent-window ledger at \(quarantinedURL.path)")
      }
      runtime = try UnsentWindowLedgerRuntime(
        store: recovery.store
      )
    } catch {
      runtime = nil
      print("Unable to load the shared unsent-window ledger: \(error)")
    }
    self.init(
      windowReportStore: windowReportStore,
      selfProofStore: SelfProofStore(),
      unsentWindowLedgerRuntime: runtime,
      sensingCryptography: BarnardSensingCryptography()
    )
  }

  /// Explicit storage seam for tests and controlled hosts. Unlike the
  /// production default initializer, this keeps strict fail-closed loading
  /// and never quarantines the caller-provided file implicitly.
  convenience init(
    windowReportStore: WindowReportStore,
    selfProofStore: SelfProofStore,
    unsentWindowLedgerFileURL: URL,
    sensingCryptography: any SensingCryptography
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
      unsentWindowLedgerRuntime: runtime,
      sensingCryptography: sensingCryptography
    )
  }

  init(
    windowReportStore: WindowReportStore,
    selfProofStore: SelfProofStore,
    unsentWindowLedgerRuntime: (any UnsentWindowLedgerRuntimeProtocol)?,
    sensingCryptography: any SensingCryptography
  ) {
    var recoveredRuntime = unsentWindowLedgerRuntime
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
        print("Unable to reconcile the shared unsent-window ledger: \(error)")
      }
    }

    self.windowReportStore = windowReportStore
    self.selfProofStore = selfProofStore
    self.unsentWindowLedgerRuntime = recoveredRuntime
    self.sensingCryptography = sensingCryptography
    engine.onEvent = { [weak self] event in
      guard let self else { return }
      Task { @MainActor in self.handle(event) }
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
        detectedDisplayId: detection.detectedDisplayId
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
  func handleDetection(enin: Int, rpid: String, detectedDisplayId: String?) {
    switch phase {
    case .sensing:
      let eventCode = engine.getCurrentEventCode() ?? "Unknown Event"
      let session = EventSession(id: eventCode, name: eventCode, venue: nil)
      beginEventFound(session)
      observe(enin: enin, rpid: rpid, detectedDisplayId: detectedDisplayId, for: session)
    case .eventFound(let session):
      observe(enin: enin, rpid: rpid, detectedDisplayId: detectedDisplayId, for: session)
    case .recording(let session, _):
      observe(enin: enin, rpid: rpid, detectedDisplayId: detectedDisplayId, for: session)
    case .idle, .signalLost:
      // `.signalLost` is frozen — real signal-loss *detection* doesn't
      // exist yet (only the demo-only manual trigger does), so this branch
      // is unreached today, but resuming is an explicit user action
      // (`resumeSensing()`), never automatic on the next detection.
      break
    }
  }

  /// Records the detection against the running device count and window, then
  /// applies whatever phase transition that observation implies.
  ///
  /// The within-window set (`currentWindowRpids`, which feeds
  /// `WindowReport.peerCount`) stays keyed on the proximity identifier and is
  /// deliberately untouched by beid#154: identifiers do not rotate *inside* a
  /// window, so counting them there already yields devices.
  private func observe(enin: Int, rpid: String, detectedDisplayId: String?, for session: EventSession) {
    advanceWindowIfNeeded(enin: enin, eventCode: session.id)
    currentWindowRpids.insert(rpid)

    let deviceCountChanged = recordDeviceIdentity(rpid: rpid, detectedDisplayId: detectedDisplayId)

    switch phase {
    case .eventFound:
      if shouldConfirmEvent {
        Self.log.notice(
          """
          Event confirmed via \(self.hasEnoughCoPresentDevicesToConfirm ? "co-presence" : "distinct devices", privacy: .public): \
          \(self.currentWindowRpids.count, privacy: .public) co-present this window, \
          \(self.devicesVerified, privacy: .public) identified this session, \
          \(self.unidentifiedRpidCount, privacy: .public) unidentified
          """
        )
        beginRecording(event: session, peersVerified: devicesVerified)
      }
    case .recording:
      // Only the identified-device count moves the recorded value; crossing
      // the threshold again in a later window is not new information.
      if deviceCountChanged {
        updateRecording(event: session, peersVerified: devicesVerified)
      }
    default:
      break
    }
  }

  /// Files this observation against the session's device identity accounting
  /// and reports whether `devicesVerified` moved.
  ///
  /// This is the display and signed-payload half of the split: it is keyed on
  /// the stable display id and is deliberately **not** what gates
  /// `.recording`.
  private func recordDeviceIdentity(rpid: String, detectedDisplayId: String?) -> Bool {
    // Barnard emits lowercase hex today; normalize so an upstream change of
    // case could not split one device into two.
    guard let displayId = detectedDisplayId?.lowercased() else {
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
      return false
    }
    if rpidsAwaitingDisplayId.remove(rpid) != nil {
      unidentifiedRpidCount = rpidsAwaitingDisplayId.count
    }
    guard distinctPeerDisplayIds.insert(displayId).inserted else { return false }
    devicesVerified = distinctPeerDisplayIds.count
    return true
  }

  /// Whether to confirm the event and start recording — either arm suffices.
  ///
  /// **The gate and the proof are different things, and that is what makes a
  /// disjunction safe here.** This decides only whether to *start recording*:
  /// is there a real, multi-device event around me. It asserts nothing. The
  /// co-presence facts are carried by the per-window reports, each of which
  /// records exactly who was present together in that window, and those are
  /// unaffected by how confirmation was reached. So confirming on devices seen
  /// one after another loosens no claim the proof makes — it only stops the
  /// app refusing to observe at real but sparse settings (a hallway, a booth,
  /// an arrival trickle), which are ordinary shapes rather than corner cases.
  ///
  /// Safety rests on two properties, both of which must survive any edit here:
  ///
  /// - **Neither arm accumulates.** The window arm is cleared at every window
  ///   boundary; the device arm is keyed on the non-rotating display id.
  ///   Neither grows with dwell time.
  /// - **A single lingering device satisfies neither.** It contributes 1 to
  ///   every window and 1 to the device count, forever. That is the property
  ///   this whole slice exists to establish, and
  ///   `testOneLingeringDeviceNeverSatisfiesTheConfirmThresholdOnItsOwn` fails
  ///   if a change ever weakens it.
  ///
  /// The two arms are kept as separate properties on purpose: the product
  /// default is still open, and dropping back to co-presence only is deleting
  /// one operand here, with nothing else entangled.
  private var shouldConfirmEvent: Bool {
    hasEnoughCoPresentDevicesToConfirm || hasEnoughDistinctDevicesToConfirm
  }

  /// Enough devices present **at the same time** — distinct proximity
  /// identifiers in the current ENIN window.
  ///
  /// Survives a total display-id outage, which is the reason this arm exists:
  /// gating solely on the display id meant a session that sensed a crowded
  /// room all evening recorded nothing.
  ///
  /// It does not consult the display id at all, and it is sound because the
  /// proximity identifier does not rotate inside a window — within one window,
  /// distinct identifier *is* distinct device. This is emphatically not the
  /// cross-window identifier counting beid#154 removed. The difference is
  /// accumulation, not the identifier: this set is cleared at every window
  /// boundary, so a lingering device contributes exactly 1 to every window
  /// forever.
  ///
  /// The phase transition latches, so this is effectively a max over windows:
  /// once any window has had enough co-present devices, the event stays
  /// confirmed even as later windows go quiet.
  private var hasEnoughCoPresentDevicesToConfirm: Bool {
    currentWindowRpids.count >= BeidConfig.eventConfirmThreshold
  }

  /// Enough distinct devices **at any point this session** — the display-id
  /// count, which does not grow with dwell time.
  ///
  /// Covers the sparse settings the co-presence arm alone would decline to
  /// record: people arriving one at a time, a booth with a steady trickle, a
  /// hallway. Three devices that never overlap are still three devices, and
  /// the per-window reports keep saying truthfully that each was alone in its
  /// own window.
  private var hasEnoughDistinctDevicesToConfirm: Bool {
    devicesVerified >= BeidConfig.eventConfirmThreshold
  }

  /// Calls the Barnard SDK's join API (`BarnardEngine.joinEvent`)
  /// with a manually entered event code — the wallet-optional fallback path
  /// (`EventCodeEntryView`) for choosing which event to sense, since there
  /// is no BLE auto-discovery yet. Returns whether the code took effect.
  @discardableResult
  func joinEvent(_ code: String) -> Bool {
    engine.joinEvent(code)
    let confirmed = engine.getCurrentEventCode()
    joinedEventCode = confirmed
    return confirmed == code
  }

  func startSensing(eventCode: String? = nil, demoEvent: EventSession = .demoSample) {
    let eventCode = eventCode ?? joinedEventCode ?? "beid-demo-event"
    resetSessionState()
    phase = .sensing
    if useDemoEventMode {
      runDemoSequence(demoEvent: demoEvent, stepDelayNanos: demoStepDelayNanos)
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
  /// indefinitely otherwise).
  func simulateSignalLost() {
    guard case .recording(let event, let peersVerified) = phase else { return }
    demoTask?.cancel()
    phase = .signalLost(event: event, peersVerified: peersVerified)
  }

  /// Resumes the same `EventSession`/count in place — never a restart, so
  /// nothing already recorded (the stored `Proof`, queued window reports)
  /// is discarded (D4, §5.4). Real BLE signal-loss *detection* (vs. this
  /// demo-only manual trigger) is still unimplemented, so on a real device
  /// this only clears the frozen UI state — scanning was never stopped, so
  /// `handle(_:)` keeps updating `peersVerified` in place regardless.
  func resumeSensing() {
    guard case .signalLost(let event, let peersVerified) = phase else { return }
    phase = .recording(event: event, peersVerified: peersVerified)
    if useDemoEventMode {
      continueDemoRecording(event: event, from: peersVerified, stepDelayNanos: demoStepDelayNanos)
    }
  }

  /// Marks the one-time entrance ceremony consumed so it never replays —
  /// called once by `RecordingView` the first time it appears for this
  /// session (including across a `resumeSensing()` cycle, since this flag
  /// outlives the view instance).
  func markRecordingCeremonyShown() {
    recordingCeremonyShown = true
  }

  @discardableResult
  func reset() -> SelfProofRecord? {
    endSensing(stopEngine: false)
  }

  private func endSensing(stopEngine: Bool) -> SelfProofRecord? {
    let selfProof = finalizeSelfProofIfNeeded()
    closeFinalWindowIfNeeded()
    demoTask?.cancel()
    demoTask = nil
    if stopEngine {
      engine.stopAuto()
    }
    resetSessionState()
    phase = .idle
    return selfProof
  }

  private func resetSessionState() {
    distinctPeerDisplayIds = []
    rpidsAwaitingDisplayId = []
    devicesVerified = 0
    unidentifiedRpidCount = 0
    currentWindowEnin = nil
    currentWindowId = nil
    currentWindowObservationReference = nil
    firstWindowEnin = nil
    lastWindowEnin = nil
    demoWindowEnin = 0
    currentWindowRpids = []
    activeCommit = nil
    activeProofId = nil
    pendingBindingMessage = nil
    bindingState = .none
    recordingCeremonyShown = false
  }

  // MARK: - Shared phase transitions
  //
  // Called synchronously from the real detection path (`observe`) and from
  // explicitly MainActor-isolated demo tasks below.

  /// Computes and fixes this session's `commit` (§5 — "fixed at event
  /// time"), then transitions to `.eventFound`. Resets prior-session state
  /// first so nothing leaks across events.
  private func beginEventFound(_ session: EventSession) {
    resetSessionState()
    let eventSigningKey = sensingCryptography.eventSigningPublicKey(eventCode: session.id)
    let ownerKey = sensingCryptography.ownerPublicKey()
    let salt = Data(randomSource.randomBytes(count: 16))
    activeCommit = EventCommitment.compute(eventSigningKey: eventSigningKey, ownerKey: ownerKey, salt: salt)
    phase = .eventFound(session)
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

  // MARK: - Per-window report signing (Q9, §4.5)

  private func advanceWindowIfNeeded(enin: Int, eventCode: String) {
    redeliverPendingWindowReports()
    guard let openEnin = currentWindowEnin else {
      openWindow(enin: enin)
      return
    }
    guard openEnin != enin else {
      return
    }
    closeWindow(enin: openEnin, eventCode: eventCode)
    openWindow(enin: enin)
  }

  private func openWindow(enin: Int) {
    let windowId = UUID()
    currentWindowId = windowId
    currentWindowEnin = enin
    lastWindowEnin = enin
    // Not unconditional: a background checkpoint can open another window
    // in the same session, but the self-proof start remains the first one.
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
  private func closeFinalWindowIfNeeded() {
    redeliverPendingWindowReports()
    guard let enin = currentWindowEnin else { return }
    // DemoEvent updates ENIN bookkeeping for self-proof coverage but never
    // opens a real native report window.
    guard currentWindowId != nil else { return }
    guard let eventCode = currentSessionEventCode else {
      print("Unable to close the native window without an active event code")
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
  func checkpointOpenWindowForBackgrounding() {
    redeliverPendingWindowReports()
    guard let enin = currentWindowEnin, let eventCode = currentSessionEventCode else { return }
    guard currentWindowId != nil else { return }
    closeWindow(enin: enin, eventCode: eventCode)
  }

  private func clearCurrentWindowState() {
    currentWindowRpids = []
    currentWindowEnin = nil
    currentWindowId = nil
    currentWindowObservationReference = nil
  }

  /// Signs the closing window's observations with the event signing key
  /// (no wallet, no user approval — high frequency, per the protocol model)
  /// and queues the report locally. No transport exists yet
  /// (`scan-protocol-model.md` §9 lists that as separate downstream work) —
  /// this only produces and stores the signature.
  private func closeWindow(enin: Int, eventCode: String) {
    guard
      let commit = activeCommit,
      let currentWindowId
    else {
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
      let payload = windowReportPayload(
        eventCode: eventCode,
        enin: enin,
        peerRpids: currentWindowRpids,
        commit: commit
      )
      let signature = sensingCryptography.signWindowReport(eventCode: eventCode, bytes: payload)
      let report = WindowReport(
        id: currentWindowId,
        eventCode: eventCode,
        enin: enin,
        peerCount: currentWindowRpids.count,
        commit: commit,
        signature: signature
      )
      // TODO: This and the shared snapshot write below synchronously
      // rewrite whole files on the MainActor BLE path. Move the I/O off
      // actor in a follow-up while preserving report-before-ledger-close
      // durability ordering. See beid#134.
      do {
        observationReference = try windowReportStore.add(report)
        currentWindowObservationReference = observationReference
      } catch {
        if let dropped = windowReportRedeliveryBuffer.enqueue(report) {
          print("Dropped the newest pending window report after reaching redelivery capacity: \(dropped.id)")
        } else {
          print("Parked a native window report for redelivery after persistence failed: \(error)")
        }
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
        print("Unable to persist a closed shared-ledger window: \(error)")
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
        print("Discarded a pending native window report absent from the shared ledger: \(report.id)")
      } catch {
        print("Unable to redeliver a pending native window report: \(error)")
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

  /// Builds, signs (`OwnerKeyProvider.signSelfProof`), and persists this
  /// session's self-proof, if one is due. `nil` if there is no `Proof` for
  /// this session (`activeProofId` unset — never reached `.recording`) or no
  /// ENIN window was ever observed (`firstWindowEnin`/`lastWindowEnin`
  /// unset). A session gated on `activeProofId` mirrors `BindingRecord
  /// .proofId`'s linkage: a session that stayed in `.eventFound` without
  /// meeting the peer threshold produced no `Proof`, so there is nothing to
  /// attest.
  ///
  /// Reads `lastWindowEnin`, not `currentWindowEnin`, for `end`: the latter
  /// is nil'd mid-session by `checkpointOpenWindowForBackgrounding()`
  /// (`docs/specs/session-end-finalization.md` §3.4) without ending the
  /// session, so a stop that follows a checkpoint with no further detection
  /// would otherwise find `currentWindowEnin == nil` here and silently
  /// return `nil` for a session that was, in fact, complete and valid.
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

    let eventIdHash = EventIdHash.compute(eventCode: eventCode)
    let eventSigningPublicKey = sensingCryptography.eventSigningPublicKey(eventCode: eventCode)
    let ownerPublicKey = sensingCryptography.ownerPublicKey()
    guard
      let signature = sensingCryptography.signSelfProof(
        eventIdHash: eventIdHash,
        eventSigningPublicKey: eventSigningPublicKey,
        eninStart: UInt64(start),
        eninEnd: UInt64(end)
      )
    else {
      return nil
    }

    let record = SelfProofRecord(
      proofId: proofId,
      eventCode: eventCode,
      eventIdHash: eventIdHash,
      eventSigningPublicKey: eventSigningPublicKey,
      eninStart: UInt64(start),
      eninEnd: UInt64(end),
      ownerPublicKey: ownerPublicKey,
      signature: BarnardCoreRecoverableSignature(
        r: Array(signature.r),
        s: Array(signature.s),
        v: signature.v
      )
    )
    selfProofStore.add(record)
    return record
  }

  // MARK: - Demo sequence
  //
  // Pure state advancement is separated from timing so tests can drive it
  // with a zero delay and await completion via
  // `waitForDemoSequenceToFinish()`. Demo mode has no real `BarnardEvent`
  // stream, so it drives the same shared phase-transition helpers directly
  // instead of going through `observe(_:for:)`; it does not produce window
  // reports (those depend on real `.detection` ENIN boundaries).

  func runDemoSequence(demoEvent: EventSession, stepDelayNanos: UInt64 = 700_000_000) {
    demoTask?.cancel()
    demoTask = Task { @MainActor [weak self] in
      guard let self else { return }
      guard await self.delay(stepDelayNanos), !Task.isCancelled else { return }
      self.beginEventFound(demoEvent)
      self.advanceDemoWindow()
      guard await self.delay(stepDelayNanos), !Task.isCancelled else { return }

      let threshold = BeidConfig.eventConfirmThreshold
      self.beginRecording(event: demoEvent, peersVerified: threshold)
      self.advanceDemoWindow()

      for peersVerified in (threshold + 1)...(threshold + 2) {
        guard await self.delay(stepDelayNanos), !Task.isCancelled else { return }
        self.updateRecording(event: demoEvent, peersVerified: peersVerified)
        self.advanceDemoWindow()
      }
    }
  }

  /// Continues the demo growth loop from a frozen (post-signal-lost) count
  /// — `resumeSensing()`'s demo-mode counterpart to `runDemoSequence`.
  private func continueDemoRecording(event: EventSession, from peersVerified: Int, stepDelayNanos: UInt64) {
    demoTask?.cancel()
    demoTask = Task { @MainActor [weak self] in
      guard let self else { return }
      for next in (peersVerified + 1)...(peersVerified + 2) {
        guard await self.delay(stepDelayNanos), !Task.isCancelled else { return }
        self.updateRecording(event: event, peersVerified: next)
        self.advanceDemoWindow()
      }
    }
  }

  /// Demo-only stand-in for the real path's `advanceWindowIfNeeded` —
  /// advances just enough ENIN-window state
  /// (`firstWindowEnin`/`currentWindowEnin`/`lastWindowEnin`) for the
  /// self-proof layer (§2.2) to be exercisable under demo mode, since there
  /// is no real BLE path to drive it with on the simulator. Deliberately
  /// never calls `closeWindow`/touches `WindowReportStore` — demo mode
  /// intentionally produces no window reports (see this section's own doc
  /// comment above), and this must not change that.
  private func advanceDemoWindow() {
    demoWindowEnin += 1
    if firstWindowEnin == nil {
      firstWindowEnin = demoWindowEnin
    }
    currentWindowEnin = demoWindowEnin
    lastWindowEnin = demoWindowEnin
  }

  func waitForDemoSequenceToFinish() async {
    await demoTask?.value
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
