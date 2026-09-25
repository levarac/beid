// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest

/// UI coverage for the interactive pop gesture in `NavigationStack`
/// (beid#631, DESIGN.md §12).
///
/// The decision keeps the standard back button and its swipe gesture across
/// all 18 screens. These tests pin that gesture on the real navigation stack:
/// a leading-edge swipe pops Proof Detail to Collection, while a swipe on the
/// Collection root leaves navigation intact.
final class BeidBackNavigationUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  /// With the standard back button, a leading-edge drag pops Proof Detail
  /// back to Collection.
  func testLeadingEdgeSwipePopsProofDetailBackToCollection() {
    navigateToCollectionWithProof()
    openFirstProof()

    swipeFromLeadingEdge()

    let senseEvent = app.buttons["Sense Event"]
    XCTAssertTrue(
      senseEvent.waitForExistence(timeout: 5),
      "the leading-edge swipe did not pop Proof Detail back to Collection"
    )
    XCTAssertFalse(app.staticTexts["proof.detail.title"].exists)
  }

  /// A leading-edge drag on Collection leaves the current standard
  /// navigation stack alive and on Collection.
  func testLeadingEdgeSwipeOnTheRootScreenIsHarmless() {
    navigateToCollectionWithProof()

    swipeFromLeadingEdge()

    XCTAssertEqual(app.state, .runningForeground, "the app did not survive a swipe on the root screen")
    XCTAssertTrue(app.buttons["Sense Event"].waitForExistence(timeout: 5))
  }

  // MARK: - Gesture

  /// A screen-edge pan, which is the only gesture
  /// `interactivePopGestureRecognizer` responds to.
  ///
  /// `XCUIElement.swipeRight()` is a different gesture: it starts in the
  /// middle of an element, so it drives scroll views and page controls and
  /// never reaches the edge recognizer. The drag therefore starts at
  /// normalized `dx: 0` — the window's leading edge under this app's `en`
  /// development language — with a near-zero press duration and a fast
  /// velocity, because a long press before the drag lets the recognizer fail
  /// before the pan begins.
  private func swipeFromLeadingEdge() {
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 5))

    let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
    let finish = window.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
    start.press(
      forDuration: 0.01,
      thenDragTo: finish,
      withVelocity: .fast,
      thenHoldForDuration: 0
    )
  }

  // MARK: - Navigation

  // The three helpers below mirror `BeidIPadLayoutTests`'
  // `reachRecordingScreen` / `navigateToCollectionWithProof` / `openFirstProof`
  // step for step. They are copied rather than shared because those are
  // `private` to that class; if the seeding route changes, both must change.

  /// Joins the DemoEvent event and waits until `.recording` begins.
  /// "Simulate Signal Lost" existing is the earliest reliable signal of that
  /// — see the comment on `BeidIPadLayoutTests.capturePrimaryFlow`.
  private func reachRecordingScreen() {
    app.launchArguments = ["-beid-ui-test"]
    app.launch()

    app.buttons["Get Started"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()

    let senseEvent = app.buttons["Sense Event"]
    XCTAssertTrue(senseEvent.waitForExistence(timeout: 5))
    senseEvent.tap()
    XCTAssertTrue(app.descendants(matching: .any)["scan.sensing"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.staticTexts["scan.event-found"].waitForExistence(timeout: 30))

    XCTAssertTrue(app.buttons["Simulate Signal Lost"].waitForExistence(timeout: 30))
  }

  /// Ends that session, landing on Collection with the resulting proof.
  private func navigateToCollectionWithProof() {
    reachRecordingScreen()
    app.buttons["Close"].tap()
    XCTAssertTrue(app.staticTexts["Stop sensing?"].waitForExistence(timeout: 5))
    app.buttons["Stop and keep record"].tap()
    XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
    app.buttons["Done"].tap()
    XCTAssertTrue(app.buttons["View collection"].waitForExistence(timeout: 5))
    app.buttons["View collection"].tap()

    XCTAssertTrue(app.buttons["Sense Event"].waitForExistence(timeout: 5))
  }

  /// Pushes Proof Detail for the DemoEvent proof left on Collection.
  private func openFirstProof() {
    app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ETHGlobal Tokyo")).firstMatch.tap()
    XCTAssertTrue(app.staticTexts["proof.detail.title"].waitForExistence(timeout: 5))
  }
}
