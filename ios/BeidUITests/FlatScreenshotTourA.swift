// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest

/// Stream A's Flat 2b frames. Merge #643's 01/02/03 methods into this one
/// tour file when the updated design branch reaches #648.
final class FlatScreenshotTourA: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testShot_13_EnterEventCode() {
    openAccountEventCodeEntry(frame: "-beid-shot-13")

    let field = app.textFields["Event code"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    XCTAssertEqual(field.value as? String, "ETH-TOKYO-26")
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    XCTAssertTrue(app.buttons["Cancel"].exists)
    XCTAssertTrue(app.buttons["Paste event code"].exists)
    XCTAssertTrue(app.buttons["Join Event"].exists)
    keepScreenshot(named: "13 Enter Event Code")
  }

  func testShot_13b_Error() {
    openAccountEventCodeEntry(frame: "-beid-shot-13b")

    let field = app.textFields["Event code"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    XCTAssertEqual(field.value as? String, "ETH-TOKY0-26")
    let errorLabel = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] %@", "Could not join event")
    ).firstMatch
    XCTAssertTrue(errorLabel.exists)
    XCTAssertTrue(
      app.staticTexts["beid couldn't join that event. Check the code and try again."].exists
    )
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    XCTAssertTrue(app.buttons["Cancel"].exists)
    keepScreenshot(named: "13b Enter Event Code Error")
  }

  /// Follow the actual Account sheet route so the stock Cancel toolbar item
  /// and nested-sheet presentation are part of each captured frame.
  private func openAccountEventCodeEntry(frame: String) {
    app.launchArguments = ["-beid-ui-test", frame]
    app.launch()

    app.buttons["Get Started"].tap()
    let allowBluetooth = app.buttons["Allow Bluetooth"]
    XCTAssertTrue(allowBluetooth.waitForExistence(timeout: 5))
    allowBluetooth.tap()

    let account = app.buttons["Account"]
    XCTAssertTrue(account.waitForExistence(timeout: 5))
    account.tap()

    let joinEvent = app.buttons["Join Event"]
    let list = app.collectionViews.firstMatch
    var attempts = 0
    while !joinEvent.exists && attempts < 6 {
      list.swipeUp()
      attempts += 1
    }
    XCTAssertTrue(joinEvent.exists, "Account's Join Event row was not reachable")
    joinEvent.tap()
    XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
  }

  private func keepScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
