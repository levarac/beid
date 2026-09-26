// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest

/// Runtime proof for beid#464: when the device clock cannot be checked, the
/// pre-join Scan screen says so. The fixture removes only the operator origin,
/// so the real `ClockPreflightController` and the shared decision produce
/// "undeterminable" — nothing is injected past that point.
final class ClockPreflightUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testUndeterminableClockRendersItsNoticeOnTheScanScreen() {
    app.launchArguments = ["-beid-ui-test", "-beid-clock-preflight-fixture"]
    app.launch()

    app.buttons["Get Started"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()

    let senseEvent = app.buttons["Sense Event"]
    XCTAssertTrue(senseEvent.waitForExistence(timeout: 5))
    senseEvent.tap()

    let title = app.staticTexts["Couldn't check this device's clock"]
    XCTAssertTrue(title.waitForExistence(timeout: 10))
    XCTAssertTrue(
      app.staticTexts[
        "beid couldn't compare the clock with the network, so event times can't be trusted yet. Check your connection, then try again."
      ].exists
    )
    XCTAssertTrue(app.buttons["scan.clock-preflight.retry"].exists)
    XCTAssertFalse(app.staticTexts["This device's clock is off"].exists)
  }
}
