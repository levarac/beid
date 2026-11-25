import XCTest

/// Witnesses the production Button action, not a direct call to its helper.
final class NearbyJoinUITests: XCTestCase {
  func testNearbyCardTapJoinsItsVerifiedEventExactlyOnce() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-beid-ui-test", "-beid-nearby-join-fixture"]
    app.launch()

    app.buttons["Continue"].tap()
    XCTAssertTrue(app.buttons["bluetooth.permission.continue"].waitForExistence(timeout: 5))
    app.buttons["bluetooth.permission.continue"].tap()
    let receipt = app.staticTexts["fixture.nearby-join.receipt"]
    XCTAssertTrue(receipt.waitForExistence(timeout: 5))
    XCTAssertEqual(receipt.label, "joins=0 event=none")
    let card = app.buttons["home.nearby.join.9adc61d60dda843e"]
    XCTAssertTrue(card.waitForExistence(timeout: 5))
    XCTAssertTrue(card.isEnabled)
    XCTAssertTrue(card.isHittable)
    XCTAssertGreaterThan(card.frame.width, 180, "The button must span the card, including the trailing padding")
    XCTAssertTrue(card.label.hasPrefix("JOIN"))
    XCTAssertTrue(card.label.contains("name announced nearby"))
    XCTAssertTrue(card.label.contains("Sample gathering"))
    XCTAssertTrue(card.label.contains("EVENT REGISTRATION CHECKED"))
    card.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.30)).tap()

    // This value changes only when the native engine seam receives a capability.
    // Entering .sensing before permissions complete is not a successful join.
    let expected = "joins=1 event=5d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab3195"
    let joined = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", expected), object: receipt
    )
    XCTAssertEqual(XCTWaiter.wait(for: [joined], timeout: 5), .completed)
    XCTAssertFalse(card.exists, "the production pre-join cards disappear after admission")
  }

  func testUnverifiedNearbyCardIsVisibleButCannotJoin() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-beid-ui-test", "-beid-nearby-join-fixture", "-beid-nearby-unverified-fixture"]
    app.launch()

    app.buttons["Continue"].tap()
    let permission = app.buttons["bluetooth.permission.continue"]
    permission.assertHittable()
    permission.tap()

    let card = app.buttons["home.nearby.join.9adc61d60dda843e"]
    card.assertHittable()
    XCTAssertTrue(card.label.contains("Sample gathering"))
    XCTAssertFalse(card.isEnabled)
    XCTAssertTrue(card.label.contains("Checking event registration…"))

    let receipt = app.staticTexts["fixture.nearby-join.receipt"]
    receipt.assertExists()
    let originalReceipt = receipt.label
    XCTAssertEqual(originalReceipt, "joins=0 event=none")
    // Send an actual touch even though SwiftUI exposes the Button as disabled.
    card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(card.exists)
    XCTAssertEqual(receipt.label, originalReceipt)
  }
}

/// Exercises the home actions through their visible controls.
final class NowNavigationUITests: XCTestCase {
  private let app = XCUIApplication()

