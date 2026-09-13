// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest

/// Runtime proof for beid#430. The fixture drives the actual SensingView with
/// one typed refusal; the existing coordinator tests cover the other refusal
/// cases and the View deliberately renders all non-nil cases at one Android-
/// parity sentence granularity.
final class JoinRefusalUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testJoinRefusalPanelIsVisibleAndClearsWhenScanCloses() {
    app.launchArguments = ["-beid-ui-test", "-beid-join-refusal-fixture"]
    app.launch()

    app.buttons["Get Started"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()

    let senseEvent = app.buttons["Sense Event"]
    XCTAssertTrue(senseEvent.waitForExistence(timeout: 5))
    senseEvent.tap()

    let refusalTitle = app.staticTexts["This event cannot be joined yet."]
    let refusalGuidance = app.staticTexts["Check the event details and try again."]
    let scrollView = app.scrollViews.firstMatch
    var attempts = 0
    while !refusalTitle.exists && attempts < 4 {
      scrollView.swipeUp()
      attempts += 1
    }
    XCTAssertTrue(refusalTitle.waitForExistence(timeout: 5))
    XCTAssertTrue(refusalGuidance.exists)

    app.buttons["Close"].tap()
    XCTAssertFalse(refusalTitle.waitForExistence(timeout: 1))

    // A fresh scan starts after finishScan() reset the coordinator session, so
    // this proves the user-visible refusal was cleared rather than left stale.
    senseEvent.tap()
    XCTAssertTrue(refusalTitle.waitForExistence(timeout: 5))
  }
}
