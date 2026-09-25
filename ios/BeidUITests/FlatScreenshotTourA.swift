// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest

/// Captures Flat 2b onboarding and event-code states through production navigation.
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

  func testShot_13_EnterEventCode() {
    openAccountEventCodeEntry(frame: "-beid-shot-13")

    let field = app.textFields["Event code"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    XCTAssertEqual(field.value as? String, "ETH-TOKYO-26")
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    XCTAssertTrue(app.buttons["Cancel"].exists)
    XCTAssertTrue(app.buttons["Paste event code"].exists)
    XCTAssertTrue(app.buttons["Join Event"].exists)
    keepScreenshot(named: "13 Enter Event Code")
  }

  func testShot_13b_Error() {
    openAccountEventCodeEntry(frame: "-beid-shot-13b")

    let field = app.textFields["Event code"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    XCTAssertEqual(field.value as? String, "ETH-TOKY0-26")
    let errorLabel = app.staticTexts.matching(
      NSPredicate(format: "label == %@", "COULD NOT JOIN EVENT")
    ).firstMatch
    XCTAssertTrue(errorLabel.exists)
    XCTAssertTrue(
      app.staticTexts["beid couldn't join that event. Check the code and try again."].exists
    )
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    XCTAssertTrue(app.buttons["Cancel"].exists)
    keepScreenshot(named: "13b Enter Event Code Error")
  }

  /// Follow the actual Account sheet route so the stock Cancel toolbar item
  /// and nested-sheet presentation are part of each captured frame.
  private func openAccountEventCodeEntry(frame: String) {
    app.launchArguments = ["-beid-ui-test", frame]
    app.launch()

    app.buttons["Get Started"].tap()
    let allowBluetooth = app.buttons["Allow Bluetooth"]
    XCTAssertTrue(allowBluetooth.waitForExistence(timeout: 5))
    allowBluetooth.tap()

    let account = app.buttons["home.account"]
    XCTAssertTrue(account.waitForExistence(timeout: 5))
    account.tap()

    let joinEvent = app.buttons["Join Event"]
    let list = app.collectionViews.firstMatch
    var attempts = 0
    while !joinEvent.exists && attempts < 6 {
      list.swipeUp()
      attempts += 1
    }
    XCTAssertTrue(joinEvent.exists, "Account's Join Event row was not reachable")
    joinEvent.tap()
    XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
  }

  private func keepScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
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
    keepScreenshot(named: frameCode)
  }
}
