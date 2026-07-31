// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Barnard
import BarnardCore
import Foundation

/// Wraps `BarnardEngine` (scan+advertise) and `BarnardIdentity` (per-event
/// signing) behind the app's `ScanPhase` state machine.
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

  /// Fired once, the instant `.recording` begins and a `Proof` is created.
  var onProofCollected: ((Proof) -> Void)?
  /// Fired on every subsequent distinct-peer observation while
  /// `.recording`, so the caller can update the same `Proof` in place
  /// (`ProofStore.updatePeersVerified(for:to:)`) rather than re-creating it.
  var onPeersVerifiedChanged: ((UUID, Int) -> Void)?

  private let engine = BarnardEngine()
  private let identity = BarnardIdentity()
  private let ownerKeyProvider = OwnerKeyProvider()
  private let randomSource: any BarnardCoreRandomSource = BeidSystemRandomSource()
  private let windowReportStore = WindowReportStore()
  private let bindingRecordStore = BindingRecordStore()
  private var demoTask: Task<Void, Never>?

  // MARK: - Per-session protocol state
  //
  // Reset at the start of every new event (`beginEventFound`) and on
  // `stopSensing()`/`reset()` so nothing leaks into the next session.

  /// Distinct peer RPIDs observed so far this session — the real-path
  /// equivalent of the demo sequence's loop counter, and the source of
  /// `peersVerified` (§4.3).
  private var distinctPeerRpids: Set<String> = []
  private var currentWindowEnin: Int?
  private var currentWindowRpids: Set<String> = []
  /// `commit = H(event signing key ‖ owner key ‖ salt)`, fixed once per
  /// event at the instant it's found (§5 — the owner key is a cross-event
  /// anchor "fixed at event time"). Carried on every window report signed
  /// during this session.
  private var activeCommit: Data?
  private var activeProofId: UUID?
  /// The in-flight binding attempt's fixed message, reused across the
  /// wallet `personal_sign` digest and the later device countersign so both
  /// signatures commit to identical bytes (`BindingMessage`'s `issuedAt`
  /// must not be recomputed with a fresh `Date()` between the two steps).
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

  init() {
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
      handleDetection(detection)
    default:
      break
    }
  }

  private func handleDetection(_ detection: BarnardDetectionEvent) {
    switch phase {
    case .sensing:
      let eventCode = engine.getCurrentEventCode() ?? "Unknown Event"
      let session = EventSession(id: eventCode, name: eventCode, venue: nil)
      beginEventFound(session)
      observe(detection, for: session)
    case .eventFound(let session):
      observe(detection, for: session)
    case .recording(let session, _):
      observe(detection, for: session)
    case .idle, .signalLost:
      // `.signalLost` is frozen — real signal-loss *detection* doesn't
      // exist yet (only the demo-only manual trigger does), so this branch
      // is unreached today, but resuming is an explicit user action
      // (`resumeSensing()`), never automatic on the next detection.
      break
    }
  }

  /// Records `detection` against the running peer count and window, then
  /// applies whatever phase transition that observation implies. Called
  /// from the real detection path only — `handleDetection`'s isolation
  /// context is already MainActor via `engine.onEvent`'s `Task { @MainActor
  /// in }`, so no `await` is needed here or in the phase-transition helpers
  /// it calls.
  private func observe(_ detection: BarnardDetectionEvent, for session: EventSession) {
    advanceWindowIfNeeded(enin: detection.enin, eventCode: session.id)
    currentWindowRpids.insert(detection.rpid)
    guard distinctPeerRpids.insert(detection.rpid).inserted else { return }

    let peersVerified = distinctPeerRpids.count
    switch phase {
    case .eventFound:
      if peersVerified >= BeidConfig.eventConfirmThreshold {
        beginRecording(event: session, peersVerified: peersVerified)
      }
    case .recording:
      updateRecording(event: session, peersVerified: peersVerified)
    default:
      break
    }
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

  func stopSensing() {
    demoTask?.cancel()
    demoTask = nil
    engine.stopAuto()
    resetSessionState()
    phase = .idle
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

  func reset() {
    demoTask?.cancel()
    demoTask = nil
    resetSessionState()
    phase = .idle
  }

  private func resetSessionState() {
    distinctPeerRpids = []
    currentWindowEnin = nil
    currentWindowRpids = []
    activeCommit = nil
    activeProofId = nil
    pendingBindingMessage = nil
    bindingState = .none
  }

  // MARK: - Shared phase transitions
  //
  // Called synchronously from the real detection path (`observe`, already
  // MainActor-isolated) and via `await` from the demo `Task` below — both
  // are valid call shapes for a MainActor-isolated method, depending on
  // whether the caller is already statically known to be on this actor.

  /// Computes and fixes this session's `commit` (§5 — "fixed at event
  /// time"), then transitions to `.eventFound`. Resets prior-session state
  /// first so nothing leaks across events.
  private func beginEventFound(_ session: EventSession) {
    resetSessionState()
    let eventSigningKey = identity.signingPublicKey(eventCode: session.id)
    let ownerKey = ownerKeyProvider.publicKeyCompressed()
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
    let proof = Proof(id: proofId, eventName: event.name, date: Date(), peersVerified: peersVerified)
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

  // MARK: - Wallet connect+binding (beid#33, sub-slice 2b, §5.6)
  //
  // The interstitial (`EventBindingSheetView`) drives these; this type owns
  // the message/signing/persistence side so the view only ever handles the
  // wallet connector's `connect()`/`requestPersonalSign(digestHex:)` calls.

  private var currentBindingEvent: EventSession? {
    switch phase {
    case .recording(let event, _), .signalLost(let event, _):
      return event
    case .idle, .sensing, .eventFound:
      return nil
    }
  }

  /// Starts (or resumes) this attempt, moving to `.connecting` and
  /// returning the `0x`-prefixed digest the wallet's `personal_sign` must
  /// sign. Reuses `pendingBindingMessage` if a digest was already handed out
  /// for this attempt — recomputing with a fresh `Date()` would desync the
  /// wallet signature and the later device countersign. `nil` if not
  /// currently recording (defensive; the sheet only calls this while
  /// `bindingState` implies `.recording`/`.signalLost`).
  func beginBinding() -> String? {
    guard let event = currentBindingEvent else { return nil }
    bindingState = .connecting
    let message = pendingBindingMessage ?? BindingMessage(
      eventCode: event.id,
      eventSigningPublicKey: identity.signingPublicKey(eventCode: event.id),
      issuedAt: Date()
    )
    pendingBindingMessage = message
    return message.walletDigestHex()
  }

  /// Called once the wallet request has been dispatched (`onDispatched` on
  /// `WalletConnector.requestPersonalSign`) — moves the ambient status from
  /// "connecting" to "waiting on the wallet". No-op if a decline/failure
  /// already raced it.
  func markBindingAwaitingApproval() {
    guard case .connecting = bindingState else { return }
    bindingState = .awaitingApproval
  }

  /// Completes the round trip: countersigns the same `BindingMessage` bytes
  /// the wallet just signed (the mutual-signature requirement, §4/§6 —
  /// neither signature alone is a valid binding), builds and persists the
  /// `BindingRecord`, and moves to `.bound`. `nil` (no state change) if
  /// there is no in-flight attempt to complete — defensive against a stale
  /// callback racing a decline.
  @discardableResult
  func completeBinding(walletAddress: String, walletSignatureHex: String) -> BindingRecord? {
    guard let message = pendingBindingMessage, let proofId = activeProofId else { return nil }
    let deviceSignature = identity.sign(eventCode: message.eventCode, bytes: message.canonicalBytes)
    let record = BindingRecord(
      proofId: proofId,
      eventCode: message.eventCode,
      walletAddress: walletAddress,
      eventSigningPublicKey: message.eventSigningPublicKey,
      boundAt: message.issuedAt,
      walletSignatureHex: walletSignatureHex,
      deviceSignature: deviceSignature
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
    guard let openEnin = currentWindowEnin else {
      currentWindowEnin = enin
      return
    }
    guard openEnin != enin else { return }
    closeWindow(enin: openEnin, eventCode: eventCode)
    currentWindowRpids = []
    currentWindowEnin = enin
  }

  /// Signs the closing window's observations with the event signing key
  /// (no wallet, no user approval — high frequency, per the protocol model)
  /// and queues the report locally. No transport exists yet
  /// (`scan-protocol-model.md` §9 lists that as separate downstream work) —
  /// this only produces and stores the signature.
  private func closeWindow(enin: Int, eventCode: String) {
    guard let commit = activeCommit else { return }
    let payload = windowReportPayload(eventCode: eventCode, enin: enin, peerRpids: currentWindowRpids, commit: commit)
    let signature = identity.sign(eventCode: eventCode, bytes: payload)
    let report = WindowReport(
      eventCode: eventCode,
      enin: enin,
      peerCount: currentWindowRpids.count,
      commit: commit,
      signature: signature
    )
    windowReportStore.add(report)
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
    demoTask = Task { [weak self] in
      guard let self else { return }
      guard await self.delay(stepDelayNanos) else { return }
      await self.beginEventFound(demoEvent)
      guard await self.delay(stepDelayNanos) else { return }

      let threshold = BeidConfig.eventConfirmThreshold
      await self.beginRecording(event: demoEvent, peersVerified: threshold)

      for peersVerified in (threshold + 1)...(threshold + 2) {
        guard await self.delay(stepDelayNanos) else { return }
        await self.updateRecording(event: demoEvent, peersVerified: peersVerified)
      }
    }
  }

  /// Continues the demo growth loop from a frozen (post-signal-lost) count
  /// — `resumeSensing()`'s demo-mode counterpart to `runDemoSequence`.
  private func continueDemoRecording(event: EventSession, from peersVerified: Int, stepDelayNanos: UInt64) {
    demoTask?.cancel()
    demoTask = Task { [weak self] in
      guard let self else { return }
      for next in (peersVerified + 1)...(peersVerified + 2) {
        guard await self.delay(stepDelayNanos) else { return }
        await self.updateRecording(event: event, peersVerified: next)
      }
    }
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
