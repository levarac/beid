// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest

/// Captures the three onboarding states for a frame-by-frame comparison with
/// Flat 2b. Each state is reached through the production screen and action.
final class FlatScreenshotTourA: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testShot_01_Welcome() {
    launch()
    capture("01 Welcome")
  }

  func testShot_02_EnableBluetooth() {
    launch()
    showBluetoothPermission()
    capture("02 Enable Bluetooth")
  }

  func testShot_03_BluetoothOff() {
    launch(bluetoothOff: true)
    showBluetoothPermission()
    app.buttons["Allow Bluetooth"].tap()
    XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 5))
    capture("03 Bluetooth Off")
  }

  private func launch(bluetoothOff: Bool = false) {
    app.launchArguments = ["-beid-ui-test"]
    if bluetoothOff {
      app.launchArguments.append("-beid-bluetooth-off-fixture")
    }
    app.launch()
  }

  private func showBluetoothPermission() {
    let getStarted = app.buttons["Get Started"]
    XCTAssertTrue(getStarted.waitForExistence(timeout: 5))
    getStarted.tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
  }

  private func capture(_ frameCode: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = frameCode
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
