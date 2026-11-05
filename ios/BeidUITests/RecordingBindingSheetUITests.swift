// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest

/// Recording must remain available without a wallet presentation.
final class RecordingBindingSheetUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws { continueAfterFailure = false }

  func testFirstRecordingDoesNotPresentWalletSheet() {
    reachRecording()
    XCTAssertFalse(app.buttons["Cancel"].exists)
    XCTAssertFalse(app.buttons["Connect wallet"].exists)
    XCTAssertTrue(app.buttons["scan.stop-sensing"].isHittable)
    XCTAssertFalse(app.staticTexts["MUTUAL"].exists)
    XCTAssertTrue(app.staticTexts["DEVICES HEARD"].exists)
    XCTAssertTrue(app.staticTexts["ELAPSED"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["scan.sealed"].exists)
  }

  func testKeepSensingReturnsToLiveRecordingWithoutWalletSheet() {
    reachRecording()
    app.buttons["scan.stop-sensing"].tap()
    XCTAssertTrue(app.staticTexts["Stop sensing?"].waitForExistence(timeout: 5))
    app.buttons["Keep sensing"].tap()
    XCTAssertTrue(app.buttons["scan.stop-sensing"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["Stop sensing?"].exists)
    XCTAssertFalse(app.buttons["Cancel"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["scan.sealed"].exists)
  }

  func testConfirmedStopSavesRecordAndOpensRecords() {
    reachRecording()
    app.buttons["scan.stop-sensing"].tap()
    XCTAssertTrue(app.staticTexts["Stop sensing?"].waitForExistence(timeout: 5))
    app.buttons["Stop and keep record"].tap()
    XCTAssertTrue(app.staticTexts["DONE · YOU CAN CLOSE THE APP"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Your record is saved on this phone. You can close the app."].exists)
    app.buttons["Done"].tap()
    XCTAssertTrue(app.buttons["View collection"].waitForExistence(timeout: 5))
    app.buttons["View collection"].tap()
    XCTAssertTrue(app.scrollViews["records.grid"].waitForExistence(timeout: 5))
    app.tabBars.buttons["Now"].tap()
    XCTAssertTrue(app.staticTexts["You’re done."].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["home.saved.view-record"].exists)
    XCTAssertTrue(app.staticTexts["home.listening"].exists)
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "N3-saved-record"
    shot.lifetime = .keepAlways
    add(shot)
  }

  private func reachRecording() {
    app.launchArguments = ["-beid-ui-test", "-beid-threshold-override", "1"]
    app.launch()
    app.buttons["Get Started"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()
    XCTAssertTrue(app.buttons["home.demo.join"].waitForExistence(timeout: 5))
    app.buttons["home.demo.join"].tap()
    XCTAssertTrue(app.buttons["Simulate Signal Lost"].waitForExistence(timeout: 30))
  }
}
