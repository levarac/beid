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

  func testShot_12_ReportDetail() {
    app.launchArguments = ["-beid-ui-test", "-beid-event-detail-frame-08"]
    app.launch()
    let getStarted = app.buttons["Get Started"]
    XCTAssertTrue(getStarted.waitForExistence(timeout: 5))
    getStarted.tap()
    let allowBluetooth = app.buttons["Allow Bluetooth"]
    XCTAssertTrue(allowBluetooth.waitForExistence(timeout: 5))
    allowBluetooth.tap()

    let event = app.buttons["home.past-event.ETHTOKYO2026"]
    XCTAssertTrue(event.waitForExistence(timeout: 5))
    event.tap()
    let report = app.buttons["event-detail.report.00000000-0000-4000-8000-000000000639"]
    for _ in 0..<5 where !report.isHittable { app.swipeUp() }
    XCTAssertTrue(report.waitForExistence(timeout: 5))
    XCTAssertTrue(report.isHittable)
    report.tap()

    let heading = app.staticTexts["report-detail.heading"]
    _ = heading.waitForExistence(timeout: 5)
    attachScreenshot("12")
    XCTAssertEqual(heading.label, "Report #1")
    XCTAssertTrue(app.staticTexts["report-detail.status"].label.contains("PREPARED ON DEVICE"))
    XCTAssertTrue(app.descendants(matching: .any)["report-detail.delivery"].label.contains("NOT SENT"))
    XCTAssertFalse(app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] %@", "verified")
    ).firstMatch.exists)
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

  /// The launch uses its own empty pack file (`OrganizerToolsObjects.storeURL`),
  /// so a pack an earlier test or run stored is not read here: this frame does
  /// not depend on an erased Simulator or on test order.
  func testShot_14_OrganizerTools() {
    openOrganizer()
    let route = app.buttons["organizer.venueBroadcast"]
    _ = route.waitForExistence(timeout: 5)
    attachScreenshot("14")
    assertMinimumHitTarget(route)
    XCTAssertEqual(route.value as? String, "Not broadcasting")

    // beid#702: the Saved pack area, and no trace of a key screen (14c).
    let heading = app.staticTexts["organizer.savedPack.heading"]
    XCTAssertTrue(heading.exists, "the Saved pack heading must be on 14")
    XCTAssertEqual(heading.label.uppercased(), "SAVED PACK")
    let status = app.staticTexts["organizer.savedPack.status"]
    XCTAssertTrue(status.exists)
    XCTAssertEqual(status.label.uppercased(), "NO SAVED PACK")
    XCTAssertFalse(app.staticTexts["organizer.savedPack.source"].exists, "a row with no value is not drawn")
    XCTAssertFalse(app.staticTexts["organizer.savedPack.storedAt"].exists, "a row with no value is not drawn")
    XCTAssertFalse(app.staticTexts["organizer.savedPack.note"].exists)
    assertNoKeyScreen()
  }

  func testShot_14_OrganizerTools_SavedPack() {
    openOrganizer(extraArguments: ["-beid-organizer-frame", "14-saved"])
    let status = app.staticTexts["organizer.savedPack.status"]
    _ = status.waitForExistence(timeout: 5)
    attachScreenshot("14-saved")
    XCTAssertTrue(status.exists, "the STATUS value must be on 14")
    XCTAssertEqual(status.label.uppercased(), "SAVED ON THIS DEVICE")
    XCTAssertEqual(app.staticTexts["organizer.savedPack.source"].label, "link, bundle from organizer.eth")
    XCTAssertTrue(app.staticTexts["organizer.savedPack.storedAt"].exists)
    XCTAssertEqual(
      app.staticTexts["organizer.savedPack.note"].label,
      "A saved pack is checked again every time it is loaded."
    )
    XCTAssertEqual(app.buttons["organizer.venueBroadcast"].value as? String, "Not broadcasting")
    assertNoKeyScreen()
  }

  func testShot_14_OrganizerTools_NotSaved() {
    openOrganizer(extraArguments: ["-beid-organizer-frame", "14-not-saved"])
    let status = app.staticTexts["organizer.savedPack.status"]
    _ = status.waitForExistence(timeout: 5)
    attachScreenshot("14-not-saved")
    XCTAssertTrue(status.exists, "the STATUS value must be on 14")
    XCTAssertEqual(status.label.uppercased(), "NOT SAVED")
    XCTAssertEqual(app.staticTexts["organizer.savedPack.source"].label, "link, bundle from organizer.eth")
    XCTAssertFalse(app.staticTexts["organizer.savedPack.storedAt"].exists, "an unsaved pack has no saved time")
    XCTAssertEqual(
      app.staticTexts["organizer.savedPack.note"].label,
      "This pack could not be saved. It stays on this device only until the app closes."
    )
    assertNoKeyScreen()
  }

  /// 14c is not built (beid#702): 14 has no text field, no key wording and no
  /// control inside the Saved pack area.
  private func assertNoKeyScreen() {
    XCTAssertEqual(app.textFields.count, 0)
    XCTAssertEqual(app.textViews.count, 0)
    for wording in ["Venue key", "Save key", "Remove key", "vk_"] {
      let match = app.descendants(matching: .any)
        .matching(NSPredicate(format: "label CONTAINS[c] %@", wording)).firstMatch
      XCTAssertFalse(match.exists, "14 must not show \"\(wording)\"")
    }
    for identifier in ["organizer.savedPack", "organizer.savedPack.status", "organizer.savedPack.source"] {
      XCTAssertFalse(app.buttons[identifier].exists, "\(identifier) must not be a control")
    }
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
    openVenue(frame: "14g")
    attachScreenshot("14g")
    let warningTitle = app.staticTexts["NOT SAVED"]
    let warningCopy = app.staticTexts["This pack could not be saved. It stays on this device only until the app closes."]
    let stop = app.buttons["Stop broadcasting"]
    XCTAssertTrue(warningTitle.isHittable)
    XCTAssertTrue(warningCopy.isHittable)
    XCTAssertLessThan(warningTitle.frame.maxY, warningCopy.frame.minY)
    XCTAssertLessThan(warningCopy.frame.maxY, stop.frame.minY)
    assertVenueControls()
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
