// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

/// Covers the additive WalletConnect (Reown) spike: the mode flag, the
/// gitignored-secrets fallback, and the coordinator's backward-compatible
/// `completeWalletConnect(address:)` overload. Does not exercise
/// `ReownWalletConnectClient.connect()` itself — that requires a live relay
/// connection and a real Reown Cloud project ID, neither of which are
/// available in CI; see ios/README.md "WalletConnect (spike)".
@MainActor
final class WalletConnectSpikeTests: XCTestCase {
  func testProjectIdIsNilWithoutSecretsPlist() {
    // On a fresh checkout (and in CI) `Beid/Secrets.plist` doesn't exist —
    // it's gitignored. This documents that WalletConnectSecrets degrades
    // to nil rather than crashing, which is what lets ReownWalletConnectView
    // reach `.notConfigured` instead of the app failing to build or launch.
    XCTAssertNil(WalletConnectSecrets.projectId)
  }

  func testCompleteWalletConnectWithExplicitAddressBypassesStub() {
    let coordinator = AppCoordinator()
    coordinator.completeWalletConnect(address: "0xREALADDRESS")
    XCTAssertEqual(coordinator.walletAddress, "0xREALADDRESS")
    XCTAssertEqual(coordinator.screen, .bluetoothPermission)
  }

  func testCompleteWalletConnectWithNoAddressFallsBackToStub() {
    let coordinator = AppCoordinator()
    coordinator.completeWalletConnect()
    XCTAssertNotNil(coordinator.walletAddress)
    XCTAssertTrue(coordinator.walletAddress?.hasPrefix("0x") == true)
  }

  func testWalletConnectModeCurrentIsRecognized() {
    // Documents whichever value WalletConnectMode.current is currently set
    // to (spike flag, same pattern as OnboardingMode.current) — fails loudly
    // if the enum ever grows a case this test doesn't know about.
    switch WalletConnectMode.current {
    case .stub, .reown:
      break
    }
  }
}
