// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import notify
import XCTest

/// Trait overrides and UIWindow geometry are separate stimuli. Neither is
/// evidence of a physical fold, a resized UIWindowScene, or BLE continuity.
final class AdaptiveContinuityUITests: XCTestCase {
  private let app = XCUIApplication()

  private struct Receipt: Decodable {
    let command: String
    let sizeClass: String
    let width: Double
    let height: Double
    let rootWidth: Double
    let sceneWidth: Double
    let sceneHeight: Double
    let owner: String
    let session: String
    let record: String
    let phase: String
    let elapsed: Double
    let observations: Int
    let starts: Int
    let stops: Int
    let finalizations: Int
    let savedRecord: String
  }

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  override func tearDownWithError() throws {
    _ = notify_post("org.levarac.beid.ui-test.adaptive.restore")
    app.terminate()
  }

  func testRecordingSurvivesTraitAndWindowChanges() throws {
    let initial = try startRecording()
    let displayedBefore = try displayedElapsedSeconds()
    try exerciseLayoutChanges(from: initial) {
      self.app.buttons["scan.stop-sensing"].assertHittable()
    }
    XCTAssertGreaterThan(try displayedElapsedSeconds(), displayedBefore,
                         "The rendered TimelineView must advance as well as the session clock")
    try stopExactlyOnce(initial)
  }

  func testStopConfirmationSurvivesTraitAndWindowChanges() throws {
    let initial = try startRecording()
    let displayedBefore = try displayedElapsedSeconds()
    app.buttons["scan.stop-sensing"].tap()
    app.alerts["Stop sensing?"].assertExists()
    try exerciseLayoutChanges(from: initial) {
      self.app.alerts["Stop sensing?"].assertExists()
      self.app.alerts.buttons["Stop and keep record"].assertHittable()
    }
    app.alerts.buttons["Cancel"].tap()
    try assertContinuing(initial)
    XCTAssertGreaterThan(try displayedElapsedSeconds(), displayedBefore)
    try stopExactlyOnce(initial)
  }

  func testSheetPathAndRecordDetailSurviveTraitAndWindowChanges() throws {
    let initial = try startRecording()
    app.navigationBars.buttons.firstMatch.tap()
    app.buttons["home.account"].assertHittable()
    app.buttons["home.account"].tap()
    app.buttons["account.aboutSensing"].assertHittable()
    app.buttons["account.aboutSensing"].tap()
    try exerciseLayoutChanges(from: initial) {
      self.app.navigationBars["About sensing"].assertExists()
    }
    app.navigationBars["About sensing"].buttons.firstMatch.tap()
    app.buttons["Done"].assertHittable()
    app.buttons["Done"].tap()
    app.tabButton("Records").assertHittable()
    app.tabButton("Records").tap()
    let card = app.buttons["records.record.\(initial.record)"]
    card.assertHittable()
    card.tap()
    app.scrollViews["proof.detail.content"].assertExists()
    try exerciseLayoutChanges(from: initial) {
      self.app.scrollViews["proof.detail.content"].assertExists()
      self.app.staticTexts["Record ID \(initial.record)"].assertExists()
    }
    let recordID = app.staticTexts["Record ID \(initial.record)"]
    for _ in 0..<8 {
      if recordID.exists && recordID.isHittable { break }
      app.scrollViews["proof.detail.content"].swipeUp()
    }
    recordID.assertHittable()
    XCTAssertEqual(recordID.label, "Record ID \(initial.record)")
    app.navigationBars.buttons.firstMatch.tap()
    app.tabButton("Now").tap()
    app.buttons["home.open-details"].assertHittable()
    app.buttons["home.open-details"].tap()
    try stopExactlyOnce(initial)
  }

