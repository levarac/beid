// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Barnard
import Foundation

/// Wraps `BarnardEngine` (scan+advertise) and `BarnardIdentity` (per-event
/// signing) behind the app's `ScanPhase` state machine.
///
/// The simulator has no BLE radio, so `useDemoEventMode` drives a simulated
/// peer sequence (06a→06c) instead of real detections — this doubles as the
/// future App-Review demo mode (see README).
@MainActor
final class SensingCoordinator: ObservableObject {
  @Published private(set) var phase: ScanPhase = .idle
  @Published private(set) var isScanning = false
  @Published private(set) var isAdvertising = false

  /// Fired once a proof is minted, before `phase` flips to `.collected`.
  var onProofCollected: ((Proof) -> Void)?

  private let engine = BarnardEngine()
  private let identity = BarnardIdentity()
  private var demoTask: Task<Void, Never>?

  /// Forced on for the simulator (no BLE radio); can be overridden for
  /// tests/demo builds.
  var useDemoEventMode: Bool = {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }()

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
    case .detection:
      if case .sensing = phase {
        let eventCode = engine.getCurrentEventCode() ?? "Unknown Event"
        phase = .eventFound(DemoEvent(name: eventCode, totalPeersToVerify: 1))
      }
    default:
      break
    }
  }

  func startSensing(eventCode: String = "beid-demo-event", demoEvent: DemoEvent = .sample) {
    phase = .sensing
    if useDemoEventMode {
      runDemoSequence(demoEvent: demoEvent)
    } else {
      engine.requestPermissions { [weak self] status in
        guard let self else { return }
        Task { @MainActor in
          guard status.canScan, status.canAdvertise else { return }
          self.engine.configure(eventCode: eventCode)
          _ = self.identity.signingPublicKey(eventCode: eventCode)
          self.engine.startAuto()
        }
      }
    }
  }

  func stopSensing() {
    demoTask?.cancel()
    demoTask = nil
    engine.stopAuto()
    phase = .idle
  }

  /// Manual trigger so the 06d Signal Lost screen is reachable from the demo
  /// flow (the golden DemoEvent path itself completes successfully).
  func simulateSignalLost() {
    guard case .verifying(let event, _) = phase else { return }
    demoTask?.cancel()
    phase = .signalLost(event: event)
  }

  func reset() {
    demoTask?.cancel()
    demoTask = nil
    phase = .idle
  }

  // MARK: - Demo sequence
  //
  // Pure state advancement (`advanceDemo`) is separated from timing so tests
  // can drive it with a zero delay and await completion via
  // `waitForDemoSequenceToFinish()`.

  func runDemoSequence(demoEvent: DemoEvent, stepDelayNanos: UInt64 = 700_000_000) {
    demoTask?.cancel()
    demoTask = Task { [weak self] in
      guard let self else { return }
      await self.advanceDemo(to: .eventFound(demoEvent))
      guard await self.delay(stepDelayNanos) else { return }

      for verified in 1...demoEvent.totalPeersToVerify {
        await self.advanceDemo(to: .verifying(event: demoEvent, peersVerified: verified))
        guard await self.delay(stepDelayNanos) else { return }
      }

      await self.advanceDemo(to: .verified(event: demoEvent, peersVerified: demoEvent.totalPeersToVerify))
      guard await self.delay(stepDelayNanos) else { return }

      let proof = Proof(eventName: demoEvent.name, date: Date(), peersVerified: demoEvent.totalPeersToVerify)
      self.onProofCollected?(proof)
      await self.advanceDemo(to: .collected(proof))
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

  private func advanceDemo(to newPhase: ScanPhase) {
    phase = newPhase
  }
}
