// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

@MainActor
final class EventCodeJoinTests: XCTestCase {
  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: "barnard.eventCode")
    super.tearDown()
  }

  func testSkipWalletForEventCodeRoutesToEventCodeEntry() {
    let coordinator = AppCoordinator()
    coordinator.screen = .walletConnect

    coordinator.skipWalletForEventCode()

    XCTAssertEqual(coordinator.screen, .eventCodeEntry)
  }

  func testJoinEventWithEmptyCodeReturnsValidationErrorAndDoesNotAdvance() {
    let coordinator = AppCoordinator()
    coordinator.screen = .eventCodeEntry

    let error = coordinator.joinEvent(code: "   ")

    XCTAssertEqual(error, .emptyCode)
    XCTAssertEqual(coordinator.screen, .eventCodeEntry)
    XCTAssertNil(coordinator.sensingCoordinator.joinedEventCode)
  }

  func testJoinEventWithValidCodeAdvancesToBluetoothPermissionWithoutWallet() {
    let coordinator = AppCoordinator()
    coordinator.screen = .eventCodeEntry

    let error = coordinator.joinEvent(code: "  ethtokyo2026  ")

    XCTAssertNil(error)
    XCTAssertEqual(coordinator.screen, .bluetoothPermission)
    XCTAssertNil(coordinator.walletAddress, "the event-code path must never set a wallet address")
    XCTAssertEqual(coordinator.sensingCoordinator.joinedEventCode, "ethtokyo2026")
  }

  /// beid#226/DECISIONS 2026-08-20: `joinEvent(code:)` case-folds through
  /// `attemptJoinEvent`'s shared `normalizedEventCodeOrNull` call, not a
  /// native `.trimmingCharacters`-only check — proves the fix end-to-end,
  /// not just at the pure-function level.
  func testJoinEventCaseFoldsTheCodeEndToEnd() {
    let coordinator = AppCoordinator()
    coordinator.screen = .eventCodeEntry

    let error = coordinator.joinEvent(code: "  ETHTOKYO2026  ")

    XCTAssertNil(error)
    XCTAssertEqual(coordinator.sensingCoordinator.joinedEventCode, "ethtokyo2026")
  }

  func testOpenEventCodeEntryFromAccountSheetPresentsSheet() {
    let coordinator = AppCoordinator()

    coordinator.openEventCodeEntryFromAccountSheet()

    XCTAssertTrue(coordinator.eventCodeEntrySheetPresented)
  }

  func testJoinEventFromAccountSheetWithValidCodeDismissesSheetWithoutTouchingScreen() {
    let coordinator = AppCoordinator()
    coordinator.screen = .home
    coordinator.eventCodeEntrySheetPresented = true

    let error = coordinator.joinEventFromAccountSheet(code: "  ethtokyo2026  ")

    XCTAssertNil(error)
    XCTAssertEqual(
      coordinator.screen, .home,
      "the Account-sheet join path must never touch onboarding screen"
    )
    XCTAssertFalse(coordinator.eventCodeEntrySheetPresented)
    XCTAssertEqual(coordinator.sensingCoordinator.joinedEventCode, "ethtokyo2026")
  }

  func testJoinEventFromAccountSheetWithEmptyCodeReturnsValidationErrorAndKeepsSheetPresented() {
    let coordinator = AppCoordinator()
    coordinator.screen = .home
    coordinator.eventCodeEntrySheetPresented = true

    let error = coordinator.joinEventFromAccountSheet(code: "   ")

    XCTAssertEqual(error, .emptyCode)
    XCTAssertEqual(coordinator.screen, .home)
    XCTAssertTrue(coordinator.eventCodeEntrySheetPresented)
    XCTAssertNil(coordinator.sensingCoordinator.joinedEventCode)
  }

  func testSensingCoordinatorJoinEventCallsBarnardSDKAndReportsSuccess() {
    let coordinator = makeIsolatedSensingCoordinator(for: self)

    let joined = coordinator.joinEvent("beid-test-event")

    XCTAssertTrue(joined)
    XCTAssertEqual(coordinator.joinedEventCode, "beid-test-event")
  }

  func testLeaveEventClearsJoinedEventCode() {
    let coordinator = makeIsolatedSensingCoordinator(for: self)

    let joined = coordinator.joinEvent("beid-test-event")
    XCTAssertTrue(joined)
    XCTAssertEqual(coordinator.joinedEventCode, "beid-test-event")

    coordinator.leaveEvent()

    XCTAssertNil(coordinator.joinedEventCode)
  }

  func testStartSensingStillWorksAfterJoiningAnEventManually() async {
    // Regression check: startSensing's eventCode parameter became optional
    // (falling back to joinedEventCode, then the demo default) to carry a
    // manually joined code through to sensing — this must not disturb the
    // DemoEvent path the simulator relies on.
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.joinEvent("beid-test-event")

    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    guard case .recording(let event, _) = coordinator.phase else {
      XCTFail("expected .recording phase, got \(coordinator.phase)")
      return
    }
    XCTAssertEqual(event.name, EventSession.demoSample.name)
    XCTAssertEqual(coordinator.joinedEventCode, "beid-test-event")
  }
}
