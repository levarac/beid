// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest

/// Account states for the Flat 2b Figma comparison. Each attachment includes
/// the full device screenshot so the PM can compare it with its named frame.
final class FlatScreenshotTourD: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testShot_10_Account() {
    openAccount()
    let copy = app.buttons["Copy address"]
    _ = copy.waitForExistence(timeout: 5)
    attachScreenshot("10")
    assertMinimumHitTarget(app.buttons["Done"])
    assertMinimumHitTarget(copy)
  }

  func testShot_10c_BluetoothOff() {
    openAccount(extraArguments: ["-beid-account-bluetooth-off-fixture"])
    let bluetoothStatus = app.buttons["account.bluetooth.status"]
    _ = bluetoothStatus.waitForExistence(timeout: 5)
    attachScreenshot("10c")
    XCTAssertEqual(bluetoothStatus.label, "Open Bluetooth Settings")
    assertMinimumHitTarget(app.buttons["Done"])
    assertMinimumHitTarget(app.buttons["Copy address"])
  }

  func testShot_10d_DisconnectConfirm() {
    openAccount()
    let disconnect = app.buttons["Disconnect wallet"]
    let list = app.collectionViews.firstMatch
    var attempts = 0
    while !disconnect.isHittable, attempts < 6 {
      list.swipeUp()
      attempts += 1
    }
    XCTAssertTrue(disconnect.isHittable)
    disconnect.tap()
    let title = app.staticTexts["Disconnect wallet?"]
    _ = title.waitForExistence(timeout: 5)
    attachScreenshot("10d")
    XCTAssertTrue(title.exists)
    let keepConnected = app.buttons["Keep connected"]
    assertMinimumHitTarget(keepConnected)
    assertMinimumHitTarget(app.buttons["Done"])
    assertMinimumHitTarget(app.buttons["Copy address"])
    assertMinimumHitTarget(app.buttons["Disconnect"])
  }

  func testShot_10e_Copied() {
    openAccount()
    let copy = app.buttons["Copy address"]
    XCTAssertTrue(copy.waitForExistence(timeout: 5))
    copy.tap()
    let copied = app.buttons["account.copy.feedback"]
    _ = copied.waitForExistence(timeout: 5)
    attachScreenshot("10e")
    assertMinimumHitTarget(app.buttons["Done"])
    assertMinimumHitTarget(copied)
  }

  func testShot_14_OrganizerTools() {
    openOrganizer()
    let route = app.buttons["organizer.venueBroadcast"]
    _ = route.waitForExistence(timeout: 5)
    attachScreenshot("14")
    assertMinimumHitTarget(route)
    XCTAssertEqual(route.value as? String, "Not broadcasting")
  }

  func testShot_14b_VenueBroadcast() {
    openVenue(frame: "14b")
    attachScreenshot("14b")
    assertVenueControls()
    XCTAssertTrue(app.staticTexts["ETH Tokyo 2026"].exists)
  }

  func testShot_14d_ScanQR() {
    openVenue(frame: "14d")
    app.buttons["Scan QR code"].tap()
    _ = app.staticTexts["venue.scanner.title"].waitForExistence(timeout: 5)
    attachScreenshot("14d")
    XCTAssertTrue(app.staticTexts["venue.scanner.title"].exists)
    assertMinimumHitTarget(app.buttons["Cancel scan"])
    XCTAssertTrue(app.staticTexts["venue.scanner.caption"].exists)
  }

  func testShot_14e_InvalidLink() {
    assertVenueFrame("14e", outcome: "Not a venue link")
  }

  func testShot_14e2_NoSource() {
    assertVenueFrame("14e2", outcome: "Link names no source")
  }

  func testShot_14e3_UnsupportedSource() {
    assertVenueFrame("14e3", outcome: "Source not supported")
  }

  func testShot_14f_NoCameraAccess() {
    openVenue(frame: "14f")
    attachScreenshot("14f")
    assertVenueControls()
    XCTAssertTrue(app.staticTexts["NO CAMERA ACCESS"].exists)
    let openSettings = openSettingsControl
    XCTAssertTrue(openSettings.exists)
    XCTAssertTrue(openSettings.elementType == .button || openSettings.elementType == .link)
    XCTAssertTrue(openSettings.isHittable)
    assertMinimumHitTarget(openSettings)
  }

  func testShot_14f2_ScanningUnavailable() {
    assertVenueFrame("14f2", outcome: "Scanning unavailable")
    XCTAssertFalse(openSettingsControl.exists)
  }

  func testShot_14f3_CameraCouldNotStart() {
    assertVenueFrame("14f3", outcome: "Camera could not start")
    XCTAssertFalse(openSettingsControl.exists)
  }

  func testShot_14g_NotSaved() {
    assertVenueFrame("14g", outcome: "Not saved")
  }

  private func assertVenueFrame(_ code: String, outcome: String) {
    openVenue(frame: code)
    attachScreenshot(code)
    assertVenueControls()
    XCTAssertTrue(app.staticTexts[outcome.uppercased()].exists)
  }

  private func assertVenueControls() {
    assertMinimumHitTarget(app.buttons["Paste venue link"])
    assertMinimumHitTarget(app.buttons["Use this link"])
    assertMinimumHitTarget(app.buttons["Scan QR code"])
    assertMinimumHitTarget(app.buttons["Copy event ID"])
    assertMinimumHitTarget(app.buttons["Stop broadcasting"])
    XCTAssertTrue(app.descendants(matching: .any)["Venue link"].exists)
  }

  private var openSettingsControl: XCUIElement {
    app.descendants(matching: .any).matching(identifier: "Open Settings").firstMatch
  }

  private func openOrganizer(extraArguments: [String] = []) {
    openAccount(extraArguments: extraArguments)
    let organizer = app.buttons["Organizer tools"]
    XCTAssertTrue(organizer.waitForExistence(timeout: 5))
    organizer.tap()
    XCTAssertTrue(app.buttons["organizer.venueBroadcast"].waitForExistence(timeout: 5))
  }

  private func openVenue(frame: String) {
    openOrganizer(extraArguments: ["-beid-venue-frame", frame])
    app.buttons["organizer.venueBroadcast"].tap()
    let scan = app.buttons["Scan QR code"]
    XCTAssertTrue(scan.waitForExistence(timeout: 5))
    let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: scan)
    XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
  }

  private func openAccount(extraArguments: [String] = []) {
    app.launchArguments = ["-beid-ui-test", "-beid-account-connected-fixture"] + extraArguments
    app.launch()

    app.buttons["Get Started"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()
    let account = app.buttons["home.account"]
    XCTAssertTrue(account.waitForExistence(timeout: 5))
    account.tap()
  }

  private func attachScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func assertMinimumHitTarget(_ control: XCUIElement) {
    XCTAssertTrue(control.exists)
    // CoreGraphics can represent an exact 44pt frame as 43.99999999999994.
    XCTAssertGreaterThanOrEqual(control.frame.width + 0.01, 44)
    XCTAssertGreaterThanOrEqual(control.frame.height + 0.01, 44)
  }
}
