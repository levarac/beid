// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest

/// Regression coverage for beid#222/#224: the wallet-binding sheet's
/// presentation and recovery behavior.
///
/// `testBindingSheetAutoPresentsOnRecordingAndDoesNotReopenAfterDismissal`
/// guards the auto-present invariant: the sheet must present automatically
/// once `.recording` begins (chained through `bindingState` going fresh
/// `.none` → `.pendingConnect`, then `RecordingView`'s entrance ceremony
/// finishing), not only on the next scenePhase foreground transition — a
/// session that never backgrounds the app (e.g. this whole DemoEvent
/// walkthrough) previously never saw it. It also guards against a
/// regression this fix could introduce if written wrong: dismissing the
/// sheet re-sets `bindingState` back to `.pendingConnect`
/// (`SensingCoordinator.declineBinding()`), so a naive `newValue`-only
/// `.onChange` guard would reopen the sheet the instant it's dismissed.
///
/// `testMistimedCloseTapDuringBindingSheetPresentationRecoversViaCancelThenClose`
/// guards the mistimed-tap-recovers invariant: tapping `ScanFlowView`'s
/// "Close" toolbar button in the narrow window right as the auto-presented
/// binding sheet begins animating in is a no-op (the button is not yet
/// hittable when the tap lands), and the user reaches Collection Home
/// deterministically in two further, real taps — `Cancel` then `Close`. See
/// that test's own doc comment for the investigation history that
/// established this.
final class RecordingBindingSheetUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testBindingSheetAutoPresentsOnRecordingAndDoesNotReopenAfterDismissal() {
    launchAndReachSenseEventScreen()

    app.buttons["Sense Event"].tap()

    // Reaching `.recording` fires `beginRecording`, which sets
    // `bindingState = .pendingConnect(event)` fresh from `.none`
    // (`resetSessionState()` at the `.eventFound` transition put it there
    // moments earlier). `ScanFlowView` no longer presents directly off that
    // — it chains presentation to `sensing.entranceCeremonyFinished`
    // instead (sequenced after the ceremony, not racing its animation —
    // see `ScanFlowView`'s doc comment on that `.onChange`), so this must
    // wait out `RecordingView`'s ~2s entrance-ceremony dwell on top of the
    // ~2s demo step delay before the sheet appears; the generous timeout
    // reflects that, not test flakiness.
    let cancelButton = app.buttons["Cancel"]
    XCTAssertTrue(
      cancelButton.waitForExistence(timeout: 15),
      "Binding sheet should auto-present once .recording begins, without backgrounding the app"
    )

    cancelButton.tap()

    // `Cancel` calls `sensing.declineBinding()`, which re-sets `bindingState`
    // back to `.pendingConnect(event)` (§5.6: re-offered next foreground,
    // never re-shown mid-session on its own) — the regression this test
    // guards against is a naive `.onChange` that treats that re-entry as
    // another fresh threshold-cross and reopens the sheet immediately.
    XCTAssertFalse(cancelButton.exists, "Binding sheet should be dismissed after tapping Cancel")

    // Give any errant auto-reopen a real window to occur before asserting
    // it stayed dismissed — long enough to catch an immediate-reopen bug,
    // short enough to keep the test fast when (correctly) nothing happens.
    // An inverted expectation that nothing ever fulfills blocks for the
    // full timeout without failing, which is exactly the "wait, then
    // check" shape needed here (unlike a manually-fulfilled expectation,
    // which would report a false failure the instant its timer fires).
    let settle = expectation(description: "settle without the sheet reopening")
    settle.isInverted = true
    wait(for: [settle], timeout: 3)

