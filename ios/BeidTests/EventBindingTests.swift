// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BarnardCore
import XCTest
@testable import Beid

@MainActor
final class EventBindingTests: XCTestCase {
  private let testWalletAddress = "0x1234567890123456789012345678901234567890"
  private let testChainId = "eip155:1"
  /// Not a real signature — only satisfies decode/shape checks. Used only by
  /// tests that are expected to fail before reaching piece (b)'s Barnard
  /// verification (malformed-hex, no-pending-attempt, decline/fail-race,
  /// and the piece (a) trap test), where there is nothing for a real
  /// signature to prove. Tests that assert a `BindingRecord` is actually
  /// produced use `TestWallet.sign(messageHex:)` instead (see below).
  private let testWalletSignatureHex = "0x" + String(repeating: "ab", count: 65)
  /// A genuinely valid EOA address (`TestWallet`'s own derived address) for
  /// tests that need `completeBinding` to actually succeed end-to-end.
  private let realWalletAddress = TestWallet.address

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

  func testCompleteBindingWithNoInFlightAttemptReturnsNotVerified() {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    XCTAssertEqual(
      coordinator.completeBinding(walletAddress: "0xABC", walletSignatureHex: "0xSIG"),
      .notVerified
    )
  }

  func testCompleteBindingBuildsAndPersistsBindingRecord() async {
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      sensingCryptography: BarnardBackedBindingCryptography()
    )
    let event = EventSession(id: "TEST-BINDING", name: "Test Binding Event", venue: nil)
    var collectedProof: Proof?
    coordinator.onProofCollected = { collectedProof = $0 }

    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    guard let messageHex = coordinator.beginBinding(walletAddress: realWalletAddress, chainId: testChainId) else {
      XCTFail("expected beginBinding to succeed")
      return
    }
    coordinator.markBindingAwaitingApproval()
    let walletSignatureHex = TestWallet.sign(messageHex: messageHex)
    guard case .bound(let record) = coordinator.completeBinding(
      walletAddress: realWalletAddress,
      walletSignatureHex: walletSignatureHex
    ) else {
      XCTFail("expected a BindingRecord")
      return
    }
    XCTAssertEqual(record.eventCode, event.id)
    XCTAssertEqual(record.walletAddress, realWalletAddress)
    XCTAssertEqual(record.walletSignatureHex, walletSignatureHex)
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

