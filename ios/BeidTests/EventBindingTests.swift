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
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    XCTAssertNil(coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId))
    XCTAssertEqual(coordinator.bindingState, .none)
  }

  func testDemoSequenceReachesPendingConnectAtThreshold() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    let event = EventSession(id: "TEST-BINDING", name: "Test Binding Event", venue: nil)

    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    XCTAssertEqual(coordinator.bindingState, .pendingConnect(event))
  }

  func testBeginBindingMovesToConnectingAndReturnsMessageHex() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    let messageHex = coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId)

    XCTAssertEqual(coordinator.bindingState, .connecting)
    XCTAssertNotNil(messageHex)
    XCTAssertTrue(messageHex?.hasPrefix("0x") == true)
  }

  func testBeginBindingReturnsNilForMalformedWalletAddress() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    XCTAssertNil(coordinator.beginBinding(walletAddress: "not-hex", chainId: testChainId))
    XCTAssertNil(coordinator.beginBinding(walletAddress: "0x1234", chainId: testChainId), "must be exactly 20 bytes")
  }

  func testBeginBindingReturnsNilForMalformedChainId() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
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
    let coordinator = makeIsolatedSensingCoordinator(for: self)
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
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    let first = coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId)
    let second = coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId)

    XCTAssertEqual(first, second)
  }

  func testMarkBindingAwaitingApprovalOnlyAppliesWhileConnecting() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    coordinator.markBindingAwaitingApproval()
    XCTAssertEqual(coordinator.bindingState, .pendingConnect(.demoSample), "no-op outside .connecting")

    _ = coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId)
    coordinator.markBindingAwaitingApproval()
    XCTAssertEqual(coordinator.bindingState, .awaitingApproval)
  }

  func testCompleteBindingWithNoInFlightAttemptReturnsNil() {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    XCTAssertNil(coordinator.completeBinding(walletAddress: "0xABC", walletSignatureHex: "0xSIG"))
  }

  func testCompleteBindingBuildsAndPersistsBindingRecord() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
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
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    _ = coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId)

    XCTAssertNil(coordinator.completeBinding(walletAddress: testWalletAddress, walletSignatureHex: "not-hex"))
  }

  func testBindingRecordRoundTripsThroughCodable() async throws {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
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
    let coordinator = makeIsolatedSensingCoordinator(for: self)
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
    let coordinator = makeIsolatedSensingCoordinator(for: self)
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
    // beid#222: `ScanFlowView`'s auto-present/auto-dismiss `.onChange(of:
    // sensing.bindingState)` presents on a fresh `.none -> .pendingConnect`
    // and dismisses on any transition INTO `.none`. Both guards depend on
    // this exact round trip (`.failed` -> Try Again's `declineBinding()`
    // -> `.pendingConnect`) never observably landing on `.none` in
    // between — if it did, the sheet would spuriously dismiss itself while
    // the user is actively retrying a failed binding. `declineBinding()`'s
    // `if let event = currentBindingEvent` branch is a single atomic
    // assignment straight to `.pendingConnect(event)`, so there is no
    // intermediate value to observe; this assertion makes that invariant
    // explicit rather than only implicit in the equality check below.
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    let event = EventSession(id: "TEST-BINDING", name: "Test Binding Event", venue: nil)
    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    _ = coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId)
    coordinator.failBinding(reason: "boom")

    coordinator.declineBinding()

    XCTAssertNotEqual(
      coordinator.bindingState,
      .none,
      "must land directly on .pendingConnect, never transiently on .none, or ScanFlowView's sheet would dismiss mid-retry"
    )
    XCTAssertEqual(coordinator.bindingState, .pendingConnect(event))
  }

  func testDeclineBindingWithoutAnAttemptIsSafe() {
    // Decline can fire from the sheet's onDisappear even if the user never
    // started a round trip (dismissed straight from `.pendingConnect`).
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.declineBinding()
    XCTAssertEqual(coordinator.bindingState, .none, "no-op when not recording")
  }

  func testResetClearsBindingStateAfterASuccessfulBinding() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
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
    let coordinator = makeIsolatedSensingCoordinator(for: self)
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

  /// beid#315 structural-containment coverage: drives the exact same
  /// live-connect → `beginBinding` → sign → `completeBinding` sequence
  /// `EventBindingSheetView.performBinding` drives, using
  /// `DemoWalletConnector` as the test double (its preview code already
  /// exercises `performBinding` this way — this is the XCTest-runnable
  /// analogue). Asserts the address on the resulting `BindingRecord` is
  /// exactly the connector's own `LiveWalletAddress.address` — the type
  /// `performBinding` requires — never a value that could have come from
  /// `CachedWalletHint`/`WalletHintStore` instead.
  func testLiveWalletAddressFromDemoConnectorFlowsIntoBindingRecordUnmodified() async throws {
    #if DEBUG
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    let event = EventSession(id: "TEST-BINDING", name: "Test Binding Event", venue: nil)
    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    let demo = DemoWalletConnector.shared
    demo.disconnect()
    await demo.connect()
    guard case .connected(let live) = demo.state else {
      XCTFail("expected DemoWalletConnector to report .connected after connect()")
      return
    }

    guard let messageHex = coordinator.beginBinding(walletAddress: live.address, chainId: live.chainId) else {
      XCTFail("expected beginBinding to succeed for the demo connector's own live address")
      return
    }
    let signResult = await demo.requestPersonalSign(messageHex: messageHex)
    guard case .success(let signatureHex) = signResult else {
      XCTFail("expected the demo connector to produce a signature")
      return
    }

    let record = coordinator.completeBinding(walletAddress: live.address, walletSignatureHex: signatureHex)

    XCTAssertEqual(
      record?.walletAddress,
      live.address,
      "the recorded address must be exactly the connector's own live address"
    )
    #else
    throw XCTSkip("DemoWalletConnector is DEBUG-only")
    #endif
  }

  // MARK: - Restored-hint mismatch (beid#315 Phase 3)
  //
  // `EventBindingSheetView.continueFromRestoredHint` is `private` and not
  // directly callable from a test. These exercise the exact
  // `SensingCoordinator`/`WalletConnector` sequence the fixed
  // `continueFromRestoredHint` runs when a `connectAndSign` result reports
  // a DIFFERENT address than the `CachedWalletHint` the flow started
  // from — beginBinding(hint) -> connectAndSign reports a mismatched
  // `live` -> discardPendingBindingMessage() -> beginBinding(live)
  // [fresh] -> requestPersonalSign -> completeBinding(live) — using
  // `FakeRestoredHintConnector` below as the `connectAndSign` double.

  /// Verifies the trap itself, at the coordinator level: without an
  /// explicit `discardPendingBindingMessage()` call, a second
  /// `beginBinding` for a genuinely different address still returns the
  /// same stale message — `beginBinding` ignores the arguments it was just
  /// passed whenever `pendingBindingMessage` is already set. A fix that
  /// forgets to discard first would silently keep signing/recording the
  /// stale (hint-embedding) message.
  func testBeginBindingIgnoresANewAddressWhilePendingMessageExists() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    let hintAddress = "0x1111111111111111111111111111111111111111"
    let liveAddress = "0x2222222222222222222222222222222222222222"

    let staleMessageHex = coordinator.beginBinding(walletAddress: hintAddress, chainId: testChainId)
    XCTAssertNotNil(staleMessageHex)

    XCTAssertEqual(
      coordinator.beginBinding(walletAddress: liveAddress, chainId: testChainId),
      staleMessageHex,
      "beginBinding must reuse the pending message and ignore the new address until explicitly discarded"
    )
  }

  /// The fix itself: on a mismatch, discarding first makes the next
  /// `beginBinding` call build a genuinely fresh message for the wallet's
  /// actual address, and the resulting `BindingRecord` carries that
  /// address, never the stale hint. (a) is asserted directly on the
  /// record; (b) — that `beginBinding` truly rebuilt rather than reusing
  /// `pendingBindingMessage` (private, unobservable directly) — is
  /// asserted indirectly via the rebuilt message hex differing from the
  /// stale one, and via the signer's captured message matching the fresh
  /// hex.
  func testRestoredHintMismatchDiscardsStaleMessageAndBindsToLiveAddress() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    let event = EventSession(id: "TEST-BINDING", name: "Test Binding Event", venue: nil)
    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    let hintAddress = "0x1111111111111111111111111111111111111111"
    let liveAddress = "0x2222222222222222222222222222222222222222"
    let connector = FakeRestoredHintConnector()
    connector.connectAndSignResult = .success((
      LiveWalletAddress.fromConnectorResult(address: liveAddress, chainId: testChainId),
      testWalletSignatureHex
    ))
    connector.requestPersonalSignResult = .success(testWalletSignatureHex)

    guard let staleMessageHex = coordinator.beginBinding(walletAddress: hintAddress, chainId: testChainId) else {
      XCTFail("expected beginBinding to succeed for the hint address")
      return
    }

    let connectAndSignResult = await connector.connectAndSign(messageHex: staleMessageHex)
    guard case .success(let (live, _)) = connectAndSignResult else {
      XCTFail("expected connectAndSign to succeed")
      return
    }
    XCTAssertNotEqual(live.address, hintAddress, "test fixture sanity: live must actually differ from hint")

    // The fix's mismatch branch: discard, then rebuild fresh for `live`.
    coordinator.discardPendingBindingMessage()
    guard let freshMessageHex = coordinator.beginBinding(walletAddress: live.address, chainId: live.chainId) else {
      XCTFail("expected beginBinding to succeed for the live address after discarding")
      return
    }
    XCTAssertNotEqual(
      freshMessageHex,
      staleMessageHex,
      "a rebuilt message must differ from the stale one (different embedded address, and a new random nonce)"
    )

    let signResult = await connector.requestPersonalSign(messageHex: freshMessageHex)
    guard case .success(let signatureHex) = signResult else {
      XCTFail("expected requestPersonalSign to succeed")
      return
    }
    XCTAssertEqual(
      connector.requestPersonalSignMessage,
      freshMessageHex,
      "must sign the freshly rebuilt message, not the stale one"
    )

    let record = coordinator.completeBinding(walletAddress: live.address, walletSignatureHex: signatureHex)

    XCTAssertEqual(
      record?.walletAddress,
      liveAddress,
      "the persisted record must carry the wallet's actual address, never the stale hint"
    )
  }
}

