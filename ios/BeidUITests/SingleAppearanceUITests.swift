// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import CoreGraphics
import XCTest

// MARK: - Why this file currently contains no tests
//
// thegreeting/beid#632 (DESIGN.md §14): beid has a single appearance and does
// not follow the OS dark-mode setting.
//
// This file held two pixel-comparison tests,
// `testWelcomeLooksTheSameWithTheDeviceInDarkMode` and
// `testAccountSheetLooksTheSameWithTheDeviceInDarkMode`. They were **deleted on
// 2026-09-23**, not skipped and not left green, because they could not fail.
// A test that cannot fail is worse than a missing test: it gets pointed at as
// evidence. These two claimed to prove the exact property #632 exists to
// establish, and cost ~55 s of every run to prove nothing. An `XCTSkip` would
// have left a skip that could never un-skip.
//
// Forwarding address for reviving this: **beid#670**.
//
// ## The cause: `XCUIDevice.shared.appearance` is a no-op on this host
//
// Assigning to `XCUIDevice.shared.appearance` has no effect at all here
// (iPhone 17 Pro / iOS 26.5 / Xcode 27A266a) — in **both** directions.
// `xcrun simctl ui <udid> appearance` works correctly on the same machine.
// So both tests captured one screen, "switched" to dark, captured the same
// screen again, and compared it with itself.
//
// Three measurements, taken 2026-09-23. The third is the one that proves it
// rather than merely suggesting it:
//
// 1. **Dark mode itself works.** With `simctl ui <udid> appearance dark`,
//    Apple's own Settings app renders fully dark. (Clock identical, 10:05, in
//    both captures, so the difference is not the clock.)
//
// 2. **The device never went dark while these tests ran.** Running
//    `--only-testing BeidUITests/SingleAppearanceUITests` while sampling
//    `simctl ui <udid> appearance` once a second from outside the test process:
//        light 102 | unknown 3 (the erase/reboot window) | dark 0
//    Both tests passed.
//
// 3. **The setter cannot move the device in either direction.** The device was
//    set dark with simctl first (confirmed `dark`), then the same two tests were
//    run with `--keep-simulator-state`. `setUpWithError` assigned `.light` and
//    the test body assigned `.dark`; the samples were:
//        dark 63 | light 0
//    The device stayed dark for the whole run, and **both tests passed again**.
//    The same green from the opposite starting state is something a working
//    switch cannot produce, and is exactly what a no-op produces.
//
// ## The comparison logic below is sound — it is the driver that is dead
//
// The machinery kept in this file was never the problem, so it is kept rather
// than deleted. Driving the appearance with simctl instead (outside the test
// process) and capturing the app directly:
//
//   - declaration present, device dark  -> app renders light (correct)
//   - declaration removed, device dark  -> app follows dark, and **the "beid"
//     wordmark disappears**: it turns white on a still-white background. The
//     subtitle and the Get Started button survive; the wordmark simply goes.
//
// Measured with CoreGraphics, status bar excluded so the clock cannot
// contribute:
//
//     differing pixels: 15613 of 2930580 (0.53%)
//     bounding box:     x = 153...247 pt, y = 394...429 pt   (the wordmark)
//
// 15613 px is far above `channelTolerance` (2 of 255), so `contentDifference`
// would have caught this instantly had the appearance actually changed. The
// test design is worth reviving; only the way it was driven needs replacing.
//
// This is not specific to #632: **any** UI test written against
// `XCUIDevice.shared.appearance` is vacuous on arrival on this host, which
// includes #633/#643 and anything else appearance-dependent.
//
// ## What is kept below, and why
//
// `RGBAPixels` (the whole struct), `settledCapture` and `assertSameAppearance`
// are the proven-sound comparison machinery a simctl-driven harness would reuse
// unchanged; `launch()` is trivial but goes with them. Removed with the tests:
// `assertLooksTheSameInDarkMode` and `setUpWithError`, both of which were built
// around switching the appearance from inside the test process — the thing that
// does not work.

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
