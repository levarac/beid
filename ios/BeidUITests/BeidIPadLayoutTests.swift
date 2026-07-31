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

    // OnboardingMode.current is .guestFirst (event-first, the default — see
    // OnboardingFlagTests): Welcome's CTA routes straight to the
    // Bluetooth-permission screen, with no wallet-connect/event-code step.
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    capture(named: "bluetooth-permission-\(orientation)")

    app.buttons["Allow Bluetooth"].tap()
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
    XCTAssertTrue(app.staticTexts["Sensing automatically"].waitForExistence(timeout: 30))
    capture(named: "sensing-\(orientation)")

    XCTAssertTrue(app.staticTexts["Event Found"].waitForExistence(timeout: 30))
    capture(named: "event-found-\(orientation)")

    // Verifying/Verified/Proof Collected merge into one continuous
    // `.recording` phase (Scan Slice-2 sub-slice 2a) — there is no
    // terminal screen to wait for anymore. Threshold-confirm auto-flips
    // into `.recording` in the background; the "Simulate Signal Lost"
    // affordance existing is the earliest reliable signal that happened.
    let signalLost = app.buttons["Simulate Signal Lost"]
    XCTAssertTrue(signalLost.waitForExistence(timeout: 30))
    capture(named: "recording-\(orientation)")

    // The scan modal's close button ends the session at any point during
    // `.recording` — there is no separate terminal "Done" CTA anymore.
    app.buttons["Close"].tap()

    XCTAssertTrue(resumedSenseEvent.waitForExistence(timeout: 5))
    capture(named: "collection-with-proof-\(orientation)")
    app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ETHGlobal Tokyo")).firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Proof Detail"].waitForExistence(timeout: 5))
    capture(named: "proof-detail-\(orientation)")
    app.navigationBars.buttons.firstMatch.tap()

    resumedSenseEvent.tap()
    // Generous timeout: re-entering the scan flow a second time in one test
    // run has been observed to take noticeably longer than the first entry
    // (accumulated simulator/accessibility-tree overhead from the
    // intervening Collection/Proof Detail navigation), not a hang.
    XCTAssertTrue(signalLost.waitForExistence(timeout: 30))
    signalLost.tap()
    XCTAssertTrue(app.staticTexts["Signal Lost"].waitForExistence(timeout: 30))
    capture(named: "signal-lost-\(orientation)")
  }

  private func assertWelcomeLayout(named name: String) {
    let getStarted = app.buttons["Get Started"]
    let appWindow = app.windows.firstMatch
    XCTAssertTrue(getStarted.waitForExistence(timeout: 5))
    XCTAssertTrue(appWindow.exists)
    XCTAssertLessThan(
      getStarted.frame.width,
      appWindow.frame.width,
      "The primary CTA must not stretch across an iPad screen."
    )
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
