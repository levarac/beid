// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

/// Covers the graceful-degradation path (no Secrets.plist/project ID) and
/// the coordinator wiring around the real WalletConnect (Reown) flow. Does
/// not exercise `ReownWalletConnectClient.connect()` itself — that requires
/// a live relay connection and a real Reown Cloud project ID, neither of
/// which are available in CI; see ios/README.md "WalletConnect".
@MainActor
final class WalletConnectTests: XCTestCase {
  func testProjectIdIsNilWithoutSecretsPlist() {
    // On a fresh checkout (and in CI) `Beid/Secrets.plist` doesn't exist —
    // it's gitignored. This documents that WalletConnectSecrets degrades to
    // nil rather than crashing, which is what lets the pairing UI reach
    // `.notConfigured` instead of the app failing to build or launch.
    XCTAssertNil(WalletConnectSecrets.projectId)
  }

  func testClientReachesNotConfiguredWithoutProjectId() {
    let client = ReownWalletConnectClient.shared
    client.configureIfNeeded()
    XCTAssertEqual(client.state, .notConfigured)
  }

  func testCompleteWalletConnectSetsAddressAndAdvancesScreen() {
    let coordinator = AppCoordinator()
    coordinator.completeWalletConnect(address: "0xREALADDRESS")
    XCTAssertEqual(coordinator.walletAddress, "0xREALADDRESS")
    XCTAssertEqual(coordinator.screen, .bluetoothPermission)
  }

  func testConnectWalletFromAccountSheetPresentsSheetWithoutChangingScreen() {
    let coordinator = AppCoordinator()
    coordinator.screen = .home
    coordinator.connectWalletFromAccountSheet()
    XCTAssertTrue(coordinator.walletConnectSheetPresented)
    XCTAssertEqual(coordinator.screen, .home)
    XCTAssertNil(coordinator.walletAddress)
  }

  func testDisconnectWalletClearsAddressAndResetsClient() {
    let coordinator = AppCoordinator()
    coordinator.walletAddress = "0xREALADDRESS"

    coordinator.disconnectWallet()

    XCTAssertNil(coordinator.walletAddress)
    // Without a project ID the shared client never leaves .notConfigured,
    // so reset() is a documented no-op here — this asserts it doesn't
    // crash or otherwise misbehave when called on an unconfigured client.
    XCTAssertEqual(ReownWalletConnectClient.shared.state, .notConfigured)
  }
}
