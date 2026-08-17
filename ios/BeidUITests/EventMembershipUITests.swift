// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest

/// Regression test for the Account sheet's Join/Leave Event re-render defect
/// (gh#101): `AccountSheetView` observes only `AppCoordinator`, and
/// `AppCoordinator` does not re-publish `SensingCoordinator`'s `@Published
/// joinedEventCode`, so before the fix the Join/Leave controls went stale
/// after `leaveEvent()` cleared the code — Leave Event stayed enabled and
/// Join Event stayed disabled until the sheet was fully dismissed and
/// reopened.
final class EventMembershipUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testJoinEventRowReenablesAfterLeavingEvent() {
    app.launchArguments = ["-beid-ui-test"]
    app.launch()

    app.buttons["Get Started"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()
    XCTAssertTrue(app.buttons["Sense Event"].waitForExistence(timeout: 5))

    app.buttons["Account"].tap()
    XCTAssertTrue(app.staticTexts["Account"].waitForExistence(timeout: 5))

    // The Account sheet opens at the "Half screen" detent, and the List's
    // lower rows (including "Leave Event") aren't laid out into the
    // accessibility tree until scrolled into view, so scroll the List down
    // before looking for anything past "Venue Device".
    let list = app.collectionViews.firstMatch
    scrollUntilExists(app.buttons["Join Event"], in: list)

    // Only one "Join Event" element exists in the tree here — the nested
    // event-code sheet is not presented yet, so there's no collision with
    // EventCodeEntryView's own "Join Event" submit button.
    let joinEventRow = app.buttons["Join Event"]
    XCTAssertTrue(joinEventRow.exists)
    XCTAssertTrue(joinEventRow.isEnabled)
    joinEventRow.tap()

    let codeField = app.textFields["Event code"]
    XCTAssertTrue(codeField.waitForExistence(timeout: 5))
    codeField.tap()
    // Submit via the keyboard's Join return-key action (onSubmit) rather
    // than tapping a button labeled "Join Event" — this avoids the label
    // collision with the Account-sheet row while both could be in the tree.
    codeField.typeText("ETHTOKYO2026\n")

    // Back on the Account sheet: the nested sheet dismissed on success.
    scrollUntilExists(app.buttons["Leave Event"], in: list)
    let leaveEventRow = app.buttons["Leave Event"]
    XCTAssertTrue(leaveEventRow.exists)
    XCTAssertTrue(leaveEventRow.isEnabled, "Leave Event should be enabled once an event is joined")
    XCTAssertFalse(
      app.buttons["Join Event"].isEnabled,
      "Join Event should be disabled while an event is already joined"
    )

    leaveEventRow.tap()

    // The regression assertion: pre-fix, AccountSheetView never invalidates
    // when SensingCoordinator.joinedEventCode changes, so this stays
    // disabled. Post-fix it re-enables immediately.
    scrollUntilExists(app.buttons["Join Event"], in: list)
    XCTAssertTrue(
      app.buttons["Join Event"].isEnabled,
      "Join Event should re-enable immediately after leaving the event"
    )
  }

  /// The Account sheet's List is tall enough that rows past "Venue Device"
  /// aren't in the accessibility tree until scrolled into view. Scrolls the
  /// given container up until `element` exists, or gives up after a bounded
  /// number of attempts (leaving whatever assertion follows to fail with a
  /// clear message rather than looping forever).
  private func scrollUntilExists(_ element: XCUIElement, in container: XCUIElement, maxAttempts: Int = 6) {
    var attempts = 0
    while !element.exists, attempts < maxAttempts {
      container.swipeUp()
      attempts += 1
    }
  }
}
