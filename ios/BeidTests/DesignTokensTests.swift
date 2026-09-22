// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI
import UIKit
import XCTest
@testable import Beid

/// Pins the Flat 2b token values (beid#628, DESIGN.md §4/§5/§7/§8). Every
/// expected value is a literal from the Flat 2b Library, never read back
/// from `Tokens.swift` or `Colors.xcassets`: a test that compares a token
/// with itself cannot fail.
final class DesignTokensTests: XCTestCase {
  /// Every `DS.Color` token and the Library hex it must resolve to. Library
  /// primitives are single-appearance, so light and dark expect the same hex.
  private let expectedColorHex: [(name: String, color: Color, hex: String)] = [
    ("surfaceCanvas", DS.Color.surfaceCanvas, "#FFFFFF"),
    ("textPrimary", DS.Color.textPrimary, "#0B0B0F"),
    ("textSecondary", DS.Color.textSecondary, "#6E6E78"),
    ("strokeHairline", DS.Color.strokeHairline, "#ECECF1"),
    ("strokeEmptyState", DS.Color.strokeEmptyState, "#C9C9CF"),
    ("surfaceTile", DS.Color.surfaceTile, "#F2F2F4"),
    ("chartDetected", DS.Color.chartDetected, "#D9D9DE"),
    ("textSecondaryOnInk", DS.Color.textSecondaryOnInk, "#8E8E96"),
    ("strokeHairlineOnInk", DS.Color.strokeHairlineOnInk, "#2A2A31"),
    ("graphNodeIdle", DS.Color.graphNodeIdle, "#5C5C66"),
    ("actionPrimary", DS.Color.actionPrimary, "#0B0B0F"),
    ("labelOnActionPrimary", DS.Color.labelOnActionPrimary, "#FFFFFF"),
    ("actionInverse", DS.Color.actionInverse, "#FFFFFF"),
    ("labelOnActionInverse", DS.Color.labelOnActionInverse, "#0B0B0F"),
    ("statusOn", DS.Color.statusOn, "#30D158"),
    ("statusPending", DS.Color.statusPending, "#FF9F0A"),
    ("statusOff", DS.Color.statusOff, "#FF453A"),
  ]

  func testColorTokensResolveToFlat2bLibraryHexInLightAndDark() {
    for style in [UIUserInterfaceStyle.light, .dark] {
      let traits = UITraitCollection(userInterfaceStyle: style)
      for token in expectedColorHex {
        let resolved = UIColor(token.color).resolvedColor(with: traits)
        XCTAssertEqual(
          Self.srgbHex(resolved),
          token.hex,
          "DS.Color.\(token.name) under \(style == .light ? "light" : "dark")"
        )
      }
    }
  }

  func testColorTokenListCoversAllSeventeenRoles() {
    XCTAssertEqual(expectedColorHex.count, 17)
    XCTAssertEqual(Set(expectedColorHex.map { $0.name }).count, 17)
  }

  func testPageMarginAndEmptyBlockSpacingMatchFlat2b() {
    XCTAssertEqual(DS.Space.pageMargin, 24)
    XCTAssertEqual(DS.Space.emptyBlockVertical, 40)
  }

  func testHairlineIsOnePoint() {
    XCTAssertEqual(DS.Size.hairline, 1)
  }

  func testEmptyBlockDashMatchesFlat2bLibrary() {
    // `Block/Empty` dashPattern [4, 4].
    XCTAssertEqual(DS.Size.emptyBlockDash, 4)
  }

  func testRowMinimumHeightsMatchFlat2b() {
    XCTAssertEqual(DS.Size.listRowMinHeight, 92)
    XCTAssertEqual(DS.Size.keyValueRowMinHeight, 44)
    XCTAssertEqual(DS.Size.sessionRowMinHeight, 48)
    XCTAssertEqual(DS.Size.reportRowMinHeight, 60)
    XCTAssertEqual(DS.Size.proofRowMinHeight, 72)
  }

  func testPrimaryButtonSizesMatchFlat2bLibrary() {
    XCTAssertEqual(DS.Size.primaryButtonMinHeight, 56)
    XCTAssertEqual(DS.Size.compactPrimaryButtonMinHeight, 52)
    XCTAssertEqual(DS.Size.compactPrimaryButtonWidth, 140)
  }

  func testEmptyBlockAndNowCardRadiiMatchFlat2b() {
    XCTAssertEqual(DS.Radius.emptyBlock, 16)
    XCTAssertEqual(DS.Radius.nowCard, 20)
  }

  /// `#RRGGBB` of `color` in 8-bit sRGB.
  private static func srgbHex(_ color: UIColor) -> String? {
    guard
      let srgb = CGColorSpace(name: CGColorSpace.sRGB),
      let converted = color.cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
      let components = converted.components,
      components.count >= 3
    else { return nil }
    let bytes = components.prefix(3).map { Int(($0 * 255).rounded()) }
    return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
  }
}
