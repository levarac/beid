// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest

/// Runtime proof for beid#430. The fixture drives the actual SensingView with
/// one typed refusal; the existing coordinator tests cover the other cases.
///
/// The original version of this comment said the View renders every refusal at
/// "one Android-parity sentence granularity". **That premise was already
/// stale when it was written:** Android has distinguished six reasons since
/// beid#463, and iOS collapsing them into one sentence was the defect
/// beid#472 fixed — the single sentence told a participant with no network to
/// check a code that was correct. The View now renders the reason's own
/// sentence, and this test asserts that sentence rather than the generic one.
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

    let senseEvent = app.buttons["home.scan"]
    XCTAssertTrue(senseEvent.waitForExistence(timeout: 5))
    senseEvent.tap()

    // The fixture's refusal is classified from a transport error code, so this
    // is the network sentence, not the generic one. Asserting the specific
    // sentence is what makes this a runtime proof of the classification and
    // not just of a panel being present.
    let refusalTitle = app.staticTexts[
      "beid needs a connection to verify this event, and couldn't reach the network. Check your connection and try again."
    ]
    let scrollView = app.scrollViews.firstMatch
    var attempts = 0
    while !refusalTitle.exists && attempts < 4 {
      scrollView.swipeUp()
      attempts += 1
    }
    XCTAssertTrue(refusalTitle.waitForExistence(timeout: 5))

    app.buttons["Close"].tap()
    XCTAssertFalse(refusalTitle.waitForExistence(timeout: 1))

    // A fresh scan starts after finishScan() reset the coordinator session, so
    // this proves the user-visible refusal was cleared rather than left stale.
    senseEvent.tap()
    XCTAssertTrue(refusalTitle.waitForExistence(timeout: 5))
  }
}
