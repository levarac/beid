// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
import UIKit

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
    assertNavigationTitleDrawn("Now")
    let title = app.navigationBars.staticTexts["Now"]
    let activeContent = app.otherElements["home.active-event"]
    XCTAssertEqual(activeContent.frame.minX, title.frame.minX, accuracy: 1.0,
                   "The active content should align with the navigation title")
    XCTAssertFalse(
      app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ETH Tokyo 2026")).firstMatch.exists,
      "The active Proof must not also appear as a PAST row"
    )
    XCTAssertFalse(app.buttons["collection.stop-sensing"].exists)
    XCTAssertFalse(app.staticTexts["DO THIS NOW"].exists)
    let details = app.buttons["home.open-details"]
    XCTAssertTrue(details.isHittable)
    XCTAssertEqual(details.label, "Sensing details")
    XCTAssertGreaterThanOrEqual(details.frame.height, 44)
    capture("04")
  }

  func testLongEventNameWrapsInSensingAndStopConfirmation() {
    let eventName = "International Community Gathering and Technology Festival Tokyo 2026"
    launchHome(arguments: ["-beid-home-frame-04", "-beid-long-event-name-fixture"])
    app.buttons["home.open-details"].scrollToHittable(in: app)
    app.buttons["home.open-details"].tap()

    let heading = app.staticTexts[eventName]
    XCTAssertTrue(heading.waitForExistence(timeout: 5))
    XCTAssertGreaterThan(heading.frame.height, 40, "The event name should wrap without truncation")
    XCTAssertLessThan(heading.frame.height, 180, "A long event name should not dominate the sensing screen")
    XCTAssertLessThanOrEqual(heading.frame.maxX, app.windows.firstMatch.frame.maxX)
    SensingVisualOracle.assertInitialMetrics(in: app, test: self, name: "long-event-name")
    capture("sensing-long-event-name")

    app.buttons["scan.stop-sensing"].tap()
    XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
    capture("stop-confirm-long-event-name")
    XCTAssertTrue(app.alerts.firstMatch.buttons["Stop sensing"].isHittable)
  }

  func testLongJapaneseEventNameWithAccessibilityTextSize() {
    let eventName = "国際コミュニティ交流とテクノロジーフェスティバル東京二千二十六"
    launchHome(arguments: [
      "-beid-home-frame-04", "-beid-long-japanese-event-name-fixture",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
    ])
    app.buttons["home.open-details"].scrollToHittable(in: app)
    app.buttons["home.open-details"].tap()
    let heading = app.staticTexts[eventName]
    XCTAssertTrue(heading.waitForExistence(timeout: 5))
    XCTAssertLessThanOrEqual(heading.frame.maxX, app.windows.firstMatch.frame.maxX)
    XCTAssertTrue(app.buttons["scan.stop-sensing"].isHittable)
    capture("sensing-japanese-accessibility")
    app.buttons["scan.stop-sensing"].tap()
    let alert = app.alerts["Stop sensing?"]
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    XCTAssertTrue(alert.buttons["Cancel"].isHittable)
    XCTAssertTrue(alert.buttons["Stop sensing"].isHittable)
    capture("sensing-japanese-accessibility-alert")
    alert.buttons["Cancel"].tap()
    let heard = app.staticTexts["DEVICES HEARD"]
    let elapsed = app.staticTexts["ELAPSED"]
    heard.scrollToHittable(in: app)
    capture("sensing-japanese-accessibility-metrics")
    XCTAssertGreaterThanOrEqual(elapsed.frame.minY, heard.frame.maxY, "Metrics should stack at accessibility text sizes")
  }

  func testHomeMetricsStackAtAccessibilityTextSize() {
    launchHome(arguments: [
      "-beid-home-frame-04", "-beid-long-japanese-event-name-fixture",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
    ])
    let heard = app.staticTexts["DEVICES HEARD"]
    let elapsed = app.staticTexts["ELAPSED"]
    heard.scrollToHittable(in: app)
    XCTAssertGreaterThanOrEqual(elapsed.frame.minY, heard.frame.maxY, "Home metrics should stack at accessibility text sizes")
  }

  func testShot_04b_Empty() {
    launchHome(arguments: ["-beid-now-standby-fixture"])
    XCTAssertTrue(app.staticTexts["home.listening"].waitForExistence(timeout: 5))
    app.buttons["fixture.now.advance29"].tap()
    XCTAssertFalse(app.buttons["home.enter-code"].exists)
    app.buttons["fixture.now.advance1"].tap()
    capture("04b")
    app.buttons["home.enter-code"].tap()
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

  func testNowBluetoothOffShowsRecoveryTileAndSettingsAction() {
    for extra in [[], ["-beid-home-frame-04"]] as [[String]] {
      launchHome(arguments: ["-beid-now-bluetooth-off-fixture"] + extra)
      app.tabButton("Now").assertHittable()
      app.staticTexts["Turn Bluetooth back on."].scrollToHittable(in: app)
      XCTAssertTrue(app.staticTexts[
        "Your records are safe. Sensing resumes when Bluetooth is back."
      ].exists)
      app.buttons["home.bluetooth.open-settings"].scrollToHittable(in: app)
      XCTAssertTrue(app.staticTexts["BLUETOOTH OFF · SENSING PAUSED"].exists)
      app.terminate()
    }
  }

  func testHomeTabsUseNavigationTitles() {
    launchHome(arguments: ["-beid-home-frame-04b"])
    XCTAssertTrue(app.navigationBars.staticTexts["Now"].waitForExistence(timeout: 5))
    assertNavigationTitleDrawn("Now")
    XCTAssertTrue(app.buttons["home.account"].isHittable)
    capture("now-navigation")
    app.tabButton("Records").tap()
    XCTAssertTrue(app.navigationBars.staticTexts["Records"].waitForExistence(timeout: 5))
    assertNavigationTitleDrawn("Records")
    XCTAssertTrue(app.buttons["records.by-event"].isHittable)
    XCTAssertTrue(app.buttons["home.account"].isHittable)
    capture("records-navigation")
  }

  func testShot_08_EventDetail() {
    launchHome(arguments: ["-beid-event-detail-frame-08"])
    app.openRecordsByEvent()
    let event = app.buttons["home.past-event.ETHTOKYO2026"]
    XCTAssertTrue(event.waitForExistence(timeout: 5))
    event.tap()
    XCTAssertTrue(app.staticTexts["event-detail.heading"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars["Event"].exists)
    XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "event-detail.report.")).firstMatch.exists)
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "receipt stored")).firstMatch.exists)
    capture("08")

    let proof = app.buttons["event-detail.proof.1"]
    if !proof.isHittable { app.swipeUp() }
    XCTAssertTrue(proof.waitForExistence(timeout: 5))
    proof.tap()
    XCTAssertTrue(app.scrollViews["proof.detail.content"].waitForExistence(timeout: 5))
  }

  func testShot_08c_NoReports() {
    launchHome(arguments: ["-beid-event-detail-frame-08c"])
    app.openRecordsByEvent()
    let event = app.buttons["home.past-event.ETHTOKYO2026"]
    XCTAssertTrue(event.waitForExistence(timeout: 5))
    event.tap()
    XCTAssertTrue(app.staticTexts["event-detail.heading"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["NO REPORTS YET"].exists)
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "prepared")).firstMatch.exists)
    XCTAssertTrue(app.staticTexts["Measurements unavailable"].exists)
    XCTAssertTrue(app.buttons["event-detail.proof.1"].exists)
    capture("08c")
  }

  private func launchHome(arguments: [String]) {
    app.launchArguments = ["-beid-ui-test"] + arguments
    app.launch()
    let getStarted = app.buttons["Continue"]
    XCTAssertTrue(getStarted.waitForExistence(timeout: 5))
    getStarted.tap()
    let allowBluetooth = app.buttons["bluetooth.permission.continue"]
    XCTAssertTrue(allowBluetooth.waitForExistence(timeout: 5))
    allowBluetooth.tap()
    XCTAssertTrue(app.tabButton("Now").waitForExistence(timeout: 5))
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func assertNavigationTitleDrawn(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
    let label = app.navigationBars.staticTexts[title]
    XCTAssertTrue(label.waitForExistence(timeout: 5), file: file, line: line)
    let window = app.windows.firstMatch
    guard let image = window.screenshot().image.cgImage else {
      return XCTFail("Cannot inspect navigation title", file: file, line: line)
    }
    let scale = CGFloat(image.width) / window.frame.width
    let frame = label.frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
      .applying(CGAffineTransform(scaleX: scale, y: scale)).integral
    guard let crop = image.cropping(to: frame), crop.width > 0, crop.height > 0 else {
      return XCTFail("Navigation title has no screenshot area", file: file, line: line)
    }
    var pixels = [UInt8](repeating: 0, count: crop.width * crop.height)
    let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height,
                                    bitsPerComponent: 8, bytesPerRow: crop.width,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
      context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
      return true
    }
    XCTAssertTrue(rendered, file: file, line: line)
    let foregroundPixels = pixels.filter { $0 < 160 }.count
    XCTAssertLessThan(foregroundPixels, pixels.count / 2, "The navigation bar must have a light background", file: file, line: line)
    XCTAssertGreaterThan(foregroundPixels, 10, "Navigation title must be visible against its background", file: file, line: line)
  }
}
