// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
import UIKit

enum UITestWait {
  // Navigation and accessibility snapshots can take more than five seconds
  // on the hosted macos-26 runner. Conditions still finish immediately.
  static let timeout: TimeInterval = 30
}

enum ControlledDemoPhase: String {
  case sensing, eventFound, recording
}

extension XCUIElement {
  func assertExists(file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(
      waitForExistence(timeout: UITestWait.timeout),
      "Element did not appear within \(UITestWait.timeout)s: \(exists ? identifier : "<absent>")",
      file: file, line: line
    )
  }

  func assertHittable(file: StaticString = #filePath, line: UInt = #line) {
    let visible = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in self.exists && self.isHittable }, object: nil
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [visible], timeout: UITestWait.timeout), .completed,
      "Element did not become hittable within \(UITestWait.timeout)s: \(exists ? identifier : "<absent>"); " +
        "exists=\(exists), hittable=\(exists && isHittable)",
      file: file, line: line
    )
  }

  func assertDisappears(file: StaticString = #filePath, line: UInt = #line) {
    let absent = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in !self.exists }, object: nil
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [absent], timeout: UITestWait.timeout), .completed,
      "Element remained present after \(UITestWait.timeout)s: \(exists ? identifier : "<absent>")",
      file: file, line: line
    )
  }

  /// Wait for the destination's scroll view before querying or scrolling its
  /// children. Existence alone does not mean a row can safely be tapped.
  func scrollToHittable(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let scrollView = app.scrollViews.firstMatch
    scrollView.assertHittable(file: file, line: line)
    for _ in 0..<5 {
      if exists && isHittable { break }
      scrollView.swipeUp()
    }
    assertHittable(file: file, line: line)
  }
}

extension XCUIApplication {
  /// Exercise the native interactive-pop recognizer on either idiom.
  /// A middle-of-screen swipe drives scrolling instead of navigation.
  func swipeFromLeadingEdge() {
    let window = windows.firstMatch
    window.assertExists()
    let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
    let finish = window.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
    start.press(forDuration: 0.01, thenDragTo: finish, withVelocity: .fast, thenHoldForDuration: 0)
  }

  /// Opt-in only: other UI tests keep the established timed demo behavior.
  func launchControlledDemo() {
    launchArguments = ["-beid-ui-test", "-beid-controlled-demo"]
    launch()
  }

  /// Consume one receipt at a time, waiting for the actual interpreter to
  /// reach its next pause. The golden scenario has four pause boundaries.
  /// No target phase is assigned by the test or by the fixture control.
  func advanceDemo(
    to phase: ControlledDemoPhase, file: StaticString = #filePath, line: UInt = #line
  ) {
    for _ in 0..<4 {
      let input = buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "demo.advance.")).firstMatch
      input.assertHittable(file: file, line: line)
      if input.value as? String == phase.rawValue { return }
      let receipt = input.identifier
      input.tap()
      buttons[receipt].assertDisappears(file: file, line: line)
    }
    XCTFail("The golden demo did not hold \(phase.rawValue) at a pause boundary", file: file, line: line)
  }

  func tabButton(_ label: String) -> XCUIElement {
    if UIDevice.current.userInterfaceIdiom == .pad {
      return buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
    return tabBars.buttons[label]
  }

  func openRecordsByEvent() {
    let recordsTab = tabButton("Records")
    recordsTab.assertHittable()
    recordsTab.tap()
    if collectionViews["records.events"].exists { return }
    let byEvent = buttons["records.by-event"]
    byEvent.assertHittable()
    byEvent.tap()
    collectionViews["records.events"].assertExists()
  }
}
