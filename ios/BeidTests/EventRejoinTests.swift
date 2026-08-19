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

  /// beid#226 is open (event-code normalization differs iOS/Android); this
  /// task must not add a second normalization rule on top of the one
  /// `attemptJoinEvent` already applies at first-join time. A stored
  /// `Proof.eventCode` was already normalized once, so replay must be
  /// verbatim — proven here by passing a string `attemptJoinEvent` would
  /// have altered (padding whitespace) and asserting it survives untouched.
  func testRejoinPastEventDoesNotNormalizeTheCodeASecondTime() {
    let coordinator = AppCoordinator()

    coordinator.rejoinPastEvent(code: "  beid-test-event  ")

    XCTAssertEqual(
      coordinator.sensingCoordinator.joinedEventCode, "  beid-test-event  ",
      "rejoinPastEvent must pass the stored eventCode verbatim, with no .trimmingCharacters or other normalization."
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
