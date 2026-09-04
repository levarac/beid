// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest

/// Regression coverage for thegreeting/beid#270: Coinbase Wallet (the
/// renamed "Base" app) stopped showing its approval dialog on real devices,
/// and the underlying SDK has no native-iOS fix available yet. The wallet
/// picker was narrowed to MetaMask only — see `WalletConnectView.swift`'s
/// `providerSelectionContent` and `EventBindingSheetView.swift`'s
/// `connectContent` for the two production call sites.
///
/// Coverage is scoped to the Account sheet's "Connect Wallet" flow
/// (`AccountSheetView` -> `WalletConnectSheetView` -> the shared
/// `WalletConnectPairingView` picker), because that is the one wallet-picker
/// entry point reachable in the shipping app today: `OnboardingMode.current`
/// is `.guestFirst` (docs/specs/onboarding-redesign.md §3), so the
/// `.walletFirst`-only root onboarding picker is dead code in production and
/// is deliberately not covered here rather than adding a new DEBUG-only
/// launch-argument seam to exercise an unshipped path.
final class WalletProviderVisibilityUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testAccountSheetConnectWalletShowsOnlyMetaMask() {
    launchAndOpenConnectWalletPicker()

    XCTAssertTrue(
      app.buttons["Connect with MetaMask"].waitForExistence(timeout: 5),
      "MetaMask must remain a reachable wallet option"
    )
    XCTAssertFalse(
      app.buttons["Connect with Coinbase Wallet"].exists,
      "Coinbase Wallet must not be a reachable wallet option (thegreeting/beid#270)"
    )
    // Belt-and-braces: no descendant anywhere under the sheet should carry
    // "Coinbase" in its accessibility label while the picker is up — guards
    // against a future relabel/restructure re-exposing Coinbase under a
    // different control.
    let coinbaseAnywhere = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS[c] %@", "Coinbase")
    )
    XCTAssertEqual(coinbaseAnywhere.count, 0, "No control should mention Coinbase while the picker is presented")
  }

  func testAccountSheetConnectWalletPickerReopensAfterCancel() {
    launchAndOpenConnectWalletPicker()

    XCTAssertTrue(app.buttons["Connect with MetaMask"].waitForExistence(timeout: 5))
    app.buttons["Cancel"].tap()
    XCTAssertFalse(app.buttons["Connect with MetaMask"].exists, "Sheet should dismiss after Cancel")

    app.buttons["Connect wallet"].tap()

    XCTAssertTrue(
      app.buttons["Connect with MetaMask"].waitForExistence(timeout: 5),
      "MetaMask must still be the option on a fresh reopen"
    )
    XCTAssertFalse(app.buttons["Connect with Coinbase Wallet"].exists)
  }

  private func launchAndOpenConnectWalletPicker() {
    app.launchArguments = ["-beid-ui-test"]
    app.launch()

    app.buttons["Get started"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()
    XCTAssertTrue(app.buttons["Account"].waitForExistence(timeout: 5))

    app.buttons["Account"].tap()
    XCTAssertTrue(app.buttons["Connect wallet"].waitForExistence(timeout: 5))
    app.buttons["Connect wallet"].tap()
  }
}