    XCTAssertEqual(
      coordinator.completeBinding(walletAddress: testWalletAddress, walletSignatureHex: "not-hex"),
      .notVerified
    )
  }

  // MARK: - Signer address verification at binding time (beid#316)

  /// Closes the exact hole `testBeginBindingIgnoresANewAddressWhilePendingMessageExists`
  /// documents at the `beginBinding` level: if `discardPendingBindingMessage()`
  /// is ever skipped (e.g. `continueFromRestoredHint`'s mismatch branch is
  /// deleted or becomes buggy), `pendingBindingMessage` still embeds the
  /// stale address while `completeBinding` may be called with a disagreeing
  /// argument address. `completeBinding` itself must refuse to produce a
  /// record in that case. Piece (a) is a cheap comparison that must
  /// short-circuit before any cryptography runs, so this deliberately stays
  /// on the plain fake signature/crypto double — there is nothing for real
  /// crypto to prove here.
  func testCompleteBindingRejectsArgumentAddressDisagreeingWithPendingMessage() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    let addressA = "0x1111111111111111111111111111111111111111"
    let addressB = "0x2222222222222222222222222222222222222222"

    XCTAssertNotNil(coordinator.beginBinding(walletAddress: addressA, chainId: testChainId))
    // No discardPendingBindingMessage() call here — simulates the regression.

    XCTAssertEqual(
      coordinator.completeBinding(walletAddress: addressB, walletSignatureHex: testWalletSignatureHex),
      .notVerified,
      """
      completeBinding must reject an argument address that disagrees with \
      the pending message's embedded address, regardless of whether the \
      signature would otherwise be valid for anything
      """
    )
  }

  /// The opposite trap: `beginBinding` reusing `pendingBindingMessage`
  /// across repeated calls for the SAME address (a legitimate retry, e.g.
  /// after a `markBindingAwaitingApproval` race or UI re-entry) must NOT be
  /// rejected by the new address check — only a genuinely disagreeing
  /// argument address should be. Guards against an address check that
  /// accidentally compares against a freshly rebuilt message instead of the
  /// actual `pendingBindingMessage` in play. Uses real crypto/signature so a
  /// verification bug that always happens to pass couldn't hide behind a
  /// fake signature piece (b) never actually checks.
  func testCompleteBindingSucceedsAfterBeginBindingCalledTwiceForSameAddress() async {
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      sensingCryptography: BarnardBackedBindingCryptography()
    )
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    let first = coordinator.beginBinding(walletAddress: realWalletAddress, chainId: testChainId)
    let second = coordinator.beginBinding(walletAddress: realWalletAddress, chainId: testChainId)
    XCTAssertEqual(first, second, "sanity: repeated calls for the same address must reuse the pending message")

    guard let messageHex = second else {
      XCTFail("expected beginBinding to succeed")
      return
    }

    let result = coordinator.completeBinding(
      walletAddress: realWalletAddress,
      walletSignatureHex: TestWallet.sign(messageHex: messageHex)
    )

    guard case .bound = result else {
      XCTFail("a legitimate retry for the same address must still succeed, got \(result)")
      return
    }
  }

  /// Piece (b): the argument address and the pending message's embedded
  /// address agree (piece (a) passes), but the wallet signature bytes were
  /// actually produced by a DIFFERENT private key than the one
  /// `realWalletAddress` derives from — simulating a wallet/connector that
  /// reported the right address but signed with the wrong key (e.g. an
  /// account switch mid-flow the connector didn't reflect in what it
  /// reported). Only `BarnardCoreSigning.verifyWalletBinding`'s own
  /// signature recovery can catch this — it's exactly why piece (b) exists.
  func testCompleteBindingRejectsWalletSignatureFromADifferentPrivateKey() async {
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      sensingCryptography: BarnardBackedBindingCryptography()
    )
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    guard let messageHex = coordinator.beginBinding(walletAddress: realWalletAddress, chainId: testChainId) else {
      XCTFail("expected beginBinding to succeed")
      return
    }

    let wrongSignatureHex = TestWallet.signWrong(messageHex: messageHex)

    XCTAssertEqual(
      coordinator.completeBinding(walletAddress: realWalletAddress, walletSignatureHex: wrongSignatureHex),
      .notVerified,
      "a wallet signature that doesn't actually recover to the claimed address must be rejected"
    )
  }

  // MARK: - beid#357: signature-length boundary check

  func testCompleteBindingDoesNotAskOwnerToSign64ByteSignature() async throws {
    try await assertOwnerAcknowledgementCalls(walletSignature: Data(repeating: 0xab, count: 64))
  }

  func testCompleteBindingDoesNotAskOwnerToSign66ByteSignature() async throws {
    try await assertOwnerAcknowledgementCalls(walletSignature: Data(repeating: 0xab, count: 66))
  }

  func testCompleteBindingDoesNotAskOwnerToSignSmartWalletSignature() async throws {
    let signature = Data(repeating: 0xcd, count: 32) + Data(Array(repeating: [UInt8(0x64), 0x92], count: 16).joined())
    try await assertOwnerAcknowledgementCalls(walletSignature: signature, expectedResult: .smartWalletUnsupported)
  }

  /// Positive control: the same setup must reach the signer for an EOA-shaped
  /// input. The double returns nil, so no real owner key signs wallet bytes.
  func testCompleteBindingAsksOwnerToSign65ByteSignature() async throws {
    try await assertOwnerAcknowledgementCalls(walletSignature: Data(repeating: 0xab, count: 65), expectedCalls: 1)
  }

  private func assertOwnerAcknowledgementCalls(
    walletSignature: Data,
    expectedResult: BindingCompletionResult = .notVerified,
    expectedCalls: Int = 0,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let cryptography = DeterministicSensingCryptography(walletAcknowledgementSignature: nil)
    let coordinator = makeIsolatedSensingCoordinator(for: self, sensingCryptography: cryptography)
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    _ = try XCTUnwrap(coordinator.beginBinding(walletAddress: testWalletAddress, chainId: testChainId))

    let result = coordinator.completeBinding(
      walletAddress: testWalletAddress,
      walletSignatureHex: "0x" + walletSignature.map { String(format: "%02x", $0) }.joined()
    )
    let acknowledgementCalls = cryptography.calls.filter {
      if case .signWalletAcknowledgement = $0 { return true }
      return false
    }.count
    XCTAssertEqual(acknowledgementCalls, expectedCalls, "classification must precede owner signing", file: file, line: line)
    XCTAssertEqual(result, expectedResult, file: file, line: line)
  }

  /// beid#357's trap: a wallet signature one byte off the required 65 bytes
  /// must be rejected before it ever reaches the owner key, and must not
  /// produce a BindingRecord. Uses a real, otherwise-valid signature with one
  /// byte truncated/appended so this fails ONLY on length, not because the
  /// bytes are garbage in some other way.
  func testCompleteBindingRejectsSignatureOneByteShortOfRequiredLength() async {
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      sensingCryptography: BarnardBackedBindingCryptography()
    )
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    guard let messageHex = coordinator.beginBinding(walletAddress: realWalletAddress, chainId: testChainId) else {
      XCTFail("expected beginBinding to succeed")
      return
    }

    let validSignatureHex = TestWallet.sign(messageHex: messageHex)
    let truncatedSignatureHex = String(validSignatureHex.dropLast(2)) // drop one byte (2 hex chars)

    XCTAssertEqual(
      coordinator.completeBinding(walletAddress: realWalletAddress, walletSignatureHex: truncatedSignatureHex),
      .notVerified,
      "a signature one byte short of the required 65 must be rejected, not passed to the owner key"
    )
  }

  func testCompleteBindingRejectsSignatureOneByteLongerThanRequiredLength() async {
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      sensingCryptography: BarnardBackedBindingCryptography()
    )
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    guard let messageHex = coordinator.beginBinding(walletAddress: realWalletAddress, chainId: testChainId) else {
      XCTFail("expected beginBinding to succeed")
      return
    }

    let validSignatureHex = TestWallet.sign(messageHex: messageHex)
    let extendedSignatureHex = validSignatureHex + "ab" // one extra byte

    XCTAssertEqual(
      coordinator.completeBinding(walletAddress: realWalletAddress, walletSignatureHex: extendedSignatureHex),
      .notVerified,
      "a signature one byte longer than the required 65 must be rejected, not passed to the owner key"
    )
  }

  // MARK: - beid#359: smart-wallet (ERC-6492) signature distinguished from a corrupt one

  /// A smart-wallet-shaped signature (ends with the ERC-6492 32-byte magic
  /// suffix `0x6492...6492`) must yield `.smartWalletUnsupported`, not the
  /// same `.notVerified` a corrupt/garbage signature gets — this is the exact
  /// collapse beid#359 reports. Length is deliberately NOT 65 bytes here
  /// (real ERC-6492 wrapped signatures aren't), so this also proves the
  /// beid#357 length gate does not swallow this case ahead of classification.
  func testCompleteBindingDistinguishesSmartWalletSignatureFromCorruptSignature() async {
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      sensingCryptography: BarnardBackedBindingCryptography()
    )
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    guard coordinator.beginBinding(walletAddress: realWalletAddress, chainId: testChainId) != nil else {
      XCTFail("expected beginBinding to succeed")
      return
    }

    // erc6492Magic per BarnardCoreOwnerKey.swift: 16 repetitions of 0x64 0x92.
    let erc6492MagicHex = String(repeating: "6492", count: 16)
    let smartWalletSignatureHex = "0x" + String(repeating: "cd", count: 32) + erc6492MagicHex

    let smartWalletResult = coordinator.completeBinding(
      walletAddress: realWalletAddress,
      walletSignatureHex: smartWalletSignatureHex
    )
    XCTAssertEqual(smartWalletResult, .smartWalletUnsupported)

    // Re-establish a pending attempt (the smart-wallet call above did not
    // consume/clear pendingBindingMessage — completeBinding never mutates
    // state on a failure path), then try a same-length but non-magic-suffixed
    // corrupt signature and confirm it gets the OTHER reason.
    // smartWalletSignatureHex is "0x" + 32 bytes (cd) + 32 bytes (magic) = 64
    // bytes; match that length here with 64 bytes of 0xef (count: 64, not the
    // byte total) so the two signatures are genuinely the same length.
    let corruptSameLengthSignatureHex = "0x" + String(repeating: "ef", count: 64)
    XCTAssertEqual(corruptSameLengthSignatureHex.count, smartWalletSignatureHex.count)

    let corruptResult = coordinator.completeBinding(
      walletAddress: realWalletAddress,
      walletSignatureHex: corruptSameLengthSignatureHex
    )
    XCTAssertEqual(corruptResult, .notVerified)

    XCTAssertNotEqual(
      smartWalletResult,
      corruptResult,
      "a smart-wallet-shaped signature must not collapse into the same reason as a corrupt one"
    )
  }

  func testBindingRecordRoundTripsThroughCodable() async throws {
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      sensingCryptography: BarnardBackedBindingCryptography()
    )
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    guard let messageHex = coordinator.beginBinding(walletAddress: realWalletAddress, chainId: testChainId) else {
      XCTFail("expected beginBinding to succeed")
      return
    }

    guard case .bound(let record) = coordinator.completeBinding(
      walletAddress: realWalletAddress,
      walletSignatureHex: TestWallet.sign(messageHex: messageHex)
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

    coordinator.failBinding(reason: "Declined in wallet", retryable: true)

    XCTAssertEqual(coordinator.bindingState, .failed(reason: "Declined in wallet", retryable: true))
    XCTAssertEqual(
      coordinator.completeBinding(walletAddress: "0xLATE", walletSignatureHex: "0xLATE"),
      .notVerified,
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
    XCTAssertEqual(
      coordinator.completeBinding(walletAddress: "0xLATE", walletSignatureHex: "0xLATE"),
      .notVerified,
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
    coordinator.failBinding(reason: "boom", retryable: true)

    coordinator.declineBinding()

    XCTAssertNotEqual(
      coordinator.bindingState,
      .none,
      "must land directly on .pendingConnect, never transiently on .none, or ScanFlowView's sheet would dismiss mid-retry"
    )
    XCTAssertEqual(coordinator.bindingState, .pendingConnect(event))
  }

  /// beid#382: an unsupported smart-contract wallet (ERC-6492) can never
  /// succeed on retry, so its failure must be non-retryable. beid#591: its
  /// Close button (`declineBinding()`, then the sheet's `onDisappear` runs
  /// `declineBinding()` again) must leave that failure in place rather than
  /// land on `.pendingConnect`, or `ScanFlowView` re-presents the sheet on
  /// every return to the foreground and offers only the wallet that cannot
  /// work. The `failBinding(reason:retryable:)` call below (with
  /// `retryable: false`) mirrors
  /// `EventBindingSheetView.completeBindingOrFailVerification`'s
  /// `.smartWalletUnsupported` branch. The view's own choice of
  /// `retryable: false` cannot be reached from a unit test (there is no
  /// view-test harness), so this test pins the state contract the sheet
  /// and `ScanFlowView` render from, not the view's branch.
  func testSmartWalletFailureIsNotRetryableAndStaysFailedAfterClose() async {
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      sensingCryptography: BarnardBackedBindingCryptography()
    )
    let event = EventSession(id: "TEST-BINDING", name: "Test Binding Event", venue: nil)
    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    guard coordinator.beginBinding(walletAddress: realWalletAddress, chainId: testChainId) != nil else {
      XCTFail("expected beginBinding to succeed")
      return
    }

    // erc6492Magic per BarnardCoreOwnerKey.swift: 16 repetitions of 0x64 0x92.
    let erc6492MagicHex = String(repeating: "6492", count: 16)
    let smartWalletSignatureHex = "0x" + String(repeating: "cd", count: 32) + erc6492MagicHex
    XCTAssertEqual(
      coordinator.completeBinding(walletAddress: realWalletAddress, walletSignatureHex: smartWalletSignatureHex),
      .smartWalletUnsupported
    )

    coordinator.failBinding(reason: "Unsupported wallet", retryable: false)

    XCTAssertEqual(coordinator.bindingState, .failed(reason: "Unsupported wallet", retryable: false))
    XCTAssertNotEqual(
      coordinator.bindingState,
      .failed(reason: "Unsupported wallet", retryable: true),
      "identical reason copy must still leave a non-retryable failure distinguishable from a retryable one"
    )

    // The sheet's Close button, then the sheet's own onDisappear.
    coordinator.declineBinding()
    coordinator.declineBinding()

    XCTAssertEqual(
      coordinator.bindingState,
      .failed(reason: "Unsupported wallet", retryable: false),
      "a non-retryable failure must stay in place after Close for the rest of the session"
    )
    XCTAssertNotEqual(
      coordinator.bindingState,
      .pendingConnect(event),
      "ScanFlowView.presentBindingSheetIfNeeded() re-presents the sheet from .pendingConnect on every foreground"
    )
  }

  /// Control for beid#591: only a non-retryable failure is sticky. Backing
  /// out of a retryable one still lands on `.pendingConnect`, and stays
  /// there across the Close/Cancel-then-`onDisappear` double call, so the
  /// sheet is re-offered next foreground as §5.6 describes.
  func testRetryableFailureStillRevertsToPendingConnectOnDecline() async {
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      sensingCryptography: BarnardBackedBindingCryptography()
    )
    let event = EventSession(id: "TEST-BINDING", name: "Test Binding Event", venue: nil)
    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    guard coordinator.beginBinding(walletAddress: realWalletAddress, chainId: testChainId) != nil else {
      XCTFail("expected beginBinding to succeed")
      return
    }

    // Not 65 bytes and no ERC-6492 suffix: the generic, retryable reason.
    let corruptSignatureHex = "0x" + String(repeating: "ef", count: 64)
    XCTAssertEqual(
      coordinator.completeBinding(walletAddress: realWalletAddress, walletSignatureHex: corruptSignatureHex),
      .notVerified
    )
    coordinator.failBinding(reason: "Couldn't verify this wallet", retryable: true)
    XCTAssertEqual(coordinator.bindingState, .failed(reason: "Couldn't verify this wallet", retryable: true))

    coordinator.declineBinding()
    coordinator.declineBinding()

    XCTAssertEqual(coordinator.bindingState, .pendingConnect(event))
  }

  /// Control for beid#591: the sticky non-retryable failure lasts only for
  /// the session. Ending it (`reset()`, through `resetSessionState()`)
  /// clears it, and the next session offers the sheet again.
  func testStickySmartWalletFailureClearsAtSessionEndAndNewSessionOffersAgain() async {
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      sensingCryptography: BarnardBackedBindingCryptography()
    )
    coordinator.startSensing(demoEvent: .demoSample)
    await coordinator.waitForDemoSequenceToFinish()
    guard coordinator.beginBinding(walletAddress: realWalletAddress, chainId: testChainId) != nil else {
      XCTFail("expected beginBinding to succeed")
      return
    }

    // erc6492Magic per BarnardCoreOwnerKey.swift: 16 repetitions of 0x64 0x92.
    let erc6492MagicHex = String(repeating: "6492", count: 16)
    let smartWalletSignatureHex = "0x" + String(repeating: "cd", count: 32) + erc6492MagicHex
    XCTAssertEqual(
      coordinator.completeBinding(walletAddress: realWalletAddress, walletSignatureHex: smartWalletSignatureHex),
      .smartWalletUnsupported
    )
    coordinator.failBinding(reason: "Unsupported wallet", retryable: false)
    XCTAssertEqual(coordinator.bindingState, .failed(reason: "Unsupported wallet", retryable: false))
    // The sheet's Close button, then the sheet's own onDisappear.
    coordinator.declineBinding()
    coordinator.declineBinding()

    coordinator.reset()

    XCTAssertEqual(coordinator.bindingState, .none)

    coordinator.startSensing(demoEvent: .demoSample)
    await coordinator.waitForDemoSequenceToFinish()

    XCTAssertEqual(coordinator.bindingState, .pendingConnect(.demoSample))
  }

  func testDeclineBindingWithoutAnAttemptIsSafe() {
    // Decline can fire from the sheet's onDisappear even if the user never
    // started a round trip (dismissed straight from `.pendingConnect`).
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.declineBinding()
    XCTAssertEqual(coordinator.bindingState, .none, "no-op when not recording")
  }

  func testResetClearsBindingStateAfterASuccessfulBinding() async {
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      sensingCryptography: BarnardBackedBindingCryptography()
    )
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    guard let messageHex = coordinator.beginBinding(walletAddress: realWalletAddress, chainId: testChainId) else {
      XCTFail("expected beginBinding to succeed")
      return
    }
    guard case .bound = coordinator.completeBinding(
      walletAddress: realWalletAddress,
      walletSignatureHex: TestWallet.sign(messageHex: messageHex)
    ) else {
      XCTFail("expected a BindingRecord")
      return
    }

    coordinator.reset()

    XCTAssertEqual(coordinator.bindingState, .none)
    XCTAssertEqual(coordinator.phase, .idle)
  }

  func testStartingANewSessionResetsBindingStateFromThePreviousOne() async {
    // A second `.eventFound`/`.recording` cycle on the same long-lived
    // coordinator (as `AppCoordinator` reuses one `SensingCoordinator`
    // across `startScan()`/`finishScan()`) must not leak the previous
    // event's binding state into the new one.
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      sensingCryptography: BarnardBackedBindingCryptography()
    )
    coordinator.startSensing(demoEvent: .demoSample)
    await coordinator.waitForDemoSequenceToFinish()
    guard let messageHex = coordinator.beginBinding(walletAddress: realWalletAddress, chainId: testChainId) else {
      XCTFail("expected beginBinding to succeed")
      return
    }
    guard case .bound = coordinator.completeBinding(
      walletAddress: realWalletAddress,
      walletSignatureHex: TestWallet.sign(messageHex: messageHex)
    ) else {
      XCTFail("expected a BindingRecord")
      return
    }
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
    // Real crypto: `DemoWalletConnector` now produces a genuinely valid
    // wallet signature (beid#316), so `completeBinding`'s piece (b)
    // verification against a fake owner-key double would otherwise reject
    // this end-to-end record.
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      sensingCryptography: BarnardBackedBindingCryptography()
    )
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

    guard case .bound(let record) = coordinator.completeBinding(
      walletAddress: live.address,
      walletSignatureHex: signatureHex
    ) else {
      XCTFail("expected a BindingRecord")
      return
    }

    XCTAssertEqual(
      record.walletAddress,
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
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      sensingCryptography: BarnardBackedBindingCryptography()
    )
    let event = EventSession(id: "TEST-BINDING", name: "Test Binding Event", venue: nil)
    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    let hintAddress = "0x1111111111111111111111111111111111111111"
    // A genuinely valid address (unlike the discarded stale signature
    // below, this one must actually verify — it's what the *final*
    // `completeBinding` call at the bottom of this test checks).
    let liveAddress = TestWallet.address
    let connector = FakeRestoredHintConnector()
    connector.connectAndSignResult = .success((
      LiveWalletAddress.fromConnectorResult(address: liveAddress, chainId: testChainId),
      testWalletSignatureHex
    ))

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

    // A real signature for the freshly rebuilt message — piece (b)'s
    // `verifyWalletBinding` recovers the actual signer, so a canned fake
    // (as `staleMessageHex`'s discarded signature above still is) would no
    // longer satisfy the final `completeBinding` call below.
    connector.requestPersonalSignResult = .success(TestWallet.sign(messageHex: freshMessageHex))

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

    guard case .bound(let record) = coordinator.completeBinding(
      walletAddress: live.address,
      walletSignatureHex: signatureHex
    ) else {
      XCTFail("expected a BindingRecord")
      return
    }

    XCTAssertEqual(
      record.walletAddress,
      liveAddress,
      "the persisted record must carry the wallet's actual address, never the stale hint"
    )
  }
}

