// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
import UIKit

enum UITestWait {
  // Navigation and accessibility snapshots can take more than five seconds
  // on the hosted iOS runner. Conditions still finish immediately.
  static let timeout: TimeInterval = 30
}

/// Layout limits known before the app launches (beid#878). A test whose
/// coverage needs a window this device can never give the app skips before
/// `launch()`, so a skipped case never launches or terminates the app. Each
/// limit only rules out geometry the app window cannot reach, so it never
/// skips a case the post-launch guard would run; those guards stay in place.
enum UITestLayoutLimits {
  /// `ios/project.yml` declares landscape only under
  /// `UISupportedInterfaceOrientations~ipad`. The runner is built for both
  /// device families, so its idiom is the device's own.
  static var appCanBecomeWiderThanTall: Bool {
    UIDevice.current.userInterfaceIdiom == .pad
  }

  /// The widest window the app can have here, or nil when no limit is known.
  /// A portrait-only app is no wider than the screen's portrait width. The
  /// screen comes from the runner's own scene, so no other app is queried;
  /// without exactly one screen the post-launch check alone decides.
  static var maximumAppWindowWidth: CGFloat? {
    guard !appCanBecomeWiderThanTall else { return nil }
    let screens = Set(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen })
    guard screens.count == 1, let bounds = screens.first?.bounds, !bounds.isEmpty else { return nil }
    return min(bounds.width, bounds.height)
  }

  /// True only when a known limit rules the width out; unknown means launch.
  static func appWindowCannotReach(width: CGFloat) -> Bool {
    guard let limit = maximumAppWindowWidth else { return false }
    return limit < width
  }
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

      scrollView.drag(in: visible, scrollFrame: scrollFrame, upward: false)
      drags += 1
    }
    assertHittable(
      file: file, line: line,
      failureContext: "\nScroll gestures: swipes=\(swipes) drags=\(drags) " +
        "lastFrame=\(exists ? String(describing: frame) : "<absent>")"
    )
  }

  /// Scroll an existing target into a specific screen's usable content area.
  /// Check its full frame as well as the accessibility hit test.
  func scrollToHittable(
    in app: XCUIApplication, within scrollView: XCUIElement,
    ignoringBackgroundTabBar: Bool = false,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    scrollView.assertExists(file: file, line: line)
    assertExists(file: file, line: line)

    var drags = 0
    for _ in 0..<5 {
      let scrollFrame = scrollView.frame
      let visible = app.visibleScrollFrame(for: scrollFrame, ignoringBackgroundTabBar: ignoringBackgroundTabBar)
      let target = frame
      guard !visible.isEmpty, !target.isEmpty, !visible.contains(target) else { break }
      scrollView.drag(in: visible, scrollFrame: scrollFrame, upward: target.minY >= visible.minY)
      drags += 1
    }

    let (state, passed, target) = waitForState {
      $0 && scrollView.exists && app.visibleScrollFrame(
        for: scrollView.frame, ignoringBackgroundTabBar: ignoringBackgroundTabBar
      ).contains(self.frame) && self.isHittable
    }
    XCTAssertTrue(
      passed,
      "Element did not become hittable inside the scroll viewport within \(UITestWait.timeout)s; " +
        "exists=\(state.exists), drags=\(drags), lastFrame=\(exists ? String(describing: frame) : "<absent>")\n\(target)",
      file: file, line: line
    )
  }

  private func drag(in visible: CGRect, scrollFrame: CGRect, upward: Bool) {
    let center = coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
      dx: visible.midX - scrollFrame.minX, dy: visible.midY - scrollFrame.minY
    ))
    let offset = visible.height * (upward ? 0.25 : -0.25)
    let start = center.withOffset(CGVector(dx: 0, dy: offset))
    let end = center.withOffset(CGVector(dx: 0, dy: -offset))
    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
  }
}

extension XCUIApplication {
  func visibleScrollFrame(for scrollFrame: CGRect, ignoringBackgroundTabBar: Bool = false) -> CGRect {
    let window = windows.firstMatch
    let viewport = scrollFrame.intersection(window.frame)
    guard !viewport.isEmpty else { return .null }
    let navigationBar = window.navigationBars.firstMatch
    let tabBar = window.tabBars.firstMatch
    let navigationFrame = navigationBar.exists ? navigationBar.frame : .null
    // The presenting screen can keep its tab bar in the accessibility tree behind a sheet.
    let tabFrame = !ignoringBackgroundTabBar && tabBar.exists ? tabBar.frame : .null

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
  func launchControlledDemo(extraArguments: [String] = []) {
    launchArguments = ["-beid-ui-test", "-beid-controlled-demo"] + extraArguments
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
    // UIKit can place tabs outside a tab bar in a wide window on any device.
    let tab = tabBars.buttons[label]
    if tab.exists { return tab }
    return buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
  }

  /// UIKit delivers the regular horizontal size class to a window roughly
  /// from 680 points up (iPad full screen and large splits; not iPhone
  /// portrait). The XCUI window frame is the app's observable geometry; the
  /// runner process's own traits are not the app's.
  var hasRegularWidthLayout: Bool {
    let window = windows.firstMatch
    window.assertExists()
    return window.frame.width >= 680
  }

  func openRecordsByEvent() {
    let recordsTab = tabButton("Records")
    recordsTab.assertHittable()
    recordsTab.tap()
    if scrollViews["records.events"].exists { return }
    selectRecordsGrouping("By event")
    scrollViews["records.events"].assertExists()
  }

  func selectRecordsGrouping(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
    let options = navigationBars.buttons["records.grouping"]
    options.assertHittable(file: file, line: line)
    options.tap()
    // Native Picker menu items omit identifiers, so use the English UI-test label.
    let item = buttons[label]
    item.assertHittable(file: file, line: line)
    item.tap()
    item.assertDisappears(file: file, line: line)
  }
}
