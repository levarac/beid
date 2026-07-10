// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest

final class BeidIPadLayoutTests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testPrimaryFlowInPortrait() {
    XCUIDevice.shared.orientation = .portrait
    capturePrimaryFlow(orientation: "portrait")
  }

  func testPrimaryFlowInLandscape() {
    XCUIDevice.shared.orientation = .landscapeLeft
    capturePrimaryFlow(orientation: "landscape")
  }

  private func capturePrimaryFlow(orientation: String) {
    app.launchArguments = ["-beid-ui-test"]
    app.launch()

    assertWelcomeLayout(named: "welcome-\(orientation)")
    app.buttons["Get Started"].tap()
    capture(named: "wallet-connect-\(orientation)")

    app.buttons["Connect Wallet"].tap()
    XCTAssertTrue(app.buttons["Enable Bluetooth"].waitForExistence(timeout: 5))
    capture(named: "bluetooth-permission-\(orientation)")

    app.buttons["Enable Bluetooth"].tap()
    let senseEvent = app.buttons["Sense Event"]
    XCTAssertTrue(senseEvent.waitForExistence(timeout: 5))
    capture(named: "collection-empty-\(orientation)")

    app.buttons["Account"].tap()
    XCTAssertTrue(app.staticTexts["Account"].waitForExistence(timeout: 5))
    capture(named: "account-\(orientation)")
    app.buttons["Done"].tap()

    let resumedSenseEvent = app.buttons["Sense Event"]
    XCTAssertTrue(resumedSenseEvent.waitForExistence(timeout: 5))
    resumedSenseEvent.tap()
    XCTAssertTrue(app.staticTexts["Sensing automatically"].waitForExistence(timeout: 10))
    capture(named: "sensing-\(orientation)")

    XCTAssertTrue(app.staticTexts["Event Found"].waitForExistence(timeout: 10))
    capture(named: "event-found-\(orientation)")

    let signalLost = app.buttons["Simulate Signal Lost"]
    XCTAssertTrue(signalLost.waitForExistence(timeout: 10))
    capture(named: "verifying-\(orientation)")

    XCTAssertTrue(app.staticTexts["Verified"].waitForExistence(timeout: 10))
    capture(named: "verified-\(orientation)")

    XCTAssertTrue(app.staticTexts["Proof Collected"].waitForExistence(timeout: 10))
    capture(named: "proof-collected-\(orientation)")
    app.buttons["Done"].tap()

    XCTAssertTrue(resumedSenseEvent.waitForExistence(timeout: 5))
    capture(named: "collection-with-proof-\(orientation)")
    app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ETHGlobal Tokyo")).firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Proof Detail"].waitForExistence(timeout: 5))
    capture(named: "proof-detail-\(orientation)")
    app.navigationBars.buttons.firstMatch.tap()

    resumedSenseEvent.tap()
    XCTAssertTrue(signalLost.waitForExistence(timeout: 10))
    signalLost.tap()
    XCTAssertTrue(app.staticTexts["Signal Lost"].waitForExistence(timeout: 5))
    capture(named: "signal-lost-\(orientation)")
  }

  private func assertWelcomeLayout(named name: String) {
    let getStarted = app.buttons["Get Started"]
    XCTAssertTrue(getStarted.waitForExistence(timeout: 5))
    XCTAssertLessThan(getStarted.frame.width, 600, "The primary CTA must not stretch across an iPad screen.")
    XCTAssertGreaterThanOrEqual(getStarted.frame.height, 44)
    capture(named: name)
  }

  private func capture(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