  func testNowShowsPendingRecordsUntilSubmissionSucceeds() {
    launchHome(["-beid-home-frame-04b", "-beid-pending-record-fixture"])
    let notice = app.otherElements["home.unsent-notice"]
    XCTAssertFalse(notice.exists, "A normal send must not display the notice")
    app.buttons["home.pending-fixture.advance60"].tap()
    XCTAssertFalse(notice.exists, "Exactly 60 seconds is still inside the grace period")
    app.buttons["home.pending-fixture.advance1"].tap()
    XCTAssertTrue(notice.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["NOT SENT YET"].exists)
    XCTAssertTrue(app.staticTexts[
      "Part of your Record is saved on this device but not sent yet. beid sends it when the app is open and online."
    ].exists)
    capture("Now-unsent-records")
    let accept = app.buttons["home.pending-fixture.accept"]
    accept.assertHittable()
    accept.tap()
    let disappeared = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: notice
    )
    XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: 5), .completed)
  }

  func testNowHidesWaitingNoticeDuringActiveSession() {
    launchHome(["-beid-home-frame-04", "-beid-pending-record-fixture"])
    app.buttons["home.pending-fixture.advance60"].tap()
    app.buttons["home.pending-fixture.advance1"].tap()
    app.otherElements["home.active-event"].assertExists()
    XCTAssertFalse(app.otherElements["home.unsent-notice"].exists)
  }

  func testNowHasNoWaitingNoticeWithoutPendingRecords() {
    launchHome(["-beid-home-frame-04b"])
    XCTAssertFalse(app.otherElements["home.unsent-notice"].exists)
  }

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testRecordsTabOwnsSavedRecordsAndEventList() {
    launchHome(["-beid-home-frame-04"])
    XCTAssertTrue(app.otherElements["home.active-event"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["collection.stop-sensing"].exists)
    XCTAssertFalse(app.staticTexts["PAST"].exists)
    XCTAssertFalse(app.buttons["home.scan"].exists)
    XCTAssertTrue(app.buttons["home.account"].exists)
    app.tabButton("Records").tap()
    XCTAssertTrue(app.scrollViews["records.grid"].waitForExistence(timeout: 5))
    app.selectRecordsGrouping("By event")
    app.scrollViews["records.events"].assertExists()
    XCTAssertTrue(app.navigationBars.staticTexts["Records"].exists)
    XCTAssertTrue(app.buttons["home.account"].isHittable)
    XCTAssertTrue(app.buttons["home.past-event.ACTIVE-EVENT"].exists)
    app.tabButton("Now").tap()
    XCTAssertTrue(app.otherElements["home.active-event"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "mutual")).firstMatch.exists)
    capture("now-active")
  }

  func testRecordsGridExposedLabelDoesNotAnnounceNumericMutuality() {
    openSavedDemoRecords()
    app.scrollViews["records.grid"].assertExists()
    let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "records.record.")).firstMatch
    tile.assertExists()
    // The tile intentionally replaces its children's labels with the event action.
    XCTAssertEqual(tile.label, "Record for ETHGlobal Tokyo")
    assertNoNumericMutualLabel(in: app.scrollViews["records.grid"])
  }

  func testRecordsByEventArtworkAnnouncesUnavailableMutuality() {
    openSavedDemoRecords()
    app.selectRecordsGrouping("By event")
    let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.past-event.")).firstMatch
    row.assertExists()
    XCTAssertNotNil(row.label.range(
      of: #"Devices heard: \d+\. Window \d+\. Mutual check not available yet\."#, options: .regularExpression
    ))
    XCTAssertTrue(row.label.contains("ETHGlobal Tokyo"))
    assertNoNumericMutualLabel(in: app.scrollViews["records.events"])
  }

  func testSealedRecordArtworkAnnouncesUnavailableMutuality() {
    launchSealedDemoRecord()
    let artwork = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS[c] %@", "mutual")
    ).firstMatch
    artwork.assertExists()
    XCTAssertTrue(artwork.label.hasPrefix("Devices heard:"))
    XCTAssertTrue(artwork.label.contains("Window"))
    XCTAssertTrue(artwork.label.contains("Mutual check not available yet."))
    assertNoNumericMutualLabel(in: app)
  }

  private func openSavedDemoRecords() {
    launchSealedDemoRecord()
    app.buttons["Done"].tap()
    app.buttons["View records"].assertHittable()
    app.buttons["View records"].tap()
    app.tabButton("Records").tap()
  }

  private func launchSealedDemoRecord() {
    launchHome([])
    app.buttons["home.demo.join"].tap()
    XCTAssertTrue(app.buttons["Simulate Signal Lost"].waitForExistence(timeout: 30))
    app.buttons["scan.stop-sensing"].tap()
    app.buttons["Stop and keep record"].assertHittable()
    app.buttons["Stop and keep record"].tap()
    app.buttons["Done"].assertHittable()
    // A persisted artwork is required: a neutral ring would make the
    // absence of numeric narration a vacuous pass at the later grid/row.
    app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS[c] %@", "mutual")
    ).firstMatch.assertExists()
  }

  /// One predicate query (one accessibility snapshot). Reading `.label` from
  /// every element of `allElementsBoundByIndex` re-resolves each element and
  /// costs one snapshot apiece.
  private func assertNoNumericMutualLabel(
    in container: XCUIElement, file: StaticString = #filePath, line: UInt = #line
  ) {
    let numeric = container.descendants(matching: .any).matching(
      NSPredicate(format: "label MATCHES[c] %@", #"(?s).*\d+\s+mutual.*"#)
    )
    XCTAssertEqual(numeric.count, 0, "A label announces a numeric mutual count", file: file, line: line)
  }

  func testEmptyRecordsExplainsBothGroupingsInPlace() {
    launchHome(["-beid-home-frame-04b"])
    app.tabButton("Records").tap()
    let explanation = app.staticTexts["Saved records appear here after sensing."]
    app.scrollViews["records.grid"].assertExists()
    explanation.assertHittable()
    capture("records-empty")
    app.selectRecordsGrouping("By event")
    app.scrollViews["records.events"].assertExists()
    explanation.assertHittable()
    XCTAssertTrue(app.navigationBars.staticTexts["Records"].exists)
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.past-event.")).count, 0)
    app.selectRecordsGrouping("All records")
    app.scrollViews["records.grid"].assertExists()
    explanation.assertHittable()
  }

  func testRecordsGroupingToolbarKeepsSelectionAndMeetsHitTarget() {
    launchHome(["-beid-home-frame-04"])
    app.tabButton("Records").tap()
    let options = app.navigationBars.buttons["records.grouping"]
    options.assertHittable()
    XCTAssertEqual(options.label, "Record view options")
    XCTAssertEqual(app.segmentedControls.count, 0)
    options.tap()
    // Native Picker menu items omit identifiers, so use the English UI-test labels.
    let allRecords = app.buttons["All records"]
    let byEvent = app.buttons["By event"]
    allRecords.assertHittable()
    byEvent.assertHittable()
    XCTAssertTrue(allRecords.isSelected)
    XCTAssertFalse(byEvent.isSelected)
    capture("records-grouping-menu")
    byEvent.tap()
    byEvent.assertDisappears()
    app.scrollViews["records.events"].assertExists()
    XCTAssertTrue(app.navigationBars.staticTexts["Records"].exists)
    options.tap()
    XCTAssertTrue(byEvent.isSelected)
    XCTAssertFalse(allRecords.isSelected)
    allRecords.tap()
    allRecords.assertDisappears()
    app.scrollViews["records.grid"].assertExists()
    XCTAssertTrue(app.navigationBars.staticTexts["Records"].exists)
    // DESIGN.md requires a 44x44 pt touch region. The accessibility frame is not
    // a hit-area measurement, so tap the four corners (inset 2 points) of a
    // 44x44 region centered on the button; a smaller hit target misses the menu.
    let inset = 44.0 / 2 - 2.0
    for dx in [-inset, inset] {
      for dy in [-inset, inset] {
        options.assertHittable()
        options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
          .withOffset(CGVector(dx: dx, dy: dy)).tap()
        allRecords.assertHittable()
        allRecords.tap()
        allRecords.assertDisappears()
        app.scrollViews["records.grid"].assertExists()
      }
    }
  }

  func testEmptyRecordsUsesSharedTitleAndExplanationAtAccessibilitySize() {
    launchHome([
      "-beid-home-frame-04b",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
    ])
    app.tabButton("Records").tap()
    let title = app.staticTexts["No records yet"]
    let description = app.staticTexts["Saved records appear here after sensing."]
    title.assertHittable()
    description.assertHittable()
    let viewport = app.scrollViews["records.grid"].frame
    XCTAssertTrue(viewport.contains(title.frame))
    XCTAssertTrue(viewport.contains(description.frame))
    XCTAssertLessThanOrEqual(title.frame.maxY, description.frame.minY)
    capture("records-empty-accessibility")
  }

  func testEmptyPastEventsKeepsItsExplanation() {
    launchHome(["-beid-home-frame-04b"])
    app.buttons["home.account"].tap()
    let pastEvents = app.buttons["Past events"]
    pastEvents.assertHittable()
    pastEvents.tap()
    app.staticTexts["No past events yet."].assertHittable()
    let explanation = app.staticTexts["Only events you have a saved record for are listed here."]
    explanation.assertHittable()
    XCTAssertEqual(app.staticTexts.matching(NSPredicate(
      format: "label == %@", "Only events you have a saved record for are listed here."
    )).count, 1)
    capture("past-events-empty")
  }

  func testRecordsGridHasOneAttendancePerEventAndKeepsSessions() {
    launchHome(["-beid-home-frame-04"])
    app.tabButton("Records").tap()
    app.scrollViews["records.grid"].assertExists()
    let recordTiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "records.record."))
    XCTAssertEqual(recordTiles.count, 4, "Two saved sessions of one event must share one record tile")
    XCTAssertFalse(app.staticTexts["4 records · 4 events"].exists)

    let repeatedEvent = app.buttons.matching(NSPredicate(format: "label == %@", "Record for DevCon Bangkok 2025"))
    XCTAssertEqual(repeatedEvent.count, 1)
    let tile = repeatedEvent.firstMatch
    let parentRecordID = String(tile.identifier.dropFirst("records.record.".count))
    tile.tap()
    app.scrollViews["proof.detail.content"].assertExists()
    let sessions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "record.session."))
    sessions.firstMatch.scrollToHittable(in: app)
    XCTAssertEqual(sessions.count, 2, "Both stored sessions must remain accessible from the event record")
    let identifiers = sessions.allElementsBoundByIndex.map(\.identifier)
    XCTAssertEqual(Set(identifiers).count, 2)
    XCTAssertTrue(identifiers.contains("record.session.\(parentRecordID)"))
    for identifier in identifiers {
      let session = app.buttons[identifier]
      session.scrollToHittable(in: app)
      session.tap()
      app.staticTexts["observation-detail.title"].assertExists()
      app.staticTexts["observation-detail.unavailable"].assertExists()
      let sessionRecordID = String(identifier.dropFirst("record.session.".count))
      let ownRecord = app.buttons["View this session's record"]
      if sessionRecordID == parentRecordID {
        XCTAssertFalse(ownRecord.exists, "Back already leads to this session's record")
      } else {
        XCTAssertTrue(ownRecord.exists, "A different session must link to its own record")
        ownRecord.scrollToHittable(in: app)
        ownRecord.tap()
        app.scrollViews["proof.detail.content"].assertExists()
        app.staticTexts.matching(NSPredicate(format: "label == %@", "Record ID \(sessionRecordID)")).firstMatch.assertExists()
        app.navigationBars.buttons.firstMatch.tap()
        app.staticTexts["observation-detail.title"].assertExists()
      }
      app.navigationBars.buttons.firstMatch.tap()
      app.scrollViews["proof.detail.content"].assertExists()
      app.staticTexts.matching(NSPredicate(format: "label == %@", "Record ID \(parentRecordID)")).firstMatch.assertExists()
    }
    app.navigationBars.buttons.firstMatch.tap()
    app.openRecordsByEvent()
    app.buttons["home.past-event.DEVCON-BANGKOK"].assertHittable()
    app.buttons["home.past-event.DEVCON-BANGKOK"].tap()
    app.buttons["event-detail.observation.1"].assertHittable()
    app.buttons["event-detail.observation.1"].tap()
    let ownRecord = app.buttons["View this session's record"]
    ownRecord.scrollToHittable(in: app)
    ownRecord.tap()
    app.scrollViews["proof.detail.content"].assertExists()
    let recordID = String(identifiers[0].dropFirst("record.session.".count))
    app.staticTexts.matching(NSPredicate(format: "label == %@", "Record ID \(recordID)")).firstMatch.assertExists()
  }

  func testCodeFallbackAppearsAtThirtySecondsAndResetsAfterCandidates() {
    launchHome(["-beid-now-standby-fixture"])
    let fallback = app.buttons["home.enter-code"]
    XCTAssertFalse(fallback.exists)
    app.buttons["fixture.now.advance29"].tap()
    XCTAssertFalse(fallback.exists, "29 seconds is below the fallback boundary")
    app.buttons["fixture.now.advance1"].tap()
    XCTAssertTrue(fallback.waitForExistence(timeout: 5))
    app.buttons["fixture.now.add-candidate"].tap()
    XCTAssertTrue(app.buttons["home.demo.join"].waitForExistence(timeout: 5))
    XCTAssertFalse(fallback.exists, "a candidate cancels the empty-discovery interval")
    app.buttons["fixture.now.remove-candidate"].tap()
    app.buttons["fixture.now.advance29"].tap()
    XCTAssertFalse(fallback.exists)
    app.buttons["fixture.now.advance1"].tap()
    XCTAssertTrue(fallback.waitForExistence(timeout: 5))
    capture("now-fallback")
  }

  func testLeavingNowAndBackgroundingRestartTheFallbackInterval() {
    launchHome(["-beid-now-standby-fixture"])
    let fallback = app.buttons["home.enter-code"]
    app.buttons["fixture.now.advance29"].tap()
    app.tabButton("Records").tap()
    app.tabButton("Now").tap()
    XCTAssertFalse(fallback.exists)
    app.buttons["fixture.now.advance1"].tap()
    XCTAssertFalse(fallback.exists, "time from the previous visible interval is discarded")
    app.buttons["fixture.now.advance29"].tap()
    XCTAssertTrue(fallback.waitForExistence(timeout: 5))
    XCUIDevice.shared.press(.home)
    app.activate()
    XCTAssertTrue(app.staticTexts["home.listening"].waitForExistence(timeout: 5))
    XCTAssertFalse(fallback.exists, "background discovery time must not show a fallback")
    app.buttons["fixture.now.advance29"].tap()
    XCTAssertFalse(fallback.exists)
    app.buttons["fixture.now.advance1"].tap()
    XCTAssertTrue(fallback.waitForExistence(timeout: 5))
  }

  func testNearbyJoinIsExplicitAndAdditionalCandidatesKeepTheirOrder() {
    launchHome(["-beid-nearby-join-fixture", "-beid-nearby-multiple-fixture"])
    app.staticTexts["beid listens for nearby events over Bluetooth. Tap your event’s card or row to join."].assertExists()
    let receipt = app.staticTexts["fixture.nearby-join.receipt"]
    XCTAssertEqual(receipt.label, "joins=0 event=none")
    let card = app.buttons["home.nearby.join.9adc61d60dda843e"]
    card.assertExists()
    XCTAssertTrue(card.label.contains("Sample gathering"))
    XCTAssertTrue(app.staticTexts["ALSO NEARBY"].exists)
    XCTAssertTrue(app.buttons["home.nearby.additional.ffffffffffffffff"].exists)
    XCTAssertTrue(card.isEnabled)
    XCTAssertFalse(app.otherElements["home.active-event"].exists)
    capture("now-candidates")
    card.tap()
    let joined = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label BEGINSWITH %@", "joins=1 event="), object: receipt
    )
    XCTAssertEqual(XCTWaiter.wait(for: [joined], timeout: 5), .completed)
  }

  func testBluetoothOffPausesStandbyAndOffersItsExistingRoute() {
    launchHome(["-beid-now-bluetooth-off-fixture"])
    XCTAssertTrue(app.staticTexts["BLUETOOTH OFF · SENSING PAUSED"].exists)
    XCTAssertFalse(app.staticTexts["home.listening"].exists)
    XCTAssertFalse(app.buttons["home.enter-code"].exists)
    app.buttons["home.bluetooth.fix"].tap()
    XCTAssertTrue(app.buttons["bluetooth.off.check-again"].waitForExistence(timeout: 5))
    capture("now-bluetooth-off")
  }

  func testDemoStartsOnlyAfterJoinAndSavesARecordInRecords() {
    launchHome([])
    app.staticTexts["Tap JOIN to start the demo."].assertExists()
    XCTAssertTrue(app.buttons["home.demo.join"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.otherElements["home.active-event"].exists)
    XCTAssertTrue(
      app.staticTexts["DEMO EVENT · SAMPLE DATA"].exists,
      "The demo must identify sample data before explicit JOIN"
    )
    app.buttons["home.demo.join"].tap()
    XCTAssertTrue(app.scrollViews["scan.sensing-session"].waitForExistence(timeout: 30))
    XCTAssertFalse(app.buttons["Cancel"].exists, "Recording must not present a wallet sheet")
    let recording = app.buttons["Simulate Signal Lost"]
    XCTAssertTrue(recording.waitForExistence(timeout: 30))
    app.buttons["scan.stop-sensing"].tap()
    app.buttons["Stop and keep record"].assertHittable()
    app.buttons["Stop and keep record"].tap()
    app.buttons["Done"].assertHittable()
    app.buttons["Done"].tap()
    app.buttons["View records"].assertHittable()
    app.buttons["View records"].tap()
    app.tabButton("Records").assertHittable()
    app.tabButton("Records").tap()
    XCTAssertTrue(app.scrollViews["records.grid"].exists)
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "records.record.")).firstMatch.exists)
    capture("records-after-demo")
  }

  private func launchHome(_ arguments: [String]) {
    app.launchArguments = ["-beid-ui-test"] + arguments
    app.launch()
    app.buttons["Continue"].assertHittable()
    app.buttons["Continue"].tap()
    app.buttons["bluetooth.permission.continue"].assertHittable()
    app.buttons["bluetooth.permission.continue"].tap()
    XCTAssertTrue(app.tabButton("Now").waitForExistence(timeout: 5))
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
