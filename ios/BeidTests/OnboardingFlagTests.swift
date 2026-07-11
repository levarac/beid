// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

@MainActor
final class OnboardingFlagTests: XCTestCase {
  func testWalletFirstRoutesToWalletConnectFirst() {
    // OnboardingMode.current is a static compile-time flag (see README
    // "Onboarding flag"); this test documents the routing it drives for
    // whichever value is currently set.
    let coordinator = AppCoordinator()
    coordinator.beginOnboarding()

    switch OnboardingMode.current {
    case .walletFirst:
      XCTAssertEqual(coordinator.screen, .walletConnect)
    case .guestFirst:
      XCTAssertEqual(coordinator.screen, .bluetoothPermission)
    }
  }

  func testWalletFirstOrderReachesBluetoothPermissionAfterConnect() throws {
    guard OnboardingMode.current == .walletFirst else {
      throw XCTSkip("only applicable when OnboardingMode.current == .walletFirst")
    }
    let coordinator = AppCoordinator()
    coordinator.beginOnboarding()
    XCTAssertEqual(coordinator.screen, .walletConnect)

    coordinator.completeWalletConnect(address: "0xREALADDRESS")
    XCTAssertEqual(coordinator.walletAddress, "0xREALADDRESS")
    XCTAssertEqual(coordinator.screen, .bluetoothPermission)
  }

  func testGuestFirstOrderSkipsWalletStepInitially() throws {
    guard OnboardingMode.current == .guestFirst else {
      throw XCTSkip("only applicable when OnboardingMode.current == .guestFirst")
    }
    let coordinator = AppCoordinator()
    coordinator.beginOnboarding()
    XCTAssertEqual(coordinator.screen, .bluetoothPermission)
    XCTAssertNil(coordinator.walletAddress)
  }
}
