import XCTest

/// Witnesses the production Button action, not a direct call to its helper.
final class NearbyJoinUITests: XCTestCase {
  func testNearbyCardTapJoinsItsVerifiedEventExactlyOnce() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-beid-ui-test", "-beid-nearby-join-fixture"]
    app.launch()

    app.buttons["Get Started"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()
    XCTAssertTrue(app.buttons["home.scan"].waitForExistence(timeout: 5))
    app.buttons["home.scan"].tap()

    let receipt = app.staticTexts["fixture.nearby-join.receipt"]
    XCTAssertTrue(receipt.waitForExistence(timeout: 5))
    XCTAssertEqual(receipt.label, "joins=0 event=none")
    // SwiftUI exposes the enclosing section identifier on this Button.
    // Match the fixture's actual card label as well, rather than the section title.
    let card = app.buttons.matching(NSPredicate(
      format: "identifier == %@ AND label CONTAINS %@", "scan.nearby-events", "Community night"
    )).firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 5))
    XCTAssertTrue(card.isEnabled)
    // XCTest can report this offscreen card as hittable behind the fixed footer.
    // Bring it into the visible part of the actual Scan scroll view first.
    app.scrollViews["scan.sensing"].swipeUp()
    XCTAssertTrue(card.isHittable)
    card.tap()

    // This value changes only when the native engine seam receives a capability.
    // Entering .sensing before permissions complete is not a successful join.
    let expected = "joins=1 event=5d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab3195"
    let joined = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", expected), object: receipt
    )
    XCTAssertEqual(XCTWaiter.wait(for: [joined], timeout: 5), .completed)
    XCTAssertFalse(card.exists, "the production pre-join cards disappear after admission")
  }
}

/// Exercises the home actions through their visible controls.
final class NowNavigationUITests: XCTestCase {
  private let app = XCUIApplication()

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
    app.tabBars.buttons["Records"].tap()
    XCTAssertTrue(app.scrollViews["records.grid"].waitForExistence(timeout: 5))
    app.buttons["records.by-event"].tap()
    XCTAssertTrue(app.collectionViews["records.events"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["home.past-event.ACTIVE-EVENT"].exists)
    app.tabBars.buttons["Now"].tap()
    XCTAssertTrue(app.otherElements["home.active-event"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "mutual")).firstMatch.exists)
    capture("now-active")
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
    app.tabBars.buttons["Records"].tap()
    app.tabBars.buttons["Now"].tap()
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
    let receipt = app.staticTexts["fixture.nearby-join.receipt"]
    XCTAssertEqual(receipt.label, "joins=0 event=none")
    XCTAssertEqual(app.staticTexts["home.nearby.primary-name"].label, "Community night")
    XCTAssertTrue(app.staticTexts["ALSO NEARBY"].exists)
    XCTAssertTrue(app.buttons["home.nearby.additional.1111111111111111"].exists)
    let join = app.buttons["home.nearby.join.9adc61d60dda843e"]
    XCTAssertTrue(join.isEnabled)
    XCTAssertFalse(app.otherElements["home.active-event"].exists)
    capture("now-candidates")
    join.tap()
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
    XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 5))
    capture("now-bluetooth-off")
  }

  func testDemoStartsOnlyAfterJoinAndReturnsToTheActiveNowSummary() {
    launchHome([])
    XCTAssertTrue(app.buttons["home.demo.join"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.otherElements["home.active-event"].exists)
    XCTAssertTrue(app.staticTexts["DEMO EVENT · FOR APP REVIEW"].exists)
    app.buttons["home.demo.join"].tap()
    XCTAssertTrue(app.scrollViews["scan.session-surface"].waitForExistence(timeout: 30))
    if app.buttons["Not now"].waitForExistence(timeout: 3) { app.buttons["Not now"].tap() }
    app.buttons["Close"].tap()
    if app.buttons["KEEP SENSING"].exists { app.buttons["KEEP SENSING"].tap() }
  }

  private func launchHome(_ arguments: [String]) {
    app.launchArguments = ["-beid-ui-test"] + arguments
    app.launch()
    app.buttons["Get Started"].assertHittable()
    app.buttons["Get Started"].tap()
    app.buttons["Allow Bluetooth"].assertHittable()
    app.buttons["Allow Bluetooth"].tap()
    XCTAssertTrue(app.tabBars.buttons["Now"].waitForExistence(timeout: 5))
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
