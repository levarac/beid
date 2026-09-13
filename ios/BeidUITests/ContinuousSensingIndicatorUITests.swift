// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest

/// Runtime acceptance for beid#200: closing the scan surface must leave a
/// truthful, actionable indication while transport continues.
final class ContinuousSensingIndicatorUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testHomeShowsContinuousSensingAndClearsAfterStop() {
    app.launchArguments = ["-beid-ui-test", "-beid-continuous-sensing-fixture"]
    app.launch()

    app.buttons["Get Started"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()

    let senseEvent = app.buttons["Sense Event"]
    XCTAssertTrue(senseEvent.waitForExistence(timeout: 5))
    senseEvent.tap()
    XCTAssertTrue(app.staticTexts["Sensing automatically"].waitForExistence(timeout: 30))

    app.buttons["Close"].tap()

    let indicator = app.staticTexts["Sensing continues in background"]
    XCTAssertTrue(indicator.waitForExistence(timeout: 5))
    let stopButton = app.buttons["Stop sensing"]
    XCTAssertTrue(stopButton.exists)

    stopButton.tap()
    XCTAssertFalse(indicator.waitForExistence(timeout: 5))
    XCTAssertFalse(stopButton.exists)
  }
}
