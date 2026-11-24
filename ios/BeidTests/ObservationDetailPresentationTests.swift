// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import XCTest
@testable import Beid

final class ObservationDetailPresentationTests: XCTestCase {
  func testSparseWindowRowsRemainSparseAndSessionDevicesAreNotSummedBars() throws {
    let input = BeidSharedKit.aggregation.createAggregationObservationInput()
    XCTAssertTrue(BeidSharedKit.aggregation.addAggregationObservation(
      input: input, windowIndex: 100, peerKey: "window-100-a",
      displayId: "same-device", mutual: false
    ))
    XCTAssertTrue(BeidSharedKit.aggregation.addAggregationObservation(
      input: input, windowIndex: 102, peerKey: "window-102-a",
      displayId: "same-device", mutual: false
    ))
    XCTAssertTrue(BeidSharedKit.aggregation.addAggregationObservation(
      input: input, windowIndex: 102, peerKey: "window-102-b",
      displayId: nil, mutual: false
    ))
    let aggregate = BeidSharedKit.aggregation.aggregateObservationsForSession(
      input: input, windowsPerBand: 1
    )
    let presentation = try XCTUnwrap(ObservationDetailPresentation(aggregate: aggregate))

    XCTAssertEqual(presentation.deviceCount, 1)
    XCTAssertEqual(presentation.windowCount, 2)
    XCTAssertEqual(presentation.windows.map(\.windowIndex), [100, 102])
    XCTAssertEqual(presentation.windows.map(\.peerCount), [1, 2])
    XCTAssertEqual(presentation.windows.map(\.gapBefore), [0, 1])
    XCTAssertEqual(presentation.windows.count, 2, "No synthetic zero bar fills window 101")
  }

  func testMissingSnapshotDoesNotBecomeAnEmptyMeasuredChart() {
    XCTAssertNil(ObservationDetailPresentation(aggregate: nil))
  }

  func testSelectedSigilUsesObservedRanksAndLeavesFullInputUnchanged() throws {
    let observations = BeidSharedKit.aggregation.createAggregationObservationInput()
    for (window, peer) in [(Int64(100), "a"), (102, "a"), (109, "b")] {
      XCTAssertTrue(BeidSharedKit.aggregation.addAggregationObservation(
        input: observations, windowIndex: window, peerKey: peer,
        displayId: peer, mutual: false
      ))
    }
    let aggregate = BeidSharedKit.aggregation.aggregateObservationsForSession(
      input: observations, windowsPerBand: 1
    )
    let presentation = try XCTUnwrap(ObservationDetailPresentation(aggregate: aggregate))
    let source = BeidSharedKit.sigil.createSigilInput(windowCount: 3)
    XCTAssertTrue(BeidSharedKit.sigil.addSigilPresence(input: source, peerKey: "a", windowIndex: 0, presence: 1))
    XCTAssertTrue(BeidSharedKit.sigil.addSigilPresence(input: source, peerKey: "a", windowIndex: 1, presence: 1))
    XCTAssertTrue(BeidSharedKit.sigil.addSigilPresence(input: source, peerKey: "b", windowIndex: 2, presence: 1))
    let proofID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    let selected = try XCTUnwrap(presentation.selectedSigilInput(
      storedInput: source, storedProofID: proofID, selectedProofID: proofID, throughWindowIndex: 102
    ))
    XCTAssertFalse(selected === source)
    let layout = BeidSharedKit.sigil.layoutSigil(input: selected, size: 200, ground: .DISC)
    XCTAssertEqual(layout.windowCount, 2)
    XCTAssertEqual(layout.detectedPeerCount, 1)
    XCTAssertEqual(layout.mutualPeerCount, 0)
    XCTAssertEqual(source.windowCount, 3)
    XCTAssertEqual(BeidSharedKit.sigil.layoutSigil(input: source, size: 200, ground: .DISC).detectedPeerCount, 2)
    XCTAssertNil(presentation.selectedSigilInput(
      storedInput: source, storedProofID: proofID, selectedProofID: UUID(), throughWindowIndex: 102
    ))
    XCTAssertNil(presentation.selectedSigilInput(
      storedInput: source, storedProofID: proofID, selectedProofID: proofID, throughWindowIndex: 101
    ))
    XCTAssertNil(presentation.selectedSigilInput(
      storedInput: BeidSharedKit.sigil.createSigilInput(windowCount: 2),
      storedProofID: proofID, selectedProofID: proofID, throughWindowIndex: 102
    ))
    XCTAssertNil(presentation.selectedSigilInput(
      storedInput: nil, storedProofID: proofID, selectedProofID: proofID, throughWindowIndex: 102
    ))
  }
}
