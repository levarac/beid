// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest

/// Coverage for Account's Join event row (gh#101). Joining from the Account
/// sheet starts sensing and presents the sensing screen (v1.1).
final class EventMembershipUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testAccountSheetJoinDismissesCodeEntryAndShowsSensing() {
    app.launchArguments = ["-beid-ui-test"]
    app.launch()

    app.buttons["Continue"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()
    XCTAssertTrue(app.buttons["home.demo.join"].waitForExistence(timeout: 5))

    app.buttons["home.account"].tap()
    XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))

    // Lower rows can exist in the accessibility tree while sitting behind
    // the footer. Scroll until the whole tappable row is unobstructed.
    let list = app.collectionViews.firstMatch
    scrollUntilTappable(app.buttons["Join event"], in: list)

    // Only one "Join event" element exists in the tree here — the nested
    // event-code sheet is not presented yet, so there's no collision with
    // EventCodeEntryView's own "Join event" submit button.
    let joinEventRow = app.buttons["Join event"]
    XCTAssertTrue(isUnobstructed(joinEventRow, in: list))
    XCTAssertTrue(joinEventRow.isEnabled)
    joinEventRow.tap()

    let codeField = app.textFields["Event code"]
    XCTAssertTrue(codeField.waitForExistence(timeout: 5))
    codeField.tap()
    // Submit via the keyboard's Join return-key action (onSubmit) rather
    // than tapping a button labeled "Join event" — this avoids the label
    // collision with the Account-sheet row while both could be in the tree.
    codeField.typeText("ETHTOKYO2026\n")

    // A successful join from the Account sheet closes the code sheet and the
    // Account sheet, selects the Now tab and presents the sensing screen,
    // which carries STOP SENSING once an event is joined.
    let codeSheetGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: codeField)
    wait(for: [codeSheetGone], timeout: 15)
    XCTAssertTrue(
      app.buttons["scan.stop-sensing"].waitForExistence(timeout: 10),
      "joining from the Account sheet must start sensing and show the sensing screen"
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
