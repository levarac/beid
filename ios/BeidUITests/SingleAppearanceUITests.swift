// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import CoreGraphics
import XCTest

/// The live panel stays ink while its page and navigation stay light.
/// These tests inspect real pixels and layout, not the ineffective
/// XCUIDevice.appearance setter. OS appearance is set by the external runner.
final class SingleAppearanceUITests: XCTestCase {
  private let app = XCUIApplication()

  /// Status-bar strip excluded from the pixel comparison. Conservative:
  /// Dynamic Island status bars are about 54–62 pt.
  private static let statusBarHeightPoints: CGFloat = 64
  /// Home-indicator strip excluded from the pixel comparison.
  private static let homeIndicatorHeightPoints: CGFloat = 40
  /// Largest per-channel difference (of 255) still counted as identical.
  private static let channelTolerance = 2
  /// Largest allowed change in the status bar's darkest-pixel luminance.
  private static let statusBarLuminanceTolerance = 0.15

  override func setUpWithError() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }

  func testNowJoinedHasLightPageAroundInkPanel() throws {
    launchHome(["-beid-home-frame-04"])
    app.otherElements["home.active-event"].assertExists()
    try assertLightPage()
    try assertInkPanel("home.live-panel")
    capture("now-joined")
  }

  func testDetectedSensingHasLightPageAroundInkPanel() throws {
    launchHome(["-beid-sensing-shot", "05a"])
    app.buttons["home.demo.join"].tap()
    app.staticTexts["ETH Tokyo 2026"].assertExists()
    try assertLightPage()
    try assertInkPanel("scan.live-panel")
    capture("sensing-after-detection")
  }

  func testStopAlertAppearsOverTheLightPageWithDecidedCopy() throws {
    launchHome(["-beid-sensing-shot", "05a"])
    app.buttons["home.demo.join"].tap()
    app.buttons["scan.stop-sensing"].assertHittable()
    app.buttons["scan.stop-sensing"].tap()
    let alert = app.alerts["Stop sensing?"]
    alert.assertExists()
    XCTAssertTrue(alert.buttons["Stop sensing"].exists)
    XCTAssertTrue(alert.buttons["Cancel"].exists)
    XCTAssertTrue(alert.staticTexts.matching(NSPredicate(
      format: "label BEGINSWITH %@", "This ends your sensing session at this event.")).firstMatch.exists)
    capture("stop-alert")
    alert.buttons["Cancel"].tap()
    app.buttons["scan.stop-sensing"].assertHittable()
  }

  func testJoinedWaitingUsesTheSameInkPanel() throws {
    launchHome(["-beid-nearby-join-fixture"])
    let join = app.buttons["home.nearby.join.9adc61d60dda843e"]
    join.assertHittable()
    join.tap()
    app.staticTexts["scan.detecting.caption"].assertExists()
    try assertLightPage()
    try assertInkPanel("scan.live-panel")
    app.buttons["scan.stop-sensing"].assertHittable()
    capture("sensing-before-detection")
  }

  func testRecordingAndSignalLossKeepLightPageAndInkPanel() throws {
    launchHome(["-beid-threshold-override", "1"])
    app.buttons["home.demo.join"].tap()
    let loseSignal = app.buttons["Simulate Signal Lost"]
    XCTAssertTrue(loseSignal.waitForExistence(timeout: 30))
    try assertLightPage()
    try assertInkPanel("scan.live-panel")
    loseSignal.tap()
    app.staticTexts.matching(NSPredicate(
      format: "label CONTAINS[c] 'signal lost' OR label BEGINSWITH 'beid lost the connection'")).firstMatch.assertExists()
    try assertLightPage()
    try assertInkPanel("scan.live-panel")
    app.buttons["scan.stop-sensing"].assertHittable()
    let retry = app.buttons["Try again"]
    retry.scrollToHittable(in: app)
    retry.tap()
    app.buttons["scan.stop-sensing"].assertHittable()
    capture("sensing-after-retry")
  }

  func testAccessibility3KeepsStopFixedAndGuidanceReachable() throws {
    launchHome(["-beid-sensing-shot", "05a3", "-beid.sensing.firstTimeHintShown", "NO",
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
    app.buttons["home.demo.join"].tap()
    let stop = app.buttons["scan.stop-sensing"]
    stop.assertHittable()
    let originalStop = stop.frame
    let guidance = app.buttons["scan.first-time.about"]
    guidance.scrollToHittable(in: app)
    let scroll = app.scrollViews.firstMatch.frame.intersection(app.windows.firstMatch.frame)
    XCTAssertGreaterThanOrEqual(guidance.frame.minY, scroll.minY)
    XCTAssertLessThanOrEqual(guidance.frame.maxY, min(scroll.maxY, stop.frame.minY))
    XCTAssertEqual(stop.frame, originalStop, "Stop must not scroll with the content")
    stop.assertHittable()
    try assertLightPage()
    capture("sensing-ax3-guidance")
  }

  private func assertInkPanel(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) throws {
    let panel = app.otherElements[identifier]
    panel.assertExists()
    let pixels = try XCTUnwrap(RGBAPixels(XCUIScreen.main.screenshot()))
    // Inside the left padding, far enough below the rounded top corner.
    let point = CGPoint(x: panel.frame.minX + 8, y: panel.frame.minY + 32)
    XCTAssertLessThan(pixels.luminance(at: point), 0.1,
                      "The bounded live panel must remain ink", file: file, line: line)
    XCTAssertGreaterThan(panel.frame.minX, app.windows.firstMatch.frame.minX)
    XCTAssertLessThan(panel.frame.maxX, app.windows.firstMatch.frame.maxX)
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func launchHome(_ arguments: [String]) {
    app.launchArguments = ["-beid-ui-test"] + arguments
    app.launch()
    app.buttons["Continue"].assertHittable()
    app.buttons["Continue"].tap()
    app.buttons["bluetooth.permission.continue"].assertHittable()
    app.buttons["bluetooth.permission.continue"].tap()
    app.tabButton("Now").assertExists()
  }

  private func assertLightPage(file: StaticString = #filePath, line: UInt = #line) throws {
    let pixels = try XCTUnwrap(RGBAPixels(XCUIScreen.main.screenshot()))
    let frame = app.windows.firstMatch.frame
    XCTAssertGreaterThan(pixels.luminance(at: CGPoint(x: frame.minX + 4, y: frame.midY)), 0.9,
                         "The outer page must stay light beside the live panel", file: file, line: line)
    XCTAssertGreaterThan(pixels.luminance(at: CGPoint(x: frame.minX + 4, y: frame.minY + 16)), 0.9,
                         "The status bar ground must remain light", file: file, line: line)
    for bar in app.navigationBars.allElementsBoundByIndex + app.tabBars.allElementsBoundByIndex where bar.exists && !bar.frame.isEmpty {
      XCTAssertGreaterThan(pixels.luminance(at: CGPoint(x: frame.minX + 4, y: bar.frame.midY)), 0.9,
                           "System bars must remain light", file: file, line: line)
    }
  }

  // MARK: - Launch

  private func launch() {
    app.launchArguments = ["-beid-ui-test"]
    app.launch()
  }

  // MARK: - Capture

  /// Waits for the screen to stop changing, attaches it, and returns its
  /// pixels, or fails and returns nil if it never settles.
  private func settledCapture(named name: String) -> RGBAPixels? {
    // An appearance change lands asynchronously. A capture taken before it
    // lands compares the old rendering with itself and passes without
    // proving anything, so wait unconditionally before looking for "settled".
    Thread.sleep(forTimeInterval: 2)

    var previousScreenshot = XCUIScreen.main.screenshot()
    var previous = RGBAPixels(previousScreenshot)
    for _ in 0..<20 {
      Thread.sleep(forTimeInterval: 0.5)
      let screenshot = XCUIScreen.main.screenshot()
      let current = RGBAPixels(screenshot)
      if let previous, let current, previous.contentDifference(from: current) == nil {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return current
      }
      previousScreenshot = screenshot
      previous = current
    }

    let attachment = XCTAttachment(screenshot: previousScreenshot)
    attachment.name = "\(name)-unsettled"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTFail("\(name): the screen never settled — no two consecutive screenshots 0.5 s apart were identical within 20 tries")
    return nil
  }

  // MARK: - Comparison

  private func assertSameAppearance(_ dark: RGBAPixels, as light: RGBAPixels, comparison: String) {
    if let difference = dark.contentDifference(from: light) {
      XCTFail("\(comparison): \(difference)")
    }

    // The clock changes between captures, so the status bar is not compared
    // pixel by pixel. On a light app its glyphs are dark; if the app followed
    // a dark OS they would turn light, raising the darkest pixel's luminance.
    let lightLuminance = light.darkestStatusBarLuminance()
    let darkLuminance = dark.darkestStatusBarLuminance()
    XCTAssertLessThanOrEqual(
      abs(darkLuminance - lightLuminance),
      Self.statusBarLuminanceTolerance,
      "\(comparison): status-bar darkest-pixel luminance changed from \(lightLuminance) (light) to \(darkLuminance)"
    )
  }

  /// A screenshot drawn into an sRGB, 8-bit RGBA (premultiplied-last) buffer;
  /// row 0 is the top row.
  private struct RGBAPixels {
    let width: Int
    let height: Int
    let scale: CGFloat
    let bytes: [UInt8]

    init?(_ screenshot: XCUIScreenshot) {
      guard
        let image = screenshot.image.cgImage,
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
      else { return nil }
      // Locals only until every stored property is set: the drawing closure
      // must not capture `self` before it is fully initialized.
      let pixelWidth = image.width
      let pixelHeight = image.height
      var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
      let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
          data: buffer.baseAddress,
          width: pixelWidth,
          height: pixelHeight,
          bitsPerComponent: 8,
          bytesPerRow: pixelWidth * 4,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return true
      }
      guard drawn else { return nil }
      width = pixelWidth
      height = pixelHeight
      scale = screenshot.image.scale
      bytes = pixels
    }

    func luminance(at point: CGPoint) -> Double {
      let x = min(width - 1, max(0, Int(point.x * scale)))
      let y = min(height - 1, max(0, Int(point.y * scale)))
      let offset = (y * width + x) * 4
      return (0.2126 * Double(bytes[offset]) + 0.7152 * Double(bytes[offset + 1])
        + 0.0722 * Double(bytes[offset + 2])) / 255
    }

    /// First pixel row below the status-bar strip.
    private var contentTop: Int {
      Int((SingleAppearanceUITests.statusBarHeightPoints * scale).rounded(.up))
    }

    /// First pixel row of the home-indicator strip.
    private var contentBottom: Int {
      height - Int((SingleAppearanceUITests.homeIndicatorHeightPoints * scale).rounded(.up))
    }

    /// nil when the content regions match; otherwise a description of how
    /// they differ.
    func contentDifference(from other: RGBAPixels) -> String? {
      guard width == other.width, height == other.height else {
        return "screenshot sizes differ: \(width)x\(height) px vs \(other.width)x\(other.height) px"
      }
      let tolerance = SingleAppearanceUITests.channelTolerance
      var differing = 0
      var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
      bytes.withUnsafeBufferPointer { mine in
        other.bytes.withUnsafeBufferPointer { theirs in
          for y in contentTop..<contentBottom {
            for x in 0..<width {
              let offset = (y * width + x) * 4
              if abs(Int(mine[offset]) - Int(theirs[offset])) > tolerance
                || abs(Int(mine[offset + 1]) - Int(theirs[offset + 1])) > tolerance
                || abs(Int(mine[offset + 2]) - Int(theirs[offset + 2])) > tolerance {
                differing += 1
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
              }
            }
          }
        }
      }
      guard differing > 0 else { return nil }
      let total = width * (contentBottom - contentTop)
      let box = CGRect(
        x: CGFloat(minX) / scale,
        y: CGFloat(minY) / scale,
        width: CGFloat(maxX - minX + 1) / scale,
        height: CGFloat(maxY - minY + 1) / scale
      )
      return "\(differing) of \(total) content pixels differ; bounding box in points: \(box)"
    }

    /// Luminance (0...1) of the darkest pixel in the status-bar strip.
    func darkestStatusBarLuminance() -> Double {
      var darkest = 1.0
      for y in 0..<min(contentTop, height) {
        for x in 0..<width {
          let offset = (y * width + x) * 4
          let luminance = (
            0.2126 * Double(bytes[offset])
              + 0.7152 * Double(bytes[offset + 1])
              + 0.0722 * Double(bytes[offset + 2])
          ) / 255
          darkest = min(darkest, luminance)
        }
      }
      return darkest
    }
  }
}
