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
}
