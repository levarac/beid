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
    XCTAssertTrue(app.buttons["Account"].waitForExistence(timeout: 5))
    app.buttons["Account"].tap()

    let share = app.buttons["account.support.share"]
    for _ in 0..<8 where !share.isHittable { app.swipeUp() }
    XCTAssertTrue(share.isHittable)
    XCTAssertFalse(app.otherElements["ActivityListView"].exists)
    share.tap()
    XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10))
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "support-share-sheet"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
