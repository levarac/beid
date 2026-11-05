// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest

/// Returning from sensing details preserves the live participation.
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
    XCTAssertTrue(app.scrollViews["scan.sensing"].waitForExistence(timeout: 30))

    app.navigationBars.buttons.element(boundBy: 0).tap()

    let indicator = app.buttons["home.open-details"]
    XCTAssertTrue(indicator.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["collection.stop-sensing"].exists)
    let details = app.buttons["home.open-details"]
    XCTAssertTrue(details.isHittable)
    details.tap()
    XCTAssertTrue(app.scrollViews["scan.sensing"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["Stop sensing?"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["scan.sealed"].exists)
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(indicator.waitForExistence(timeout: 5))
  }
}
