// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest

/// Runtime acceptance for beid#200: closing the scan surface must leave a
/// truthful, actionable indication while transport continues.
final class ContinuousSensingIndicatorUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testHomeResumesContinuousSensingThroughDetails() {
    app.launchArguments = ["-beid-ui-test", "-beid-continuous-sensing-fixture"]
    app.launch()

    app.buttons["Get Started"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()

    let senseEvent = app.buttons["home.demo.join"]
    XCTAssertTrue(senseEvent.waitForExistence(timeout: 5))
    senseEvent.tap()
    XCTAssertTrue(app.staticTexts["Sensing automatically"].waitForExistence(timeout: 30))

    app.buttons["Close"].tap()

    let indicator = app.staticTexts["collection.continuous-sensing"]
    XCTAssertTrue(indicator.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["collection.stop-sensing"].exists)
    let details = app.buttons["home.open-details"]
    XCTAssertTrue(details.isHittable)
    details.tap()
    XCTAssertTrue(app.scrollViews["scan.sensing"].waitForExistence(timeout: 5))
    app.buttons["Close"].tap()
    XCTAssertTrue(indicator.waitForExistence(timeout: 5))
  }
}
