// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

final class SensingWindowBarsTests: XCTestCase {
  func testSixSlotsEndAtTheCurrentWallClockWindow() {
    let now = Date(timeIntervalSince1970: 300 * 100 + 17)
    XCTAssertEqual(SensingWindowBars.endWindowIndex(now: now, lastObservedWindowIndex: 7), 100)
    XCTAssertEqual(SensingWindowBars.endWindowIndex(now: nil, lastObservedWindowIndex: 7), 7)
    XCTAssertNil(SensingWindowBars.endWindowIndex(now: nil, lastObservedWindowIndex: nil))

    let slots = SensingWindowBars.slotCounts(
      peerCountsByWindow: [95: 1, 96: 2, 97: 3, 98: 4, 99: 5, 100: 6], endWindowIndex: 100
    )
    XCTAssertEqual(slots, [1, 2, 3, 4, 5, 6])
  }

  func testWindowWithoutDetectionStaysAThinSlot() {
    let slots = SensingWindowBars.slotCounts(
      peerCountsByWindow: [96: 2, 98: 4], endWindowIndex: 100
    )
    XCTAssertEqual(slots, [nil, 2, nil, 4, nil, nil])
    XCTAssertEqual(SensingWindowBars.barHeight(peerCount: nil), 4)
    XCTAssertEqual(SensingWindowBars.barHeight(peerCount: 0), 4)
    XCTAssertEqual(SensingWindowBars.barHeight(peerCount: 3), 10)
    XCTAssertEqual(SensingWindowBars.barHeight(peerCount: 100), 40)
  }

  func testSeventhWindowShiftsSlotsLeftAndDropsTheOldest() {
    let counts: [Int64: Int] = [95: 1, 96: 2, 97: 3, 98: 4, 99: 5, 100: 6, 101: 7]
    XCTAssertEqual(
      SensingWindowBars.slotCounts(peerCountsByWindow: counts, endWindowIndex: 100),
      [1, 2, 3, 4, 5, 6]
    )
    XCTAssertEqual(
      SensingWindowBars.slotCounts(peerCountsByWindow: counts, endWindowIndex: 101),
      [2, 3, 4, 5, 6, 7]
    )
  }

  func testCurrentWindowWithoutDetectionIsStillTheRightmostSlotAtBaseline() {
    let slots = SensingWindowBars.slotCounts(peerCountsByWindow: [98: 4], endWindowIndex: 100)
    XCTAssertNil(slots[5])
    XCTAssertEqual(SensingWindowBars.barHeight(peerCount: slots[5]), 4)
  }

  func testLeftLabelIsTheStartOfTheOldestVisibleWindow() {
    XCTAssertEqual(
      SensingWindowBars.oldestWindowStart(endWindowIndex: 100).timeIntervalSince1970,
      95 * 300
    )
  }
}