/// Synthetic EOA wallet keypairs for tests that need genuinely valid wallet
/// signatures — `testWalletSignatureHex` above is not a real signature, it
/// only satisfies decode/shape checks and never Barnard's own signature
/// recovery. Derived deterministically via `BarnardCoreSigning
/// .deriveOwnerKeyPair` purely because that's the existing fixed-seed-to-
/// keypair primitive of the right shape already used in this test target
/// (`SelfProofCheckpointRecoveryTests.swift`'s `BarnardBackedSelfProofCryptography`)
/// — these are ordinary synthetic test wallets, not beid owner keys.
private enum TestWallet {
  private static let keyPair = BarnardCoreSigning.deriveOwnerKeyPair(
    accountSecret: [UInt8](repeating: 0x13, count: 32)
  )
  /// A second, distinct keypair for the "signed by the wrong key" test —
  /// its own derived address is never used, only its private key, to
  /// produce a signature that recovers to an address other than
  /// `TestWallet.address`.
  private static let wrongKeyPair = BarnardCoreSigning.deriveOwnerKeyPair(
    accountSecret: [UInt8](repeating: 0x17, count: 32)
  )

  static let address: String = ethereumAddress(for: keyPair)

  /// Signs `messageHex` (the `0x`-prefixed hex `beginBinding` returns) with
  /// `keyPair`'s private key, producing the 65-byte wallet-format signature
  /// (`r ‖ s ‖ v`) `BarnardCoreSigning.verifyWalletBinding` expects — the
  /// signature a wallet that actually owns `address` would have produced.
  static func sign(messageHex: String) -> String {
    sign(messageHex: messageHex, privateKey: keyPair.privateKey)
  }

