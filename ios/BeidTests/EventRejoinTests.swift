// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

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
    let coordinator = makeApp()

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
    let coordinator = makeApp()

    coordinator.rejoinPastEvent(code: "  ETHTOKYO  ")

    XCTAssertEqual(
      coordinator.sensingCoordinator.joinedEventCode, "ethtokyo",
      "rejoinPastEvent must normalize through the same shared decision attemptJoinEvent uses."
    )
  }

  func testRejoinPastEventIsANoOpWhileAnEventIsAlreadyJoined() {
    let coordinator = makeApp()
    coordinator.rejoinPastEvent(code: "first-event")
    XCTAssertEqual(coordinator.sensingCoordinator.joinedEventCode, "first-event")

    coordinator.rejoinPastEvent(code: "second-event")

    XCTAssertEqual(
      coordinator.sensingCoordinator.joinedEventCode, "first-event",
      "rejoinPastEvent must not replace an already-joined event — matches the single-slot invariant Join event already enforces (EventMembershipUITests)."
    )
  }

  /// A joined code outlives STOP, so the guard keys on an active session:
  /// after stopping, rejoining the same or another event works and starts
  /// sensing again.
  func testRejoinAfterStoppingTheSessionJoinsAgainAndStartsSensing() {
    let coordinator = makeApp()
    coordinator.rejoinPastEvent(code: "first-event")
    XCTAssertEqual(coordinator.sensingCoordinator.phase, .sensing)
    _ = coordinator.sensingCoordinator.stopSensing()
    coordinator.scanPresented = false
    XCTAssertEqual(coordinator.sensingCoordinator.phase, .idle)
    XCTAssertTrue(coordinator.sensingCoordinator.canSelectEventToJoin)

    coordinator.rejoinPastEvent(code: "first-event")

    XCTAssertEqual(coordinator.sensingCoordinator.phase, .sensing)
    XCTAssertTrue(coordinator.scanPresented)
    XCTAssertEqual(coordinator.sensingCoordinator.joinedEventCode, "first-event")

    _ = coordinator.sensingCoordinator.stopSensing()
    coordinator.rejoinPastEvent(code: "second-event")
    XCTAssertEqual(coordinator.sensingCoordinator.joinedEventCode, "second-event")
    XCTAssertEqual(coordinator.sensingCoordinator.phase, .sensing)
    _ = coordinator.sensingCoordinator.reset()
  }

  func testSelectingAnEventIsUnavailableWhileASessionIsActive() {
    let coordinator = makeApp()
    XCTAssertTrue(coordinator.sensingCoordinator.canSelectEventToJoin)
    coordinator.rejoinPastEvent(code: "first-event")
    XCTAssertFalse(coordinator.sensingCoordinator.canSelectEventToJoin)
    _ = coordinator.sensingCoordinator.reset()
  }

  func testStoppedEventIsNoLongerCurrentWhileJoinedCodeIsRetained() {
    let coordinator = makeApp()
    let sensing = coordinator.sensingCoordinator
    XCTAssertNil(sensing.currentEventCode)
    coordinator.rejoinPastEvent(code: "first-event")
    XCTAssertEqual(sensing.currentEventCode, "first-event")

    _ = sensing.stopSensing()

    XCTAssertEqual(sensing.phase, .idle)
    XCTAssertEqual(sensing.joinedEventCode, "first-event")
    XCTAssertNil(sensing.currentEventCode)
  }

  func testSuccessfulRejoinStartsSensingAndShowsItFromTheNowTab() {
    let coordinator = makeApp()
    coordinator.selectedHomeTab = .records
    coordinator.accountSheetPresented = true
    coordinator.eventCodeEntrySheetPresented = true
    XCTAssertEqual(coordinator.sensingCoordinator.phase, .idle)

    coordinator.rejoinPastEvent(code: "beid-test-event")

    XCTAssertEqual(coordinator.sensingCoordinator.phase, .sensing)
    XCTAssertTrue(coordinator.scanPresented)
    XCTAssertEqual(coordinator.selectedHomeTab, .now)
    XCTAssertFalse(coordinator.accountSheetPresented)
    XCTAssertFalse(coordinator.eventCodeEntrySheetPresented)
    XCTAssertNil(coordinator.sealedSnapshot)
    XCTAssertNil(coordinator.proofCollectedSnapshot)
    _ = coordinator.sensingCoordinator.reset()
  }

  func testRejoinThatIsRefusedDoesNotPresentSensingAgain() {
    let coordinator = makeApp()
    coordinator.rejoinPastEvent(code: "first-event")
    coordinator.scanPresented = false

    coordinator.rejoinPastEvent(code: "second-event")

    XCTAssertFalse(coordinator.scanPresented, "a no-op rejoin must not present the sensing screen")
    XCTAssertEqual(coordinator.sensingCoordinator.joinedEventCode, "first-event")
    _ = coordinator.sensingCoordinator.reset()
  }

  func testSuccessfulAccountSheetJoinStartsSensingAndShowsItFromTheNowTab() {
    let coordinator = makeApp()
    coordinator.selectedHomeTab = .records
    coordinator.accountSheetPresented = true
    coordinator.eventCodeEntrySheetPresented = true

    let error = coordinator.joinEventFromAccountSheet(code: "beid-test-event")

    XCTAssertNil(error)
    XCTAssertEqual(coordinator.sensingCoordinator.phase, .sensing)
    XCTAssertTrue(coordinator.scanPresented)
    XCTAssertEqual(coordinator.selectedHomeTab, .now)
    XCTAssertFalse(coordinator.accountSheetPresented)
    XCTAssertFalse(coordinator.eventCodeEntrySheetPresented)
    XCTAssertNil(coordinator.sealedSnapshot)
    _ = coordinator.sensingCoordinator.reset()
  }

  func testFailedAccountSheetJoinKeepsTheSheetsAndStaysIdle() {
    let coordinator = makeApp()
    coordinator.accountSheetPresented = true
    coordinator.eventCodeEntrySheetPresented = true

    let error = coordinator.joinEventFromAccountSheet(code: "   ")

    XCTAssertEqual(error, .emptyCode)
    XCTAssertEqual(coordinator.sensingCoordinator.phase, .idle)
    XCTAssertFalse(coordinator.scanPresented)
    XCTAssertTrue(coordinator.accountSheetPresented)
    XCTAssertTrue(coordinator.eventCodeEntrySheetPresented)
  }

  private func makeApp() -> AppCoordinator {
    let sensing = makeIsolatedSensingCoordinator(for: self, eventJoinControl: RecordingEventJoinControl())
    sensing.useDemoEventMode = false
    let defaults = UserDefaults(suiteName: "EventRejoinTests.\(UUID().uuidString)")!
    return AppCoordinator(sensingCoordinator: sensing, registryClient: nil, userDefaults: defaults)
  }
}
