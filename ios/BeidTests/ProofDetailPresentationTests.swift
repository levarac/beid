// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

final class ProofDetailPresentationTests: XCTestCase {
  func testOnlyAMatchingSelfProofDeterminesOnDeviceSignatureEvidence() {
    let recorded = makePresentation(selfProof: false, binding: false)
    XCTAssertEqual(recorded.status, "Recorded on device")
    XCTAssertEqual(recorded.signature, "NOT AVAILABLE")

    let selfSigned = makePresentation(selfProof: true, binding: false)
    XCTAssertEqual(selfSigned.status, "Sealed")
    XCTAssertEqual(selfSigned.signature, "Self-signed on device")

    let bound = makePresentation(selfProof: true, binding: true)
    XCTAssertEqual(bound.status, "Sealed")
    XCTAssertEqual(bound.signature, "Self-signed on device")

    // A binding is not itself a SelfProofRecord. These are deliberately
    // independent lookups, even when historical data is incomplete.
    let bindingOnly = makePresentation(selfProof: false, binding: true)
    XCTAssertEqual(bindingOnly.status, "Recorded on device")
    XCTAssertEqual(bindingOnly.signature, "NOT AVAILABLE")
    for value in [recorded, selfSigned, bound, bindingOnly] {
      XCTAssertFalse(value.signature.localizedCaseInsensitiveContains("wallet"))
      XCTAssertFalse(value.signature.localizedCaseInsensitiveContains("bind"))
      XCTAssertFalse(value.signature.localizedCaseInsensitiveContains("bound"))
      XCTAssertNil(value.incompleteReason)
    }
  }

  func testDiscardedSelfProofShowsAnIncompleteRecording() {
    for selfProof in [false, true] {
      for binding in [false, true] {
        let value = makePresentation(selfProof: selfProof, binding: binding, incomplete: true)
        XCTAssertEqual(value.status, "Recording incomplete")
        XCTAssertEqual(value.incompleteReason,
                       "This recording could not be signed because its signing key changed or could not be verified. The record is kept on this phone.")
        XCTAssertEqual(value.signature, "NOT AVAILABLE")
        XCTAssertFalse(value.isSealedOnDevice)
        let ladder = RecordSendingLadderPresentation(hasSelfProof: value.isSealedOnDevice, records: nil)
        XCTAssertEqual(ladder.rungs[0].title, "RECORDED ON THIS PHONE")
        XCTAssertFalse(ladder.rungs[0].reached)
      }
    }
  }

  func testOrdinarySignedAndUnsignedRecordsHaveNoIncompleteWarning() {
    for selfProof in [false, true] {
      for binding in [false, true] {
        let value = makePresentation(selfProof: selfProof, binding: binding)
        XCTAssertNil(value.incompleteReason)
        XCTAssertEqual(value.isSealedOnDevice, selfProof)
      }
    }
  }

  func testMissingAggregateIsUnavailableRatherThanZero() {
    let value = makePresentation(
      selfProof: false, binding: false, devices: nil, windows: nil
    )
    XCTAssertEqual(value.withValue, "Not yet available")
    XCTAssertEqual(value.signature, "NOT AVAILABLE")
    XCTAssertFalse(value.withValue.contains("0 devices"))
    XCTAssertFalse(value.withValue.contains("0 windows"))
  }

  func testMultiSessionGroupDoesNotClaimRepresentativeCountsForWholeEvent() {
    let oneSession = makePresentation(
      selfProof: true, binding: false, devices: 15, windows: 6
    )
    XCTAssertEqual(oneSession.withValue, "15 devices · 6 windows")

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
    XCTAssertEqual(singular.withValue, "1 device · 1 window")

    let zero = makePresentation(
      selfProof: true, binding: false, devices: 0, windows: 0
    )
    XCTAssertEqual(zero.withValue, "0 devices · 0 windows")
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
    sessions: Int = 1,
    incomplete: Bool = false
  ) -> ProofDetailPresentation {
    ProofDetailPresentation(
      method: "Bluetooth Sensing",
      hasSelfProof: selfProof,
      hasBinding: binding,
      deviceCount: devices,
      windowCount: windows,
      sessionCount: sessions,
      selfProofDiscardedForKeyChange: incomplete
    )
  }
}