  /// Same signing recipe, but with `wrongKeyPair`'s private key — the
  /// signature a DIFFERENT wallet would have produced, so it never
  /// recovers to `address`.
  static func signWrong(messageHex: String) -> String {
    sign(messageHex: messageHex, privateKey: wrongKeyPair.privateKey)
  }

  private static func sign(messageHex: String, privateKey: [UInt8]) -> String {
    let digest = BarnardCoreSigning.computeEip191Digest(messageBytes: decodeHex(messageHex))
    let signature = BarnardCoreSigning.signRecoverable(privateKey: privateKey, messageHash32: digest)
    let signatureBytes = signature.r + signature.s + [UInt8(signature.v)]
    return "0x" + signatureBytes.map { String(format: "%02x", $0) }.joined()
  }

  private static func ethereumAddress(for pair: BarnardCoreSigningKeyPair) -> String {
    guard let addressBytes = BarnardCoreSigning.ethereumAddress(publicKeyCompressed: pair.publicKeyCompressed) else {
      preconditionFailure("TestWallet's fixed keypair must yield a valid Ethereum address")
    }
    return "0x" + addressBytes.map { String(format: "%02x", $0) }.joined()
  }

  private static func decodeHex(_ string: String) -> [UInt8] {
    let stripped = string.hasPrefix("0x") || string.hasPrefix("0X")
      ? String(string.dropFirst(2))
      : string
    var bytes = [UInt8]()
    bytes.reserveCapacity(stripped.count / 2)
    var index = stripped.startIndex
    while index < stripped.endIndex {
      let next = stripped.index(index, offsetBy: 2)
      guard let byte = UInt8(stripped[index..<next], radix: 16) else {
        preconditionFailure("messageHex must be well-formed hex")
      }
      bytes.append(byte)
      index = next
    }
    return bytes
  }
}

