// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

final class ProofDetailPresentationTests: XCTestCase {
  func testOnlyAMatchingSelfProofCanSealAndOnlyABindingCanClaimWallet() {
    let recorded = makePresentation(selfProof: false, binding: false)
    XCTAssertEqual(recorded.status, "Recorded on device")
    XCTAssertEqual(recorded.signature, "Not yet available")

    let selfSigned = makePresentation(selfProof: true, binding: false)
    XCTAssertEqual(selfSigned.status, "Sealed")
    XCTAssertEqual(selfSigned.signature, "Self-signed on device")

    let bound = makePresentation(selfProof: true, binding: true)
    XCTAssertEqual(bound.status, "Sealed")
    XCTAssertEqual(bound.signature, "Bound to wallet")

    // A binding is not itself a SelfProofRecord. These are deliberately
    // independent lookups, even when historical data is incomplete.
    let bindingOnly = makePresentation(selfProof: false, binding: true)
    XCTAssertEqual(bindingOnly.status, "Recorded on device")
    XCTAssertEqual(bindingOnly.signature, "Bound to wallet")
  }

  func testMissingAggregateIsUnavailableRatherThanZero() {
    let value = makePresentation(
      selfProof: false, binding: false, devices: nil, windows: nil
    )
    XCTAssertEqual(value.withValue, "Not yet available")
    XCTAssertFalse(value.withValue.contains("0 peers"))
    XCTAssertFalse(value.withValue.contains("0 windows"))
  }

  func testMultiSessionGroupDoesNotClaimRepresentativeCountsForWholeEvent() {
    let oneSession = makePresentation(
      selfProof: true, binding: false, devices: 15, windows: 6
    )
    XCTAssertEqual(oneSession.withValue, "15 peers · 6 windows")

    let multipleSessions = makePresentation(
      selfProof: true, binding: false, devices: 15, windows: 6, sessions: 3
    )
    XCTAssertEqual(multipleSessions.withValue, "See each session")
    XCTAssertFalse(multipleSessions.withValue.contains("15"))
  }

  func testWithValueUsesSingularAndZeroPluralForms() {
    let singular = makePresentation(
      selfProof: true, binding: false, devices: 1, windows: 1
    )
    XCTAssertEqual(singular.withValue, "1 peer · 1 window")

    let zero = makePresentation(
      selfProof: true, binding: false, devices: 0, windows: 0
    )
    XCTAssertEqual(zero.withValue, "0 peers · 0 windows")
  }

  func testRecordIDShorthandHasAFixedLiteralVectorOnBothScreens() {
    let id = UUID(uuidString: "9C410000-0000-4000-8000-00000000E2A7")!
    XCTAssertEqual(RecordIDDisplay.abbreviated(id), "9c41…e2a7")
    let proof = Proof(id: id, eventName: "Event", date: Date(), peersVerified: 1)
    let collected = ProofCollectedSnapshot(
      proof: proof, detectedPeerCount: 1, observedWindowCount: nil
    )
    XCTAssertEqual(collected.shortRecordID, "9c41…e2a7")
  }

  private func makePresentation(
    selfProof: Bool,
    binding: Bool,
    devices: Int? = nil,
    windows: Int? = nil,
    sessions: Int = 1
  ) -> ProofDetailPresentation {
    ProofDetailPresentation(
      method: "Bluetooth Sensing",
      hasSelfProof: selfProof,
      hasBinding: binding,
      deviceCount: devices,
      windowCount: windows,
      sessionCount: sessions
    )
  }
}
