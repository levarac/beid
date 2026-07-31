// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

@MainActor
final class EventBindingTests: XCTestCase {
  func testBeginBindingReturnsNilWhenNotRecording() {
    let coordinator = SensingCoordinator()
    XCTAssertNil(coordinator.beginBinding())
    XCTAssertEqual(coordinator.bindingState, .none)
  }

  func testDemoSequenceReachesPendingConnectAtThreshold() async {
    let coordinator = SensingCoordinator()
    let event = EventSession(id: "TEST-BINDING", name: "Test Binding Event", venue: nil)

    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    XCTAssertEqual(coordinator.bindingState, .pendingConnect(event))
  }

  func testBeginBindingMovesToConnectingAndReturnsDigest() async {
    let coordinator = SensingCoordinator()
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    let digest = coordinator.beginBinding()

    XCTAssertEqual(coordinator.bindingState, .connecting)
    XCTAssertNotNil(digest)
    XCTAssertTrue(digest?.hasPrefix("0x") == true)
  }

  func testBeginBindingReusesTheSameDigestAcrossRepeatedCalls() async {
    // Guards the mutual-signature invariant: the wallet digest and the
    // later device countersign must cover identical bytes, so a second
    // `beginBinding()` call for the same attempt must not recompute a
    // fresh `issuedAt`.
    let coordinator = SensingCoordinator()
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    let first = coordinator.beginBinding()
    let second = coordinator.beginBinding()

    XCTAssertEqual(first, second)
  }

  func testMarkBindingAwaitingApprovalOnlyAppliesWhileConnecting() async {
    let coordinator = SensingCoordinator()
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    coordinator.markBindingAwaitingApproval()
    XCTAssertEqual(coordinator.bindingState, .pendingConnect(.demoSample), "no-op outside .connecting")

    _ = coordinator.beginBinding()
    coordinator.markBindingAwaitingApproval()
    XCTAssertEqual(coordinator.bindingState, .awaitingApproval)
  }

  func testCompleteBindingWithNoInFlightAttemptReturnsNil() {
    let coordinator = SensingCoordinator()
    XCTAssertNil(coordinator.completeBinding(walletAddress: "0xABC", walletSignatureHex: "0xSIG"))
  }

  func testCompleteBindingBuildsAndPersistsBindingRecord() async {
    let coordinator = SensingCoordinator()
    let event = EventSession(id: "TEST-BINDING", name: "Test Binding Event", venue: nil)
    var collectedProof: Proof?
    coordinator.onProofCollected = { collectedProof = $0 }

    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    _ = coordinator.beginBinding()
    coordinator.markBindingAwaitingApproval()
    let record = coordinator.completeBinding(walletAddress: "0xWALLET", walletSignatureHex: "0xSIGNATURE")

    guard let record else {
      XCTFail("expected a BindingRecord")
      return
    }
    XCTAssertEqual(record.eventCode, event.id)
    XCTAssertEqual(record.walletAddress, "0xWALLET")
    XCTAssertEqual(record.walletSignatureHex, "0xSIGNATURE")
    XCTAssertEqual(record.proofId, collectedProof?.id, "the record must attach to the Proof created for this recording session")
    XCTAssertFalse(record.eventSigningPublicKeyHex.isEmpty)
    XCTAssertFalse(record.deviceSignatureRHex.isEmpty)
    XCTAssertFalse(record.deviceSignatureSHex.isEmpty)

    guard case .bound(let stateRecord) = coordinator.bindingState else {
      XCTFail("expected .bound(record), got \(coordinator.bindingState)")
      return
    }
    XCTAssertEqual(stateRecord, record)
  }

  func testBindingRecordRoundTripsThroughCodable() async throws {
    let coordinator = SensingCoordinator()
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    _ = coordinator.beginBinding()

    guard let record = coordinator.completeBinding(walletAddress: "0xWALLET", walletSignatureHex: "0xSIGNATURE") else {
      XCTFail("expected a BindingRecord")
      return
    }

    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(BindingRecord.self, from: data)

    XCTAssertEqual(decoded, record)
  }

  func testFailBindingSetsFailedReasonAndClearsInFlightMessage() async {
    let coordinator = SensingCoordinator()
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    _ = coordinator.beginBinding()

    coordinator.failBinding(reason: "Declined in wallet")

    XCTAssertEqual(coordinator.bindingState, .failed(reason: "Declined in wallet"))
    XCTAssertNil(
      coordinator.completeBinding(walletAddress: "0xLATE", walletSignatureHex: "0xLATE"),
      "a stale completion racing the failure must not resurrect the old attempt"
    )
  }

