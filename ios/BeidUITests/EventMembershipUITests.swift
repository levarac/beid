// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest

/// Regression coverage for Account's Join Event re-render (gh#101).
/// AppCoordinator does not republish the joined code, so the row must observe
/// SensingCoordinator and disable while the same Account sheet stays open.
final class EventMembershipUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testJoinEventRowDisablesImmediatelyAfterJoining() {
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

    // Wait for the asynchronous join to dismiss its nested sheet, leaving
    // this same Account sheet open. Only EventMembershipSections observes
    // the joined code directly, so disabling here protects its re-render.
    let codeSheetGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: codeField)
    wait(for: [codeSheetGone], timeout: 15)
    let joinDisabled = expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: joinEventRow)
    wait(for: [joinDisabled], timeout: 5)
    XCTAssertFalse(app.buttons["Leave Event"].exists)
    XCTAssertFalse(
      joinEventRow.isEnabled,
      "Join Event should disable immediately when the current session joins"
    )
    app.buttons["Done"].tap()
    XCTAssertTrue(app.buttons["home.scan"].waitForExistence(timeout: 5))
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
