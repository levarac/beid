// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import CoreGraphics
import UIKit
import XCTest

/// Recording must remain available without a wallet presentation.
final class RecordingBindingSheetUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws { continueAfterFailure = false }

  func testFirstRecordingDoesNotPresentWalletSheet() {
    reachRecording()
    XCTAssertFalse(app.buttons["Cancel"].exists)
    XCTAssertFalse(app.buttons["Connect wallet"].exists)
    XCTAssertTrue(app.buttons["scan.stop-sensing"].isHittable)
    XCTAssertFalse(app.staticTexts["MUTUAL"].exists)
    XCTAssertTrue(app.staticTexts["DEVICES HEARD"].exists)
    XCTAssertTrue(app.staticTexts["ELAPSED"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["scan.sealed"].exists)
  }

  func testKeepSensingReturnsToLiveRecordingWithoutWalletSheet() {
    reachRecording()
    app.buttons["scan.stop-sensing"].tap()
    XCTAssertTrue(app.staticTexts["Stop sensing?"].waitForExistence(timeout: 5))
    app.buttons["Keep sensing"].tap()
    XCTAssertTrue(app.buttons["scan.stop-sensing"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["Stop sensing?"].exists)
    XCTAssertFalse(app.buttons["Cancel"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["scan.sealed"].exists)
  }

  func testConfirmedStopSavesRecordAndOpensRecords() {
    reachRecording()
    app.buttons["scan.stop-sensing"].tap()
    XCTAssertTrue(app.staticTexts["Stop sensing?"].waitForExistence(timeout: 5))
    app.buttons["Stop and keep record"].tap()
    XCTAssertTrue(app.staticTexts["DONE · YOU CAN CLOSE THE APP"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Your record is saved on this phone. You'll find it in Records."].exists)
    app.buttons["Done"].tap()
    XCTAssertTrue(app.buttons["View records"].waitForExistence(timeout: 5))
    app.buttons["View records"].tap()
    XCTAssertTrue(app.scrollViews["records.grid"].waitForExistence(timeout: 5))
    app.tabButton("Now").tap()
    XCTAssertTrue(app.staticTexts["You’re done."].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["home.saved.view-record"].exists)
    XCTAssertTrue(app.staticTexts["home.listening"].exists)
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "N3-saved-record"
    shot.lifetime = .keepAlways
    add(shot)
  }

  // S47 RED: identifiers below name the eventual outcome UI, which does not
  // exist yet. Missing elements must fail assertions, never compilation.
  func testConfirmedStopAfterSaveFailureExplainsNoSavedRecordAndOffersNextAction() {
    reachStopOutcomeFixture("save-failure")
    confirmStop()
    assertNoSealedOrCollectedClaim()
    XCTAssertEqual(app.alerts.count, 0, "The save fault has no signing alert to explain STOP")

    let message = app.staticTexts["stop.outcome.message"]
    XCTAssertTrue(message.waitForExistence(timeout: UITestWait.timeout),
                  "S47 RED: confirmed STOP silently dismisses after ProofStore save failure")
    let text = message.label.lowercased()
    XCTAssertTrue(text.contains("record") && (text.contains("not saved") || text.contains("could not be saved")))
    let action = app.buttons["stop.outcome.action"]
    action.assertHittable()
    XCTAssertFalse(action.label.isEmpty)
    action.tap()
    app.tabButton("Now").assertHittable()
    app.tabButton("Records").tap()
    app.scrollViews["records.grid"].assertExists()
    XCTAssertEqual(recordTiles.count, 0, "This injected write failure created no durable Record")
    assertNoSealedOrCollectedClaim()
  }

  func testConfirmedStopWithNilSignatureExplainsUnsignedLocalRecordAndKeepsItAccessible() {
    reachStopOutcomeFixture("nil-signature")
    confirmStop()
    assertNoSealedOrCollectedClaim()
    XCTAssertEqual(app.alerts.count, 0, "A nil signature has no existing signing-error alert")

    let message = app.staticTexts["stop.outcome.message"]
    XCTAssertTrue(message.waitForExistence(timeout: UITestWait.timeout),
                  "S47 RED: unsigned local Record remains, but STOP gives no signature outcome")
    let text = message.label.lowercased()
    XCTAssertTrue(text.contains("record") && text.contains("signature"))
    XCTAssertTrue(text.contains("could not") || text.contains("not completed") || text.contains("incomplete"))
    XCTAssertFalse(text.contains("record was not saved") || text.contains("no record"),
                   "A nil SelfProofRecord does not mean the durable local Record is missing")
    let action = app.buttons["stop.outcome.action"]
    action.assertHittable()
    XCTAssertFalse(action.label.isEmpty)
    action.tap()
    assertUnsignedLocalRecordIsAccessible()
  }

  func testConfirmedStopDuringDetectingRemainsNormalCancellation() {
    reachStopOutcomeFixture("detecting")
    app.staticTexts["scan.event-found"].assertExists()
    confirmStop()

    app.tabButton("Now").assertHittable()
    XCTAssertEqual(app.alerts.count, 0)
    XCTAssertFalse(app.staticTexts["stop.outcome.message"].exists)
    assertNoSealedOrCollectedClaim()
    app.tabButton("Records").tap()
    app.scrollViews["records.grid"].assertExists()
    XCTAssertEqual(recordTiles.count, 0)
    XCTAssertEqual(app.alerts.count, 0)
    XCTAssertFalse(app.staticTexts["stop.outcome.message"].exists)
  }

  func testConfirmedStopWithSigningKeyErrorShowsExistingAlertOnlyOnce() {
    reachStopOutcomeFixture("signing-error")
    confirmStop()

    let alert = app.alerts["Recording unavailable"]
    alert.assertHittable()
    alert.staticTexts["The device signing key is unavailable. Unlock your device and try again."].assertExists()
    XCTAssertEqual(app.alerts.count, 1)
    XCTAssertFalse(app.staticTexts["stop.outcome.message"].exists, "Do not duplicate the existing explanation")
    assertNoSealedOrCollectedClaim()
    alert.buttons["Close"].tap()
    alert.assertDisappears()
    assertUnsignedLocalRecordIsAccessible()
    app.tabButton("Now").tap()
    app.tabButton("Now").assertHittable()
    XCTAssertEqual(app.alerts.count, 0, "Returning home must not repeat the acknowledged alert")
    XCTAssertFalse(app.staticTexts["stop.outcome.message"].exists)
  }

  func testConfirmedStopAfterSaveFailureWithEndpointsUsesExistingAlertOnlyOnce() {
    reachStopOutcomeFixture("save-failure-with-endpoints")
    confirmStop()
    let alert = app.alerts["Earlier record update failed"]
    alert.assertHittable()
    XCTAssertEqual(app.alerts.count, 1)
    XCTAssertFalse(app.staticTexts["stop.outcome.message"].exists)
    assertNoSealedOrCollectedClaim()
    alert.buttons["Close"].tap()
    alert.assertDisappears()
    app.tabButton("Records").assertHittable()
    app.tabButton("Records").tap()
    app.scrollViews["records.grid"].assertExists()
    XCTAssertEqual(recordTiles.count, 0)
    XCTAssertEqual(app.alerts.count, 0)
  }

  private var recordTiles: XCUIElementQuery {
    app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "records.record."))
  }

  private func reachStopOutcomeFixture(_ mode: String) {
    app.launchArguments = ["-beid-ui-test", "-beid-stop-outcome-fixture", mode]
    app.launch()
    app.buttons["Continue"].assertHittable()
    app.buttons["Continue"].tap()
    app.buttons["Allow Bluetooth"].assertHittable()
    app.buttons["Allow Bluetooth"].tap()
    app.tabButton("Now").assertHittable()
    let join = app.buttons["home.demo.join"]
    join.scrollToHittable(in: app)
    join.tap()
    app.buttons["scan.stop-sensing"].assertHittable()
    XCTAssertEqual(app.alerts.count, 0, "Fixture fault must be armed only after recording setup")
  }

  private func confirmStop() {
    app.buttons["scan.stop-sensing"].tap()
    let stop = app.buttons["scan.stop-confirm.stop"]
    stop.assertHittable()
    stop.tap()
    stop.assertDisappears()
  }

  private func assertNoSealedOrCollectedClaim() {
    XCTAssertFalse(app.descendants(matching: .any)["scan.sealed"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["scan.proof-collected"].exists)
    XCTAssertFalse(app.staticTexts["DONE · YOU CAN CLOSE THE APP"].exists)
    XCTAssertFalse(app.staticTexts["Your record is saved on this phone. You'll find it in Records."].exists)
  }

  private func assertUnsignedLocalRecordIsAccessible() {
    app.tabButton("Records").assertHittable()
    app.tabButton("Records").tap()
    app.scrollViews["records.grid"].assertExists()
    XCTAssertEqual(recordTiles.count, 1, "Keep the existing unsigned local Record")
    let record = recordTiles.firstMatch
    record.scrollToHittable(in: app)
    record.tap()
    app.staticTexts["proof.detail.title"].assertExists()
    app.staticTexts["SIGNATURE"].assertExists()
    app.staticTexts.matching(identifier: "NOT YET AVAILABLE").firstMatch.assertExists()
    XCTAssertFalse(app.staticTexts["Sealed"].exists)
    XCTAssertFalse(app.staticTexts["Self-signed on device"].exists)
    XCTAssertEqual(app.alerts.count, 0)
  }

  func testRecordingMetricsAreFullyVisibleBeforeScrolling() {
    reachRecording()
    SensingVisualOracle.assertInitialMetrics(in: app, test: self, name: "recording-live")
  }

  func testConfirmedStopCaptionHasReadableOnInkForeground() {
    reachRecording()
    app.buttons["scan.stop-sensing"].tap()
    XCTAssertTrue(app.staticTexts["Stop sensing?"].waitForExistence(timeout: 5))
    app.buttons["Stop and keep record"].tap()
    XCTAssertTrue(app.staticTexts[SensingVisualOracle.savedCaption].waitForExistence(timeout: 5))
    SensingVisualOracle.assertSavedCaption(in: app, test: self, name: "saved-live")
  }

  func testRecordingGuidanceRemainsReachableAfterScrolling() {
    reachRecording()
    SensingVisualOracle.assertPostScrollGuidance(in: app, test: self, name: "recording-live")
  }

  private func reachRecording() {
    app.launchArguments = ["-beid-ui-test", "-beid-threshold-override", "1"]
    app.launch()
    app.buttons["Continue"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()
    XCTAssertTrue(app.buttons["home.demo.join"].waitForExistence(timeout: 5))
    app.buttons["home.demo.join"].tap()
    XCTAssertTrue(app.buttons["Simulate Signal Lost"].waitForExistence(timeout: 30))
  }
}

/// Narrow raster/frame evidence for the sensing surfaces on the approved portrait phone.
/// Initial checks never scroll. Post-scroll checks retain their own initial evidence.
enum SensingVisualOracle {
  static let savedCaption = "DONE · YOU CAN CLOSE THE APP"
  private static let guidance = "Keep the app open nearby to help phones observe each other and keep signed records."

  static func assertInitialMetrics(
    in app: XCUIApplication, test: XCTestCase, name: String,
    expected: (heard: String, elapsed: String)? = nil, screenshot: XCUIScreenshot? = nil,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    // Capture before querying/touching the metrics; no scroll-to-hittable or element screenshot.
    let image = screenshot ?? XCUIScreen.main.screenshot()
    attach(image, named: "\(name)-initial-viewport", to: test)
    let window = app.windows.firstMatch.frame
    let scrolls = app.scrollViews.allElementsBoundByIndex.map(\.frame).filter { usable($0.intersection(window)) }
    let viewport = unobscuredRect(in: app, scrolls: scrolls, window: window)
    let labels = ["DEVICES HEARD", "ELAPSED"]
    let texts = app.staticTexts.allElementsBoundByIndex
    var frames: [String: Any] = [:]
    var resolved: [CGRect] = []
    var setupErrors: [String] = []
    for (index, label) in labels.enumerated() {
      let matches = texts.filter { $0.label == label }
      frames[label] = matches.map { rect($0.frame) }
      guard matches.count == 1, let element = matches.first, usable(element.frame) else {
        setupErrors.append("Missing, empty or ambiguous label: \(label)")
        continue
      }
      let labelFrame = element.frame
      let literal = index == 0 ? expected?.heard : expected?.elapsed
      let pattern = index == 0 ? "^[0-9]+$" : "^[0-9]+:[0-5][0-9]$"
      let values = texts.filter {
        let frame = $0.frame
        return (literal == nil || $0.label == literal)
          && $0.label.range(of: pattern, options: .regularExpression) != nil
          && usable(frame) && abs(frame.minX - labelFrame.minX) <= labelFrame.height
          && frame.maxY <= labelFrame.minY + 1
          && labelFrame.minY - frame.maxY <= labelFrame.height * 2
      }
      frames["\(label) value"] = values.map { ["text": $0.label, "frame": rect($0.frame)] }
      guard values.count == 1, let value = values.first else {
        setupErrors.append("Missing or ambiguous value in \(label) column")
        continue
      }
      resolved += [value.frame, labelFrame]
    }
    if !usable(window) || window.width >= window.height || scrolls.count != 1 || !usable(viewport) {
      setupErrors.append("Expected one nonempty portrait window/scroll viewport")
    }
    attachJSON([
      "phase": "initial-before-any-scroll", "window": rect(window), "scrolls": scrolls.map(rect),
      "unobscured": rect(viewport), "metrics": frames, "setup_errors": setupErrors,
      "obstructions": (app.navigationBars.allElementsBoundByIndex + app.tabBars.allElementsBoundByIndex
        + [app.buttons["scan.stop-sensing"], app.buttons["Simulate Signal Lost"]])
        .filter(\.exists).map { ["label": $0.label, "frame": rect($0.frame)] },
      "raster_review": "PARENT_REVIEW_REQUIRED; no automatic text recognition"
    ], named: "\(name)-initial-frames", to: test)
    guard setupErrors.isEmpty, resolved.count == 4 else {
      XCTFail("SETUP_FAILURE: \(setupErrors.joined(separator: "; "))", file: file, line: line)
      return
    }
    for (index, frame) in resolved.enumerated() {
      XCTAssertTrue(viewport.insetBy(dx: 1, dy: 1).contains(frame),
                    "VISUAL_LAYOUT: metric \(index) full frame \(frame) outside unobscured \(viewport)", file: file, line: line)
    }
  }

  static func assertSavedCaption(
    in app: XCUIApplication, test: XCTestCase, name: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    attach(XCUIScreen.main.screenshot(), named: "\(name)-initial-before-caption-scroll", to: test)
    let matches = app.staticTexts.matching(NSPredicate(format: "label == %@", savedCaption))
    guard matches.count == 1 else {
      XCTFail("SETUP_FAILURE: saved caption identity is missing/ambiguous", file: file, line: line)
      return
    }
    let caption = matches.element(boundBy: 0)
    guard let viewport = scrollFullyIntoView(caption, in: app, test: test, name: name) else {
      XCTFail("SETUP_FAILURE: complete saved-caption crop remains occluded after bounded scroll", file: file, line: line)
      return
    }
    let image = XCUIScreen.main.screenshot()
    attach(image, named: "\(name)-post-scroll-caption", to: test)
    guard let pixels = Pixels(image, window: app.windows.firstMatch.frame),
          let sample = pixels.captionSample(frame: caption.frame, viewport: viewport) else {
      XCTFail("SETUP_FAILURE: invalid sRGB crop or no clear tile background", file: file, line: line)
      return
    }
    if let crop = image.image.cgImage?.cropping(to: sample.crop) {
      let attachment = XCTAttachment(image: UIImage(cgImage: crop))
      attachment.name = "\(name)-post-scroll-caption-crop"
      attachment.lifetime = .keepAlways
      test.add(attachment)
    }
    attachJSON([
      "phase": "caption-after-explicit-bounded-scroll", "caption": savedCaption,
      "caption_frame": rect(caption.frame), "unobscured": rect(viewport), "pixel_crop": rect(sample.crop),
      "background_luminance": sample.background, "foreground_luminance": sample.foreground,
      "contrast": sample.contrast, "bright_counts_by_six_text_bands": sample.brightCounts,
      "minimum_bright_per_band": sample.minimumBright, "raster_review": "PARENT_REVIEW_REQUIRED"
    ], named: "\(name)-caption-pixels", to: test)
    XCTAssertGreaterThanOrEqual(sample.foreground, 0.8, "VISUAL_CAPTION: glyph core is not light on ink", file: file, line: line)
    XCTAssertGreaterThan(sample.foreground, sample.background, "VISUAL_CAPTION: wrong foreground polarity", file: file, line: line)
    XCTAssertGreaterThanOrEqual(sample.contrast, 4.5, "VISUAL_CAPTION: actual glyph/tile contrast below 4.5:1", file: file, line: line)
    XCTAssertTrue(sample.brightCounts.allSatisfy { $0 >= sample.minimumBright },
                  "VISUAL_CAPTION: insufficient bright glyph cores across text bands", file: file, line: line)
  }

  static func assertPostScrollGuidance(in app: XCUIApplication, test: XCTestCase, name: String) {
    attach(XCUIScreen.main.screenshot(), named: "\(name)-guidance-initial-before-scroll", to: test)
    let matches = app.staticTexts.matching(NSPredicate(format: "label == %@", guidance))
    guard matches.count == 1,
          let viewport = scrollFullyIntoView(matches.element(boundBy: 0), in: app, test: test, name: name) else {
      XCTFail("POST_SCROLL_VISIBILITY: complete guidance not reachable with bounded scroll")
      return
    }
    let frame = matches.element(boundBy: 0).frame
    attach(XCUIScreen.main.screenshot(), named: "\(name)-post-scroll-guidance", to: test)
    attachJSON(["phase": "post-scroll-only", "guidance": rect(frame), "unobscured": rect(viewport)],
               named: "\(name)-post-scroll-guidance-frames", to: test)
    XCTAssertTrue(viewport.insetBy(dx: 1, dy: 1).contains(frame), "POST_SCROLL_VISIBILITY: guidance clipped")
    XCTAssertTrue(app.buttons["scan.stop-sensing"].isHittable)
    XCTAssertTrue(app.navigationBars.buttons.firstMatch.isHittable)
  }

  private static func scrollFullyIntoView(
    _ element: XCUIElement, in app: XCUIApplication, test: XCTestCase, name: String
  ) -> CGRect? {
    for attempt in 0...5 {
      let window = app.windows.firstMatch.frame
      let scrolls = app.scrollViews.allElementsBoundByIndex.map(\.frame).filter { usable($0.intersection(window)) }
      let viewport = unobscuredRect(in: app, scrolls: scrolls, window: window)
      let frame = element.frame
      attachJSON(["attempt": attempt, "element": rect(frame), "unobscured": rect(viewport)],
                 named: "\(name)-explicit-scroll-\(attempt)", to: test)
      guard scrolls.count == 1, usable(viewport), usable(frame) else { return nil }
      if viewport.insetBy(dx: 4, dy: 4).contains(frame) { return viewport }
      if attempt < 5 { app.scrollViews.firstMatch.swipeUp() }
    }
    return nil
  }

  private static func unobscuredRect(in app: XCUIApplication, scrolls: [CGRect], window: CGRect) -> CGRect {
    guard scrolls.count == 1 else { return .zero }
    var result = scrolls[0].intersection(window)
    for bar in app.navigationBars.allElementsBoundByIndex where usable(bar.frame.intersection(result)) {
      result.origin.y = max(result.minY, bar.frame.maxY)
      result.size.height = max(0, scrolls[0].intersection(window).maxY - result.minY)
    }
    let obstacles = [app.buttons["scan.stop-sensing"], app.buttons["Simulate Signal Lost"]]
      + app.tabBars.allElementsBoundByIndex
    for obstacle in obstacles where obstacle.exists && usable(obstacle.frame.intersection(result)) {
      result.size.height = max(0, obstacle.frame.minY - result.minY)
    }
    return result
  }

  private static func usable(_ frame: CGRect) -> Bool {
    !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0
  }

  private static func rect(_ frame: CGRect) -> [String: CGFloat] {
    ["x": frame.origin.x, "y": frame.origin.y, "width": frame.width, "height": frame.height]
  }

  private static func attach(_ image: XCUIScreenshot, named name: String, to test: XCTestCase) {
    let attachment = XCTAttachment(screenshot: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    test.add(attachment)
  }

  private static func attachJSON(_ value: [String: Any], named name: String, to test: XCTestCase) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
      XCTFail("SETUP_FAILURE: frame/pixel evidence is not valid JSON")
      return
    }
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = name
    attachment.lifetime = .keepAlways
    test.add(attachment)
  }

  /// Same sRGB CGContext decoding technique as SingleAppearanceUITests; no appearance driver or sleeps.
  private struct Pixels {
    let width: Int
    let height: Int
    let window: CGRect
    let bytes: [UInt8]

    init?(_ screenshot: XCUIScreenshot, window: CGRect) {
      guard usable(window), window.width < window.height, let image = screenshot.image.cgImage,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
      let pixelWidth = image.width, pixelHeight = image.height
      guard abs(CGFloat(pixelHeight) / CGFloat(pixelWidth) - window.height / window.width) < 0.01 else { return nil }
      var storage = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
      let drawn = storage.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return true
      }
      guard drawn else { return nil }
      width = pixelWidth; height = pixelHeight; self.window = window; bytes = storage
    }

    struct Sample {
      let crop: CGRect
      let background: Double
      let foreground: Double
      let contrast: Double
      let brightCounts: [Int]
      let minimumBright: Int
    }

    func captionSample(frame: CGRect, viewport: CGRect) -> Sample? {
      guard viewport.insetBy(dx: 4, dy: 4).contains(frame) else { return nil }
      let scale = CGFloat(width) / window.width
      let crop = CGRect(x: (frame.minX - window.minX) * scale, y: (frame.minY - window.minY) * scale,
                        width: frame.width * scale, height: frame.height * scale).integral
      let bounds = CGRect(x: 0, y: 0, width: width, height: height)
      guard bounds.contains(crop.insetBy(dx: -4 * scale, dy: -4 * scale)), crop.width >= 6 else { return nil }
      var background: [Double] = []
      for x in Int(crop.minX)..<Int(crop.maxX) {
        for y in [Int(crop.minY - 3 * scale), Int(crop.maxY + 3 * scale)] { background.append(luminance(x, y)) }
      }
      background.sort()
      guard let low = background.first, let high = background.last, high - low < 0.05 else { return nil }
      let tile = background[background.count / 2]
      var foreground: [Double] = []
      var bands = [Int](repeating: 0, count: 6)
      for y in Int(crop.minY)..<Int(crop.maxY) {
        for x in Int(crop.minX)..<Int(crop.maxX) {
          let light = luminance(x, y)
          foreground.append(light)
          if light >= 0.8 { bands[min(5, (x - Int(crop.minX)) * 6 / Int(crop.width))] += 1 }
        }
      }
      foreground.sort()
      guard !foreground.isEmpty else { return nil }
      let core = foreground[min(foreground.count - 1, foreground.count * 95 / 100)]
      return Sample(crop: crop, background: tile, foreground: core, contrast: (core + 0.05) / (tile + 0.05),
                    brightCounts: bands, minimumBright: max(6, Int(crop.width * crop.height / 6 * 0.005)))
    }

    private func luminance(_ x: Int, _ y: Int) -> Double {
      let offset = (y * width + x) * 4
      func linear(_ value: UInt8) -> Double {
        let component = Double(value) / 255
        return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
      }
      return 0.2126 * linear(bytes[offset]) + 0.7152 * linear(bytes[offset + 1]) + 0.0722 * linear(bytes[offset + 2])
    }
  }
}
