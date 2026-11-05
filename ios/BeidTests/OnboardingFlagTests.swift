// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

@MainActor
final class OnboardingFlagTests: XCTestCase {
  func testOnboardingStartsWithBluetoothPermission() {
    // Legacy feature flags must not introduce a wallet step.
    let coordinator = AppCoordinator()
    coordinator.beginOnboarding()

    XCTAssertEqual(coordinator.screen, .bluetoothPermission)
    XCTAssertNil(coordinator.walletAddress)
  }

  func testWalletFirstOrderReachesBluetoothPermissionAfterConnect() throws {
    guard OnboardingMode.current == .walletFirst else {
      throw XCTSkip("only applicable when OnboardingMode.current == .walletFirst")
    }
    let coordinator = AppCoordinator()
    coordinator.beginOnboarding()
    XCTAssertEqual(coordinator.screen, .bluetoothPermission)

    coordinator.completeWalletConnect(
      address: LiveWalletAddress.fromConnectorResult(address: "0xREALADDRESS", chainId: "eip155:1")
    )
    XCTAssertEqual(coordinator.walletAddress, "0xREALADDRESS")
    XCTAssertEqual(coordinator.screen, .bluetoothPermission)
  }

  func testLeavingLegacyCodeEntryReturnsToBluetoothWithoutWalletPresentation() {
    let coordinator = AppCoordinator()
    coordinator.screen = .eventCodeEntry
    coordinator.returnToWalletConnect()
    XCTAssertEqual(coordinator.screen, .bluetoothPermission)
    XCTAssertNil(coordinator.walletAddress)
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
