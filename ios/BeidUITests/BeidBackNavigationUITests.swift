// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest

/// UI coverage for the interactive pop gesture in `NavigationStack`
/// (beid#631, DESIGN.md §12).
///
/// The decision keeps the standard back button and its swipe gesture across
/// all 18 screens. These tests pin that gesture on the real navigation stack:
/// leading-edge swipes pop Proof Detail through Event Detail to Collection,
/// while a swipe on the Collection root leaves navigation intact.
final class BeidBackNavigationUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  /// A Proof pushed from Event Detail pops through both standard stack levels.
  func testLeadingEdgeSwipePopsProofDetailBackToCollection() {
    navigateToCollectionWithProof()
    openFirstProof()

    let detailHeading = app.staticTexts["proof.detail.title"]
    let backButton = app.navigationBars["ETHGlobal Tokyo"].buttons.firstMatch
    let collection = app.collectionViews["records.events"]
    let eventHeading = app.staticTexts["event-detail.heading"]
    // The screen this push covered is Event Detail, not the event list. The
    // push has finished only once Event Detail has left the hierarchy, and
    // the edge recognizer does not begin while a transition is running.
    swipeFromLeadingEdge {
      detailHeading.exists && detailHeading.isHittable
        && backButton.exists && backButton.isHittable
        && !eventHeading.exists
    }

    XCTAssertTrue(eventHeading.waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["proof.detail.title"].exists)
    let eventBack = app.navigationBars.buttons["By event"]
    swipeFromLeadingEdge {
      eventHeading.exists && eventHeading.isHittable
        && eventBack.exists && eventBack.isHittable
        && (!collection.exists || !collection.isHittable)
    }

    XCTAssertTrue(
      app.collectionViews["records.events"].waitForExistence(timeout: 5),
      "the second leading-edge swipe did not return to the event list"
    )
    let byEventNavigation = app.navigationBars["By event"]
    let byEventHeading = byEventNavigation.staticTexts["By event"]
    let byEventBack = byEventNavigation.buttons["Back"]
    swipeFromLeadingEdge {
      byEventHeading.exists && byEventHeading.isHittable
        && byEventBack.exists && byEventBack.isHittable
        && (!eventHeading.exists || !eventHeading.isHittable)
    }
    XCTAssertTrue(app.scrollViews["records.grid"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["proof.detail.title"].exists)
  }

  /// A leading-edge drag on Collection leaves the current standard
  /// navigation stack alive and on Collection.
  func testLeadingEdgeSwipeOnTheRootScreenIsHarmless() {
    navigateToCollectionWithProof()

    let grid = app.scrollViews["records.grid"]
    swipeFromLeadingEdge {
      grid.exists
    }

    XCTAssertEqual(app.state, .runningForeground, "the app did not survive a swipe on the root screen")
    XCTAssertTrue(app.scrollViews["records.grid"].waitForExistence(timeout: 5))
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
  private func swipeFromLeadingEdge(when isReady: @escaping () -> Bool) {
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 5))

    // Hittability is a UI-readiness proxy, not UIKit transition completion.
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in isReady() }, object: nil
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [ready], timeout: 5), .completed,
      "The current screen must be ready before each leading-edge swipe"
    )

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

  /// Joins the demonstration event and waits for live recording controls.
  private func reachRecordingScreen() {
    app.launchArguments = ["-beid-ui-test"]
    app.launch()

    app.buttons["Continue"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()

    let senseEvent = app.buttons["home.demo.join"]
    XCTAssertTrue(senseEvent.waitForExistence(timeout: 5))
    senseEvent.tap()
    XCTAssertTrue(app.descendants(matching: .any)["scan.sensing"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.staticTexts["scan.event-found"].waitForExistence(timeout: 30))

    XCTAssertTrue(app.buttons["Simulate Signal Lost"].waitForExistence(timeout: 30))
    dismissBindingSheetToReachLiveRecording()
  }

  private func dismissBindingSheetToReachLiveRecording() {
    XCTAssertFalse(app.buttons["Cancel"].exists, "Recording must not present a wallet sheet")
    XCTAssertTrue(app.buttons["Simulate Signal Lost"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["scan.stop-sensing"].isHittable)
  }

  /// Ends that session, landing on Collection with the resulting proof.
  private func navigateToCollectionWithProof() {
    reachRecordingScreen()
    app.buttons["scan.stop-sensing"].tap()
    XCTAssertTrue(app.staticTexts["Stop sensing?"].waitForExistence(timeout: 5))
    app.buttons["Stop and keep record"].tap()
    XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
    app.buttons["Done"].tap()
    XCTAssertTrue(app.buttons["View records"].waitForExistence(timeout: 5))
    app.buttons["View records"].tap()

    XCTAssertTrue(app.scrollViews["records.grid"].waitForExistence(timeout: 5))
  }

  /// Pushes Proof Detail for the DemoEvent proof left on Collection.
  private func openFirstProof() {
    app.openRecordsByEvent()
    app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ETHGlobal Tokyo")).firstMatch.tap()
    XCTAssertTrue(app.staticTexts["event-detail.heading"].waitForExistence(timeout: 5))
    app.buttons["event-detail.proof.1"].tap()
    XCTAssertTrue(app.staticTexts["proof.detail.title"].waitForExistence(timeout: 5))
  }
}
