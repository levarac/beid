// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
import UIKit

enum UITestWait {
  // Navigation and accessibility snapshots can take more than five seconds
  // on the hosted iOS runner. Conditions still finish immediately.
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

  func assertHittable(
    file: StaticString = #filePath, line: UInt = #line, failureContext: @autoclosure () -> String = ""
  ) {
    let (state, passed, target) = waitForState { $0 && self.isHittable }
    XCTAssertTrue(
      passed,
      "Element did not become hittable within \(UITestWait.timeout)s; " +
        "exists=\(state.exists), hittable=\(state.satisfied)\(failureContext())\n\(target)",
      file: file, line: line
    )
  }

  func assertDisappears(file: StaticString = #filePath, line: UInt = #line) {
    let (state, passed, target) = waitForState { !$0 }
    XCTAssertTrue(
      passed,
      "Element remained present after \(UITestWait.timeout)s; exists=\(state.exists)\n\(target)",
      file: file, line: line
    )
  }

  private func waitForState(
    _ condition: @escaping (Bool) -> Bool
  ) -> (state: (exists: Bool, satisfied: Bool), passed: Bool, target: String) {
    func capture() -> (exists: Bool, satisfied: Bool) {
      let present = exists
      return (present, condition(present))
    }

    var state = (exists: false, satisfied: false)
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        state = capture()
        return state.satisfied
      },
      object: nil
    )
    let outcome = XCTWaiter.wait(for: [expectation], timeout: UITestWait.timeout)
    if outcome == .timedOut {
      state = capture()
    }
    let passed = state.satisfied && (outcome == .completed || outcome == .timedOut)
    // Preserve the last evaluation and read the query only for a failure.
    // Resolving identifier while views transition can fail on duplicate matches.
    let target = passed ? "" : String(debugDescription.suffix(2048))
    return (state, passed, target)
  }

  /// Wait for the destination's scroll view before querying or scrolling its
  /// children. Existence alone does not mean a row can safely be tapped.
  func scrollToHittable(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let scrollView = app.scrollViews.firstMatch
    scrollView.assertHittable(file: file, line: line)
    var swipes = 0
    for _ in 0..<5 {
      if exists && isHittable { break }
      scrollView.swipeUp()
      swipes += 1
    }

    // A swipe can leave an existing row above the visible scroll area.
    var drags = 0
    for _ in 0..<3 {
      guard exists, !isHittable else { break }
      let scrollFrame = scrollView.frame
      let visible = app.visibleScrollFrame(for: scrollFrame)
      let target = frame
      guard !visible.isEmpty, !target.isEmpty, target.maxY <= visible.minY else { break }

      let quarter = visible.height * 0.25
      let center = scrollView.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
        dx: visible.midX - scrollFrame.minX, dy: visible.midY - scrollFrame.minY
      ))
      let start = center.withOffset(CGVector(dx: 0, dy: -quarter))
      let end = center.withOffset(CGVector(dx: 0, dy: quarter))
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
      drags += 1
    }
    assertHittable(
      file: file, line: line,
      failureContext: "\nScroll gestures: swipes=\(swipes) drags=\(drags) " +
        "lastFrame=\(exists ? String(describing: frame) : "<absent>")"
    )
  }
}

extension XCUIApplication {
  fileprivate func visibleScrollFrame(for scrollFrame: CGRect) -> CGRect {
    let window = windows.firstMatch
    let viewport = scrollFrame.intersection(window.frame)
    guard !viewport.isEmpty else { return .null }
    let navigationBar = window.navigationBars.firstMatch
    let tabBar = window.tabBars.firstMatch
    let navigationFrame = navigationBar.exists ? navigationBar.frame : .null
    let tabFrame = tabBar.exists ? tabBar.frame : .null

    // Only bars on the corresponding edge can cover the central drag path.
    let top = navigationFrame.intersects(viewport) && navigationFrame.midY < viewport.midY &&
      navigationFrame.minX <= viewport.midX && navigationFrame.maxX >= viewport.midX
      ? max(viewport.minY, navigationFrame.maxY) : viewport.minY
    let bottom = tabFrame.intersects(viewport) && tabFrame.midY > viewport.midY &&
      tabFrame.minX <= viewport.midX && tabFrame.maxX >= viewport.midX
      ? min(viewport.maxY, tabFrame.minY) : viewport.maxY
    guard top < bottom else { return .null }
    return CGRect(x: viewport.minX, y: top, width: viewport.width, height: bottom - top)
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
    if scrollViews["records.events"].exists { return }
    let byEvent = buttons["By event"]
    byEvent.assertHittable()
    byEvent.tap()
    scrollViews["records.events"].assertExists()
  }
}
