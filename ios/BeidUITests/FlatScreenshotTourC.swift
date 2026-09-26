// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

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
  func testShot_05d_CantJoin() { capture("05d") }
  func testShot_05e_StopConfirm() { capture("05e") }
  func testShot_06_Sealed() { capture("06") }
  func testShot_07_ProofCollected() { capture("07") }
  func testShot_09_ProofDetail() { capture("09") }

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
    XCTAssertFalse(app.staticTexts["AVG SIGNAL"].exists)
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
    XCTAssertFalse(app.staticTexts["PEERS OBSERVED"].exists)
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

    XCTAssertTrue(app.staticTexts["SESSION PROOF"].exists)
    let proofRow = app.buttons["report-detail.session-proof"]
    for _ in 0..<5 where !proofRow.isHittable { app.swipeUp() }
    XCTAssertTrue(proofRow.waitForExistence(timeout: 5))
    XCTAssertTrue(proofRow.label.contains("Session 1 proof"), proofRow.label)
    XCTAssertFalse(app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS[c] %@", "verif")
    ).firstMatch.exists)
    attachScreenshot("12-linked")

    proofRow.tap()
    XCTAssertTrue(app.staticTexts["proof.detail.title"].waitForExistence(timeout: 5))
    assertFromReportsListsTheLinkedReport(app)
  }

  func testLinkedSessionListsItsReportAndOtherSessionsDoNot() {
    let app = launchEventDetailFixture(extraArguments: ["-beid-report-links-701"])
    openSession(1, in: app)
    let included = app.staticTexts["INCLUDED IN REPORTS"]
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
    XCTAssertFalse(app.staticTexts["INCLUDED IN REPORTS"].exists)
    XCTAssertFalse(app.buttons["observation-detail.report.\(Self.linkedReportID)"].exists)
  }

  func testLinkedProofDetailFromEventDetailListsItsReport() {
    let app = launchEventDetailFixture(extraArguments: ["-beid-report-links-701"])
    let proof = app.buttons["event-detail.proof.1"]
    for _ in 0..<5 where !proof.isHittable { app.swipeUp() }
    XCTAssertTrue(proof.waitForExistence(timeout: 5))
    proof.tap()
    XCTAssertTrue(app.staticTexts["proof.detail.title"].waitForExistence(timeout: 5))
    assertFromReportsListsTheLinkedReport(app)
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
    XCTAssertFalse(app.staticTexts["SESSION PROOF"].exists)
    XCTAssertFalse(app.buttons["report-detail.session-proof"].exists)

    app.navigationBars.buttons.element(boundBy: 0).tap()
    let proof = app.buttons["event-detail.proof.1"]
    for _ in 0..<5 where !proof.isHittable { app.swipeUp() }
    XCTAssertTrue(proof.waitForExistence(timeout: 5))
    proof.tap()
    XCTAssertTrue(app.staticTexts["proof.detail.title"].waitForExistence(timeout: 5))
    for _ in 0..<3 { app.swipeUp() }
    XCTAssertFalse(app.staticTexts["FROM REPORTS"].exists)
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
    let report = app.buttons["event-detail.report.\(Self.linkedReportID)"]
    for _ in 0..<5 where !report.isHittable { app.swipeUp() }
    XCTAssertTrue(report.waitForExistence(timeout: 5))
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
    XCTAssertEqual(title.label, "Session \(number)")
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
    let getStarted = app.buttons["Get Started"]
    XCTAssertTrue(getStarted.waitForExistence(timeout: 10))
    getStarted.tap()
    let allowBluetooth = app.buttons["Allow Bluetooth"]
    XCTAssertTrue(allowBluetooth.waitForExistence(timeout: 10))
    allowBluetooth.tap()
    XCTAssertTrue(app.buttons["home.scan"].waitForExistence(timeout: 10))
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

  private func capture(_ code: String, file: StaticString = #filePath, line: UInt = #line) {
    let app = XCUIApplication()
    app.launchArguments = ["-beid-ui-test", "-beid-sensing-shot", code]
    app.launch()

    let getStarted = app.buttons["Get Started"]
    XCTAssertTrue(getStarted.waitForExistence(timeout: 10), file: file, line: line)
    getStarted.tap()

    let allowBluetooth = app.buttons["Allow Bluetooth"]
    XCTAssertTrue(allowBluetooth.waitForExistence(timeout: 10), file: file, line: line)
    allowBluetooth.tap()

    let senseEvent = app.buttons["home.scan"]
    XCTAssertTrue(senseEvent.waitForExistence(timeout: 10), file: file, line: line)
    senseEvent.tap()

    XCTAssertTrue(app.staticTexts["ETH Tokyo 2026"].waitForExistence(timeout: 10), file: file, line: line)
    if code == "07" {
      XCTAssertTrue(app.buttons["View collection"].exists, file: file, line: line)
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
      XCTAssertTrue(app.staticTexts["proof.detail.title"].exists, file: file, line: line)
      XCTAssertTrue(app.staticTexts["Bound to wallet"].exists, file: file, line: line)
      XCTAssertTrue(app.buttons["Transparency"].exists, file: file, line: line)
      XCTAssertTrue(app.buttons["View participation summary"].exists, file: file, line: line)
      XCTAssertFalse(app.staticTexts["FROM REPORTS"].exists, file: file, line: line)
    }
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = code
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
