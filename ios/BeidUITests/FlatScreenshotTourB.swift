// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest

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
    XCTAssertFalse(
      app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ETH Tokyo 2026")).firstMatch.exists,
      "The active Proof must not also appear as a PAST row"
    )
    XCTAssertFalse(app.buttons["collection.stop-sensing"].exists)
    XCTAssertTrue(app.buttons["home.open-details"].isHittable)
    capture("04")
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

  func testShot_08_EventDetail() {
    launchHome(arguments: ["-beid-event-detail-frame-08"])
    app.openRecordsByEvent()
    let event = app.buttons["home.past-event.ETHTOKYO2026"]
    XCTAssertTrue(event.waitForExistence(timeout: 5))
    event.tap()
    XCTAssertTrue(app.staticTexts["event-detail.heading"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "event-detail.report.")).firstMatch.exists)
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "receipt stored")).firstMatch.exists)
    capture("08")

    let proof = app.buttons["event-detail.proof.1"]
    if !proof.isHittable { app.swipeUp() }
    XCTAssertTrue(proof.waitForExistence(timeout: 5))
    proof.tap()
    XCTAssertTrue(app.staticTexts["proof.detail.title"].waitForExistence(timeout: 5))
  }

  func testRecordsByEventSeparatesRecordsFromSessionsAndReturnsToGrid() {
    launchHome(arguments: ["-beid-home-frame-04"])
    app.tabButton("Records").assertHittable()
    app.tabButton("Records").tap()
    let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "records.record."))
    let gridRecordIDs = Set(tiles.allElementsBoundByIndex.map(\.identifier))
    XCTAssertEqual(gridRecordIDs.count, 4)

    app.openRecordsByEvent()
    let multiSession = app.buttons["home.past-event.DEVCON-BANGKOK"]
    multiSession.assertExists()
    let multiDate = Date(timeIntervalSince1970: 1_763_467_200)
      .formatted(.dateTime.month(.abbreviated).day()).uppercased()
    XCTAssertTrue(multiSession.label.uppercased().contains("\(multiDate) · 2 SESSIONS"), multiSession.label)
    XCTAssertTrue(multiSession.label.contains("1 record →"), multiSession.label)
    XCTAssertFalse(multiSession.label.contains("2 records"), multiSession.label)

    let singleSession = app.buttons["home.past-event.ACTIVE-EVENT"]
    singleSession.assertExists()
    let singleDate = Date(timeIntervalSince1970: 1_774_526_400)
      .formatted(.dateTime.month(.abbreviated).day()).uppercased()
    XCTAssertTrue(singleSession.label.uppercased().contains("\(singleDate) · 1 SESSION"), singleSession.label)
    XCTAssertTrue(singleSession.label.contains("1 record →"), singleSession.label)

    multiSession.assertHittable()
    multiSession.tap()
    app.staticTexts["event-detail.heading"].assertExists()
    app.navigationBars.buttons.firstMatch.tap()
    let allRecords = app.buttons["records.all-records"]
    allRecords.assertHittable()
    XCTAssertEqual(allRecords.label, "All records")
    allRecords.tap()
    app.scrollViews["records.grid"].assertExists()
    XCTAssertEqual(Set(tiles.allElementsBoundByIndex.map(\.identifier)), gridRecordIDs)
  }

  func testEmptyRecordsByEventShowsExplanationAndReturnsToGrid() {
    launchHome(arguments: [])
    let recordsTab = app.tabButton("Records")
    XCTAssertTrue(recordsTab.exists)
    XCTAssertTrue(recordsTab.isHittable)
    recordsTab.tap()

    let explanation = "Saved records appear here after sensing."
    let grid = app.scrollViews.matching(identifier: "records.grid")
    let gridExplanation = grid.element.staticTexts.matching(NSPredicate(format: "label == %@", explanation))
    let gridCounts = grid.element.staticTexts.matching(NSPredicate(format: "label == %@", "0 records · 0 events"))
    let recordTiles = grid.element.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "records.record."))
    let byEvent = grid.element.buttons.matching(identifier: "records.by-event")
    let events = app.collectionViews.matching(identifier: "records.events")
    let eventBar = app.navigationBars.matching(identifier: "By event")
    let eventHeading = eventBar.element.staticTexts.matching(NSPredicate(format: "label == %@", "By event"))
    let allRecords = events.element.buttons.matching(identifier: "records.all-records")
    let eventRows = events.element.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.past-event."))
    let nativeBack = eventBar.element.buttons.matching(NSPredicate(format: "label == %@", "Back"))
    let eventExplanation = events.element.staticTexts.matching(NSPredicate(format: "label == %@", explanation))

    let assertEmptyGrid = {
      XCTAssertEqual(grid.count, 1)
      XCTAssertTrue(grid.element.isHittable)
      XCTAssertEqual(gridCounts.count, 1)
      XCTAssertTrue(gridCounts.element.isHittable)
      XCTAssertEqual(recordTiles.count, 0)
      XCTAssertEqual(gridExplanation.count, 1)
      XCTAssertTrue(gridExplanation.element.isHittable)
      XCTAssertEqual(byEvent.count, 1)
      XCTAssertEqual(byEvent.element.label, "Records by event")
      XCTAssertTrue(byEvent.element.isHittable)
      XCTAssertFalse(events.element.exists && events.element.isHittable)
    }
    let assertEmptyEventList = {
      XCTAssertEqual(events.count, 1)
      // Only text inside the visible By event list can satisfy this assertion.
      XCTAssertEqual(
        eventExplanation.count, 1,
        "Empty By event must show the saved-records explanation inside records.events"
      )
      XCTAssertEqual(eventBar.count, 1)
      XCTAssertEqual(eventHeading.count, 1)
      XCTAssertTrue(eventHeading.element.isHittable)
      XCTAssertEqual(allRecords.count, 1)
      XCTAssertEqual(allRecords.element.label, "All records")
      XCTAssertTrue(allRecords.element.isHittable)
      XCTAssertEqual(nativeBack.count, 1)
      XCTAssertTrue(nativeBack.element.isHittable)
      XCTAssertEqual(eventRows.count, 0)
      XCTAssertFalse(grid.element.exists && grid.element.isHittable)
      XCTAssertTrue(eventExplanation.element.isHittable)
    }

    assertEmptyGrid()
    byEvent.element.tap()
    assertEmptyEventList()
    allRecords.element.tap()
    assertEmptyGrid()
    byEvent.element.tap()
    assertEmptyEventList()
    nativeBack.element.tap()
    assertEmptyGrid()
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
    let allowBluetooth = app.buttons["Allow Bluetooth"]
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
}