/// Minimal `WalletConnector` double for the restored-hint mismatch tests
/// above — a configurable `connectAndSign`/`requestPersonalSign` result,
/// since neither `DemoWalletConnector` (fixed demo address only) nor
/// `MetaMaskConnector` (requires driving its private session bookkeeping
/// through a `MetaMaskTransport` double) can report an arbitrary mismatched
/// address as directly as this.
@MainActor
private final class FakeRestoredHintConnector: ObservableObject, WalletConnector {
  @Published var state: WalletConnectorState = .idle
  var connectAndSignResult: Result<(LiveWalletAddress, String), WalletConnectorError> = .failure(.notConnected)
  var requestPersonalSignResult: Result<String, WalletConnectorError> = .failure(.notConnected)
  private(set) var requestPersonalSignMessage: String?

  var address: String? {
    if case .connected(let live) = state { return live.address }
    return nil
  }

  var chainId: String { "eip155:1" }

  func configureIfNeeded() {}
  func connect() async {}

  func requestPersonalSign(
    messageHex: String,
    responseTimeout: TimeInterval = 90,
    onDispatched: (() -> Void)? = nil
  ) async -> Result<String, WalletConnectorError> {
    requestPersonalSignMessage = messageHex
    onDispatched?()
    return requestPersonalSignResult
  }

