// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import BeidNative

@MainActor
final class SensingCoordinatorTests: XCTestCase {
  func testEngineOnEventIsWired() {
    // Smoke test: constructing the coordinator wires BarnardEngine's
    // onEvent callback without crashing (barnard#56 engine integration).
    let coordinator = SensingCoordinator()
    XCTAssertEqual(coordinator.phase, .idle)
  }

  func testDemoSequenceReachesCollectedPhase() async {
    let coordinator = SensingCoordinator()
    let event = DemoEvent(name: "Test Event", totalPeersToVerify: 2)
    var collectedProof: Proof?
    coordinator.onProofCollected = { collectedProof = $0 }

    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    guard case .collected(let proof) = coordinator.phase else {
      XCTFail("expected .collected phase, got \(coordinator.phase)")
      return
    }
    XCTAssertEqual(proof.eventName, "Test Event")
    XCTAssertEqual(proof.peersVerified, 2)
    XCTAssertEqual(collectedProof, proof)
  }

  func testDemoSequenceStepsThroughVerifyingCounts() async {
    let coordinator = SensingCoordinator()
    let event = DemoEvent(name: "Test Event", totalPeersToVerify: 3)
    var observedPeerCounts: [Int] = []

    // Drive the sequence with a real delay short enough for a test, and
    // sample intermediate phases via a manual polling loop instead of
    // reaching into private state.
    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 10_000_000)
    while true {
      try? await Task.sleep(nanoseconds: 5_000_000)
      if case .verifying(_, let peersVerified) = coordinator.phase {
        if observedPeerCounts.last != peersVerified {
          observedPeerCounts.append(peersVerified)
        }
      }
      if case .collected = coordinator.phase { break }
    }

    XCTAssertEqual(observedPeerCounts, Array(1...3))
  }

  func testSimulateSignalLostOnlyAppliesDuringVerifying() {
    let coordinator = SensingCoordinator()
    coordinator.simulateSignalLost()
    XCTAssertEqual(coordinator.phase, .idle, "no-op outside .verifying")
  }

  func testResetReturnsToIdle() async {
    let coordinator = SensingCoordinator()
    coordinator.runDemoSequence(demoEvent: .sample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    coordinator.reset()
    XCTAssertEqual(coordinator.phase, .idle)
  }
}
