// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest

/// Stream C's deterministic Figma comparison tour. Every app-side sample is
/// gated by -beid-ui-test and -beid-sensing-shot. The 05b frame is excluded by
/// the owner: it depicts a verification process and reciprocal connections
/// that v1.0 cannot establish on-device.
final class FlatScreenshotTourC: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testShot_05_Sensing() { capture("05") }
  func testShot_05a_Detecting() { capture("05a") }
  func testShot_05a2_Detecting20s() { capture("05a2") }
  func testShot_05a3_DetectingFirstTime() { capture("05a3") }
  func testShot_05d_CantJoin() { capture("05d") }
  func testShot_05e_StopConfirm() { capture("05e") }
  func testShot_06_Sealed() { capture("06") }
  func testShot_07_ProofCollected() { capture("07") }

  private func capture(_ code: String, file: StaticString = #filePath, line: UInt = #line) {
    let app = XCUIApplication()
    app.launchArguments = ["-beid-ui-test", "-beid-sensing-shot", code]
    app.launch()

    let getStarted = app.buttons["Get Started"]
    XCTAssertTrue(getStarted.waitForExistence(timeout: 10), file: file, line: line)
    getStarted.tap()

    let allowBluetooth = app.buttons["Allow Bluetooth"]
    XCTAssertTrue(allowBluetooth.waitForExistence(timeout: 10), file: file, line: line)
    allowBluetooth.tap()

    let senseEvent = app.buttons["home.scan"]
    XCTAssertTrue(senseEvent.waitForExistence(timeout: 10), file: file, line: line)
    senseEvent.tap()

    XCTAssertTrue(app.staticTexts["ETH Tokyo 2026"].waitForExistence(timeout: 10), file: file, line: line)
    if code == "07" {
      XCTAssertTrue(app.buttons["View collection"].exists, file: file, line: line)
      let recordID = app.staticTexts["proof-collected.record-id"]
      XCTAssertTrue(recordID.exists, file: file, line: line)
      XCTAssertEqual(
        recordID.label,
        "Record ID 42110000-0000-4000-8000-000000000000",
        file: file, line: line
      )
      XCTAssertGreaterThan(recordID.frame.width, 100, file: file, line: line)
      XCTAssertEqual(app.staticTexts["proof-collected.status"].label, "SEALED", file: file, line: line)
    }
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = code
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
