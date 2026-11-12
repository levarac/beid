// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest

/// Regression coverage for thegreeting/beid#270: Coinbase Wallet (the
/// renamed "Base" app) stopped showing its approval dialog on real devices,
/// and the underlying SDK has no native-iOS fix available yet. The wallet
/// picker was narrowed to MetaMask only — see `WalletConnectView.swift`'s
/// `providerSelectionContent` and the removed binding sheet's `swift`'s
/// `connectContent` for the two production call sites.
///
/// v1.1 offers no wallet connection. A user with no wallet must not find a
/// "Connect Wallet" row (or anything that opens the pairing sheet) in the
/// Account sheet. H1 also removes legacy connected-wallet rows, covered by
/// FlatScreenshotTourD with `-beid-account-connected-fixture`.
final class WalletProviderVisibilityUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testAccountSheetOffersNoWalletConnectionWhenNotConnected() {
    app.launchArguments = ["-beid-ui-test"]
    app.launch()

    app.buttons["Continue"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()
    XCTAssertTrue(app.buttons["home.account"].waitForExistence(timeout: 5))

    app.buttons["home.account"].tap()
    XCTAssertTrue(app.buttons["Organizer tools"].waitForExistence(timeout: 5), "the Account sheet must be open")
    XCTAssertFalse(app.buttons["Connect Wallet"].exists)
    XCTAssertFalse(app.buttons["Connect with MetaMask"].exists)
    XCTAssertFalse(app.buttons["Disconnect wallet"].exists)
  }
}
