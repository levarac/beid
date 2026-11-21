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
    let (state, passed, target) = waitForState { $0 && self.isHittable }
    XCTAssertTrue(
      passed,
      "Element did not become hittable within \(UITestWait.timeout)s; " +
        "exists=\(state.exists), hittable=\(state.satisfied)\n\(target)",
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
    let (scrollView, selection) = scrollViewForTarget(in: app)
    scrollView.assertHittable(file: file, line: line)
    XCTContext.runActivity(named: "Scroll view selection: \(selection), identifier=\(scrollView.identifier)") { _ in }
    for _ in 0..<8 {
      let targetExists = exists
      if targetExists && isHittable {
        XCTContext.runActivity(named: "Scroll step: target already hittable") { _ in }
        break
      }
      let scrollFrame = scrollView.frame
      let visible = app.visibleScrollFrame(for: scrollFrame)
      guard !visible.isEmpty, visible.width.isFinite, visible.height.isFinite, visible.height > 2 else {
        XCTContext.runActivity(named: "Scroll fallback: swipe up without a usable viewport") { _ in
          scrollView.swipeUp()
        }
        continue
      }

      let target = targetExists ? frame : .null
      let contentBefore = targetExists ? nil : scrollView.scrollContentPosition
      // Continue toward later rows when a lazy container has not created the target.
      let targetAbove = !target.isEmpty && target.midY.isFinite && target.midY < visible.midY
      let quarter = visible.height * 0.25
      let dragOffset = targetAbove ? -quarter : quarter
      let center = scrollView.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
        dx: visible.midX - scrollFrame.minX, dy: visible.midY - scrollFrame.minY
      ))
      let start = center.withOffset(CGVector(dx: 0, dy: dragOffset))
      let end = center.withOffset(CGVector(dx: 0, dy: -dragOffset))
      let direction = targetAbove ? "down" : "up"
      XCTContext.runActivity(named: "Scroll step: drag \(direction)") { _ in
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
      }

      let targetExistsAfterDrag = exists
      if targetExistsAfterDrag && isHittable { break }
      guard targetExists == targetExistsAfterDrag else { continue }
      let stalled = targetExists
        ? abs(frame.minY - target.minY) <= 1
        : scrollView.scrollContentStayedAt(contentBefore)
      guard stalled else { continue }
      XCTContext.runActivity(named: "Scroll fallback: swipe \(direction) after stalled drag") { _ in
        if targetAbove {
          scrollView.swipeDown()
        } else {
          scrollView.swipeUp()
        }
      }
    }
    assertHittable(file: file, line: line)
  }

  private func scrollViewForTarget(in app: XCUIApplication) -> (XCUIElement, String) {
    let scrollViews = app.scrollViews
    let candidates = scrollViews.allElementsBoundByIndex
    guard candidates.count > 1, exists, let target = try? snapshot() else {
      return (scrollViews.firstMatch, "first match")
    }

    // An offscreen target can still be a descendant of the correct scroll view.
    if !target.identifier.isEmpty {
      let containing = scrollViews.containing(target.elementType, identifier: target.identifier).allElementsBoundByIndex
      if containing.count == 1 {
        return (containing[0], "target descendant")
      }
      if !target.frame.isEmpty, let owner = containing.first(where: { $0.frame.contains(target.frame) }) {
        return (owner, "target descendant and frame")
      }
    }
    if !target.frame.isEmpty, let owner = candidates.first(where: { $0.frame.contains(target.frame) }) {
      return (owner, "target frame")
    }
    return (scrollViews.firstMatch, "first match")
  }

  // A lazy target can remain absent while content moves. Follow a descendant
  // because the scroll view's own frame does not move with its content.
  private var scrollContentPosition: (identifier: String, label: String, minY: CGFloat)? {
    let text = staticTexts.firstMatch
    let item = text.exists ? text : buttons.firstMatch
    guard item.exists else { return nil }
    let position = item.frame
    guard !position.isEmpty, position.minY.isFinite else { return nil }
    return (item.identifier, item.label, position.minY)
  }

  private func scrollContentStayedAt(_ before: (identifier: String, label: String, minY: CGFloat)?) -> Bool {
    let after = scrollContentPosition
    return before?.identifier == after?.identifier && before?.label == after?.label &&
      abs((before?.minY ?? 0) - (after?.minY ?? 0)) <= 1
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
