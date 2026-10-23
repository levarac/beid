// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest

enum UITestWait {
  // Navigation and accessibility snapshots can take more than five seconds
  // on the hosted macos-26 runner. Conditions still finish immediately.
  static let timeout: TimeInterval = 30
}

extension XCUIElement {
  func assertExists(file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(
      waitForExistence(timeout: UITestWait.timeout),
      "Element did not appear within \(UITestWait.timeout)s: \(identifier); \(self)",
      file: file, line: line
    )
  }

  func assertHittable(file: StaticString = #filePath, line: UInt = #line) {
    let visible = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in self.exists && self.isHittable }, object: nil
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [visible], timeout: UITestWait.timeout), .completed,
      "Element did not become hittable within \(UITestWait.timeout)s: \(identifier); " +
        "exists=\(exists), hittable=\(isHittable); \(self)",
      file: file, line: line
    )
  }

  func assertDisappears(file: StaticString = #filePath, line: UInt = #line) {
    let absent = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in !self.exists }, object: nil
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [absent], timeout: UITestWait.timeout), .completed,
      "Element remained present after \(UITestWait.timeout)s: \(identifier); \(self)",
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