/// A `SensingCryptography` facade whose owner-key half is backed by a real
/// `OwnerKeyProvider` over a fixed seed, so `signWalletAcknowledgement`
/// produces signatures `BarnardCoreSigning.verifyWalletBinding` actually
/// accepts — unlike `DeterministicSensingCryptography`, which returns a
/// fabricated, non-cryptographic owner public key and acknowledgement.
/// Mirrors `SelfProofCheckpointRecoveryTests.swift`'s
/// `BarnardBackedSelfProofCryptography`, except `signWalletAcknowledgement`
/// actually delegates to the real `ownerKeyProvider` here — that suite's
/// double returns `nil` there because it never needs it.
private final class BarnardBackedBindingCryptography: SensingCryptography {
  private let ownerKeyProvider = OwnerKeyProvider(
    keyStorage: FixedSeedBindingKeyStorage(seed: Data(repeating: 0x21, count: 32)),
    randomSource: NeverCalledBindingRandomSource()
  )
  private let fixedEventSigningPublicKey = Data([0x02] + [UInt8](repeating: 0x09, count: 32))

  func eventSigningPublicKey(eventCode: String) -> Data {
    fixedEventSigningPublicKey
  }

  func ownerPublicKey() throws -> Data {
    try ownerKeyProvider.publicKeyCompressed()
  }

