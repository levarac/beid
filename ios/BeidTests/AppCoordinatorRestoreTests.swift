// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

/// Covers #194: a device that has already completed onboarding must not
/// restart at `.welcome` on cold launch.
@MainActor
final class AppCoordinatorRestoreTests: XCTestCase {
  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: "beid.hasCompletedOnboarding")
    super.tearDown()
  }

  func testColdLaunchWithCompletedOnboardingDoesNotStartAtWelcome() {
    UserDefaults.standard.set(true, forKey: "beid.hasCompletedOnboarding")

    let coordinator = AppCoordinator()

    XCTAssertNotEqual(coordinator.screen, .welcome)
  }

  func testColdLaunchWithoutCompletedOnboardingStartsAtWelcome() {
    UserDefaults.standard.removeObject(forKey: "beid.hasCompletedOnboarding")

    let coordinator = AppCoordinator()

    XCTAssertEqual(coordinator.screen, .welcome)
  }

  func testRestoreLandsOnHomeOrBluetoothOffWithoutSkippingEvaluation() async {
    UserDefaults.standard.set(true, forKey: "beid.hasCompletedOnboarding")

    let coordinator = AppCoordinator()

    // requestBluetoothPermission() has no awaitable completion handle (see
    // AppCoordinator.requestBluetoothPermission's ~300ms production delay
    // before evaluateBluetoothState() runs); this mirrors the async-sleep
    // style already used in EventCodeJoinTests.waitForDemoSequenceToFinish().
    // A single fixed ~500ms sleep is not enough here: constructing
    // CBCentralManager inside the BeidTests unit-test host (no prior test in
    // this suite exercises BluetoothMonitor/CBCentralManager) has been
    // observed to make CoreBluetooth's XPC handshake take upwards of 15s in
    // this environment, well past the ~300ms production delay — so this
    // polls with a generous overall ceiling instead of asserting after one
    // fixed delay.
    let deadline = Date().addingTimeInterval(20)
    while coordinator.screen == .bluetoothPermission, Date() < deadline {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // The Simulator always reports Bluetooth powered-on (ios/README.md), so
    // only the .home branch is actually observable here — .bluetoothOff is
    // asserted as an allowed outcome for documentation, not exercised.
    XCTAssertTrue(coordinator.screen == .home || coordinator.screen == .bluetoothOff)
  }
}
