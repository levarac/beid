// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

/// beid#230 — rejoining a previously joined event by tapping a past-events
/// row, using the `eventCode` already stored on a `Proof` (beid#137) instead
/// of retyping it. Covers `AppCoordinator.rejoinPastEvent(code:)` only;
/// `EventGrouping.pastEvents(from:)` (the derivation feeding that list) is
/// covered in `EventGroupingTests`.
@MainActor
final class EventRejoinTests: XCTestCase {
  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: "barnard.eventCode")
    super.tearDown()
  }

  func testRejoinPastEventJoinsWhenNothingIsCurrentlyJoined() {
    let coordinator = AppCoordinator()

    coordinator.rejoinPastEvent(code: "beid-test-event")

    XCTAssertEqual(coordinator.sensingCoordinator.joinedEventCode, "beid-test-event")
  }

  /// beid#226 is resolved (DECISIONS 2026-08-20): `rejoinPastEvent` now
  /// shares `attemptJoinEvent`'s normalization (trim surrounding
  /// whitespace, then fold case) instead of passing `code` through
  /// verbatim. This keeps rejoin and a fresh join of the same typed text
  /// deriving the same RPID — including for a `Proof.eventCode` stored
  /// before this fix, which may still carry surrounding whitespace or
  /// mixed case from the old, platform-diverging behavior.
  func testRejoinPastEventNormalizesTheStoredCode() {
    let coordinator = AppCoordinator()

    coordinator.rejoinPastEvent(code: "  ETHTOKYO  ")

    XCTAssertEqual(
      coordinator.sensingCoordinator.joinedEventCode, "ethtokyo",
      "rejoinPastEvent must normalize through the same shared decision attemptJoinEvent uses."
    )
  }

  func testRejoinPastEventIsANoOpWhileAnEventIsAlreadyJoined() {
    let coordinator = AppCoordinator()
    coordinator.rejoinPastEvent(code: "first-event")
    XCTAssertEqual(coordinator.sensingCoordinator.joinedEventCode, "first-event")

    coordinator.rejoinPastEvent(code: "second-event")

    XCTAssertEqual(
      coordinator.sensingCoordinator.joinedEventCode, "first-event",
      "rejoinPastEvent must not replace an already-joined event — matches the single-slot invariant Join Event already enforces (EventMembershipUITests)."
    )
  }

  func testRejoinPastEventAfterLeavingJoinsTheNewCode() {
    let coordinator = AppCoordinator()
    coordinator.rejoinPastEvent(code: "first-event")
    coordinator.leaveEvent()
    XCTAssertNil(coordinator.sensingCoordinator.joinedEventCode)

    coordinator.rejoinPastEvent(code: "second-event")

    XCTAssertEqual(coordinator.sensingCoordinator.joinedEventCode, "second-event")
  }
}
