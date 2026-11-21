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
    let state = waitForState { $0 && isHittable }
    XCTAssertTrue(
      state.satisfied,
      "Element did not become hittable within \(UITestWait.timeout)s; " +
        "exists=\(state.exists), hittable=\(state.satisfied)",
      file: file, line: line
    )
  }

  func assertDisappears(file: StaticString = #filePath, line: UInt = #line) {
    let state = waitForState { !$0 }
    XCTAssertTrue(
      state.satisfied,
      "Element remained present after \(UITestWait.timeout)s; exists=\(state.exists)",
      file: file, line: line
    )
  }

  private func waitForState(_ condition: (Bool) -> Bool) -> (exists: Bool, satisfied: Bool) {
    func capture() -> (exists: Bool, satisfied: Bool) {
      let present = exists
      return (present, condition(present))
    }

    let deadline = ProcessInfo.processInfo.systemUptime + UITestWait.timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
      let state = capture()
      if state.satisfied { return state }
      let delay = min(0.25, deadline - ProcessInfo.processInfo.systemUptime)
      if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    }
    return capture()
  }

  /// Wait for the destination's scroll view before querying or scrolling its
  /// children. Existence alone does not mean a row can safely be tapped.
  func scrollToHittable(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let scrollView = app.scrollViews.firstMatch
    scrollView.assertHittable(file: file, line: line)
    for _ in 0..<8 {
      let targetExists = exists
      if targetExists && isHittable { return }
      let scrollFrame = scrollView.frame
      let visible = app.visibleScrollFrame(for: scrollFrame)
      guard !visible.isEmpty else { break }

      let target = targetExists ? frame : .null
      // Continue toward later rows when a lazy container has not created the target.
      let targetAbove = !target.isEmpty && target.midY.isFinite && target.midY < visible.midY
      let quarter = visible.height * 0.25
      let dragOffset = targetAbove ? -quarter : quarter
      let center = scrollView.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
        dx: visible.midX - scrollFrame.minX, dy: visible.midY - scrollFrame.minY
      ))
      let start = center.withOffset(CGVector(dx: 0, dy: dragOffset))
      let end = center.withOffset(CGVector(dx: 0, dy: -dragOffset))
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    assertHittable(file: file, line: line)
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
