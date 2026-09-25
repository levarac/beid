// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest

/// Deterministic Home frames for PM's Figma side-by-side review. Each launch
/// passes -beid-ui-test before its frame fixture so the production app never
/// seeds sample records or sensing state.
final class FlatScreenshotTourB: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testShot_04_Events() {
    launchHome(arguments: ["-beid-home-frame-04"])
    XCTAssertTrue(app.otherElements["home.active-event"].waitForExistence(timeout: 5))
    XCTAssertFalse(
      app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ETH Tokyo 2026")).firstMatch.exists,
      "The active Proof must not also appear as a PAST row"
    )
    let stopSensing = app.buttons["collection.stop-sensing"]
    XCTAssertTrue(stopSensing.waitForExistence(timeout: 5))
    XCTAssertTrue(stopSensing.isHittable, "The live Stop control must clear the fixed Scan button")
    capture("04")
  }

  func testShot_04b_Empty() {
    launchHome(arguments: ["-beid-home-frame-04b"])
    XCTAssertTrue(app.staticTexts["NO EVENTS YET"].waitForExistence(timeout: 5))
    capture("04b")
    app.buttons["Enter event code"].tap()
    XCTAssertTrue(app.staticTexts["eventCode.title"].waitForExistence(timeout: 5))
    app.buttons["Cancel"].tap()
  }

  func testShot_04c_ClockWarning() {
    launchHome(arguments: ["-beid-home-frame-04c"])
    XCTAssertTrue(
      app.staticTexts["CLOCK OUT OF SYNC"].waitForExistence(timeout: 10)
    )
    XCTAssertFalse(app.staticTexts["CLOCK CHECK UNAVAILABLE"].exists)
    capture("04c")
  }

  func testShot_08_EventDetail() {
    launchHome(arguments: ["-beid-event-detail-frame-08"])
    let event = app.buttons["home.past-event.ETHTOKYO2026"]
    XCTAssertTrue(event.waitForExistence(timeout: 5))
    event.tap()
    XCTAssertTrue(app.staticTexts["event-detail.heading"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "prepared")).firstMatch.exists)
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "receipt stored")).firstMatch.exists)
    capture("08")

    let proof = app.buttons["event-detail.proof.1"]
    if !proof.isHittable { app.swipeUp() }
    XCTAssertTrue(proof.waitForExistence(timeout: 5))
    proof.tap()
    XCTAssertTrue(app.staticTexts["proof.detail.title"].waitForExistence(timeout: 5))
  }

  func testShot_08c_NoReports() {
    launchHome(arguments: ["-beid-event-detail-frame-08c"])
    let event = app.buttons["home.past-event.ETHTOKYO2026"]
    XCTAssertTrue(event.waitForExistence(timeout: 5))
    event.tap()
    XCTAssertTrue(app.staticTexts["NO REPORTS YET"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "prepared")).firstMatch.exists)
    XCTAssertTrue(app.staticTexts["Measurements unavailable"].exists)
    XCTAssertTrue(app.buttons["event-detail.proof.1"].exists)
    capture("08c")
  }

  private func launchHome(arguments: [String]) {
    app.launchArguments = ["-beid-ui-test"] + arguments
    app.launch()
    let getStarted = app.buttons["Get Started"]
    XCTAssertTrue(getStarted.waitForExistence(timeout: 5))
    getStarted.tap()
    let allowBluetooth = app.buttons["Allow Bluetooth"]
    XCTAssertTrue(allowBluetooth.waitForExistence(timeout: 5))
    allowBluetooth.tap()
    XCTAssertTrue(app.buttons["home.scan"].waitForExistence(timeout: 5))
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
