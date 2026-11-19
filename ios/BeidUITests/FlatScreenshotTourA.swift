// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
import UIKit

/// Captures Flat 2b onboarding and event-code states through production navigation.
final class FlatScreenshotTourA: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testShot_01_Welcome() {
    launch()
    assertExactText("Record you were there.", message: "Welcome must use the approved Record headline")
    assertExactText(
      "Nearby devices say hello to each other, and keep a note anyone can verify.",
      message: "Welcome must use the approved keep-a-note explanation"
    )
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "beid")).firstMatch
        .waitForExistence(timeout: 5),
      "Welcome must retain its brand label"
    )
    XCTAssertTrue(app.buttons["Continue"].exists)
    XCTAssertFalse(app.buttons["Connect Wallet"].exists)
    XCTAssertFalse(app.buttons["Connect wallet instead"].exists)
    capture("01 Welcome")
  }

  func testShot_02_EnableBluetooth() {
    launch()
    showBluetoothPermission()
    let title = app.staticTexts["Allow Bluetooth access"]
    XCTAssertTrue(title.exists && title.isHittable, "The Bluetooth permission request must be visible")
    assertVisibleDarkText(title)
    XCTAssertFalse(app.navigationBars["Bluetooth"].exists)
    assertExactText("Allow Bluetooth access")
    assertExactText("Your device may ask for permission.")
    assertExactText(
      "beid needs Bluetooth to find your event and exchange signals with nearby devices. These observations help create your Record.",
      message: "Bluetooth permission must describe device observation"
    )
    XCTAssertTrue(app.staticTexts["bluetooth.permission.purpose"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["Setup · 1 / 1"].exists)
    XCTAssertFalse(app.buttons["Connect Wallet"].exists)
    let continueButton = app.buttons["bluetooth.permission.continue"]
    XCTAssertTrue(continueButton.exists)
    XCTAssertEqual(continueButton.label, "Continue")
    capture("02 Bluetooth")
    continueButton.tap()
    XCTAssertTrue(app.buttons["home.account"].waitForExistence(timeout: 5))
  }

  func testShot_03_BluetoothOff() {
    launch(bluetoothOff: true)
    showBluetoothPermission()
    app.buttons["bluetooth.permission.continue"].tap()
    XCTAssertTrue(app.staticTexts["Bluetooth is off"].waitForExistence(timeout: 5))
    let checkAgain = app.buttons["bluetooth.off.check-again"]
    XCTAssertTrue(checkAgain.isHittable)
    XCTAssertEqual(checkAgain.label, "Check again")
    assertExactText("Turn on Bluetooth in Settings > Bluetooth, then return to beid.")
    assertExactText("beid can’t find nearby events or record observations while Bluetooth is off.")
    capture("03 Bluetooth Off")
  }

  func testShot_13_EnterEventCode() {
    openAccountEventCodeEntry(frame: "-beid-shot-13")
    keepScreenshot(named: "13 Enter Event Code")
    let accessibilityTree = XCTAttachment(string: app.debugDescription)
    accessibilityTree.name = "13 accessibility tree"
    accessibilityTree.lifetime = .keepAlways
    add(accessibilityTree)

    let field = app.textFields["Event code"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    XCTAssertEqual(field.value as? String, "ETH-TOKYO-26")
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    XCTAssertTrue(app.buttons["Cancel"].exists)
    let paste = app.buttons["eventCode.paste"]
    XCTAssertTrue(paste.exists)
    XCTAssertEqual(paste.label, "Paste event code")
    XCTAssertTrue(app.buttons["Join event"].exists)
  }

  func testShot_13b_Error() {
    openAccountEventCodeEntry(frame: "-beid-shot-13b")
    keepScreenshot(named: "13b Enter Event Code Error")

    let field = app.textFields["Event code"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    XCTAssertEqual(field.value as? String, "ETH-TOKY0-26")
    let errorLabel = app.staticTexts.matching(
      NSPredicate(format: "label == %@", "COULD NOT JOIN EVENT")
    ).firstMatch
    XCTAssertTrue(errorLabel.exists)
    XCTAssertTrue(
      app.staticTexts["beid couldn't join that event. Check the code and try again."].exists
    )
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    XCTAssertTrue(app.buttons["Cancel"].exists)
  }

  /// Follow the actual Account sheet route so the Cancel toolbar item
  /// and nested-sheet presentation are part of each captured frame.
  private func openAccountEventCodeEntry(frame: String? = nil) {
    app.launchArguments = ["-beid-ui-test"]
    if let frame { app.launchArguments.append(frame) }
    app.launch()

    app.buttons["Continue"].tap()
    let allowBluetooth = app.buttons["bluetooth.permission.continue"]
    XCTAssertTrue(allowBluetooth.waitForExistence(timeout: 5))
    allowBluetooth.tap()

    let account = app.buttons["home.account"]
    XCTAssertTrue(account.waitForExistence(timeout: 5))
    account.tap()

    let joinEvent = app.buttons["Join event"]
    let list = app.collectionViews.firstMatch
    var attempts = 0
    while !joinEvent.exists && attempts < 6 {
      list.swipeUp()
      attempts += 1
    }
    XCTAssertTrue(joinEvent.exists, "Account's Join event row was not reachable")
    joinEvent.tap()
    XCTAssertTrue(app.staticTexts["eventCode.title"].waitForExistence(timeout: 5))
  }

  private func keepScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func launch(bluetoothOff: Bool = false) {
    app.launchArguments = ["-beid-ui-test"]
    if bluetoothOff {
      app.launchArguments.append("-beid-bluetooth-off-fixture")
    }
    app.launch()
  }

  private func showBluetoothPermission() {
    let getStarted = app.buttons["Continue"]
    XCTAssertTrue(
      getStarted.waitForExistence(timeout: 5),
      "Welcome must offer its primary action before Bluetooth permission"
    )
    getStarted.tap()
    XCTAssertTrue(app.buttons["bluetooth.permission.continue"].waitForExistence(timeout: 5))
  }

  private func capture(_ frameCode: String) {
    keepScreenshot(named: frameCode)
  }

  private func assertVisibleDarkText(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    let windowElement = app.windows.firstMatch
    let screenshot = windowElement.screenshot().image
    guard let image = screenshot.cgImage else {
      return XCTFail("Cannot inspect the navigation title screenshot", file: file, line: line)
    }
    let window = windowElement.frame
    let scale = CGFloat(image.width) / window.width
    let frame = element.frame.offsetBy(dx: -window.minX, dy: -window.minY)
      .applying(CGAffineTransform(scaleX: scale, y: scale)).integral
    guard let crop = image.cropping(to: frame), crop.width > 0, crop.height > 0 else {
      return XCTFail("Navigation title has no visible screenshot area", file: file, line: line)
    }
    var pixels = [UInt8](repeating: 255, count: crop.width * crop.height)
    let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress, width: crop.width, height: crop.height,
        bitsPerComponent: 8, bytesPerRow: crop.width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
      ) else { return false }
      context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
      return true
    }
    XCTAssertTrue(rendered, "Cannot render the navigation title screenshot", file: file, line: line)
    XCTAssertGreaterThan(pixels.filter { $0 < 160 }.count, 10, "Navigation title must be drawn", file: file, line: line)
  }

  func testWelcomeVersionMatchesTheAppMetadataInAccount() {
    launch()
    let version = app.staticTexts["welcome.version"]
    XCTAssertTrue(
      version.waitForExistence(timeout: 5),
      "Welcome must expose the actual app short version"
    )
    let welcomeVersion = version.label
    showBluetoothPermission()
    app.buttons["bluetooth.permission.continue"].tap()
    XCTAssertTrue(app.buttons["home.account"].waitForExistence(timeout: 5))
    app.buttons["home.account"].tap()
    let accountVersion = app.staticTexts["account.version.value"]
    XCTAssertTrue(accountVersion.waitForExistence(timeout: 5))
    XCTAssertTrue(accountVersion.label.hasPrefix("beid "))
    let metadata = String(accountVersion.label.dropFirst("beid ".count))
    let shortVersion = metadata.components(separatedBy: " (").first ?? ""
    XCTAssertFalse(shortVersion.isEmpty)
    XCTAssertEqual(welcomeVersion, "V \(shortVersion)")
  }

  func testEventCodeGuidanceSupportsPasteWithoutAShortCodeExample() {
    openAccountEventCodeEntry()
    assertExactText(
      "If your event is not listed, ask the organizer for its event code and paste it here.",
      message: "Event code entry must describe organizer-supplied paste input"
    )
    let field = app.textFields["Event code"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    XCTAssertEqual(field.placeholderValue, "Paste event code")
    XCTAssertTrue(app.buttons["eventCode.paste"].exists)
    XCTAssertFalse(app.buttons["Connect wallet instead"].exists)
    XCTAssertTrue(app.buttons["Cancel"].exists)
    app.buttons["Cancel"].tap()
    XCTAssertTrue(app.buttons["account.aboutSensing"].waitForExistence(timeout: 5))
  }

  func testWelcomeExplanationDescribesJoinAndForegroundSensing() {
    launch()
    app.buttons["welcome.howItWorks"].tap()
    XCTAssertTrue(app.buttons["aboutSensing.whatWeSend"].waitForExistence(timeout: 5))
    assertExplainerCopy()
  }

  func testWelcomeExplanationReportsUnavailableSendingDetails() {
    launch()
    app.buttons["welcome.howItWorks"].tap()
    let scroll = app.scrollViews["aboutSensing.scroll"]
    XCTAssertTrue(scroll.waitForExistence(timeout: 5))
    let capability = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Sending is on.")
    ).firstMatch
    for _ in 0..<5 where !capability.isHittable { scroll.swipeUp() }
    XCTAssertTrue(capability.isHittable, "About must describe the actual enabled sending capability")
    assertContainsText(
      "Sending details are not available here.",
      message: "About must make unavailable sending details explicit"
    )
    assertExactText("SENDING STATUS")
    XCTAssertFalse(app.staticTexts["SENDING STATUS · ALL SAVED OBSERVATIONS"].exists)
    XCTAssertFalse(app.staticTexts["Up to date"].exists)
  }

  func testAboutEnabledCapabilityKeepsSendingDetailsUnavailable() {
    assertSendingCapability(setting: "on", expected: "Sending is on.")
  }

  func testAboutDisabledCapabilityKeepsSendingDetailsUnavailable() {
    assertSendingCapability(setting: "off", expected: "Sending is off in this version.")
  }

  private func assertSendingCapability(setting: String, expected: String) {
    app.launchArguments = ["-beid-ui-test", "-beid-about-sending", setting]
    app.launch()
    app.buttons["welcome.howItWorks"].tap()
    let scroll = app.scrollViews["aboutSensing.scroll"]
    XCTAssertTrue(scroll.waitForExistence(timeout: 5))
    let capability = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch
    for _ in 0..<5 where !capability.isHittable { scroll.swipeUp() }
    XCTAssertTrue(capability.isHittable)
    assertContainsText("Sending details are not available here.")
    assertExactText("SENDING STATUS")
    XCTAssertFalse(app.staticTexts["SENDING STATUS · ALL SAVED OBSERVATIONS"].exists)
    XCTAssertFalse(app.staticTexts["Up to date"].exists)
    let otherState = setting == "on"
      ? "Sending is off in this version." : "Sending is on."
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", otherState)).firstMatch.exists)
  }

  private func assertExplainerCopy() {
    assertContainsText("Choose your event", message: "The explanation must require explicit event selection")
    assertContainsText("beid looks for nearby events. Tap JOIN when your event appears.")
    assertContainsText("Private by design")
    assertContainsText("Devices exchange rotating anonymous IDs, not names or wallet addresses.")
    assertContainsText("Keep beid open")
    assertContainsText("Keep the app open while sensing. Tap STOP SENSING when you want to finish.")
  }

  private func assertExactText(_ text: String, message: String = "Expected complete screen copy") {
    let element = app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
    XCTAssertTrue(element.waitForExistence(timeout: 5), message)
    XCTAssertEqual(element.label, text, message)
  }

  private func assertContainsText(_ text: String, message: String = "Expected complete explanation copy") {
    let element = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    XCTAssertTrue(element.waitForExistence(timeout: 5), message)
    XCTAssertTrue(element.label.contains(text), message)
  }

  // MARK: - #646 About sensing / What we send

  /// 01's HOW IT WORKS reaches 15, and 15 reaches 16 (#646 entry wiring).
  func testWelcomeHowItWorksOpensAboutSensingAndWhatWeSend() {
    launch()
    let howItWorks = app.buttons["welcome.howItWorks"]
    XCTAssertTrue(howItWorks.waitForExistence(timeout: 5))
    assertMinimumHitTarget(howItWorks)
    howItWorks.tap()
    XCTAssertTrue(app.navigationBars["About sensing"].waitForExistence(timeout: 5))
    let whatWeSend = app.buttons["aboutSensing.whatWeSend"]
    XCTAssertTrue(whatWeSend.waitForExistence(timeout: 5))
    whatWeSend.tap()
    XCTAssertTrue(app.descendants(matching: .any)["whatWeSend.firstRow"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars["What we send"].waitForExistence(timeout: 5))
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(whatWeSend.waitForExistence(timeout: 5))
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(howItWorks.waitForExistence(timeout: 5))
  }

  func testShot_15_AboutSensing() {
    openAboutSensing()
    let title = app.navigationBars.staticTexts["About sensing"]
    XCTAssertTrue(title.waitForExistence(timeout: 5) && title.isHittable)
    assertVisibleDarkText(title)
    let firstSection = app.staticTexts["HOW IT WORKS"]
    XCTAssertEqual(firstSection.frame.minX, title.frame.minX, accuracy: 1.0,
                   "The first section should align with the navigation title")
    keepScreenshot(named: "15")
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
    let title = app.navigationBars.staticTexts["What we send"]
    XCTAssertTrue(title.waitForExistence(timeout: 5) && title.isHittable)
    assertVisibleDarkText(title)
    let firstSection = app.staticTexts["WHAT WE SEND"]
    XCTAssertEqual(firstSection.frame.minX, title.frame.minX, accuracy: 1.0,
                   "The first section should align with the navigation title")
    let firstRow = app.descendants(matching: .any)["whatWeSend.firstRow"]
    XCTAssertTrue(firstRow.isHittable)
    keepScreenshot(named: "16")

    let finalRow = app.descendants(matching: .any)["whatWeSend.finalRow"]
    var attempts = 0
    while !finalRow.isHittable, attempts < 6 {
      scroll.swipeUp()
      attempts += 1
    }
    XCTAssertTrue(finalRow.isHittable)
    scroll.swipeUp()
    let inlineTitle = app.navigationBars.staticTexts["What we send"]
    XCTAssertTrue(inlineTitle.exists && inlineTitle.isHittable)
    assertVisibleDarkText(inlineTitle)
    keepScreenshot(named: "16-bottom")
    assertMinimumHitTarget(app.navigationBars.buttons.firstMatch)
  }

  private func openAboutSensing() {
    app.launchArguments = ["-beid-ui-test"]
    app.launch()

    let getStarted = app.buttons["Continue"]
    XCTAssertTrue(getStarted.waitForExistence(timeout: 5))
    getStarted.tap()
    let allowBluetooth = app.buttons["bluetooth.permission.continue"]
    XCTAssertTrue(allowBluetooth.waitForExistence(timeout: 5))
    allowBluetooth.tap()
    let account = app.buttons["home.account"]
    XCTAssertTrue(account.waitForExistence(timeout: 5))
    account.tap()

    let aboutSensing = app.buttons["account.aboutSensing"]
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

  private func assertMinimumHitTarget(_ control: XCUIElement) {
    XCTAssertTrue(control.exists)
    XCTAssertGreaterThanOrEqual(control.frame.width, 44)
    XCTAssertGreaterThanOrEqual(control.frame.height, 44)
  }
}
