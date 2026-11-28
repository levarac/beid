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

    app.buttons["Continue"].tap()
    XCTAssertTrue(app.buttons["bluetooth.permission.continue"].existsOrWait(timeout: 5))
    app.buttons["bluetooth.permission.continue"].tap()

    let senseEvent = app.buttons["home.demo.join"]
    XCTAssertTrue(senseEvent.existsOrWait(timeout: 5))
    senseEvent.tap()
    XCTAssertTrue(app.scrollViews["scan.sensing"].existsOrWait(timeout: 30))

    app.navigationBars.buttons.element(boundBy: 0).tap()

    let indicator = app.buttons["home.open-details"]
    XCTAssertTrue(indicator.existsOrWait(timeout: 5))
    XCTAssertTrue(app.staticTexts["Sensing continues"].exists)
    XCTAssertFalse(app.staticTexts["SENSING"].exists)
    XCTAssertFalse(app.staticTexts["DO THIS NOW"].exists)
    XCTAssertEqual(indicator.label, "Sensing details")
    XCTAssertFalse(app.buttons["collection.stop-sensing"].exists)
    let details = app.buttons["home.open-details"]
    XCTAssertTrue(details.isHittable)
    details.tap()
    XCTAssertTrue(app.scrollViews["scan.sensing"].existsOrWait(timeout: 5))
    XCTAssertTrue(app.navigationBars["Sensing"].staticTexts["Sensing"].exists)
    XCTAssertFalse(app.staticTexts["Stop sensing?"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["scan.sealed"].exists)
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(indicator.existsOrWait(timeout: 5))
  }
}
