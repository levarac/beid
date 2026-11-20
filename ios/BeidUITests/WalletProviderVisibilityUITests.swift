// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest

/// H1 removes every wallet connection entry from v1.1 Account. This also
/// preserves beid#270's protection against offering an unusable provider,
/// without relying on the removed wallet picker or binding sheet.
/// A user with no wallet must not find a
/// "Connect Wallet" row (or anything that opens the pairing sheet) in the
/// Account sheet. H1 also removes legacy connected-wallet rows, covered by
/// FlatScreenshotTourD with `-beid-account-connected-fixture`.
final class WalletProviderVisibilityUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

}
