// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest

final class SupportBundleUITests: XCTestCase {
  func testAccountOpensSystemShareSheetOnlyOnUserAction() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-beid-ui-test"]
    app.launch()
    app.buttons["Get Started"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()
    XCTAssertTrue(app.buttons["home.account"].waitForExistence(timeout: 5))
    app.buttons["home.account"].tap()
    XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))

    // Flat 2b: the share row is the Account sheet's last list row, and the
    // version footer can cover it while XCTest still reports it hittable.
    let share = app.buttons["account.support.share"]
    let list = app.collectionViews.firstMatch
    for _ in 0..<8 where !isUnobstructed(share, in: list, app: app) { list.swipeUp() }
    XCTAssertTrue(isUnobstructed(share, in: list, app: app))
    XCTAssertFalse(app.otherElements["ActivityListView"].exists)
    share.tap()
    XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10))
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "support-share-sheet"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func isUnobstructed(_ element: XCUIElement, in container: XCUIElement, app: XCUIApplication) -> Bool {
    guard element.exists, container.exists else { return false }
    let footer = app.staticTexts["account.version.value"]
    let visibleBottom = min(
      container.frame.maxY - 60,
      footer.exists ? footer.frame.minY - 8 : container.frame.maxY
    )
    let frame = element.frame
    return element.isHittable && frame.minY >= container.frame.minY + 56 && frame.maxY <= visibleBottom
  }
}
