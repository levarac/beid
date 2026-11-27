// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

final class SensingWindowTimelineTests: XCTestCase {
  func testDemoUsesCurrentSyntheticWindowInsteadOfWallClock() {
    let now = Date(timeIntervalSince1970: 1_800_000_017)
    XCTAssertEqual(SensingWindowTimeline.endIndex(now: now, lastObserved: 1, demoCurrent: 1, windowSeconds: 300), 1)
    XCTAssertEqual(SensingWindowTimeline.endIndex(now: now, lastObserved: 1, demoCurrent: 2, windowSeconds: 300), 2)
  }

  func testSealedDemoLabelsUseFirstSightingAsWallTimeAnchor() {
    let first = Date(timeIntervalSince1970: 1_800_000_017)
    let result = SensingWindowTimeline.oldestStart(
      end: 6, firstObserved: 0, firstSighting: first, isDemo: true, windowSeconds: 300, slotCount: 6
    )
    XCTAssertEqual(result?.timeIntervalSince1970, 1_800_000_300)
  }

  func testProductionAndFrozenFixturesRemainWallClockBased() {
    let now = Date(timeIntervalSince1970: 300 * 100 + 17)
    XCTAssertEqual(SensingWindowTimeline.endIndex(now: now, lastObserved: 7, demoCurrent: nil, windowSeconds: 300), 100)
    XCTAssertEqual(SensingWindowTimeline.endIndex(now: nil, lastObserved: 7, demoCurrent: nil, windowSeconds: 300), 7)
    XCTAssertNil(SensingWindowTimeline.endIndex(now: nil, lastObserved: nil, demoCurrent: nil, windowSeconds: 300))
    let oldest = SensingWindowTimeline.oldestStart(
      end: 100, firstObserved: 95, firstSighting: now, isDemo: false, windowSeconds: 300, slotCount: 6
    )
    XCTAssertEqual(oldest?.timeIntervalSince1970, 95 * 300)
    XCTAssertNil(SensingWindowTimeline.oldestStart(
      end: 0, firstObserved: nil, firstSighting: nil, isDemo: true, windowSeconds: 300, slotCount: 6
    ))
  }
}
