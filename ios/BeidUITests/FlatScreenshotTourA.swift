// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest

/// Production-state route through Account to the Flat 2b sensing explainers.
/// These tests intentionally add no wallet or observation fixtures.
final class FlatScreenshotTourA: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testShot_15_AboutSensing() {
    openAboutSensing()
    attachScreenshot("15")
    assertMinimumHitTarget(app.buttons["aboutSensing.whatWeSend"])
    assertMinimumHitTarget(app.navigationBars.buttons.firstMatch)
  }

  func testShot_16_WhatWeSend() {
    openAboutSensing()
    let whatWeSend = app.buttons["aboutSensing.whatWeSend"]
    assertMinimumHitTarget(whatWeSend)
    whatWeSend.tap()

    let scroll = app.scrollViews["whatWeSend.scroll"]
    XCTAssertTrue(scroll.waitForExistence(timeout: 5))
    let firstRow = app.descendants(matching: .any)["whatWeSend.firstRow"]
    XCTAssertTrue(firstRow.isHittable)
    attachScreenshot("16")

    let finalRow = app.descendants(matching: .any)["whatWeSend.finalRow"]
    var attempts = 0
    while !finalRow.isHittable, attempts < 6 {
      scroll.swipeUp()
      attempts += 1
    }
    XCTAssertTrue(finalRow.isHittable)
    scroll.swipeUp()
    attachScreenshot("16-bottom")
    assertMinimumHitTarget(app.navigationBars.buttons.firstMatch)
  }

  private func openAboutSensing() {
    app.launchArguments = ["-beid-ui-test"]
    app.launch()

    let getStarted = app.buttons["Get Started"]
    XCTAssertTrue(getStarted.waitForExistence(timeout: 5))
    getStarted.tap()
    let allowBluetooth = app.buttons["Allow Bluetooth"]
    XCTAssertTrue(allowBluetooth.waitForExistence(timeout: 5))
    allowBluetooth.tap()
    let account = app.buttons["Account"]
    XCTAssertTrue(account.waitForExistence(timeout: 5))
    account.tap()

    let aboutSensing = app.buttons["About sensing"]
    let accountList = app.collectionViews.firstMatch
    var attempts = 0
    while !aboutSensing.isHittable, attempts < 6 {
      accountList.swipeUp()
      attempts += 1
    }
    XCTAssertTrue(aboutSensing.isHittable)
    assertMinimumHitTarget(aboutSensing)
    aboutSensing.tap()
    XCTAssertTrue(app.buttons["aboutSensing.whatWeSend"].waitForExistence(timeout: 5))
  }

  private func attachScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func assertMinimumHitTarget(_ control: XCUIElement) {
    XCTAssertTrue(control.exists)
    XCTAssertGreaterThanOrEqual(control.frame.width, 44)
    XCTAssertGreaterThanOrEqual(control.frame.height, 44)
  }
}
