// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest

/// Runtime proof for beid#430. The fixture drives the actual scan flow with
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

  func testDeviceKeyFailureAppearsOnOpenScanFlowAndDismissesOnce() {
    app.launchArguments = [
      "-beid-ui-test", "-beid-nearby-join-fixture", "-beid-device-key-unavailable-fixture"
    ]
    app.launch()
    app.buttons["Get Started"].assertHittable()
    app.buttons["Get Started"].tap()
    app.buttons["Allow Bluetooth"].assertHittable()
    app.buttons["Allow Bluetooth"].tap()
    app.buttons["home.scan"].assertHittable()
    app.buttons["home.scan"].tap()

    let receipt = app.staticTexts["fixture.nearby-join.receipt"]
    receipt.assertHittable()
    XCTAssertEqual(receipt.label, "joins=0 event=none")
    let card = app.buttons.matching(NSPredicate(
      format: "identifier == %@ AND label CONTAINS %@", "scan.nearby-events", "Community night"
    )).firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 5))
    let alert = app.alerts["Recording unavailable"]
    XCTAssertFalse(alert.exists, "the failure must occur after the scan flow opens")
    app.scrollViews["scan.sensing"].swipeUp()
    card.assertHittable()
    card.tap()

    let message = "The device signing key is unavailable. Unlock your device and try again."
    alert.assertHittable()
    alert.staticTexts[message].assertHittable()
    XCTAssertEqual(app.alerts.count, 1)
    alert.buttons["Close"].tap()
    alert.assertDisappears()
    XCTAssertEqual(receipt.label, "joins=0 event=none")

    let panel = app.scrollViews["scan.cant-join"]
    panel.assertHittable()
    let title = panel.staticTexts["scan.join-refusal"]
    title.scrollToHittable(in: app)
    XCTAssertEqual(title.label, "Recording unavailable")
    panel.staticTexts[message].scrollToHittable(in: app)
    XCTAssertFalse(app.staticTexts["beid couldn't join that event. Check the code and try again."].exists)
    app.buttons["Close"].assertHittable()
    app.buttons["Close"].tap()
    panel.assertDisappears()
    app.buttons["home.scan"].assertHittable()

    let repeatedAlert = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: alert)
    repeatedAlert.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [repeatedAlert], timeout: 1), .completed)
  }

  func testJoinRefusalPanelIsVisibleAndClearsWhenScanCloses() {
    app.launchArguments = ["-beid-ui-test", "-beid-join-refusal-fixture"]
    app.launch()

    app.buttons["Continue"].assertHittable()
    app.buttons["Continue"].tap()
    app.buttons["Allow Bluetooth"].assertHittable()
    app.buttons["Allow Bluetooth"].tap()

    let senseEvent = app.buttons["home.demo.join"]
    senseEvent.assertHittable()
    senseEvent.tap()

    // The fixture's refusal is classified from a transport error code, so this
    // is the network sentence, not the generic one. Asserting the specific
    // sentence is what makes this a runtime proof of the classification and
    // not just of a panel being present.
    let refusalTitle = app.staticTexts[
      "beid needs a connection to verify this event, and couldn't reach the network. Check your connection and try again."
    ]
    // A refusal replaces the sensing screen; it is not a panel inside it.
    let refusalPanel = app.scrollViews["scan.cant-join"]
    refusalPanel.assertHittable()
    refusalTitle.scrollToHittable(in: app)

    app.navigationBars.buttons.element(boundBy: 0).assertHittable()
    app.navigationBars.buttons.element(boundBy: 0).tap()
    refusalPanel.assertDisappears()
    refusalTitle.assertDisappears()

    // A fresh scan starts after finishScan() reset the coordinator session, so
    // this proves the user-visible refusal was cleared rather than left stale.
    senseEvent.assertHittable()
    senseEvent.tap()
    refusalPanel.assertHittable()
    refusalTitle.scrollToHittable(in: app)
  }
}
