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

  func testSensingCoordinatorJoinEventCallsBarnardSDKAndReportsSuccess() {
    let coordinator = SensingCoordinator()

    let joined = coordinator.joinEvent("beid-test-event")

    XCTAssertTrue(joined)
    XCTAssertEqual(coordinator.joinedEventCode, "beid-test-event")
  }

  func testStartSensingStillWorksAfterJoiningAnEventManually() async {
    // Regression check: startSensing's eventCode parameter became optional
    // (falling back to joinedEventCode, then the demo default) to carry a
    // manually joined code through to sensing — this must not disturb the
    // DemoEvent path the simulator relies on.
    let coordinator = SensingCoordinator()
    coordinator.joinEvent("beid-test-event")

    coordinator.runDemoSequence(demoEvent: .sample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    guard case .collected(let proof) = coordinator.phase else {
      XCTFail("expected .collected phase, got \(coordinator.phase)")
      return
    }
    XCTAssertEqual(proof.eventName, DemoEvent.sample.name)
    XCTAssertEqual(coordinator.joinedEventCode, "beid-test-event")
  }
}