  func testDeclineBindingRevertsToPendingConnectAndClearsInFlightMessage() async {
    let coordinator = SensingCoordinator()
    let event = EventSession(id: "TEST-BINDING", name: "Test Binding Event", venue: nil)
    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    _ = coordinator.beginBinding()

    coordinator.declineBinding()

    XCTAssertEqual(coordinator.bindingState, .pendingConnect(event))
    XCTAssertNil(
      coordinator.completeBinding(walletAddress: "0xLATE", walletSignatureHex: "0xLATE"),
      "a stale completion racing the decline must not resurrect the old attempt"
    )
  }

  func testDeclineBindingFromFailedRevertsToPendingConnect() async {
    let coordinator = SensingCoordinator()
    let event = EventSession(id: "TEST-BINDING", name: "Test Binding Event", venue: nil)
    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    _ = coordinator.beginBinding()
    coordinator.failBinding(reason: "boom")

    coordinator.declineBinding()

    XCTAssertEqual(coordinator.bindingState, .pendingConnect(event))
  }

  func testDeclineBindingWithoutAnAttemptIsSafe() {
    // Decline can fire from the sheet's onDisappear even if the user never
    // started a round trip (dismissed straight from `.pendingConnect`).
    let coordinator = SensingCoordinator()
    coordinator.declineBinding()
    XCTAssertEqual(coordinator.bindingState, .none, "no-op when not recording")
  }

  func testResetClearsBindingStateAfterASuccessfulBinding() async {
    let coordinator = SensingCoordinator()
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    _ = coordinator.beginBinding()
    XCTAssertNotNil(coordinator.completeBinding(walletAddress: "0xWALLET", walletSignatureHex: "0xSIGNATURE"))

    coordinator.reset()

    XCTAssertEqual(coordinator.bindingState, .none)
    XCTAssertEqual(coordinator.phase, .idle)
  }

  func testStartingANewSessionResetsBindingStateFromThePreviousOne() async {
    // A second `.eventFound`/`.recording` cycle on the same long-lived
    // coordinator (as `AppCoordinator` reuses one `SensingCoordinator`
    // across `startScan()`/`finishScan()`) must not leak the previous
    // event's binding state into the new one.
    let coordinator = SensingCoordinator()
    coordinator.startSensing(demoEvent: .demoSample)
    await coordinator.waitForDemoSequenceToFinish()
    _ = coordinator.beginBinding()
    XCTAssertNotNil(coordinator.completeBinding(walletAddress: "0xWALLET", walletSignatureHex: "0xSIGNATURE"))
    coordinator.reset()

    coordinator.startSensing(demoEvent: .demoSample)
    await coordinator.waitForDemoSequenceToFinish()

    XCTAssertEqual(coordinator.bindingState, .pendingConnect(.demoSample))
  }
}

@MainActor
final class DemoWalletConnectorTests: XCTestCase {
  func testConnectSettlesToConnectedDemoAddress() async throws {
    #if DEBUG
    let connector = DemoWalletConnector.shared
    connector.disconnect()

    await connector.connect()

    XCTAssertEqual(connector.state, .connected(address: DemoWalletConnector.demoAddress))
    XCTAssertEqual(connector.address, DemoWalletConnector.demoAddress)
    #else
    throw XCTSkip("DemoWalletConnector is DEBUG-only")
    #endif
  }

  func testRequestPersonalSignFailsBeforeConnecting() async throws {
    #if DEBUG
    let connector = DemoWalletConnector.shared
    connector.disconnect()

    let result = await connector.requestPersonalSign(digestHex: "0xDIGEST")

    XCTAssertEqual(result, .failure(.notConnected))
    #else
    throw XCTSkip("DemoWalletConnector is DEBUG-only")
    #endif
  }

  func testRequestPersonalSignSucceedsAfterConnectingAndReportsDispatch() async throws {
    #if DEBUG
    let connector = DemoWalletConnector.shared
    connector.disconnect()
    await connector.connect()

    var dispatched = false
    let result = await connector.requestPersonalSign(digestHex: "0xDIGEST") {
      dispatched = true
    }

    XCTAssertTrue(dispatched)
    guard case .success(let signatureHex) = result else {
      XCTFail("expected a successful signature, got \(result)")
      return
    }
    XCTAssertTrue(signatureHex.hasPrefix("0x"))
    #else
    throw XCTSkip("DemoWalletConnector is DEBUG-only")
    #endif
  }
}
