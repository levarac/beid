// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest

/// Account states for the Flat 2b Figma comparison. Each attachment includes
/// the full device screenshot so the PM can compare it with its named frame.
final class FlatScreenshotTourD: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testAccountNavigationBarShowsTitleAndDoneDismisses() {
    openAccount()
    let bar = app.navigationBars["Account"]
    XCTAssertTrue(bar.waitForExistence(timeout: 5))
    XCTAssertTrue(bar.staticTexts["Account"].exists)
    let done = bar.buttons["Done"]
    done.assertHittable()
    assertMinimumHitTarget(done)
    attachScreenshot("account-navigation-bar")
    done.tap()
    XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
    app.buttons["home.account"].assertHittable()
  }

  func testAccountPushedScreenUsesNativeBackInTheSameBar() {
    openAccount()
    let accountBar = app.navigationBars["Account"]
    XCTAssertTrue(accountBar.waitForExistence(timeout: 5))
    let originalFrame = accountBar.frame
    app.buttons["Organizer tools"].tap()
    app.buttons["organizer.venueBroadcast"].assertHittable()
    let bar = app.navigationBars.firstMatch
    XCTAssertTrue(bar.staticTexts["Organizer tools"].exists)
    XCTAssertEqual(bar.frame.minY, originalFrame.minY, accuracy: 1)
    XCTAssertEqual(bar.frame.width, originalFrame.width, accuracy: 1)
    XCTAssertFalse(bar.buttons["Done"].exists)
    let back = bar.buttons.firstMatch
    back.assertHittable()
    attachScreenshot("account-organizer-native-back")
    back.tap()
    accountBar.buttons["Done"].assertHittable()
    XCTAssertTrue(accountBar.staticTexts["Account"].exists)
    app.buttons["Organizer tools"].assertHittable()
  }

  func testAccountKeepsPastEventsAndAboutSensingRoutes() {
    openAccount()
    let list = app.collectionViews.firstMatch
    let pastEvents = app.buttons["Past events"]
    for _ in 0..<5 where !pastEvents.isHittable { list.swipeUp() }
    pastEvents.assertHittable()
    pastEvents.tap()
    let pastBar = app.navigationBars["Past events"]
    XCTAssertTrue(pastBar.waitForExistence(timeout: 5))
    XCTAssertFalse(pastBar.buttons["Done"].exists)
    pastBar.buttons.firstMatch.tap()
    app.navigationBars["Account"].buttons["Done"].assertHittable()

    let about = app.buttons["account.aboutSensing"]
    for _ in 0..<5 where !about.isHittable { list.swipeUp() }
    about.assertHittable()
    about.tap()
    let aboutBar = app.navigationBars["About sensing"]
    XCTAssertTrue(aboutBar.waitForExistence(timeout: 5))
    XCTAssertFalse(aboutBar.buttons["Done"].exists)
    aboutBar.buttons.firstMatch.tap()
    app.navigationBars["Account"].buttons["Done"].assertHittable()
  }

  func testAccountSheetKeepsItsHeightWhenOpeningOrganizerTools() {
    openAccount()
    let done = app.navigationBars["Account"].buttons["Done"]
    done.assertHittable()
    let accountTop = app.navigationBars["Account"].frame.minY
    let viewport = app.windows.firstMatch.frame
    XCTAssertLessThan(accountTop, viewport.minY + viewport.height / 4,
                      "Account should open at full height")
    let organizer = app.buttons["Organizer tools"]
    organizer.assertHittable()
    organizer.tap()
    app.buttons["organizer.venueBroadcast"].assertHittable()
    let destinationBar = app.navigationBars.firstMatch
    XCTAssertTrue(destinationBar.exists)
    XCTAssertEqual(destinationBar.frame.minY, accountTop, accuracy: 36,
                   "The sheet must already be at full height before pushing Organizer tools")
  }

  func testAccountRemovesWalletRowsEvenWithLegacyConnectedFixture() {
    openAccount()
    app.buttons["Organizer tools"].assertHittable()
    attachScreenshot("10")
    assertMinimumHitTarget(app.navigationBars["Account"].buttons["Done"])
    assertMinimumHitTarget(app.buttons["Organizer tools"])
    XCTAssertTrue(app.descendants(matching: .any)["account.bluetooth.status"].exists)
    let list = app.collectionViews.firstMatch
    let privacy = app.descendants(matching: .any)["account.privacy-policy"]
    var sawPrivacy = false
    for _ in 0..<5 {
      for label in ["Copy address", "Copied address", "Disconnect wallet", "Disconnect", "Keep connected"] {
        XCTAssertFalse(app.buttons[label].exists, label)
      }
      XCTAssertFalse(app.staticTexts["Disconnect wallet?"].exists)
      XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "0x7aF3")).firstMatch.exists)
      sawPrivacy = sawPrivacy || privacy.isHittable
      if app.buttons["account.support.share"].isHittable { break }
      list.swipeUp()
    }
    XCTAssertTrue(sawPrivacy)
    app.buttons["account.support.share"].assertHittable()
    app.navigationBars["Account"].buttons["Done"].assertHittable()
  }

  func testShot_12_ReportDetail() {
    app.launchArguments = ["-beid-ui-test", "-beid-event-detail-frame-08"]
    app.launch()
    let getStarted = app.buttons["Continue"]
    XCTAssertTrue(getStarted.waitForExistence(timeout: 5))
    getStarted.tap()
    let allowBluetooth = app.buttons["bluetooth.permission.continue"]
    XCTAssertTrue(allowBluetooth.waitForExistence(timeout: 5))
    allowBluetooth.tap()

    app.openRecordsByEvent()
    let event = app.buttons["home.past-event.ETHTOKYO2026"]
    XCTAssertTrue(event.waitForExistence(timeout: 5))
    event.tap()
    let session = app.buttons["event-detail.observation.1"]
    session.scrollToHittable(in: app)
    session.tap()
    app.staticTexts["observation-detail.title"].assertExists()
    let report = app.buttons["observation-detail.unassigned-report.00000000-0000-4000-8000-000000000639"]
    for _ in 0..<5 where !report.isHittable { app.swipeUp() }
    XCTAssertTrue(report.waitForExistence(timeout: 5))
    XCTAssertTrue(report.isHittable)
    report.tap()

    let heading = app.staticTexts["report-detail.heading"]
    _ = heading.waitForExistence(timeout: 5)
    attachScreenshot("12")
    XCTAssertEqual(heading.label, "Report #1")
    XCTAssertTrue(app.staticTexts["report-detail.status"].label.contains("PREPARED ON THIS DEVICE"))
    XCTAssertTrue(app.descendants(matching: .any)["report-detail.delivery"].label.contains("NOT SENT"))
    XCTAssertFalse(app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] %@", "verified")
    ).firstMatch.exists)
  }

  func testShot_10c_BluetoothOff() {
    openAccount(extraArguments: ["-beid-account-bluetooth-off-fixture"])
    let bluetoothStatus = app.buttons["account.bluetooth.status"]
    bluetoothStatus.assertHittable()
    attachScreenshot("10c")
    XCTAssertEqual(bluetoothStatus.label, "Open Bluetooth Settings")
    assertMinimumHitTarget(app.navigationBars["Account"].buttons["Done"])
    assertMinimumHitTarget(bluetoothStatus)
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

  func testVenueBroadcastQRFirstShowsRegistrarAndTwoTimingRows() {
    openVenue(frame: "14b")
    let scan = app.buttons["Scan QR code"]
    let paste = app.buttons["venue.showLink"]
    XCTAssertTrue(scan.isHittable)
    XCTAssertLessThan(scan.frame.maxY, paste.frame.minY)
    XCTAssertFalse(app.descendants(matching: .any)["Venue link"].exists)
    XCTAssertTrue(app.staticTexts["venue.registrar"].exists)
    let until = app.staticTexts["venue.until"]
    let remaining = app.staticTexts["venue.remaining"]
    XCTAssertTrue(until.exists)
    XCTAssertTrue(remaining.exists)
    XCTAssertLessThan(until.frame.maxY, remaining.frame.minY)
    paste.tap()
    XCTAssertTrue(app.descendants(matching: .any)["Venue link"].exists)
  }

  func testVenuePackRequiresStartBeforeBroadcasting() {
    openVenue(frame: "14b-ready")
    XCTAssertTrue(app.staticTexts["READY TO BROADCAST"].exists)
    XCTAssertTrue(app.staticTexts["ETH Tokyo 2026"].exists)
    XCTAssertTrue(app.staticTexts["venue.registrar"].exists)
    XCTAssertTrue(app.staticTexts["venue.digest"].exists)
    XCTAssertTrue(app.staticTexts["venue.until"].exists)
    let start = app.buttons["Start broadcasting"]
    XCTAssertTrue(start.isHittable)
    XCTAssertFalse(app.buttons["Stop broadcasting"].exists)
    start.tap()
    XCTAssertTrue(app.buttons["Stop broadcasting"].exists)
    XCTAssertFalse(app.buttons["Start broadcasting"].exists)
  }

  func testVenueOrganizerStatusRowsShowOnlyAvailableDeviceFacts() {
    openVenue(frame: "14b")
    for identifier in ["venue.digest", "venue.delivery", "venue.until", "venue.battery", "venue.bluetooth"] {
      XCTAssertTrue(app.staticTexts[identifier].exists, identifier)
    }
    // Label/Mono uppercases the visual text, while accessibility keeps the
    // localized sentence and the checked permit's actual hop count.
    XCTAssertEqual(app.staticTexts["venue.delivery"].label, "Direct · hop 0")
    XCTAssertTrue(app.staticTexts["venue.bluetooth"].label.uppercased().contains("ASKED TO BROADCAST"))
    attachScreenshot("14b")
    assertVenueControls()
    XCTAssertTrue(app.staticTexts["ETH Tokyo 2026"].exists)
  }

  func testVenueInvalidSignatureAnotherEventAndExpiredPackCannotStart() {
    for (frame, reason) in [
      ("14e-signature", "This pack's signature or event details did not check out."),
      ("14e-event", "The pack is not for the event this link named."),
      ("14e-expired", "The lease ended. Broadcasting stopped. Load a current pack."),
      ("14e-empty", "No valid announcements remain. Broadcasting stopped. Load a current pack.")
    ] {
      openVenue(frame: frame)
      XCTAssertTrue(app.staticTexts[reason].exists, frame)
      XCTAssertFalse(app.buttons["Start broadcasting"].exists, frame)
      XCTAssertFalse(app.buttons["Stop broadcasting"].exists, frame)
      XCTAssertEqual(app.staticTexts["venue.bluetooth"].label.uppercased(), "STOPPED.")
      app.terminate()
    }
  }

  func testVenueRefreshFailureShowsValidEndOrExplicitStoppedState() {
    openVenue(frame: "14b-refresh-failed")
    XCTAssertTrue(app.staticTexts["PACK REFRESH FAILED"].exists)
    XCTAssertTrue(app.staticTexts["venue.until"].exists)
    XCTAssertTrue(app.staticTexts["The pack could not be refreshed. Broadcasting can continue only until the time shown."].exists)
    app.terminate()
    openVenue(frame: "14e-refresh-ended")
    XCTAssertTrue(app.staticTexts["The lease ended and the pack could not be refreshed. Broadcasting stopped. Load a current pack."].exists)
    XCTAssertFalse(app.buttons["Start broadcasting"].exists)
    XCTAssertEqual(app.staticTexts["venue.bluetooth"].label.uppercased(), "STOPPED.")
  }

  func testShot_14d_ScanQR() {
    openVenue(frame: "14d")
    app.buttons["Scan QR code"].tap()
    // A native navigation title (#856): the bar exposes it as its static text.
    let title = app.navigationBars.staticTexts["Scan QR code"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    attachScreenshot("14d")
    // The OS's close item (DESIGN.md §12, #732): its size is the OS's, so this
    // pins that it sits in the real navigation bar and can be tapped.
    let cancel = app.navigationBars.buttons["Cancel scan"]
    XCTAssertTrue(cancel.exists)
    XCTAssertTrue(cancel.isHittable)
    XCTAssertEqual(cancel.label, "Cancel scan")
    XCTAssertTrue(app.staticTexts["venue.scanner.caption"].exists)
  }

  func testShot_14e_InvalidLink() {
    app.launchArguments = ["-beid-ui-test", "-beid-account-connected-fixture", "-beid-venue-frame", "14e"]
    app.launch()
    let getStarted = app.buttons["Continue"]
    getStarted.assertExists()
    getStarted.tap()
    let allowBluetooth = app.buttons["bluetooth.permission.continue"]
    allowBluetooth.assertExists()
    allowBluetooth.tap()
    app.tabButton("Now").assertHittable()
    let account = app.buttons["home.account"]
    account.assertExists()
    account.tap()
    let organizer = app.buttons["Organizer tools"]
    organizer.assertExists()
    organizer.tap()
    let venue = app.buttons["organizer.venueBroadcast"]
    venue.assertExists()
    venue.tap()
    app.buttons["Scan QR code"].assertHittable()

    attachScreenshot("14e")
    assertVenueControls()
    XCTAssertTrue(app.staticTexts["NOT A VENUE LINK"].exists)
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
    let link = app.descendants(matching: .any)["Venue link"]
    let opened = !link.exists
    if opened { app.buttons["venue.showLink"].tap() }
    assertMinimumHitTarget(app.buttons["Paste venue link"])
    assertMinimumHitTarget(app.buttons["Use this link"])
    assertMinimumHitTarget(app.buttons["Scan QR code"])
    assertMinimumHitTarget(app.buttons["Copy event ID"])
    assertMinimumHitTarget(app.buttons["Stop broadcasting"])
    XCTAssertTrue(app.descendants(matching: .any)["Venue link"].exists)
    if opened { app.buttons["venue.showLink"].tap() }
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

    app.buttons["Continue"].tap()
    XCTAssertTrue(app.buttons["bluetooth.permission.continue"].waitForExistence(timeout: 5))
    app.buttons["bluetooth.permission.continue"].tap()
    app.tabButton("Now").assertHittable()
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
