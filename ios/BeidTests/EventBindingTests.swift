// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

@MainActor
final class EventBindingTests: XCTestCase {
  private let testWalletAddress = "0x1234567890123456789012345678901234567890"
  private let testChainId = "eip155:1"
  private let testWalletSignatureHex = "0x" + String(repeating: "ab", count: 65)

  func testBeginBindingReturnsNilWhenNotRecording() {
    let coordinator = SensingCoordinator()
    XCTAssertNil(coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId))
    XCTAssertEqual(coordinator.bindingState, .none)
  }

  func testDemoSequenceReachesPendingConnectAtThreshold() async {
    let coordinator = SensingCoordinator()
    let event = EventSession(id: "TEST-BINDING", name: "Test Binding Event", venue: nil)

    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    XCTAssertEqual(coordinator.bindingState, .pendingConnect(event))
  }

  func testBeginBindingMovesToConnectingAndReturnsMessageHex() async {
    let coordinator = SensingCoordinator()
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    let messageHex = coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId)

    XCTAssertEqual(coordinator.bindingState, .connecting)
    XCTAssertNotNil(messageHex)
    XCTAssertTrue(messageHex?.hasPrefix("0x") == true)
  }

  func testBeginBindingReturnsNilForMalformedWalletAddress() async {
    let coordinator = SensingCoordinator()
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    XCTAssertNil(coordinator.beginBinding(walletAddress: "not-hex", chainId: testChainId))
    XCTAssertNil(coordinator.beginBinding(walletAddress: "0x1234", chainId: testChainId), "must be exactly 20 bytes")
  }

  func testBeginBindingReturnsNilForMalformedChainId() async {
    let coordinator = SensingCoordinator()
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    XCTAssertNil(coordinator.beginBinding(walletAddress: testWalletAddress, chainId: "not-caip2"))
  }

  func testBeginBindingWithMalformedInputLeavesBindingStateRecoverable() async {
    // Regression test: `bindingState` must never move to `.connecting`
    // before wallet-address/chain-ID validation succeeds. If it did (the
    // original bug), `EventBindingSheetView` would disable swipe-dismiss
    // and hide the Cancel button with no path back — asserting only the
    // `nil` return (as the two tests above do) would not catch that, since
    // `beginBinding` still returns `nil` correctly either way. This asserts
    // on `bindingState` itself after each failed call.
    let coordinator = SensingCoordinator()
    let event = EventSession(id: "TEST-BINDING", name: "Test Binding Event", venue: nil)
    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    XCTAssertNil(coordinator.beginBinding(walletAddress: "not-hex", chainId: testChainId))
    XCTAssertEqual(coordinator.bindingState, .pendingConnect(event), "must not get stuck in .connecting")

    XCTAssertNil(coordinator.beginBinding(walletAddress: testWalletAddress, chainId: "not-caip2"))
    XCTAssertEqual(coordinator.bindingState, .pendingConnect(event), "must not get stuck in .connecting")

    // "0x1234" is valid hex but only 2 bytes, not the 20 Barnard's own
    // `buildAccountBindingText` requires — `Data(hexEncoded:)` has no
    // length check, so this only fails deep inside `walletMessageHex()`,
    // not at either shallow guard above. This is the exact input shape
    // that slipped past this test's first version.
    XCTAssertNil(coordinator.beginBinding(walletAddress: "0x1234", chainId: testChainId))
    XCTAssertEqual(coordinator.bindingState, .pendingConnect(event), "must not get stuck in .connecting")
  }

  func testBeginBindingReusesTheSameMessageAcrossRepeatedCalls() async {
    // Guards the mutual-signature invariant: the wallet message and the
    // later owner-key wallet-ack must reference identical nonce/issuedAt,
    // so a second `beginBinding()` call for the same attempt must not
    // regenerate either.
    let coordinator = SensingCoordinator()
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    let first = coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId)
    let second = coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId)

    XCTAssertEqual(first, second)
  }

  func testMarkBindingAwaitingApprovalOnlyAppliesWhileConnecting() async {
    let coordinator = SensingCoordinator()
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    coordinator.markBindingAwaitingApproval()
    XCTAssertEqual(coordinator.bindingState, .pendingConnect(.demoSample), "no-op outside .connecting")

    _ = coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId)
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

    _ = coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId)
    coordinator.markBindingAwaitingApproval()
    let record = coordinator.completeBinding(
      walletAddress: testWalletAddress,
      walletSignatureHex: testWalletSignatureHex
    )

    guard let record else {
      XCTFail("expected a BindingRecord")
      return
    }
    XCTAssertEqual(record.eventCode, event.id)
    XCTAssertEqual(record.walletAddress, testWalletAddress)
    XCTAssertEqual(record.walletSignatureHex, testWalletSignatureHex)
    XCTAssertEqual(
      record.proofId,
      collectedProof?.id,
      "the record must attach to the Proof created for this recording session"
    )
    XCTAssertEqual(record.chainId, 1)
    XCTAssertEqual(record.nonceHex.count, 32, "nonce is always 16 bytes")
    XCTAssertFalse(record.issuedAt.isEmpty)
    XCTAssertFalse(record.eventSigningPublicKeyHex.isEmpty)
    XCTAssertFalse(record.ownerPublicKeyHex.isEmpty)
    XCTAssertFalse(record.deviceSignatureRHex.isEmpty)
    XCTAssertFalse(record.deviceSignatureSHex.isEmpty)

    guard case .bound(let stateRecord) = coordinator.bindingState else {
      XCTFail("expected .bound(record), got \(coordinator.bindingState)")
      return
    }
    XCTAssertEqual(stateRecord, record)
  }

  func testCompleteBindingReturnsNilForMalformedWalletSignatureHex() async {
    let coordinator = SensingCoordinator()
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    _ = coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId)

    XCTAssertNil(coordinator.completeBinding(walletAddress: testWalletAddress, walletSignatureHex: "not-hex"))
  }

  func testBindingRecordRoundTripsThroughCodable() async throws {
    let coordinator = SensingCoordinator()
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    _ = coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId)

    guard let record = coordinator.completeBinding(
      walletAddress: testWalletAddress,
      walletSignatureHex: testWalletSignatureHex
    ) else {
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
    _ = coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId)

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
    _ = coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId)

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
    _ = coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId)
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
    _ = coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId)
    XCTAssertNotNil(coordinator.completeBinding(
      walletAddress: testWalletAddress,
      walletSignatureHex: testWalletSignatureHex
    ))

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
    _ = coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId)
    XCTAssertNotNil(coordinator.completeBinding(
      walletAddress: testWalletAddress,
      walletSignatureHex: testWalletSignatureHex
    ))
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

    let result = await connector.requestPersonalSign(messageHex: "0xMESSAGE")

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
    let result = await connector.requestPersonalSign(messageHex: "0xMESSAGE") {
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