  func signWindowReport(eventCode: String, bytes: Data) -> SensingRecoverableSignature {
    SensingRecoverableSignature(r: Data(repeating: 0, count: 32), s: Data(repeating: 0, count: 32), v: 0)
  }

  func signSelfProof(
    eventIdHash: Data,
    eventSigningPublicKey: Data,
    eninStart: UInt64,
    eninEnd: UInt64
  ) throws -> SensingRecoverableSignature? {
    nil
  }

  func signWalletAcknowledgement(
    walletAddress: Data,
    walletSignature: Data
  ) throws -> SensingRecoverableSignature? {
    try ownerKeyProvider.signWalletAcknowledgement(
      walletAddress: walletAddress,
      walletSignature: walletSignature
    ).map { SensingRecoverableSignature(barnardCore: $0) }
  }
}

private struct FixedSeedBindingKeyStorage: OwnerKeySeedResolving {
  let seed: Data

  func bytes(forKey key: String) -> [UInt8]? {
    Array(seed)
  }

  func setBytes(_ bytes: [UInt8], forKey key: String) {}
  func resolveSeed(forKey key: String, randomSource: any OwnerKeyRandomBytesGenerating) throws -> [UInt8] { Array(seed) }
}

private struct NeverCalledBindingRandomSource: BarnardCoreRandomSource, OwnerKeyRandomBytesGenerating {
  func randomBytes(count: Int) -> [UInt8] {
    XCTFail("randomSource must not be used when a seed is already stored")
    return [UInt8](repeating: 0, count: count)
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

  func cancelPendingOperation() {
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
    // Well-formed hex — beid#316: `requestPersonalSign` now actually
    // decodes and signs the message, so (unlike the placeholder
    // `"0xMESSAGE"` used elsewhere in this file for calls that never reach
    // signing) this needs to be real hex, though its content is otherwise
    // arbitrary for this test's purpose (dispatch flag + success shape).
    let result = await connector.requestPersonalSign(messageHex: "0x1234abcd") {
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
    // Well-formed hex, for the same reason as the `requestPersonalSign`
    // test above (beid#316: `connectAndSign` now actually signs it too).
    let result = await connector.connectAndSign(messageHex: "0x1234abcd") {
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
