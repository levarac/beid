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
    XCTAssertTrue(app.buttons["home.scan"].waitForExistence(timeout: 5))

    app.buttons["home.account"].tap()
    XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))

    // Lower rows can exist in the accessibility tree while sitting behind
    // the footer. Scroll until the whole tappable row is unobstructed.
    let list = app.collectionViews.firstMatch
    scrollUntilTappable(app.buttons["Join Event"], in: list)

    // Only one "Join Event" element exists in the tree here — the nested
    // event-code sheet is not presented yet, so there's no collision with
    // EventCodeEntryView's own "Join Event" submit button.
    let joinEventRow = app.buttons["Join Event"]
    XCTAssertTrue(isUnobstructed(joinEventRow, in: list))
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
    scrollUntilTappable(app.buttons["Leave Event"], in: list)
    let leaveEventRow = app.buttons["Leave Event"]
    XCTAssertTrue(isUnobstructed(leaveEventRow, in: list))
    XCTAssertTrue(leaveEventRow.isEnabled, "Leave Event should be enabled once an event is joined")
    XCTAssertFalse(
      app.buttons["Join Event"].isEnabled,
      "Join Event should be disabled while an event is already joined"
    )

    leaveEventRow.tap()

    // The regression assertion: pre-fix, AccountSheetView never invalidates
    // when SensingCoordinator.joinedEventCode changes, so this stays
    // disabled. Post-fix it re-enables immediately.
    scrollUntilTappable(app.buttons["Join Event"], in: list)
    XCTAssertTrue(
      app.buttons["Join Event"].isEnabled,
      "Join Event should re-enable immediately after leaving the event"
    )
  }

  /// An offscreen List row may already `exist`, so require its full frame to
  /// sit between the root Done control and the fixed Account footer.
  private func scrollUntilTappable(_ element: XCUIElement, in container: XCUIElement, maxAttempts: Int = 6) {
    var attempts = 0
    while !isUnobstructed(element, in: container), attempts < maxAttempts {
      if element.exists, element.frame.minY < container.frame.minY + 56 {
        container.swipeDown()
      } else {
        container.swipeUp()
      }
      attempts += 1
    }
  }

  private func isUnobstructed(_ element: XCUIElement, in container: XCUIElement) -> Bool {
    guard element.exists, container.exists else { return false }
    let visibleTop = container.frame.minY + 56
    let footer = app.staticTexts["account.version.value"]
    let visibleBottom = min(
      container.frame.maxY - 60,
      footer.exists ? footer.frame.minY - 8 : container.frame.maxY
    )
    let frame = element.frame
    return element.isHittable && frame.minY >= visibleTop && frame.maxY <= visibleBottom
  }
}
