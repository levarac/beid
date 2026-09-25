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
    let copy = app.buttons["Copy address"]
    _ = copy.waitForExistence(timeout: 5)
    attachScreenshot("10")
    assertMinimumHitTarget(app.buttons["Done"])
    assertMinimumHitTarget(copy)
  }

  func testShot_10c_BluetoothOff() {
    openAccount(extraArguments: ["-beid-account-bluetooth-off-fixture"])
    let bluetoothStatus = app.buttons["account.bluetooth.status"]
    _ = bluetoothStatus.waitForExistence(timeout: 5)
    attachScreenshot("10c")
    XCTAssertEqual(bluetoothStatus.label, "Open Bluetooth Settings")
    assertMinimumHitTarget(app.buttons["Done"])
    assertMinimumHitTarget(app.buttons["Copy address"])
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
    let title = app.staticTexts["Disconnect wallet?"]
    _ = title.waitForExistence(timeout: 5)
    attachScreenshot("10d")
    XCTAssertTrue(title.exists)
    let keepConnected = app.buttons["Keep connected"]
    assertMinimumHitTarget(keepConnected)
    assertMinimumHitTarget(app.buttons["Done"])
    assertMinimumHitTarget(app.buttons["Copy address"])
    assertMinimumHitTarget(app.buttons["Disconnect"])
  }

  func testShot_10e_Copied() {
    openAccount()
    let copy = app.buttons["Copy address"]
    XCTAssertTrue(copy.waitForExistence(timeout: 5))
    copy.tap()
    let copied = app.buttons["account.copy.feedback"]
    _ = copied.waitForExistence(timeout: 5)
    attachScreenshot("10e")
    assertMinimumHitTarget(app.buttons["Done"])
    assertMinimumHitTarget(copied)
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

  private func assertMinimumHitTarget(_ control: XCUIElement) {
    XCTAssertTrue(control.exists)
    XCTAssertGreaterThanOrEqual(control.frame.width, 44)
    XCTAssertGreaterThanOrEqual(control.frame.height, 44)
  }
}
