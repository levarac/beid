// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest

/// The demo path is deliberately not a registry-verification outcome. This
/// UI test protects the absence contract on every event-card screen while the
/// pure presentation tests cover the visible non-demo status variants.
final class EventIdentityVerificationUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testDemoEventSuppressesIdentityVerificationRow() {
    app.launchArguments = ["-beid-ui-test"]
    app.launch()

    app.buttons["Get Started"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()

    let senseEvent = app.buttons["Sense Event"]
    XCTAssertTrue(senseEvent.waitForExistence(timeout: 5))
    senseEvent.tap()

    XCTAssertTrue(app.staticTexts["scan.event-found"].waitForExistence(timeout: 30))
    XCTAssertFalse(identityVerificationRow.exists)

    let simulateSignalLost = app.buttons["Simulate Signal Lost"]
    XCTAssertTrue(simulateSignalLost.waitForExistence(timeout: 30))
    XCTAssertFalse(identityVerificationRow.exists)
    simulateSignalLost.tap()

    XCTAssertTrue(app.staticTexts["Signal Lost"].waitForExistence(timeout: 5))
    XCTAssertFalse(identityVerificationRow.exists)
  }

  private var identityVerificationRow: XCUIElement {
    app.descendants(matching: .any)["event-identity-verification-row"]
  }
}