  func connectAndSign(
    messageHex: String,
    responseTimeout: TimeInterval = 90,
    onDispatched: (() -> Void)? = nil
  ) async -> Result<(LiveWalletAddress, String), WalletConnectorError> {
    onDispatched?()
    if case .success(let (live, _)) = connectAndSignResult {
      state = .connected(live)
    }
    return connectAndSignResult
  }

  func disconnect() {
    state = .idle
  }

  @discardableResult
  func handle(url: URL) -> Bool { false }
}

@MainActor
final class DemoWalletConnectorTests: XCTestCase {
  func testConnectSettlesToConnectedDemoAddress() async throws {
    #if DEBUG
    let connector = DemoWalletConnector.shared
    connector.disconnect()

    await connector.connect()

    XCTAssertEqual(
      connector.state,
      .connected(LiveWalletAddress.fromConnectorResult(address: DemoWalletConnector.demoAddress, chainId: "eip155:1"))
    )
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

  /// Parity coverage for `WalletConnector.connectAndSign` (dispatch#26
  /// condition 2) — `DemoWalletConnector` has no `.restored`/cache-hint
  /// story of its own (see its type doc comment), so this only confirms it
  /// still satisfies the shared protocol's single-round-trip shape.
  func testConnectAndSignSettlesToConnectedDemoAddressAndReportsDispatch() async throws {
    #if DEBUG
    let connector = DemoWalletConnector.shared
    connector.disconnect()

    var dispatched = false
    let result = await connector.connectAndSign(messageHex: "0xMESSAGE") {
      dispatched = true
    }

    XCTAssertTrue(dispatched)
    guard case .success(let (live, signatureHex)) = result else {
      XCTFail("expected success, got \(result)")
      return
    }
    XCTAssertEqual(live, LiveWalletAddress.fromConnectorResult(address: DemoWalletConnector.demoAddress, chainId: "eip155:1"))
    XCTAssertTrue(signatureHex.hasPrefix("0x"))
    XCTAssertEqual(connector.state, .connected(live))
    #else
    throw XCTSkip("DemoWalletConnector is DEBUG-only")
    #endif
  }
}
