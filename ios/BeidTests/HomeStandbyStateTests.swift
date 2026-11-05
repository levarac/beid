// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

final class HomeStandbyStateTests: XCTestCase {
  func testFallbackUsesTheThirtySecondBoundary() {
    var state = HomeStandbyState()
    state.update(isEnabled: true, hasCandidates: false, now: 100)
    XCTAssertFalse(state.offersCodeEntry(at: 129))
    XCTAssertTrue(state.offersCodeEntry(at: 130))
  }

  func testCandidateArrivalCancelsAndRemovalRestartsTheInterval() {
    var state = HomeStandbyState()
    state.update(isEnabled: true, hasCandidates: false, now: 100)
    state.update(isEnabled: true, hasCandidates: true, now: 129)
    XCTAssertFalse(state.offersCodeEntry(at: 200))
    state.update(isEnabled: true, hasCandidates: false, now: 300)
    XCTAssertFalse(state.offersCodeEntry(at: 329))
    XCTAssertTrue(state.offersCodeEntry(at: 330))
  }

  func testLeavingHomeOrPausingDiscoveryDiscardsTheInterval() {
    var state = HomeStandbyState()
    state.update(isEnabled: true, hasCandidates: false, now: 100)
    state.update(isEnabled: false, hasCandidates: false, now: 129)
    XCTAssertFalse(state.offersCodeEntry(at: 500))
    state.update(isEnabled: true, hasCandidates: false, now: 600)
    XCTAssertFalse(state.offersCodeEntry(at: 629))
    XCTAssertTrue(state.offersCodeEntry(at: 630))
  }

  func testRepeatedUpdatesDoNotRestartAnUninterruptedInterval() {
    var state = HomeStandbyState()
    state.update(isEnabled: true, hasCandidates: false, now: 100)
    state.update(isEnabled: true, hasCandidates: false, now: 115)
    state.update(isEnabled: true, hasCandidates: false, now: 129)
    XCTAssertTrue(state.offersCodeEntry(at: 130))
    XCTAssertEqual(state.elapsed(at: 130), 30)
  }

  func testNoFallbackBeforeDiscoveryBeginsOrWhileCandidatesExist() {
    var state = HomeStandbyState()
    XCTAssertFalse(state.offersCodeEntry(at: 300))
    state.update(isEnabled: true, hasCandidates: true, now: 100)
    XCTAssertFalse(state.offersCodeEntry(at: 300))
    XCTAssertEqual(state.elapsed(at: 300), 0)
  }
}