    XCTAssertFalse(cancelButton.exists, "Binding sheet must not reopen itself after being dismissed")
  }

  /// Regression test for beid#224: a mistimed tap on `ScanFlowView`'s own
  /// "Close" toolbar button, landing in the narrow window right as the
  /// auto-presented binding sheet begins animating in, must not strand the
  /// user.
  ///
  /// **Four fix attempts were tried and abandoned before the investigation
  /// that settled this issue (3x reruns each unless noted):**
  /// 1. Dismiss `bindingSheetPresented` on any `bindingState` transition
  ///    into `.none` (driven from `ScanFlowView`'s own `.onChange`, still
  ///    present in `ScanFlowView.swift` today) — insufficient alone.
  /// 2. Add sequencing: Close dismisses the sheet first and defers
  ///    `finishScan()` to the sheet's `onDismiss`; presentation itself
  ///    chained to `RecordingView`'s entrance-ceremony finishing rather
  ///    than directly to `bindingState` (both still present in
  ///    `ScanFlowView.swift`/`SensingCoordinator.swift`/`RecordingView.swift`
  ///    today) — still insufficient, identical failure signature.
  /// 3. Restructure `EventBindingSheetView`'s presentation to be a sibling
  ///    of `ScanFlowView`'s `.fullScreenCover` (owned by `AppCoordinator`,
  ///    presented from `RootView`) instead of nested inside it — this
  ///    doesn't fail the *race*, it fails *completely*: SwiftUI does not
  ///    support two simultaneously-active `.sheet`/`.fullScreenCover`
  ///    modifiers anchored to the same view when both need to be visible at
  ///    once (well-documented SwiftUI limitation, confirmed empirically —
  ///    the sheet silently never presented at all). Reverted; not present
  ///    in the current code.
  /// 4. Swap the binding sheet's presentation container from `.sheet` to
  ///    `.fullScreenCover` — failed identically to attempts 1-2 (the same
  ///    byte-identical 3/3 failure signature), because the underlying tap
  ///    is a no-op regardless of container type, not a container-specific
  ///    presentation conflict. Reverted; not present in the current code,
  ///    which ships `.sheet` as-is.
  ///
  /// What the investigation that followed attempt 4 actually established,
  /// as settled fact rather than an open question: the raced `Close` tap
  /// lands on a not-yet-hittable element (`Close.isHittable == false` at
  /// the moment the tap lands) and is therefore a no-op — not a UIKit
  /// presentation deadlock. Nothing wedges at the UIKit level: a
  /// ~68k-line console capture across 3 runs showed zero
  /// presentation-conflict warnings. Recovery is deterministic in exactly
  /// two further, real, reachable taps: `Cancel` dismisses the binding
  /// sheet onto a live `RecordingView` (confirmed by
  /// `"Simulate Signal Lost"` being present — the same identifier
  /// `BeidIPadLayoutTests.swift` already uses to detect being on that
  /// screen), then `Close` reaches Collection Home (`"Sense Event"`
  /// hittable). Ruling: beid#224 is not a defect. The auto-present binding
  /// sheet ships as-is, on `.sheet` — no chrome change, no fallback, no
  /// fifth structural fix. This test's job is to protect that recovery
  /// invariant going forward, not to chase a lockup that doesn't exist.
  func testMistimedCloseTapDuringBindingSheetPresentationRecoversViaCancelThenClose() {
    launchAndReachSenseEventScreen()

    app.buttons["Sense Event"].tap()

    let cancelButton = app.buttons["Cancel"]
    XCTAssertTrue(cancelButton.waitForExistence(timeout: 15))

    let closeButton = app.buttons["Close"]
    print(
      "PRE-TAP: Close.isHittable=\(closeButton.isHittable) Cancel.isHittable=\(cancelButton.isHittable)"
    )

    // Deliberately no wait here — tapping Close in the same tight cadence
    // XCUITest naturally uses between an existence check and the next
    // action is exactly the timing that reproduces the race; inserting a
    // delay here would defeat the point of this test.
    closeButton.tap()

    // The raced tap is a no-op, not damage: it must not tear down or
    // otherwise disturb the binding sheet that's still mid-presentation.
    XCTAssertTrue(
      cancelButton.exists,
      "A mistimed Close tap should be a no-op (Close not yet hittable), leaving the binding sheet's Cancel button present"
    )

    cancelButton.tap()

    XCTAssertFalse(cancelButton.exists, "Cancel should dismiss the binding sheet")
    XCTAssertTrue(
      app.buttons["Simulate Signal Lost"].waitForExistence(timeout: 5),
      "Cancel must land the user on a live RecordingView, not a dead screen"
    )

    closeButton.tap()

    let closeGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: closeButton)
    let cancelStillGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: cancelButton)
    let senseEventHittable = expectation(
      for: NSPredicate(format: "isHittable == true"),
      evaluatedWith: app.buttons["Sense Event"]
    )
    wait(for: [closeGone, cancelStillGone, senseEventHittable], timeout: 8)

    XCTAssertFalse(closeButton.exists, "Close should dismiss the scan flow")
    XCTAssertFalse(cancelButton.exists, "Binding sheet must not remain presented")
    XCTAssertTrue(
      app.buttons["Sense Event"].isHittable,
      "The second real Close tap must reach Collection Home"
    )
  }

  private func launchAndReachSenseEventScreen() {
    // `-beid-threshold-override 1` collapses the demo sequence's
    // `.sensing -> .recording` transition into a single step (see
    // `SensingCoordinator.runDemoSequence`'s own doc comment on device #1),
    // so `.recording` — and therefore the fresh `.none -> .pendingConnect`
    // transition these tests exercise — is reached in one
    // `demoStepDelayNanos` wait instead of needing three scripted devices.
    app.launchArguments = ["-beid-ui-test", "-beid-threshold-override", "1"]
    app.launch()

    app.buttons["Get Started"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()
    XCTAssertTrue(app.buttons["Sense Event"].waitForExistence(timeout: 5))
  }
}
