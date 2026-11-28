// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
import UIKit

final class BeidIPadLayoutTests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testPrimaryFlowInPortrait() throws {
    XCUIDevice.shared.orientation = .portrait
    try capturePrimaryFlow(orientation: "portrait")
  }

  func testPrimaryFlowInLandscape() throws {
    // Decided before rotating or launching (beid#878), so a skip leaves the
    // device as the next case expects; checked again on the launched window.
    if !UITestLayoutLimits.appCanBecomeWiderThanTall {
      throw XCTSkip("The current window did not become wider than tall")
    }
    XCUIDevice.shared.orientation = .landscapeLeft
    try capturePrimaryFlow(orientation: "landscape")
  }

  func testRecordCardsNavigateIndependentlyInPortrait() throws {
    try captureRecordNavigation(orientation: .portrait, name: "portrait")
  }

  func testRecordCardsNavigateIndependentlyInLandscape() throws {
    try captureRecordNavigation(orientation: .landscapeLeft, name: "landscape")
  }

  private func captureRecordNavigation(orientation: UIDeviceOrientation, name: String) throws {
    // A width the device can never give the app skips before launching
    // (beid#878). The ratio check needs the launched window, because a
    // width limit says only what the window cannot exceed.
    if UITestLayoutLimits.appWindowCannotReach(width: 680) {
      throw XCTSkip("Requires regular width and at least 600 points for the wide Records checks")
    }
    let initialOrientation = XCUIDevice.shared.orientation
    defer { XCUIDevice.shared.orientation = initialOrientation }
    XCUIDevice.shared.orientation = orientation
    app.launchArguments = ["-beid-ui-test", "-beid-home-frame-04"]
    app.launch()
    // The geometry under test, not the hardware family, selects this coverage.
    // A Duo inner display can qualify; a narrow iPad window cannot.
    let viewport = app.windows.firstMatch.frame
    guard app.hasRegularWidthLayout, viewport.width >= 600 else {
      throw XCTSkip("Requires regular width and at least 600 points for the wide Records checks")
    }
    if orientation == .landscapeLeft, viewport.width <= viewport.height {
      throw XCTSkip("The current window did not become wider than tall")
    }
    let welcome = app.buttons["Continue"]
    XCTAssertTrue(welcome.existsOrWait(timeout: 5))
    welcome.tap()
    let permission = app.buttons["bluetooth.permission.continue"]
    XCTAssertTrue(permission.existsOrWait(timeout: 5))
    permission.tap()
    let records = app.tabButton("Records")
    XCTAssertTrue(records.existsOrWait(timeout: 5))
    records.tap()
    let grid = app.scrollViews["records.grid"]
    XCTAssertTrue(grid.existsOrWait(timeout: 5))
    let window = app.windows.firstMatch
    XCTAssertEqual(window.frame.width > window.frame.height, orientation == .landscapeLeft)

    // Event names come from the fixture specification, independently of the
    // selected card's UUID. Matching both catches a card opening another event.
    let titles = ["DeFi Summit Singapore", "ETH Denver 2025", "DevCon Bangkok 2025", "ETH Tokyo 2026"]
    let expectedTitles = Dictionary(uniqueKeysWithValues: titles.map { ("Record for \($0)", $0) })
    let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "records.record."))
    captureRecordState("records-\(name)-initial")
    let heading = app.navigationBars.staticTexts["Records"]
    assertVisibleInWindow(heading)

    // Observe two distinct, simultaneously visible cards before any scrolling.
    let visibleCards = cards.allElementsBoundByIndex.filter {
      $0.isHittable && window.frame.contains($0.frame) && !$0.frame.isEmpty
    }
    XCTAssertGreaterThanOrEqual(visibleCards.count, 2)
    if let firstCard = visibleCards.first {
      XCTAssertEqual(firstCard.frame.minX, heading.frame.minX, accuracy: 1.0,
                     "The grid should align with the navigation title")
    }
    let selectedCards = Array(visibleCards.prefix(2)).map { ($0.identifier, $0.label) }
    XCTAssertEqual(Set(selectedCards.map { $0.0 }).count, 2)
    XCTAssertEqual(Set(selectedCards.map { $0.1 }).count, 2)

    var inventory: [String: String] = [:]
    for step in 0..<5 {
      for card in cards.allElementsBoundByIndex where card.isHittable {
        XCTAssertNotNil(expectedTitles[card.label], "Unexpected fixture card: \(card.label)")
        let recordID = String(card.identifier.dropFirst("records.record.".count))
        XCTAssertNotNil(UUID(uuidString: recordID), "Card must expose a full UUID")
        if let previous = inventory[card.label] { XCTAssertEqual(previous, card.identifier) }
        inventory[card.label] = card.identifier
      }
      if inventory.count == expectedTitles.count { break }
      if step < 4 { grid.swipeUp() }
    }
    XCTAssertEqual(Set(inventory.keys), Set(expectedTitles.keys))
    XCTAssertEqual(Set(inventory.values).count, 4)
    // Return to the original viewport; selection still uses the two cards
    // observed together before inventory collection, never replacement cards.
    for _ in 0..<4 { grid.swipeDown() }
    assertVisibleInWindow(heading)
    captureRecordState("records-\(name)-before-navigation")

    for (index, selected) in selectedCards.enumerated() {
      let (identifier, label) = selected
      let title = try XCTUnwrap(expectedTitles[label])
      let recordID = String(identifier.dropFirst("records.record.".count))
      let card = app.buttons[identifier]
      XCTAssertEqual(card.label, label)
      assertVisibleInWindow(card)
      card.tap()
      let navigation = app.navigationBars[title]
      XCTAssertTrue(navigation.existsOrWait(timeout: 5))
      XCTAssertTrue(app.scrollViews["proof.detail.content"].existsOrWait(timeout: 5))
      XCTAssertEqual(navigation.staticTexts[title].label, title)
      let fullID = app.staticTexts["Record ID \(recordID)"]
      fullID.scrollToHittable(in: app)
      XCTAssertEqual(fullID.label, "Record ID \(recordID)")
      let back = navigation.buttons.firstMatch
      assertVisibleInWindow(back)
      captureRecordState("record-\(name)-\(index)-detail")
      back.tap()
      XCTAssertTrue(grid.existsOrWait(timeout: 5))
      assertVisibleInWindow(heading)
      for original in selectedCards {
        let returned = app.buttons[original.0]
        XCTAssertEqual(returned.label, original.1)
        assertVisibleInWindow(returned)
      }
      captureRecordState("records-\(name)-\(index)-returned")
    }

    let account = app.buttons["home.account"]
    assertVisibleInWindow(account)
    captureRecordState("records-\(name)-before-account")
    account.tap()
    let done = app.navigationBars["Account"].buttons["Done"]
    XCTAssertTrue(done.existsOrWait(timeout: 5))
    assertVisibleInWindow(done)
    captureRecordState("account-\(name)-open")
    done.tap()
    XCTAssertTrue(done.waitForNonExistence(timeout: 5))
    XCTAssertTrue(grid.existsOrWait(timeout: 5))
    assertVisibleInWindow(heading)
    for original in selectedCards { assertVisibleInWindow(app.buttons[original.0]) }
    captureRecordState("records-\(name)-after-account")
  }

  private func assertVisibleInWindow(
    _ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(element.exists, "Expected element in the XCTest hierarchy", file: file, line: line)
    XCTAssertTrue(element.isHittable, "Expected a hittable element", file: file, line: line)
    XCTAssertFalse(element.frame.isEmpty, file: file, line: line)
    XCTAssertTrue(app.windows.firstMatch.frame.contains(element.frame), file: file, line: line)
  }

  private func captureRecordState(_ name: String) {
    capture(named: name)
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "\(name)-accessibility"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
  }

  private func capturePrimaryFlow(orientation: String) throws {
    let fitArguments = [
      "-beid.sensing.firstTimeHintShown", "NO",
      "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.large.rawValue
    ]
    app.launchControlledDemo(extraArguments: fitArguments)
    let viewport = app.windows.firstMatch.frame
    if orientation == "landscape", viewport.width <= viewport.height {
      throw XCTSkip("The current window did not become wider than tall")
    }
    let checksSensingFit = app.hasRegularWidthLayout && viewport.width >= 600 && viewport.height >= viewport.width

    assertWelcomeLayout(named: "welcome-\(orientation)")
    app.buttons["Continue"].tap()

    // OnboardingMode.current is .guestFirst (event-first, the default — see
    // OnboardingFlagTests): Welcome's CTA routes straight to the
    // Bluetooth-permission screen, with no wallet-connect/event-code step.
    XCTAssertTrue(app.buttons["bluetooth.permission.continue"].existsOrWait(timeout: 5))
    capture(named: "bluetooth-permission-\(orientation)")

    app.buttons["bluetooth.permission.continue"].tap()
    let senseEvent = app.buttons["home.demo.join"]
    XCTAssertTrue(senseEvent.existsOrWait(timeout: 5))
    capture(named: "collection-empty-\(orientation)")

    app.buttons["home.account"].tap()
    XCTAssertTrue(app.navigationBars["Account"].buttons["Done"].existsOrWait(timeout: 5))
    capture(named: "account-\(orientation)")
    app.navigationBars["Account"].buttons["Done"].tap()

    let resumedSenseEvent = app.buttons["home.demo.join"]
    XCTAssertTrue(resumedSenseEvent.existsOrWait(timeout: 5))
    resumedSenseEvent.tap()
    app.advanceDemo(to: .sensing)
    XCTAssertTrue(
      app.descendants(matching: .any)["scan.sensing"].existsOrWait(timeout: 30),
      "Expected the transient sensing screen in \(orientation).\n\(app.debugDescription)"
    )
    capture(named: "sensing-\(orientation)")

    app.advanceDemo(to: .eventFound)
    XCTAssertTrue(
      app.staticTexts["scan.event-found"].existsOrWait(timeout: 30),
      "Expected the transient event-found screen in \(orientation).\n\(app.debugDescription)"
    )
    capture(named: "event-found-\(orientation)")

    // Recording remains live until the user confirms stopping. Threshold
    // confirmation auto-flips into `.recording`; the "Simulate Signal Lost"
    // affordance existing is the earliest reliable signal that happened.
    let signalLost = app.buttons["Simulate Signal Lost"]
    app.advanceDemo(to: .recording)
    XCTAssertTrue(signalLost.existsOrWait(timeout: 30))
    dismissBindingSheetToReachLiveRecording()
    if checksSensingFit {
      assertSensingFooterVisibleInPortrait()
    }
    capture(named: "recording-\(orientation)")

    // CLOSE confirms the real Proof, DONE advances through persistent 07,
    // then View records dismisses to Home.
    app.buttons["scan.stop-sensing"].tap()
    XCTAssertTrue(app.staticTexts["Stop sensing?"].existsOrWait(timeout: 5))
    capture(named: "stop-confirm-\(orientation)")
    // Cancelling must leave the existing sensing session live.
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(app.buttons["scan.stop-sensing"].isHittable)
    XCTAssertFalse(app.descendants(matching: .any)["scan.sealed"].exists)
    app.buttons["scan.stop-sensing"].tap()
    XCTAssertTrue(app.staticTexts["Stop sensing?"].existsOrWait(timeout: 5))
    app.alerts.buttons["Stop sensing"].tap()
    XCTAssertTrue(app.buttons["Done"].existsOrWait(timeout: 5))
    capture(named: "sealed-\(orientation)")
    app.buttons["Done"].tap()
    XCTAssertTrue(app.buttons["View records"].existsOrWait(timeout: 5))
    assertProofCollectedHeader()
    capture(named: "proof-collected-\(orientation)")
    app.buttons["View records"].tap()

    XCTAssertTrue(app.scrollViews["records.grid"].existsOrWait(timeout: 5))
    capture(named: "collection-with-proof-\(orientation)")
    app.openRecordsByEvent()
    app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ETHGlobal Tokyo")).firstMatch.tap()
    XCTAssertTrue(app.staticTexts["event-detail.heading"].existsOrWait(timeout: 5))
    app.buttons["event-detail.proof.1"].tap()
    XCTAssertTrue(app.scrollViews["proof.detail.content"].existsOrWait(timeout: 5))
    capture(named: "proof-detail-\(orientation)")
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(app.staticTexts["event-detail.heading"].existsOrWait(timeout: 5))
    app.navigationBars.buttons.firstMatch.tap()
    app.scrollViews["records.events"].assertExists()
    app.selectRecordsGrouping("All records")
    XCTAssertTrue(app.scrollViews["records.grid"].existsOrWait(timeout: 5))
    app.tabButton("Now").tap()
    // After an explicit stop, Now stays quiet until Look for events reopens discovery.
    app.buttons["home.look-for-events"].assertHittable()
    app.buttons["home.look-for-events"].tap()

    XCTAssertTrue(resumedSenseEvent.existsOrWait(timeout: 5))
    resumedSenseEvent.tap()
    app.advanceDemo(to: .recording)
    // Generous timeout: re-entering the scan flow a second time in one test
    // run has been observed to take noticeably longer than the first entry
    // (accumulated simulator/accessibility-tree overhead from the
    // intervening Collection/Proof Detail navigation), not a hang.
    XCTAssertTrue(signalLost.existsOrWait(timeout: 30))
    dismissBindingSheetToReachLiveRecording()
    signalLost.tap()
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "signal lost"))
      .firstMatch.existsOrWait(timeout: 30))
    capture(named: "signal-lost-\(orientation)")
  }

  /// A finished DemoEvent creates a matching SelfProofRecord. That record
  /// supports Sealed; no third-party verification or wallet binding follows.
  func testProofDetailStatusReflectsStoredSelfProof() {
    navigateToCollectionWithProof()
    openFirstProof()

    XCTContext.runActivity(named: "Check that the record is complete") { _ in
      XCTAssertFalse(app.staticTexts["record.incomplete.title"].exists)
      XCTAssertFalse(app.staticTexts["record.incomplete.reason"].exists)
    }
    XCTContext.runActivity(named: "Find the local seal on Record Detail") { _ in
      app.staticTexts["SEALED ON THIS DEVICE"].scrollToHittable(in: app)
      XCTAssertTrue(app.staticTexts["SEALED ON THIS DEVICE"].exists)
    }
    XCTContext.runActivity(named: "Check the local signature and external status") { _ in
      XCTAssertTrue(app.staticTexts["Self-signed on device"].exists)
      XCTAssertFalse(app.staticTexts["Verified"].exists)
      XCTAssertFalse(app.staticTexts["Bound to wallet"].exists)
    }
  }

  /// D1 forbids numeric mutual counts anywhere on Record Detail, including
  /// separate values beside a mutual label and the artwork's VoiceOver text.
  func testParticipationSummaryHeadlineHidesNumericMutualCount() {
    navigateToCollectionWithProof()
    openFirstProof()

    assertRecordDetailHidesNumericMutualCount(firstRung: "SEALED ON THIS DEVICE")
  }

  func testRecordDetailHidesNumericMutualCountWithMeasuredSnapshot() {
    app.launchArguments = ["-beid-ui-test", "-beid-observation-frame-11"]
    app.launch()
    app.buttons["Continue"].assertHittable()
    app.buttons["Continue"].tap()
    app.buttons["bluetooth.permission.continue"].assertHittable()
    app.buttons["bluetooth.permission.continue"].tap()
    app.openRecordsByEvent()
    app.buttons["home.past-event.ETHTOKYO2026"].assertHittable()
    app.buttons["home.past-event.ETHTOKYO2026"].tap()
    app.staticTexts["event-detail.heading"].assertExists()
    let record = app.buttons["event-detail.proof.1"]
    record.scrollToHittable(in: app)
    record.tap()
    app.scrollViews["proof.detail.content"].assertExists()

    // This is a real stored aggregate (23 devices, six observed windows),
    // not a missing snapshot that could hide a fabricated measured zero.
    app.descendants(matching: .any).matching(NSPredicate(
      format: "label == %@", "Devices heard: 23. Window 6. Mutual check not available yet."
    )).firstMatch.assertExists()
    assertRecordDetailHidesNumericMutualCount(firstRung: "RECORDED ON THIS DEVICE")
  }

  private func assertRecordDetailHidesNumericMutualCount(
    firstRung: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let titles = [firstRung, "SENT TO ORGANIZER", "ACCEPTED", "THIRD-PARTY RESULT"]
    let scroll = app.scrollViews["proof.detail.content"]
    scroll.assertExists(file: file, line: line)
    scroll.buttons["record.event-name.disclosure"].assertHittable(file: file, line: line)
    let window = app.windows.firstMatch
    let sessions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "record.session."))
    guard sessions.count > 0 else {
      XCTFail("Expected stored session routes on Record Detail", file: file, line: line)
      return
    }
    let lastSession = sessions.element(boundBy: sessions.count - 1)
    var seenRungs = Set<Int>()
    var reachedEnd = false
    for _ in 0..<10 {
      let mutualLabels = scroll.descendants(matching: .any).matching(
        NSPredicate(format: "label CONTAINS[c] %@", "mutual")
      ).allElementsBoundByIndex.filter {
        !$0.frame.isEmpty && window.frame.intersects($0.frame)
      }
      let numericValues = scroll.staticTexts.matching(
        NSPredicate(format: "label MATCHES %@", #"(?s)\s*\d.*"#)
      ).allElementsBoundByIndex
      for (index, title) in titles.enumerated() {
        // SwiftUI exposes the enclosing rung's identifier on its text children.
        let rung = app.staticTexts.matching(identifier: "record.ladder.\(index + 1)")
          .matching(NSPredicate(format: "label == %@", title)).firstMatch
        if rung.exists && !rung.frame.isEmpty && window.frame.contains(rung.frame) {
          XCTAssertEqual(rung.label, title, file: file, line: line)
          seenRungs.insert(index + 1)
        }
      }
      for mutual in mutualLabels {
        // Device/window numbers in other sentences of the Sigil label are
        // allowed; a number in its mutual statement is not (D1).
        let statements = mutual.label.components(separatedBy: CharacterSet(charactersIn: ".!?;"))
        for statement in statements where statement.localizedCaseInsensitiveContains("mutual") {
          XCTAssertNil(statement.rangeOfCharacter(from: .decimalDigits),
                       "D1: numeric mutual wording: \(mutual.label)", file: file, line: line)
        }
        let mutualFrame = mutual.frame
        let adjacentValues = numericValues.filter { value in
          let valueFrame = value.frame
          let sameRow = valueFrame.minY < mutualFrame.maxY && valueFrame.maxY > mutualFrame.minY
          let below = valueFrame.minY >= mutualFrame.maxY && valueFrame.minY - mutualFrame.maxY <= 12
            && valueFrame.minX < mutualFrame.maxX && valueFrame.maxX > mutualFrame.minX
          return sameRow || below
        }
        XCTAssertTrue(adjacentValues.isEmpty,
                      "D1: numeric value next to \(mutual.label): \(adjacentValues.map(\.label))", file: file, line: line)
      }
      if lastSession.exists && lastSession.isHittable && !lastSession.frame.isEmpty
        && window.frame.contains(lastSession.frame) {
        reachedEnd = true
        break
      }
      scroll.swipeUp()
    }
    XCTAssertEqual(seenRungs, Set(1...4), "Must inspect all four evidence rungs", file: file, line: line)
    XCTAssertTrue(reachedEnd, "Must inspect Record Detail through its last session route", file: file, line: line)
  }

  /// Two independent launches share the installed container but must not
  /// accumulate DemoEvent sessions. Their common event code makes an extra
  /// session route a witness that the first launch's stored record leaked.
  func testProofStoreDoesNotAccumulateAcrossUITestLaunches() {
    navigateToCollectionWithProof()

    // Force-quit-and-relaunch (documented `XCUIApplication.launch()`
    // behavior for an already-running app), simulating the process
    // boundary between two independent UI-test launches that share one
    // installed app container — the exact scenario beid#244 reported.
    app.terminate()
    navigateToCollectionWithProof()
    openFirstProof()

    let sessions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "record.session."))
    sessions.firstMatch.scrollToHittable(in: app)
    XCTAssertEqual(
      sessions.count, 1,
      "The second launch must retain one session; an extra route means the first launch's record leaked"
    )
    sessions.firstMatch.tap()
    XCTAssertTrue(app.staticTexts["observation-detail.title"].existsOrWait(timeout: 5))
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(app.scrollViews["proof.detail.content"].existsOrWait(timeout: 5))
  }

  /// beid#218, DECISIONS 2026-08-20: the Recording screen must show a
  /// diagnostic caption with both the identified and unidentified device
  /// counts, unconditionally (not `#if DEBUG`-gated), so a field tester can
  /// read them without a debugger attached. Asserts the caption's static
  /// structure only ("Diagnostics:" prefix, "identified"/"unidentified"
  /// present) — not an exact numeric value for the identified count, since
  /// `devicesVerified` grows across several `Task.sleep`-gated steps in the
  /// DemoEvent sequence and pinning a number would make this test racy for
  /// reasons unrelated to whether the fix is correct. The unidentified
  /// count IS asserted exactly as "0": DemoEvent's synthetic devices always
  /// carry a `detectedDisplayId` (`observeOneDemoDevice()`), so none should
  /// ever land in the unidentified bucket — this also serves as the
  /// empirical, on-screen confirmation of that (not just a code-reading
  /// claim); the full caption text is printed to the test log for manual
  /// review.
  func testRecordingScreenShowsDiagnosticCounters() {
    reachRecordingScreen()

    let diagnosticCaption = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Diagnostics:")
    ).firstMatch
    XCTAssertTrue(diagnosticCaption.existsOrWait(timeout: 5))

    let label = diagnosticCaption.label
    print("RECORDING DIAGNOSTIC CAPTION: \(label)")
    XCTAssertTrue(label.contains("identified"), "Expected an \"identified\" count in: \(label)")
    XCTAssertTrue(label.contains("unidentified"), "Expected an \"unidentified\" count in: \(label)")
    XCTAssertTrue(
      label.contains("0 unidentified"),
      "Expected the DemoEvent sequence's unidentified count to stay 0; got: \(label)"
    )
  }

  /// Shared navigation prefix: joins the DemoEvent event and waits until
  /// `.recording` begins without a wallet presentation. Used by both the
  /// Recording-screen test above and `navigateToCollectionWithProof` below.
  private func reachRecordingScreen() {
    XCTContext.runActivity(named: "Launch controlled demo") { _ in
      app.launchControlledDemo()
    }

    XCTContext.runActivity(named: "Complete onboarding and reach Now") { _ in
      app.buttons["Continue"].tap()
      XCTAssertTrue(
        app.buttons["bluetooth.permission.continue"].existsOrWait(timeout: 5),
        "Expected Bluetooth permission after Get Started.\n\(app.debugDescription)"
      )
      app.buttons["bluetooth.permission.continue"].tap()
    }

    XCTContext.runActivity(named: "Join the demo event from Now") { _ in
      let senseEvent = app.buttons["home.demo.join"]
      XCTAssertTrue(
        senseEvent.existsOrWait(timeout: 5),
        "Expected Home after allowing Bluetooth.\n\(app.debugDescription)"
      )
      senseEvent.tap()
    }
    XCTContext.runActivity(named: "Advance controlled demo to Sensing") { _ in
      app.advanceDemo(to: .sensing)
      XCTAssertTrue(
        app.descendants(matching: .any)["scan.sensing"].existsOrWait(timeout: 30),
        "Expected the transient sensing screen after Scan.\n\(app.debugDescription)"
      )
    }
    XCTContext.runActivity(named: "Advance controlled demo to Event Found") { _ in
      app.advanceDemo(to: .eventFound)
      XCTAssertTrue(
        app.staticTexts["scan.event-found"].existsOrWait(timeout: 30),
        "Expected the transient event-found screen after sensing.\n\(app.debugDescription)"
      )
    }

    XCTContext.runActivity(named: "Advance controlled demo to Recording") { _ in
      app.advanceDemo(to: .recording)
      XCTAssertTrue(
        app.buttons["Simulate Signal Lost"].existsOrWait(timeout: 30),
        "Expected recording after Event Found.\n\(app.debugDescription)"
      )
      dismissBindingSheetToReachLiveRecording()
    }
  }

  private func assertSensingFooterVisibleInPortrait() {
    let scroll = app.scrollViews["scan.sensing-session"]
    let guidance = scroll.staticTexts["Keep the app open nearby to help devices observe each other and keep signed records."]
    let help = scroll.buttons["scan.first-time.about"]
    let stop = app.buttons["scan.stop-sensing"]
    scroll.assertExists()
    guidance.assertExists()
    help.assertExists()
    stop.assertHittable()
    let viewport = app.visibleScrollFrame(for: scroll.frame)
    let stopFrame = stop.frame
    XCTAssertTrue(app.windows.firstMatch.frame.contains(stopFrame))

    for (element, label) in [(guidance, "Sensing guidance"), (help, "First-time help")] {
      let frame = element.frame
      XCTAssertTrue(
        !frame.isEmpty && viewport.contains(frame),
        "\(label) must fit in the scroll viewport without scrolling. Frame: \(frame), viewport: \(viewport)"
      )
      XCTAssertLessThanOrEqual(frame.maxY, stopFrame.minY, "\(label) must fit above the fixed Stop control.")
      element.assertHittable()
    }
  }

  private func dismissBindingSheetToReachLiveRecording() {
    XCTAssertFalse(app.buttons["Cancel"].exists, "Recording must not present a wallet sheet")
    XCTAssertTrue(app.buttons["Simulate Signal Lost"].existsOrWait(timeout: 5))
    XCTAssertTrue(app.buttons["scan.stop-sensing"].isHittable)
  }

  /// Ends the session `reachRecordingScreen()` just started, landing on
  /// Collection with the resulting proof. Same steps `capturePrimaryFlow`
  /// already exercises, without its screenshot/orientation concerns.
  private func navigateToCollectionWithProof() {
    reachRecordingScreen()
    XCTContext.runActivity(named: "Stop sensing and confirm the stop") { _ in
      app.buttons["scan.stop-sensing"].tap()
      XCTAssertTrue(app.staticTexts["Stop sensing?"].existsOrWait(timeout: 5))
      app.alerts.buttons["Stop sensing"].tap()
    }
    XCTContext.runActivity(named: "Open the saved-record outcome") { _ in
      XCTAssertTrue(app.buttons["Done"].existsOrWait(timeout: 5))
      app.buttons["Done"].tap()
      XCTAssertTrue(app.buttons["View records"].existsOrWait(timeout: 5))
      assertProofCollectedHeader()
    }
    XCTContext.runActivity(named: "Open Records from the saved-record outcome") { _ in
      app.buttons["View records"].tap()

      XCTAssertTrue(
        app.scrollViews["records.grid"].existsOrWait(timeout: 5),
        "Expected Records after ending recording.\n\(app.debugDescription)"
      )
    }
  }

  /// Opens the DemoEvent proof `navigateToCollectionWithProof` just left on
  /// Collection, and waits for Proof Detail to appear.
  private func openFirstProof() {
    XCTContext.runActivity(named: "Open Records by event and select the demo event") { _ in
      app.openRecordsByEvent()
      app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ETHGlobal Tokyo")).firstMatch.tap()
      XCTAssertTrue(app.staticTexts["event-detail.heading"].existsOrWait(timeout: 5))
    }
    XCTContext.runActivity(named: "Open the demo Record Detail") { _ in
      app.buttons["event-detail.proof.1"].tap()
      XCTAssertTrue(
        app.scrollViews["proof.detail.content"].existsOrWait(timeout: 5),
        "Expected Proof Detail after opening the DemoEvent proof.\n\(app.debugDescription)"
      )
    }
  }

  private func assertProofCollectedHeader() {
    let recordID = app.staticTexts["proof-collected.record-id"]
    XCTAssertTrue(recordID.existsOrWait(timeout: 5))
    XCTAssertTrue(recordID.label.hasPrefix("Record ID "))
    XCTAssertEqual(recordID.label.count, "Record ID ".count + 36, "VoiceOver needs the full UUID")
    XCTAssertGreaterThan(recordID.frame.width, 100, "The visible record label must not truncate")
    XCTAssertEqual(app.staticTexts["proof-collected.status"].label, "SEALED")
  }

  private func assertWelcomeLayout(named name: String) {
    let getStarted = app.buttons["Continue"]
    let appWindow = app.windows.firstMatch
    XCTAssertTrue(getStarted.existsOrWait(timeout: 5), "Expected Welcome CTA: \(name)")
    XCTAssertTrue(appWindow.exists, "Expected an app window: \(name)")
    XCTAssertLessThan(
      getStarted.frame.width,
      appWindow.frame.width,
      "The primary CTA must not stretch across an iPad screen."
    )
    XCTAssertGreaterThanOrEqual(getStarted.frame.height, 44)
    capture(named: name)
  }

  private func capture(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
