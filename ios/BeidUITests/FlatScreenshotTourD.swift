// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest

/// Account states for the Flat 2b Figma comparison. Each attachment includes
/// the full device screenshot so the PM can compare it with its named frame.
final class FlatScreenshotTourD: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testShot_10_Account() {
    openAccount()
    XCTAssertTrue(app.buttons["Copy address"].waitForExistence(timeout: 5))
    attachScreenshot("10")
  }

  func testShot_10c_BluetoothOff() {
    openAccount(extraArguments: ["-beid-account-bluetooth-off-fixture"])
    XCTAssertTrue(app.buttons["account.bluetooth.status"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["account.bluetooth.status"].label, "Open Bluetooth Settings")
    attachScreenshot("10c")
  }

  func testShot_10d_DisconnectConfirm() {
    openAccount()
    let disconnect = app.buttons["Disconnect wallet"]
    let list = app.collectionViews.firstMatch
    var attempts = 0
    while !disconnect.isHittable, attempts < 6 {
      list.swipeUp()
      attempts += 1
    }
    XCTAssertTrue(disconnect.isHittable)
    disconnect.tap()
    XCTAssertTrue(app.staticTexts["Disconnect wallet?"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["account.disconnect.cancel"].exists)
    attachScreenshot("10d")
  }

  func testShot_10e_Copied() {
    openAccount()
    let copy = app.buttons["Copy address"]
    XCTAssertTrue(copy.waitForExistence(timeout: 5))
    copy.tap()
    XCTAssertTrue(app.buttons["account.copy.feedback"].waitForExistence(timeout: 5))
    attachScreenshot("10e")
  }

  private func openAccount(extraArguments: [String] = []) {
    app.launchArguments = ["-beid-ui-test", "-beid-account-connected-fixture"] + extraArguments
    app.launch()

    app.buttons["Get Started"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()
    let account = app.buttons["Account"]
    XCTAssertTrue(account.waitForExistence(timeout: 5))
    account.tap()
  }

  private func attachScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
