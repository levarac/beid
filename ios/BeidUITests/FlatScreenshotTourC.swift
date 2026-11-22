// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest

/// Stream C's deterministic Figma comparison tour. Every app-side sample is
/// gated by -beid-ui-test and -beid-sensing-shot. The 05b frame is excluded by
/// the owner: it depicts a verification process and reciprocal connections
/// that v1.0 cannot establish on-device.
final class FlatScreenshotTourC: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testShot_05_Sensing() { capture("05") }
  func testShot_05a_Detecting() { capture("05a") }
  func testShot_05a2_Detecting20s() { capture("05a2") }
  func testShot_05a3_DetectingFirstTime() { capture("05a3") }

  func testDetectingCaptionOnlyAppearsAfterJoinBeforeAnyPhoneIsHeard() {
    let app = XCUIApplication()
    app.launchArguments = ["-beid-ui-test", "-beid-nearby-join-fixture"]
    app.launch()
    app.buttons["Continue"].assertHittable()
    app.buttons["Continue"].tap()
    app.buttons["bluetooth.permission.continue"].assertHittable()
    app.buttons["bluetooth.permission.continue"].tap()
    app.tabButton("Now").assertExists()
    XCTAssertFalse(app.staticTexts["scan.detecting.caption"].exists)

    let join = app.buttons["home.nearby.join.9adc61d60dda843e"]
    join.assertHittable()
    join.tap()
    let caption = app.staticTexts["scan.detecting.caption"]
    caption.scrollToHittable(in: app)
    XCTAssertEqual(caption.label, "LOOKING FOR PEERS · STAY NEARBY")
    XCTAssertFalse(app.staticTexts["MUTUAL"].exists)
    XCTAssertFalse(app.staticTexts["DETECTED"].exists)
    app.buttons["scan.stop-sensing"].assertHittable()
    app.terminate()

    // 05a's sample already contains five heard devices. Its presentation
    // name must not override the actual sensing state and claim zero peers.
    let heard = launchSensingFixture("05a")
    XCTAssertFalse(heard.staticTexts["scan.detecting.caption"].exists)
    XCTAssertTrue(heard.staticTexts["DEVICES HEARD"].exists)
    XCTAssertTrue(heard.staticTexts["ELAPSED"].exists)
  }

  func testShot_05e_StopConfirm() {
    let app = launchSensingFixture("05e")
    SensingVisualOracle.assertInitialMetrics(in: app, test: self, name: "05e-before-stop", expected: ("13", "25:00"))
    app.buttons["scan.stop-sensing"].assertHittable()
    app.buttons["scan.stop-sensing"].tap()
    let alert = app.alerts["Stop sensing?"]
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    XCTAssertTrue(alert.buttons["Cancel"].exists)
    XCTAssertTrue(alert.buttons["Stop sensing"].exists)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "05e"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testSensingHeaderAndFirstTimeExplanationMatchTheApprovedFrames() {
    for code in ["05", "05a3"] {
      let app = launchSensingFixture(code)
      let status = app.navigationBars.staticTexts.matching(
        NSPredicate(format: "label ==[c] %@", "Sensing")
      ).firstMatch
      status.assertExists()
      XCTAssertFalse(app.staticTexts["MUTUAL"].exists)
      XCTAssertFalse(app.staticTexts["DETECTED"].exists)
      XCTAssertTrue(app.staticTexts["DEVICES HEARD"].exists)
      XCTAssertTrue(app.staticTexts["ELAPSED"].exists)
      app.buttons["scan.stop-sensing"].assertHittable()

      if code == "05a3" {
        let hint = app.buttons["scan.first-time.about"]
        hint.scrollToHittable(in: app)
        XCTAssertEqual(hint.label, "How sensing works")
        XCTAssertEqual(hint.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1)
        hint.tap()
        app.staticTexts["HOW IT WORKS"].assertExists()
        app.navigationBars.buttons.firstMatch.tap()
        hint.scrollToHittable(in: app)
      }

      // Native Back must still leave the live session available in Now.
      app.navigationBars.buttons.firstMatch.assertHittable()
      app.navigationBars.buttons.firstMatch.tap()
      app.buttons["home.open-details"].assertHittable()
      app.buttons["home.open-details"].tap()
      app.descendants(matching: .any)["scan.sensing-session"].assertExists()
      XCTAssertFalse(app.descendants(matching: .any)["scan.sealed"].exists)
      app.terminate()
    }
  }

  func testShot_06_Sealed() { capture("06") }
  func testSensingGuidanceRemainsReachableAfterScrolling() {
    let app = launchSensingFixture("05a3")
    SensingVisualOracle.assertPostScrollGuidance(in: app, test: self, name: "05a3-fixture")
  }

  func testProductionFirstSensingHintPersistsAcrossRelaunch() {
    let app = XCUIApplication()
    addTeardownBlock { [weak self] in
      guard let self, let run = self.testRun, run.totalFailureCount > 0 else { return }
      let hierarchy = XCTAttachment(string: app.debugDescription)
      hierarchy.name = "First sensing hint failure accessibility tree"
      hierarchy.lifetime = .keepAlways
      self.add(hierarchy)
    }

    for firstLaunch in [true, false] {
      app.launchArguments = ["-beid-ui-test", "-beid-controlled-demo"]
      if firstLaunch {
        app.launchArguments += ["-beid.sensing.firstTimeHintShown", "NO"]
      }
      app.launch()
      app.buttons["Continue"].assertHittable()
      app.buttons["Continue"].tap()
      app.buttons["bluetooth.permission.continue"].assertHittable()
      app.buttons["bluetooth.permission.continue"].tap()
      app.tabButton("Now").assertHittable()
      app.buttons["home.demo.join"].assertHittable()
      app.buttons["home.demo.join"].tap()
      // Recording mounts its own scroll view. Drive the demo to that
      // phase before reading or changing the scroll position.
      app.advanceDemo(to: .recording)
      let sensing = app.scrollViews["scan.sensing-session"]
      sensing.assertExists()
      let hint = app.buttons["scan.first-time.about"]
      if firstLaunch {
        hint.scrollToHittable(in: app, within: sensing)
        let stop = app.buttons["scan.stop-sensing"]
        stop.assertHittable()
        XCTAssertLessThanOrEqual(hint.frame.maxY, stop.frame.minY, "The hint must scroll fully above Stop")
        // The glyph-bearing control supplies a spoken label for VoiceOver.
        XCTAssertEqual(hint.label, "How sensing works")
        hint.tap()
        let about = app.scrollViews["aboutSensing.scroll"]
        let heading = about.staticTexts["HOW IT WORKS"]
        heading.scrollToHittable(in: app, within: about)
        app.navigationBars.buttons.firstMatch.assertHittable()
        app.navigationBars.buttons.firstMatch.tap()
        hint.scrollToHittable(in: app, within: sensing)
      } else {
        for _ in 0..<3 { app.swipeUp() }
        XCTAssertFalse(hint.exists)
      }
      app.terminate()
    }
  }
  func testShot_07_ProofCollected() { capture("07") }
  func testShot_09_ProofDetail() { capture("09") }

  func testCollectedRecordKeepsItsIDAndDisclosureRoute() {
    let app = launchCollectedRecordForCopyAssertions()
    let recordID = app.staticTexts["proof-collected.record-id"]
    XCTAssertEqual(recordID.label, "Record ID 42110000-0000-4000-8000-000000000000")
    XCTAssertTrue(app.buttons["View records"].exists)

    let disclosure = app.buttons["proof-collected.whatWeSend"]
    disclosure.assertHittable()
    let disclosureLabel = disclosure.label
    disclosure.tap()
    app.descendants(matching: .any)["whatWeSend.firstRow"].assertExists()
    app.navigationBars.buttons.firstMatch.assertHittable()
    app.navigationBars.buttons.firstMatch.tap()
    recordID.assertExists()

    XCTAssertTrue(
      disclosureLabel.localizedCaseInsensitiveContains("what we send"),
      "The general disclosure must say WHAT WE SEND; got: \(disclosureLabel)"
    )
    let title = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] %@", "collected")
    ).firstMatch
    title.assertExists()
    XCTAssertEqual(title.label.replacingOccurrences(of: "\n", with: " "), "Record collected")
  }

  func testEventDetailShowsOneRecordWithoutLosingSessions() {
    let app = launchEventDetailFixture(extraArguments: ["-beid-report-links-701"])
    openReportDetail(app)
    let reportID = app.descendants(matching: .any)["report-detail.record-id"]
    reportID.assertExists()
    XCTAssertTrue(reportID.label.contains(Self.linkedReportID), reportID.label)
    XCTAssertTrue(app.staticTexts["report-detail.status"].label.contains("PREPARED ON THIS DEVICE"))
    XCTAssertTrue(app.descendants(matching: .any)["report-detail.delivery"].label.contains("NOT SENT"))
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.staticTexts["observation-detail.title"].assertExists()
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.staticTexts["event-detail.heading"].assertExists()

    for ordinal in 1...3 {
      XCTAssertTrue(app.buttons["event-detail.observation.\(ordinal)"].exists)
    }
    let firstSession = app.buttons["event-detail.observation.1"]
    XCTAssertTrue(
      firstSession.label.localizedCaseInsensitiveContains("prepared"),
      "The first session must include its linked prepared report status; got: \(firstSession.label)"
    )
    let records = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "event-detail.proof.")
    )
    XCTAssertEqual(records.count, 1, "One event has one record; all three sessions remain accessible")
  }

  func testEventDetailFoldsReportsIntoSessionsAndKeepsUnassignedReportsReachable() {
    let app = launchEventDetailFixture(extraArguments: [])
    XCTAssertFalse(app.staticTexts["Reports"].exists)
    XCTAssertFalse(app.staticTexts["NO REPORTS YET"].exists)
    XCTAssertFalse(app.staticTexts["OTHER STORED REPORTS"].exists)
    XCTAssertFalse(app.buttons["event-detail.report.\(Self.linkedReportID)"].exists)
    openSession(1, in: app)
    let report = app.buttons["observation-detail.unassigned-report.\(Self.linkedReportID)"]
    report.scrollToHittable(in: app)
    XCTAssertTrue(app.staticTexts["The session is unavailable for these event reports."].exists)
    report.tap()
    app.staticTexts["report-detail.heading"].assertExists()
    XCTAssertFalse(app.descendants(matching: .any)["report-detail.session"].exists)
  }

  func testRecordDetailSeparatesLocalRecordFromExternalResults() {
    let app = launchEventDetailFixture(extraArguments: ["-beid-report-links-701"])
    let record = app.buttons["event-detail.proof.1"]
    record.scrollToHittable(in: app)
    record.tap()
    app.scrollViews["proof.detail.content"].assertExists()
    XCTAssertTrue(app.navigationBars["ETH Tokyo 2026"].exists)
    XCTAssertTrue(app.staticTexts["RECORDED ON THIS DEVICE"].exists)
    XCTAssertFalse(app.staticTexts["record.incomplete.title"].exists)
    XCTAssertFalse(app.staticTexts["record.incomplete.reason"].exists)
    assertSignatureUnavailable(app)
    XCTAssertFalse(app.staticTexts["STATUS"].exists)
    XCTAssertFalse(app.staticTexts["Bound to wallet"].exists)
    XCTAssertFalse(app.buttons["Connect wallet"].exists)
    XCTAssertFalse(app.staticTexts["VERIFIED"].exists)

    let expectedTitles = ["RECORDED ON THIS DEVICE", "SENT TO ORGANIZER", "ACCEPTED", "THIRD-PARTY RESULT"]
    for (index, expected) in expectedTitles.enumerated() {
      // Match the exposed row identifier and title, excluding its detail text.
      let rung = app.staticTexts.matching(identifier: "record.ladder.\(index + 1)")
        .matching(NSPredicate(format: "label == %@", expected)).firstMatch
      rung.scrollToHittable(in: app)
      XCTAssertEqual(rung.label, expected)
    }
    let unavailableResults = app.staticTexts.matching(
      NSPredicate(format: "label == %@", "NOT YET AVAILABLE")
    )
    XCTAssertGreaterThanOrEqual(unavailableResults.count, 2)
  }

  func testRecordDetailKeepsLongEventNameAvailable() {
    let eventName = "International Community Gathering and Technology Festival Tokyo 2026"
    let app = launchEventDetailFixture(extraArguments: ["-beid-long-record-name-fixture"])
    let record = app.buttons["event-detail.proof.1"]
    record.scrollToHittable(in: app)
    record.tap()
    XCTAssertTrue(app.scrollViews["proof.detail.content"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars[eventName].exists)
    let disclosure = app.buttons["record.event-name.disclosure"]
    disclosure.scrollToHittable(in: app)
    disclosure.tap()
    let fullName = app.staticTexts.matching(identifier: "record.event-name.disclosure")
      .matching(NSPredicate(format: "label == %@", eventName)).firstMatch
    XCTAssertTrue(fullName.waitForExistence(timeout: 5))
    XCTAssertEqual(fullName.label, eventName)
    XCTAssertGreaterThan(fullName.frame.height, 40)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "record-detail-long-event-name"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.swipeUp()
    XCTAssertTrue(app.navigationBars[eventName].exists)
  }

  func testRecordDetailDoesNotRepeatEventNameAsHeading() {
    let app = launchEventDetailFixture(extraArguments: [])
    let record = app.buttons["event-detail.proof.1"]
    record.scrollToHittable(in: app)
    record.tap()
    XCTAssertTrue(app.navigationBars["ETH Tokyo 2026"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["proof.detail.title"].exists,
                   "The event name should not appear as a second heading")
    XCTAssertTrue(app.buttons["record.event-name.disclosure"].exists)
  }

  func testSessionOpenedFromRecordHasNoParentRecordLink() {
    let app = launchEventDetailFixture(extraArguments: [])
    let record = app.buttons["event-detail.proof.1"]
    record.scrollToHittable(in: app)
    record.tap()
    let session = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "record.session.")).firstMatch
    session.scrollToHittable(in: app)
    session.tap()
    XCTAssertTrue(app.staticTexts["observation-detail.title"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["View this session's record"].exists,
                   "Back already returns to the parent record")
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(app.navigationBars["ETH Tokyo 2026"].waitForExistence(timeout: 5))
    app.scrollViews["proof.detail.content"].assertExists()
  }

  func testIncompleteRecordExplainsKeyChangeAndKeepsSessionAndReportRoutes() {
    assertIncompleteRecordKeepsSessionAndReportRoutes(legacyBinding: false)
  }

  func testIncompleteRecordWithLegacyBindingDoesNotInventSignatureEvidence() {
    assertIncompleteRecordKeepsSessionAndReportRoutes(legacyBinding: true)
  }

  private func assertIncompleteRecordKeepsSessionAndReportRoutes(legacyBinding: Bool) {
    var arguments = ["-beid-report-links-701", "-beid-record-incomplete-fixture"]
    if legacyBinding { arguments.append("-beid-record-legacy-binding-fixture") }
    let app = launchEventDetailFixture(extraArguments: arguments)
    let record = app.buttons["event-detail.proof.1"]
    record.scrollToHittable(in: app)
    record.tap()
    app.scrollViews["proof.detail.content"].assertExists()
    let status = app.staticTexts["record.incomplete.title"]
    status.scrollToHittable(in: app)
    XCTAssertEqual(status.label, "Recording incomplete")
    let reason = app.staticTexts["record.incomplete.reason"]
    reason.scrollToHittable(in: app)
    XCTAssertEqual(reason.label,
                   "This recording could not be signed because its signing key changed or could not be verified. The record is kept on this device.")
    XCTAssertTrue(app.windows.firstMatch.frame.contains(reason.frame))
    assertSignatureUnavailable(app)
    app.staticTexts["RECORDED ON THIS DEVICE"].scrollToHittable(in: app)
    attachScreenshot(legacyBinding ? "09-incomplete-legacy-binding" : "09-incomplete-record")
    assertRecordKeepsSessionAndReportRoutes(app)
    XCTAssertEqual(reason.label,
                   "This recording could not be signed because its signing key changed or could not be verified. The record is kept on this device.")
  }

  func testLegacyBindingWithoutSelfProofDoesNotInventSignatureEvidence() {
    // The fixture loads a matching BindingRecord from an isolated store,
    // without creating a SelfProofRecord or overriding presentation values.
    // Placeholder signature bytes establish stored shape, not cryptographic validity.
    let app = launchEventDetailFixture(extraArguments: [
      "-beid-report-links-701", "-beid-record-legacy-binding-fixture"
    ])
    let record = app.buttons["event-detail.proof.1"]
    record.scrollToHittable(in: app)
    record.tap()
    app.scrollViews["proof.detail.content"].assertExists()
    assertSignatureUnavailable(app)
    XCTAssertFalse(app.staticTexts["record.incomplete.title"].exists)
    XCTAssertFalse(app.staticTexts["record.incomplete.reason"].exists)
    let rung = app.staticTexts["RECORDED ON THIS DEVICE"]
    rung.scrollToHittable(in: app)
    if UIDevice.current.userInterfaceIdiom == .phone {
      // Reproduce a fling that leaves the rung behind the navigation bar.
      let navigationBar = app.navigationBars.firstMatch
      let scrollView = app.scrollViews.firstMatch
      for _ in 0..<5 {
        if rung.frame.maxY < navigationBar.frame.maxY { break }
        scrollView.swipeUp()
      }
      XCTAssertTrue(rung.exists)
      XCTAssertFalse(rung.isHittable)
      XCTAssertLessThan(rung.frame.maxY, navigationBar.frame.maxY, "The rung must start above the readable area.")
      rung.scrollToHittable(in: app)
      XCTAssertEqual(rung.label, "RECORDED ON THIS DEVICE")
    }
    attachScreenshot("09-legacy-binding")
    assertRecordKeepsSessionAndReportRoutes(app)
    XCTAssertFalse(app.staticTexts["record.incomplete.title"].exists)
    XCTAssertFalse(app.staticTexts["record.incomplete.reason"].exists)
  }

  private func assertSignatureUnavailable(_ app: XCUIApplication) {
    app.staticTexts["SIGNATURE"].scrollToHittable(in: app)
    app.staticTexts["NOT AVAILABLE"].scrollToHittable(in: app)
    XCTAssertEqual(app.staticTexts["NOT AVAILABLE"].label, "NOT AVAILABLE")
    XCTAssertFalse(app.staticTexts["Self-signed on device"].exists)
    XCTAssertFalse(app.staticTexts["SEALED ON THIS DEVICE"].exists)
    assertNoWalletOrBindingPresentation(app)
  }

  private func assertNoWalletOrBindingPresentation(_ app: XCUIApplication) {
    let elements = app.descendants(matching: .any).allElementsBoundByIndex
    for element in elements {
      let text = element.label + " " + (element.value as? String ?? "")
      for word in ["wallet", "bind", "bound"] {
        XCTAssertFalse(text.localizedCaseInsensitiveContains(word), text)
      }
    }
  }

  private func assertRecordKeepsSessionAndReportRoutes(_ app: XCUIApplication) {
    let recordID = app.staticTexts["Record ID 00000000-0000-4000-8000-000000000631"]
    XCTAssertTrue(recordID.exists)
    XCTAssertTrue(app.staticTexts["See each session"].exists)
    let report = app.buttons["proof-detail.report.\(Self.linkedReportID)"]
    // The linked report is above the ladder; return to the top before scrolling to it.
    for _ in 0..<5 { app.swipeDown() }
    report.scrollToHittable(in: app)
    let reportLabel = report.label
    report.tap()
    app.staticTexts["report-detail.heading"].assertExists()
    XCTAssertTrue(app.descendants(matching: .any)["report-detail.record-id"].label.contains(Self.linkedReportID))
    XCTAssertTrue(app.staticTexts["report-detail.status"].label.contains("PREPARED ON THIS DEVICE"))
    XCTAssertTrue(app.descendants(matching: .any)["report-detail.delivery"].label.contains("NOT SENT"))
    app.navigationBars.buttons.firstMatch.tap()
    for number in 1...3 {
      XCTAssertTrue(app.buttons["record.session.00000000-0000-4000-8000-00000000063\(number)"].exists)
    }
    let session = app.buttons["record.session.00000000-0000-4000-8000-000000000631"]
    session.scrollToHittable(in: app)
    session.tap()
    app.staticTexts["observation-detail.title"].assertExists()
    XCTAssertFalse(app.staticTexts["observation-detail.unavailable"].exists)
    app.navigationBars.buttons.firstMatch.tap()
    app.scrollViews["proof.detail.content"].assertExists()
    for _ in 0..<5 { app.swipeDown() }
    XCTAssertTrue(recordID.exists)
    assertSignatureUnavailable(app)
    XCTAssertEqual(report.label, reportLabel)
  }

  func testSelectingObservedWindowExposesThatSelection() {
    let app = launchObservationFixture()
    let record = app.buttons["event-detail.proof.1"]
    record.scrollToHittable(in: app)
    record.tap()
    app.scrollViews["proof.detail.content"].assertExists()
    let fullSigil = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == %@", "Devices heard: 23. Window 6. Mutual check not available yet.")
    ).firstMatch
    fullSigil.assertExists()
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.staticTexts["event-detail.heading"].assertExists()

    let session = app.buttons["event-detail.observation.1"]
    session.scrollToHittable(in: app)
    session.tap()
    app.staticTexts["observation-detail.title"].assertExists()
    app.descendants(matching: .any)["observation-detail.chart"].assertExists()
    let fourthWindow = app.descendants(matching: .any).matching(
      NSPredicate(
        format: "label == %@",
        "Observed window 4; peer count 19; preceding unobserved window count 1"
      )
    ).firstMatch
    fourthWindow.assertHittable()
    fourthWindow.tap()
    XCTAssertTrue(
      app.descendants(matching: .any).matching(
        NSPredicate(format: "label == %@", "Devices heard: 23. Window 4. Mutual check not available yet.")
      ).firstMatch.exists,
      "Selected window 4 must render four observed windows from stored Sigil input"
    )
    XCTAssertTrue(fourthWindow.isSelected)

    let firstWindow = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == %@", "Observed window 1; peer count 4")
    ).firstMatch
    firstWindow.assertHittable()
    firstWindow.tap()
    XCTAssertTrue(
      app.descendants(matching: .any).matching(
        NSPredicate(format: "label == %@", "Devices heard: 4. Window 1. Mutual check not available yet.")
      ).firstMatch.exists,
      "Selected window 1 must exclude peers first observed in later windows"
    )
    XCTAssertTrue(firstWindow.isSelected)
    XCTAssertFalse(fourthWindow.isSelected)

    let secondWindow = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == %@", "Observed window 2; peer count 8")
    ).firstMatch
    secondWindow.assertHittable()
    secondWindow.tap()
    XCTAssertTrue(
      app.descendants(matching: .any).matching(
        NSPredicate(format: "label == %@", "Devices heard: 12. Window 2. Mutual check not available yet.")
      ).firstMatch.exists,
      "Selected window 2 must include only the first two observed windows"
    )
    XCTAssertTrue(secondWindow.isSelected)
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.staticTexts["event-detail.heading"].assertExists()
    record.scrollToHittable(in: app)
    record.tap()
    app.scrollViews["proof.detail.content"].assertExists()
    fullSigil.assertExists()
  }

  func testStoredRecordArtworkAnnouncesMutualityAsUnavailable() {
    let app = launchObservationFixture()
    let record = app.buttons["event-detail.proof.1"]
    record.scrollToHittable(in: app)
    record.tap()
    app.scrollViews["proof.detail.content"].assertExists()
    let artwork = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == %@", "Devices heard: 23. Window 6. Mutual check not available yet.")
    ).firstMatch
    artwork.assertExists()
    XCTAssertTrue(
      artwork.label.localizedCaseInsensitiveContains("mutual check not available yet"),
      "A device record cannot announce mutual confirmation as a measured zero"
    )
    XCTAssertFalse(artwork.label.localizedCaseInsensitiveContains("0 mutual"))
  }

  func testDisclosureDescribesASignatureWithoutPresenceClaims() {
    let app = launchCollectedRecordForCopyAssertions()
    app.buttons["proof-collected.whatWeSend"].assertHittable()
    app.buttons["proof-collected.whatWeSend"].tap()
    app.descendants(matching: .any)["whatWeSend.firstRow"].assertExists()
    let scroll = app.scrollViews["whatWeSend.scroll"]
    scroll.assertExists()
    let signatureTitle = "A signature from this device"
    let signature = app.descendants(matching: .any).matching(
      NSPredicate(format: "label BEGINSWITH %@ AND label != %@", signatureTitle, signatureTitle)
    ).firstMatch
    for _ in 0..<6 where !signature.isHittable { scroll.swipeUp() }
    signature.assertHittable()
    XCTAssertFalse(
      signature.label.localizedCaseInsensitiveContains("proves"),
      "The signature description must explain a signed record without a proves claim; got: \(signature.label)"
    )
    XCTAssertFalse(signature.label.localizedCaseInsensitiveContains("attendance"))
    XCTAssertFalse(signature.label.localizedCaseInsensitiveContains("was there"))
  }

  func testShot_11_ObservationDetail() {
    let app = launchObservationFixture()
    let row = app.buttons["event-detail.observation.1"]
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    if !row.isHittable { app.swipeUp() }
    row.tap()
    XCTAssertTrue(app.staticTexts["observation-detail.title"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["PEERS PER OBSERVED WINDOW"].exists)
    XCTAssertTrue(app.staticTexts["23"].exists)
    XCTAssertTrue(app.staticTexts["6"].exists)
    XCTAssertFalse(app.staticTexts["MUTUAL"].exists)
    XCTAssertTrue(app.staticTexts["AVG SIGNAL"].exists)
    XCTAssertTrue(app.staticTexts["WINDOW DURATION"].exists)
    XCTAssertTrue(app.staticTexts["NOT YET AVAILABLE"].exists)
    XCTAssertFalse(app.staticTexts["INCLUDED IN REPORTS"].exists)

    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "11"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testObservationDetailWithMissingSnapshotShowsOneUnavailableState() {
    let app = launchObservationFixture()
    let row = app.buttons["event-detail.observation.3"]
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    if !row.isHittable { app.swipeUp() }
    row.tap()
    XCTAssertTrue(app.staticTexts["observation-detail.title"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["observation-detail.unavailable"].exists)
    XCTAssertFalse(app.staticTexts["PEERS PER OBSERVED WINDOW"].exists)
    XCTAssertFalse(app.staticTexts["DEVICES HEARD"].exists)
  }

  // MARK: - beid#701 report-to-proof links

  private static let linkedReportID = "00000000-0000-4000-8000-000000000639"

  /// The 08 fixture's report, linked to Session 1 only.
  func testLinkedReportDetailShowsItsSessionAndSessionProof() {
    let app = launchEventDetailFixture(extraArguments: ["-beid-report-links-701"])
    openReportDetail(app)

    let session = app.descendants(matching: .any)["report-detail.session"]
    for _ in 0..<5 where !session.isHittable { app.swipeUp() }
    XCTAssertTrue(session.waitForExistence(timeout: 5))
    XCTAssertTrue(session.label.contains("Session 1"), session.label)
    // Not a link: 11 opens 12, so a 12 → 11 link would cycle without end.
    XCTAssertFalse(app.buttons["report-detail.session"].exists)

    XCTAssertTrue(app.staticTexts["SESSION RECORD"].exists)
    let proofRow = app.buttons["report-detail.session-proof"]
    for _ in 0..<5 where !proofRow.isHittable { app.swipeUp() }
    XCTAssertTrue(proofRow.waitForExistence(timeout: 5))
    XCTAssertTrue(proofRow.label.contains("Record for session 1"), proofRow.label)
    XCTAssertFalse(app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS[c] %@", "verif")
    ).firstMatch.exists)
    attachScreenshot("12-linked")

    proofRow.tap()
    XCTAssertTrue(app.scrollViews["proof.detail.content"].waitForExistence(timeout: 5))
    assertFromReportsListsTheLinkedReport(app)
  }

  func testLinkedSessionListsItsReportAndOtherSessionsDoNot() {
    let app = launchEventDetailFixture(extraArguments: ["-beid-report-links-701"])
    openSession(1, in: app)
    let included = app.staticTexts["OTHER STORED REPORTS"]
    for _ in 0..<5 where !included.isHittable { app.swipeUp() }
    XCTAssertTrue(included.waitForExistence(timeout: 5))
    let report = app.buttons["observation-detail.report.\(Self.linkedReportID)"]
    XCTAssertTrue(report.exists)
    XCTAssertTrue(report.label.contains("Report #1"), report.label)
    attachScreenshot("11-linked")

    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.staticTexts["event-detail.heading"].waitForExistence(timeout: 5))
    openSession(2, in: app)
    for _ in 0..<3 { app.swipeUp() }
    XCTAssertFalse(app.staticTexts["OTHER STORED REPORTS"].exists)
    XCTAssertFalse(app.buttons["observation-detail.report.\(Self.linkedReportID)"].exists)
  }

  func testLinkedProofDetailFromEventDetailListsItsReport() {
    let app = XCUIApplication()
    app.launchArguments = ["-beid-ui-test", "-beid-event-detail-frame-08", "-beid-report-links-701"]
    app.launch()
    let getStarted = app.buttons["Continue"]
    getStarted.assertExists()
    getStarted.tap()
    let allowBluetooth = app.buttons["bluetooth.permission.continue"]
    allowBluetooth.assertExists()
    allowBluetooth.tap()
    app.openRecordsByEvent()
    let event = app.buttons["home.past-event.ETHTOKYO2026"]
    event.assertExists()
    event.tap()
    app.staticTexts["event-detail.heading"].assertHittable()

    let proof = app.buttons["event-detail.proof.1"]
    proof.scrollToHittable(in: app)
    proof.tap()
    app.scrollViews["proof.detail.content"].assertHittable()
    app.staticTexts["FROM REPORTS"].scrollToHittable(in: app)
    let report = app.buttons["proof-detail.report.\(Self.linkedReportID)"]
    XCTAssertTrue(report.exists)
    XCTAssertTrue(report.label.contains("Report #1"), report.label)
    attachScreenshot("09-linked")
  }

  /// The same report without a link row is every pre-#701 record: 12 shows
  /// exactly its old screen and 09 has no report section.
  func testUnlinkedReportShowsNoLinkContent() {
    let app = launchEventDetailFixture(extraArguments: [])
    openReportDetail(app)
    for _ in 0..<3 { app.swipeUp() }
    XCTAssertTrue(app.staticTexts["OBSERVATIONS INCLUDED"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["report-detail.session"].exists)
    XCTAssertFalse(app.staticTexts["SESSION RECORD"].exists)
    XCTAssertFalse(app.buttons["report-detail.session-proof"].exists)

    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.staticTexts["observation-detail.title"].assertExists()
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.staticTexts["event-detail.heading"].assertExists()
    let proof = app.buttons["event-detail.proof.1"]
    for _ in 0..<5 where !proof.isHittable { app.swipeUp() }
    XCTAssertTrue(proof.waitForExistence(timeout: 5))
    proof.tap()
    XCTAssertTrue(app.scrollViews["proof.detail.content"].waitForExistence(timeout: 5))
    for _ in 0..<3 { app.swipeUp() }
    XCTAssertFalse(app.staticTexts["FROM REPORTS"].exists)
  }

  private func launchCollectedRecordForCopyAssertions() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-beid-ui-test", "-beid-sensing-shot", "07"]
    app.launch()
    app.buttons["Continue"].assertHittable()
    app.buttons["Continue"].tap()
    app.buttons["bluetooth.permission.continue"].assertHittable()
    app.buttons["bluetooth.permission.continue"].tap()
    app.buttons["home.demo.join"].assertHittable()
    app.buttons["home.demo.join"].tap()
    app.staticTexts["proof-collected.record-id"].assertExists()
    return app
  }

  private func assertFromReportsListsTheLinkedReport(
    _ app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let heading = app.staticTexts["FROM REPORTS"]
    for _ in 0..<5 where !heading.isHittable { app.swipeUp() }
    XCTAssertTrue(heading.waitForExistence(timeout: 5), file: file, line: line)
    let report = app.buttons["proof-detail.report.\(Self.linkedReportID)"]
    XCTAssertTrue(report.exists, file: file, line: line)
    XCTAssertTrue(report.label.contains("Report #1"), report.label, file: file, line: line)
  }

  private func openReportDetail(_ app: XCUIApplication) {
    openSession(1, in: app)
    let linked = app.buttons["observation-detail.report.\(Self.linkedReportID)"]
    let unassigned = app.buttons["observation-detail.unassigned-report.\(Self.linkedReportID)"]
    let report = linked.exists ? linked : unassigned
    report.scrollToHittable(in: app)
    report.tap()
    let heading = app.staticTexts["report-detail.heading"]
    XCTAssertTrue(heading.waitForExistence(timeout: 5))
    XCTAssertEqual(heading.label, "Report #1")
  }

  private func openSession(_ number: Int, in app: XCUIApplication) {
    let row = app.buttons["event-detail.observation.\(number)"]
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    if !row.isHittable { app.swipeUp() }
    row.tap()
    let title = app.staticTexts["observation-detail.title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    let starts: [TimeInterval] = [1_774_486_920, 1_774_498_500, 1_774_510_200]
    XCTAssertEqual(title.label, Date(timeIntervalSince1970: starts[number - 1]).formatted(date: .omitted, time: .shortened))
  }

  private func launchEventDetailFixture(extraArguments: [String]) -> XCUIApplication {
    launchPastEvent(arguments: ["-beid-ui-test", "-beid-event-detail-frame-08"] + extraArguments)
  }

  private func launchObservationFixture() -> XCUIApplication {
    launchPastEvent(arguments: ["-beid-ui-test", "-beid-observation-frame-11"])
  }

  private func launchPastEvent(arguments: [String]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = arguments
    app.launch()
    let getStarted = app.buttons["Continue"]
    XCTAssertTrue(getStarted.waitForExistence(timeout: 10))
    getStarted.tap()
    let allowBluetooth = app.buttons["bluetooth.permission.continue"]
    XCTAssertTrue(allowBluetooth.waitForExistence(timeout: 10))
    allowBluetooth.tap()
    XCTAssertTrue(app.buttons["home.demo.join"].waitForExistence(timeout: 10))
    app.openRecordsByEvent()
    let event = app.buttons["home.past-event.ETHTOKYO2026"]
    XCTAssertTrue(event.waitForExistence(timeout: 10))
    event.tap()
    XCTAssertTrue(app.staticTexts["event-detail.heading"].waitForExistence(timeout: 5))
    return app
  }

  private func attachScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func launchSensingFixture(
    _ code: String, file: StaticString = #filePath, line: UInt = #line
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-beid-ui-test", "-beid-sensing-shot", code]
    app.launch()

    let getStarted = app.buttons["Continue"]
    XCTAssertTrue(getStarted.waitForExistence(timeout: 10), file: file, line: line)
    getStarted.tap()

    let allowBluetooth = app.buttons["bluetooth.permission.continue"]
    XCTAssertTrue(allowBluetooth.waitForExistence(timeout: 10), file: file, line: line)
    allowBluetooth.tap()

    let senseEvent = app.buttons["home.demo.join"]
    XCTAssertTrue(senseEvent.waitForExistence(timeout: 10), file: file, line: line)
    senseEvent.tap()

    XCTAssertTrue(app.staticTexts["ETH Tokyo 2026"].waitForExistence(timeout: 10), file: file, line: line)
    return app
  }

  private func capture(_ code: String, file: StaticString = #filePath, line: UInt = #line) {
    let app = launchSensingFixture(code, file: file, line: line)
    if ["05", "05a", "05a2", "05a3", "05e", "06"].contains(code) {
      XCTAssertFalse(app.staticTexts["MUTUAL"].exists, file: file, line: line)
      XCTAssertTrue(app.staticTexts["DEVICES HEARD"].exists, file: file, line: line)
      XCTAssertTrue(app.staticTexts["ELAPSED"].exists, file: file, line: line)
    }
    if code == "06" {
      XCTAssertTrue(app.staticTexts["DONE · YOU CAN CLOSE THE APP"].exists, file: file, line: line)
    }
    if code == "07" {
      XCTAssertTrue(app.buttons["View records"].exists, file: file, line: line)
      let recordID = app.staticTexts["proof-collected.record-id"]
      XCTAssertTrue(recordID.exists, file: file, line: line)
      XCTAssertEqual(
        recordID.label,
        "Record ID 42110000-0000-4000-8000-000000000000",
        file: file, line: line
      )
      XCTAssertGreaterThan(recordID.frame.width, 100, file: file, line: line)
      XCTAssertEqual(app.staticTexts["proof-collected.status"].label, "SEALED", file: file, line: line)
    } else if code == "09" {
      XCTAssertTrue(app.scrollViews["proof.detail.content"].exists, file: file, line: line)
      XCTAssertTrue(app.staticTexts["Self-signed on device"].exists, file: file, line: line)
      assertNoWalletOrBindingPresentation(app)
      XCTAssertFalse(app.staticTexts["Bound to wallet"].exists, file: file, line: line)
      XCTAssertFalse(app.buttons["Transparency"].exists, file: file, line: line)
      XCTAssertFalse(app.buttons["View participation summary"].exists, file: file, line: line)
      let externalResult = app.staticTexts["THIRD-PARTY RESULT"]
      for _ in 0..<4 where !externalResult.isHittable { app.swipeUp() }
      XCTAssertTrue(externalResult.exists, file: file, line: line)
      XCTAssertTrue(app.staticTexts["NOT YET AVAILABLE"].exists, file: file, line: line)
      for _ in 0..<4 { app.swipeDown() }
      XCTAssertFalse(app.staticTexts["FROM REPORTS"].exists, file: file, line: line)
    }
    let initial = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: initial)
    attachment.name = code
    attachment.lifetime = .keepAlways
    add(attachment)
    let values: [String: (heard: String, elapsed: String)] = [
      "05": ("13", "25:00"), "05a": ("5", "0:10"), "05a2": ("5", "0:24"),
      "05a3": ("5", "2:00"), "05e": ("13", "25:00"), "06": ("13", "30:00")
    ]
    if let expected = values[code] {
      SensingVisualOracle.assertInitialMetrics(in: app, test: self, name: code, expected: expected,
                                               screenshot: initial, file: file, line: line)
    }
    if code == "06" { SensingVisualOracle.assertSavedCaption(in: app, test: self, name: "06-fixture", file: file, line: line) }
  }
}
