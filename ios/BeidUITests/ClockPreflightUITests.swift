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

    let senseEvent = app.buttons["home.scan"]
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
    // A notice, not a refusal: code entry stays on the same screen and frame
    // 05d's Can't join layout is not shown. (This fixture has no nearby event,
    // so there is no list header to find; NearbyJoinUITests covers a list shown
    // under the same undeterminable notice.)
    // The pre-join manual-entry control is visible here but not found by its
    // identifier in the accessibility tree; tracked separately (see the issue
    // linked from the Flat 2b main PR) rather than asserted in this clock test.
    XCTAssertFalse(app.descendants(matching: .any)["scan.cant-join"].exists)
  }
}
