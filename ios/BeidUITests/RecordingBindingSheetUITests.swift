// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import UIKit
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
/// binding sheet begins animating in must not strand the user. **Its
/// recovery path is device-class dependent (beid#245)** — see that test's
/// own doc comment. On iPhone, the tap is a true no-op (the page sheet
/// covers the button) and recovery takes two further, real taps: `Cancel`
/// then `Close`. On iPad, the same tap lands on the form sheet's visible
/// backdrop and genuinely dismisses the binding sheet, recovering in one
/// fewer tap. Both device classes converge on the same end state —
/// Collection Home, deterministically reachable — by different real paths.
final class RecordingBindingSheetUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testBindingSheetAutoPresentsOnRecordingAndDoesNotReopenAfterDismissal() {
    launchAndReachSenseEventScreen()

    app.buttons["home.scan"].tap()

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
  /// screen), then `Close` reaches Collection Home (`home.scan`
  /// hittable). Ruling: beid#224 is not a defect. The auto-present binding
  /// sheet ships as-is, on `.sheet` — no chrome change, no fallback, no
  /// fifth structural fix. This test's job is to protect that recovery
  /// invariant going forward, not to chase a lockup that doesn't exist.
  ///
  /// **beid#245 — this test's claim depends on device class.** The
  /// investigation above was run on iPhone, where `.sheet` presents as a
  /// page sheet covering nearly the full screen: the toolbar `Close`
  /// button underneath is genuinely covered, so the raced tap lands on
  /// nothing and is a true no-op. On iPad, `.sheet` instead presents as a
  /// centered form sheet with a wide dimmed backdrop visible around it;
  /// `Close`'s on-screen coordinate falls on that backdrop, and UIKit's
  /// standard backdrop-tap-to-dismiss (no `.interactiveDismissDisabled` is
  /// set anywhere on this sheet) closes the binding sheet immediately —
  /// not a no-op, and not a defect either: the user is left on a live
  /// `RecordingView` in this single tap, recovering in *one* fewer real
  /// tap than the iPhone path needs. Neither path is broken; they are
  /// different, correct recoveries for different presentation styles, and
  /// this test asserts each one on the device class that actually produces
  /// it rather than asserting iPhone's shape everywhere and failing
  /// deterministically on iPad (which is exactly what this test did before
  /// this fix).
  func testMistimedCloseTapDuringBindingSheetPresentationRecoversViaCancelThenClose() {
    launchAndReachSenseEventScreen()

    app.buttons["home.scan"].tap()

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

    if UIDevice.current.userInterfaceIdiom == .pad {
      // See this method's doc comment (beid#245): the raced tap lands on
      // the form sheet's backdrop and dismisses the binding sheet for
      // real, in this one tap.
      let cancelGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: cancelButton)
      wait(for: [cancelGone], timeout: 5)
      XCTAssertFalse(
        cancelButton.exists,
        "On iPad the mistimed tap lands on the form sheet's backdrop and should dismiss the binding sheet"
      )
      XCTAssertTrue(
        app.buttons["Simulate Signal Lost"].waitForExistence(timeout: 5),
        "The backdrop-dismissed sheet should reveal a live RecordingView, not a dead screen"
      )

      // The binding sheet is already gone, so this real tap reaches
      // ScanFlowView's own toolbar Close button directly — the same final
      // destination the iPhone branch below reaches in two taps instead.
      closeButton.tap()
    } else {
      // The raced tap is a no-op, not damage: it must not tear down or
      // otherwise disturb the binding sheet that's still mid-presentation.
      XCTAssertTrue(
        cancelButton.exists,
        "A mistimed Close tap should be a no-op on iPhone (Close not yet hittable), leaving the binding sheet's Cancel button present"
      )

      cancelButton.tap()

      XCTAssertFalse(cancelButton.exists, "Cancel should dismiss the binding sheet")
      XCTAssertTrue(
        app.buttons["Simulate Signal Lost"].waitForExistence(timeout: 5),
        "Cancel must land the user on a live RecordingView, not a dead screen"
      )

      closeButton.tap()
    }

    let closeGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: closeButton)
    let cancelStillGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: cancelButton)
    let senseEventHittable = expectation(
      for: NSPredicate(format: "isHittable == true"),
      evaluatedWith: app.buttons["home.scan"]
    )
    wait(for: [closeGone, cancelStillGone, senseEventHittable], timeout: 8)

    XCTAssertFalse(closeButton.exists, "Close should dismiss the scan flow")
    XCTAssertFalse(cancelButton.exists, "Binding sheet must not remain presented")
    XCTAssertTrue(
      app.buttons["home.scan"].isHittable,
      "The final real Close tap must reach Collection Home"
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
    XCTAssertTrue(app.buttons["home.scan"].waitForExistence(timeout: 5))
  }
}