  func testSystemWindowResizeKeepsRecordingWhereSupported() throws {
    let initial = try startRecording()
    guard initial.width >= 600 else {
      try stopExactlyOnce(initial)
      throw XCTSkip("System window resizing requires a wide starting window")
    }
    let window = app.windows.firstMatch
    window.assertExists()
    // iPad windowing exposes a bottom-trailing resize affordance. Attempt a
    // system gesture, independently of our UIWindow-frame test hook above.
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.995))
      .press(forDuration: 0.5, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.75)))
    if app.state != .runningForeground { app.activate() }
    let resized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      guard let current = try? self.readReceipt() else { return false }
      return abs(current.sceneWidth - initial.sceneWidth) > 10 || abs(current.sceneHeight - initial.sceneHeight) > 10
    }, object: nil)
    let outcome = XCTWaiter.wait(for: [resized], timeout: 8)
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "system-window-resize-attempt"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    let geometry = XCTAttachment(string: try receiptText())
    geometry.name = "system-window-resize-geometry"
    geometry.lifetime = .keepAlways
    add(geometry)
    try assertContinuing(initial)
    try stopExactlyOnce(initial)
    guard outcome == .completed else {
      throw XCTSkip("The system resize gesture did not change UIWindowScene geometry on this simulator")
    }
  }

  private func startRecording() throws -> Receipt {
    app.launchArguments = ["-beid-ui-test", "-beid-adaptive-continuity", "-beid.sensing.firstTimeHintShown", "NO"]
    app.launch()
    app.buttons["Continue"].assertHittable()
    app.buttons["Continue"].tap()
    app.buttons["bluetooth.permission.continue"].assertHittable()
    app.buttons["bluetooth.permission.continue"].tap()
    app.buttons["home.demo.join"].assertHittable()
    app.buttons["home.demo.join"].tap()
    try waitForReceipt { $0.phase == "recording" && !$0.record.isEmpty && $0.observations > 0 }
    let receipt = try readReceipt()
    XCTAssertNotNil(UUID(uuidString: receipt.owner))
    XCTAssertNotNil(UUID(uuidString: receipt.session))
    XCTAssertNotNil(UUID(uuidString: receipt.record))
    XCTAssertEqual(receipt.starts, 1)
    XCTAssertEqual(receipt.stops, 0)
    XCTAssertEqual(receipt.finalizations, 0)
    return receipt
  }

  private func exerciseLayoutChanges(from initial: Receipt, checkPresentation: () -> Void) throws {
    for command in ["compact", "regular", "narrow", "full", "compact", "restore"] {
      let before = try readReceipt()
      XCTAssertEqual(notify_post("org.levarac.beid.ui-test.adaptive.\(command)"), 0)
      try waitForReceipt {
        guard $0.command == command else { return false }
        if command == "compact" || command == "regular" { return $0.sizeClass == command }
        if command == "restore" { return $0.sizeClass == initial.sizeClass && abs($0.width - initial.width) < 1 }
        return abs($0.rootWidth - $0.width) < 1
      }
      let after = try readReceipt()
      switch command {
      case "compact", "regular":
        XCTAssertEqual(after.sizeClass, command)
        XCTAssertEqual(after.width, before.width, accuracy: 1)
      case "narrow":
        XCTAssertLessThan(after.width, before.width - 10)
        XCTAssertEqual(after.rootWidth, after.width, accuracy: 1)
      case "full":
        XCTAssertGreaterThan(after.width, before.width + 10)
      case "restore":
        XCTAssertEqual(after.sizeClass, initial.sizeClass)
        XCTAssertEqual(after.width, initial.width, accuracy: 1)
      default: break
      }
      checkPresentation()
      try assertContinuing(initial, advancingFrom: before)
      let attachment = XCTAttachment(string: try receiptText())
      attachment.name = "adaptive-\(command)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  private func assertContinuing(_ initial: Receipt, advancingFrom previous: Receipt? = nil) throws {
    let previous = previous ?? initial
    try waitForReceipt { $0.elapsed > previous.elapsed && $0.observations > previous.observations }
    let current = try readReceipt()
    XCTAssertEqual(current.owner, initial.owner, "Resizing must retain the session's coordinator")
    XCTAssertEqual(current.session, initial.session)
    XCTAssertEqual(current.record, initial.record)
    XCTAssertEqual(current.phase, "recording")
    XCTAssertEqual(current.starts, initial.starts)
    XCTAssertEqual(current.stops, initial.stops)
    XCTAssertEqual(current.finalizations, initial.finalizations)
  }

  private func stopExactlyOnce(_ initial: Receipt) throws {
    app.buttons["scan.stop-sensing"].assertHittable()
    app.buttons["scan.stop-sensing"].tap()
    app.alerts.buttons["Stop and keep record"].assertHittable()
    app.alerts.buttons["Stop and keep record"].tap()
    try waitForReceipt { $0.finalizations == 1 && $0.stops == 1 }
    let stopped = try readReceipt()
    XCTAssertEqual(stopped.owner, initial.owner)
    XCTAssertEqual(stopped.starts, 1)
    XCTAssertEqual(stopped.savedRecord, initial.record)
    app.buttons["Done"].assertHittable()
    app.buttons["Done"].tap()
    app.buttons["View records"].assertHittable()
    app.buttons["View records"].tap()
    let saved = try readReceipt()
    XCTAssertEqual(saved.starts, 1)
    XCTAssertEqual(saved.stops, 1)
    XCTAssertEqual(saved.finalizations, 1)
    XCTAssertEqual(saved.savedRecord, initial.record)
  }

  private func receiptText() throws -> String {
    let element = app.staticTexts["adaptive.receipt"]
    return try XCTUnwrap(element.value as? String)
  }

  private func displayedElapsedSeconds() throws -> Int {
    let clock = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+:[0-9]{2}$")).firstMatch
    clock.assertExists()
    let parts = clock.label.split(separator: ":")
    XCTAssertEqual(parts.count, 2)
    let minutes = try XCTUnwrap(parts.first.flatMap { Int($0) })
    let seconds = try XCTUnwrap(parts.last.flatMap { Int($0) })
    return minutes * 60 + seconds
  }

  private func readReceipt() throws -> Receipt {
    try JSONDecoder().decode(Receipt.self, from: Data(receiptText().utf8))
  }

  private func waitForReceipt(_ condition: @escaping (Receipt) -> Bool) throws {
    app.staticTexts["adaptive.receipt"].assertExists()
    var lastReceipt = "No receipt read"
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      do {
        lastReceipt = try self.receiptText()
        return condition(try JSONDecoder().decode(Receipt.self, from: Data(lastReceipt.utf8)))
      } catch {
        lastReceipt = String(describing: error)
        return false
      }
    }, object: nil)
    let outcome = XCTWaiter.wait(for: [expectation], timeout: UITestWait.timeout)
    if outcome != .completed {
      let receipt = XCTAttachment(string: lastReceipt)
      receipt.name = "adaptive-wait-failure-receipt"
      receipt.lifetime = .keepAlways
      add(receipt)
      let hierarchy = XCTAttachment(string: app.debugDescription)
      hierarchy.name = "adaptive-wait-failure-hierarchy"
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
    }
    XCTAssertEqual(outcome, .completed, lastReceipt)
  }
}
