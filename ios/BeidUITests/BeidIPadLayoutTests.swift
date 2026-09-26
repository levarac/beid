// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest

final class BeidIPadLayoutTests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testPrimaryFlowInPortrait() {
    XCUIDevice.shared.orientation = .portrait
    capturePrimaryFlow(orientation: "portrait")
  }

  func testPrimaryFlowInLandscape() {
    XCUIDevice.shared.orientation = .landscapeLeft
    capturePrimaryFlow(orientation: "landscape")
  }

  private func capturePrimaryFlow(orientation: String) {
    app.launchArguments = ["-beid-ui-test"]
    app.launch()

    assertWelcomeLayout(named: "welcome-\(orientation)")
    app.buttons["Get Started"].tap()

    // OnboardingMode.current is .guestFirst (event-first, the default — see
    // OnboardingFlagTests): Welcome's CTA routes straight to the
    // Bluetooth-permission screen, with no wallet-connect/event-code step.
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    capture(named: "bluetooth-permission-\(orientation)")

    app.buttons["Allow Bluetooth"].tap()
    let senseEvent = app.buttons["home.scan"]
    XCTAssertTrue(senseEvent.waitForExistence(timeout: 5))
    capture(named: "collection-empty-\(orientation)")

    app.buttons["home.account"].tap()
    XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
    capture(named: "account-\(orientation)")
    app.buttons["Done"].tap()

    let resumedSenseEvent = app.buttons["home.scan"]
    XCTAssertTrue(resumedSenseEvent.waitForExistence(timeout: 5))
    resumedSenseEvent.tap()
    XCTAssertTrue(app.descendants(matching: .any)["scan.sensing"].waitForExistence(timeout: 30))
    capture(named: "sensing-\(orientation)")

    XCTAssertTrue(app.staticTexts["scan.event-found"].waitForExistence(timeout: 30))
    capture(named: "event-found-\(orientation)")

    // Recording remains live until the user confirms stopping. Threshold
    // confirmation auto-flips into `.recording`; the "Simulate Signal Lost"
    // affordance existing is the earliest reliable signal that happened.
    let signalLost = app.buttons["Simulate Signal Lost"]
    XCTAssertTrue(signalLost.waitForExistence(timeout: 30))
    dismissBindingSheetToReachLiveRecording()
    capture(named: "recording-\(orientation)")

    // CLOSE confirms the real Proof, DONE advances through persistent 07,
    // then View collection dismisses to Home.
    app.buttons["Close"].tap()
    XCTAssertTrue(app.staticTexts["Stop sensing?"].waitForExistence(timeout: 5))
    capture(named: "stop-confirm-\(orientation)")
    app.buttons["Stop and keep record"].tap()
    XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
    capture(named: "sealed-\(orientation)")
    app.buttons["Done"].tap()
    XCTAssertTrue(app.buttons["View collection"].waitForExistence(timeout: 5))
    assertProofCollectedHeader()
    capture(named: "proof-collected-\(orientation)")
    app.buttons["View collection"].tap()

    XCTAssertTrue(resumedSenseEvent.waitForExistence(timeout: 5))
    capture(named: "collection-with-proof-\(orientation)")
    app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ETHGlobal Tokyo")).firstMatch.tap()
    XCTAssertTrue(app.staticTexts["event-detail.heading"].waitForExistence(timeout: 5))
    app.buttons["event-detail.proof.1"].tap()
    XCTAssertTrue(app.staticTexts["proof.detail.title"].waitForExistence(timeout: 5))
    capture(named: "proof-detail-\(orientation)")
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(app.staticTexts["event-detail.heading"].waitForExistence(timeout: 5))
    app.navigationBars.buttons.firstMatch.tap()

    resumedSenseEvent.tap()
    // Generous timeout: re-entering the scan flow a second time in one test
    // run has been observed to take noticeably longer than the first entry
    // (accumulated simulator/accessibility-tree overhead from the
    // intervening Collection/Proof Detail navigation), not a hang.
    XCTAssertTrue(signalLost.waitForExistence(timeout: 30))
    dismissBindingSheetToReachLiveRecording()
    signalLost.tap()
    XCTAssertTrue(app.staticTexts["Signal Lost"].waitForExistence(timeout: 30))
    capture(named: "signal-lost-\(orientation)")
  }

  /// A finished DemoEvent creates a matching SelfProofRecord. That record
  /// supports Sealed; no third-party verification or wallet binding follows.
  func testProofDetailStatusReflectsStoredSelfProof() {
    navigateToCollectionWithProof()
    openFirstProof()

    XCTAssertTrue(app.staticTexts["Sealed"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Self-signed on device"].exists)
    XCTAssertFalse(app.staticTexts["Verified"].exists)
    XCTAssertFalse(app.staticTexts["Bound to wallet"].exists)
  }

  /// beid#222, DECISIONS 2026-08-20: the Participation summary headline
  /// ("Devices mutually confirmed") must never render a literal number,
  /// including 0 — the protocol cannot measure mutual (two-way)
  /// confirmation on-device, and an honest 0 reads on real hardware as
  /// "measured and got 0," which is misinformation. It must always show a
  /// "not yet available" state instead, independent of whether a
  /// session-aggregate snapshot exists (this DemoEvent proof does have one,
  /// so `bandBuildupSection` legitimately shows real band rows — this test
  /// confirms the headline's own fix applies even when other data on the
  /// same screen is present, which is the actual #222 regression scenario).
  func testParticipationSummaryHeadlineHidesNumericMutualCount() {
    navigateToCollectionWithProof()
    openFirstProof()

    app.buttons["View participation summary"].tap()
    XCTAssertTrue(app.staticTexts["Devices mutually confirmed"].waitForExistence(timeout: 5))

    XCTAssertTrue(app.staticTexts["Not yet available"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["0"].exists)
  }

  /// Regression coverage for beid#244. **What this test's claim depends
  /// on**: every DemoEvent proof carries the same fixed `eventCode`
  /// (`DemoEvent.EventSession.demoSample.id`, `"ETHGLOBALTOKYO-DEMO"`), so
  /// two proofs recorded in two different launches of this test still
  /// group together via `EventGrouping.sessions(for:in:)` unless
  /// `ProofStore`'s on-disk state was actually reset between launches —
  /// this test does not by itself prove isolation for a store keyed some
  /// other way.
  ///
  /// `xcodebuild test` reinstalls the app once per suite run, not once per
  /// test method: every `app.launch()` across every UI test method reuses
  /// the same on-disk container. Before the beid#244 fix, a `ProofStore`
  /// proof left behind by an earlier launch silently accumulated with a
  /// later launch's proof under the same `eventCode`, flipping
  /// `ItemDetailView.participationSummaryRow`'s destination from
  /// `ParticipationSummaryView` (single session) to
  /// `SessionParticipationListView` (multi-session) without failing any
  /// assertion on its own — this test forces that exact
  /// record/terminate/relaunch/record sequence inside one method (rather
  /// than relying on suite execution order, which is not guaranteed) and
  /// asserts the second launch still resolves a single-session group.
  func testProofStoreDoesNotAccumulateAcrossUITestLaunches() {
    navigateToCollectionWithProof()

    // Force-quit-and-relaunch (documented `XCUIApplication.launch()`
    // behavior for an already-running app), simulating the process
    // boundary between two independent UI-test launches that share one
    // installed app container — the exact scenario beid#244 reported.
    app.terminate()
    navigateToCollectionWithProof()
    openFirstProof()

    app.buttons["View participation summary"].tap()
    XCTAssertTrue(
      app.staticTexts["Devices mutually confirmed"].waitForExistence(timeout: 5),
      "A second -beid-ui-test launch must still resolve a single-session group; seeing " +
        "the multi-session list here means the first launch's proof leaked into this one"
    )
    XCTAssertFalse(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "recorded for this event")).firstMatch.exists,
      "SessionParticipationListView's header must not appear for what should be a single-session group"
    )
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
    XCTAssertTrue(diagnosticCaption.waitForExistence(timeout: 5))

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
  /// `.recording` begins, then declines its automatic binding sheet so the
  /// live screen's controls are hittable. Used by both the
  /// Recording-screen test above and `navigateToCollectionWithProof` below.
  private func reachRecordingScreen() {
    app.launchArguments = ["-beid-ui-test"]
    app.launch()

    app.buttons["Get Started"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()

    let senseEvent = app.buttons["home.scan"]
    XCTAssertTrue(senseEvent.waitForExistence(timeout: 5))
    senseEvent.tap()
    XCTAssertTrue(app.descendants(matching: .any)["scan.sensing"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.staticTexts["scan.event-found"].waitForExistence(timeout: 30))

    XCTAssertTrue(app.buttons["Simulate Signal Lost"].waitForExistence(timeout: 30))
    dismissBindingSheetToReachLiveRecording()
  }

  private func dismissBindingSheetToReachLiveRecording() {
    let cancel = app.buttons["Not now"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 15), "Recording must offer the binding sheet")
    XCTAssertTrue(cancel.isHittable, "The binding sheet Not now control must be tappable")
    cancel.tap()
    XCTAssertFalse(cancel.exists, "Not now must dismiss the binding sheet")
    XCTAssertTrue(app.buttons["Simulate Signal Lost"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Close"].isHittable, "Live recording Close must be tappable")
  }

  /// Ends the session `reachRecordingScreen()` just started, landing on
  /// Collection with the resulting proof. Same steps `capturePrimaryFlow`
  /// already exercises, without its screenshot/orientation concerns.
  private func navigateToCollectionWithProof() {
    reachRecordingScreen()
    app.buttons["Close"].tap()
    XCTAssertTrue(app.staticTexts["Stop sensing?"].waitForExistence(timeout: 5))
    app.buttons["Stop and keep record"].tap()
    XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
    app.buttons["Done"].tap()
    XCTAssertTrue(app.buttons["View collection"].waitForExistence(timeout: 5))
    assertProofCollectedHeader()
    app.buttons["View collection"].tap()

    XCTAssertTrue(app.buttons["home.scan"].waitForExistence(timeout: 5))
  }

  /// Opens the DemoEvent proof `navigateToCollectionWithProof` just left on
  /// Collection, and waits for Proof Detail to appear.
  private func openFirstProof() {
    app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ETHGlobal Tokyo")).firstMatch.tap()
    XCTAssertTrue(app.staticTexts["event-detail.heading"].waitForExistence(timeout: 5))
    app.buttons["event-detail.proof.1"].tap()
    XCTAssertTrue(app.staticTexts["proof.detail.title"].waitForExistence(timeout: 5))
  }

  private func assertProofCollectedHeader() {
    let recordID = app.staticTexts["proof-collected.record-id"]
    XCTAssertTrue(recordID.waitForExistence(timeout: 5))
    XCTAssertTrue(recordID.label.hasPrefix("Record ID "))
    XCTAssertEqual(recordID.label.count, "Record ID ".count + 36, "VoiceOver needs the full UUID")
    XCTAssertGreaterThan(recordID.frame.width, 100, "The visible record label must not truncate")
    XCTAssertEqual(app.staticTexts["proof-collected.status"].label, "SEALED")
  }

  private func assertWelcomeLayout(named name: String) {
    let getStarted = app.buttons["Get Started"]
    let appWindow = app.windows.firstMatch
    XCTAssertTrue(getStarted.waitForExistence(timeout: 5))
    XCTAssertTrue(appWindow.exists)
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
