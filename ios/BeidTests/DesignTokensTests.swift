// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import CoreText
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

  // MARK: - Font (beid#629, DESIGN.md §6)

  /// Every `DS.Font.Library` style and the Flat 2b ramp row it must carry.
  /// Tracking is the Library percentage over 100; `lineHeight` is nil for
  /// the Library's "auto". Text styles are #629's decision, not the
  /// Library's — Display takes `.largeTitle` throughout for its flat
  /// accessibility curve.
  private let expectedFontStyles: [(
    name: String,
    style: DS.Font.Style,
    postScriptName: String,
    size: CGFloat,
    textStyle: Font.TextStyle,
    tracking: CGFloat,
    lineHeight: CGFloat?,
    isUppercase: Bool,
    usesMonospacedDigits: Bool
  )] = [
    ("display60", DS.Font.Library.display60,
     "BricolageGrotesque-Display60ExtraBold", 60, .largeTitle, -0.02, 1.0, false, false),
    ("display52", DS.Font.Library.display52,
     "BricolageGrotesque-Display52ExtraBold", 52, .largeTitle, -0.02, 1.0, false, false),
    ("display46", DS.Font.Library.display46,
     "BricolageGrotesque-Display46ExtraBold", 46, .largeTitle, -0.015, 1.0, false, false),
    ("displayNumber40", DS.Font.Library.displayNumber40,
     "BricolageGrotesque-Display40ExtraBold", 40, .largeTitle, -0.01, nil, false, true),
    ("displayAddress34", DS.Font.Library.displayAddress34,
     "BricolageGrotesque-Display34ExtraBold", 34, .largeTitle, -0.01, nil, false, false),
    ("title19", DS.Font.Library.title19, "DMSans-Bold", 19, .title3, 0, nil, false, false),
    ("title17", DS.Font.Library.title17, "DMSans-Bold", 17, .headline, 0, nil, false, false),
    ("title16", DS.Font.Library.title16, "DMSans-Bold", 16, .callout, 0, nil, false, false),
    ("title15", DS.Font.Library.title15, "DMSans-Bold", 15, .subheadline, 0, nil, false, false),
    ("body15", DS.Font.Library.body15, "DMSans-Regular", 15, .subheadline, 0, 1.4, false, false),
    ("body13", DS.Font.Library.body13, "DMSans-Regular", 13, .footnote, 0, 1.4, false, false),
    ("labelMono11", DS.Font.Library.labelMono11,
     "DMMono-Medium", 11, .caption2, 0.08, nil, true, false),
    ("labelMono10", DS.Font.Library.labelMono10,
     "DMMono-Medium", 10, .caption2, 0.08, nil, true, false),
    ("labelMono9", DS.Font.Library.labelMono9,
     "DMMono-Medium", 9, .caption2, 0.06, nil, true, false),
    ("labelMono10Tight", DS.Font.Library.labelMono10Tight,
     "DMMono-Medium", 10, .caption2, 0.06, nil, false, false),
    ("labelMono11Time", DS.Font.Library.labelMono11Time,
     "DMMono-Medium", 11, .caption2, 0, nil, false, false),
    ("labelMono13Value", DS.Font.Library.labelMono13Value,
     "DMMono-Medium", 13, .footnote, 0, nil, false, false),
  ]

  /// Each `DS.Font` role and the name of the Library style it must point
  /// at. The name is the literal; the style itself is looked up in
  /// `expectedFontStyles`, whose own row is pinned field by field above.
  private let expectedFontRoles: [(name: String, role: Font, styleName: String)] = [
    ("screenTitle", DS.Font.screenTitle, "display46"),
    ("sectionTitle", DS.Font.sectionTitle, "title19"),
    ("cardTitle", DS.Font.cardTitle, "title17"),
    ("body", DS.Font.body, "body15"),
    ("supporting", DS.Font.supporting, "body13"),
    ("meta", DS.Font.meta, "body13"),
    ("ledgerMono", DS.Font.ledgerMono, "labelMono13Value"),
    ("cta", DS.Font.cta, "title16"),
  ]

  /// The `expectedFontStyles` row named `styleName`, or a test failure.
  private func expectedStyleRow(
    _ styleName: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> (
    name: String,
    style: DS.Font.Style,
    postScriptName: String,
    size: CGFloat,
    textStyle: Font.TextStyle,
    tracking: CGFloat,
    lineHeight: CGFloat?,
    isUppercase: Bool,
    usesMonospacedDigits: Bool
  ) {
    try XCTUnwrap(
      expectedFontStyles.first { $0.name == styleName },
      "no Library style named \(styleName)",
      file: file,
      line: line
    )
  }

  func testFontLibraryStylesMatchFlat2bRamp() {
    for row in expectedFontStyles {
      let style = row.style
      XCTAssertEqual(style.postScriptName, row.postScriptName, "\(row.name) face")
      XCTAssertEqual(style.size, row.size, "\(row.name) base size")
      XCTAssertEqual(style.textStyle, row.textStyle, "\(row.name) text style")
      XCTAssertEqual(style.tracking, row.tracking, accuracy: 0.0001, "\(row.name) tracking")
      XCTAssertEqual(style.lineHeight, row.lineHeight, "\(row.name) line height")
      XCTAssertEqual(style.isUppercase, row.isUppercase, "\(row.name) uppercase")
      XCTAssertEqual(
        style.usesMonospacedDigits,
        row.usesMonospacedDigits,
        "\(row.name) monospaced digits"
      )
    }
  }

  func testFontLibraryListCoversAllSeventeenStyles() {
    XCTAssertEqual(expectedFontStyles.count, 17)
    XCTAssertEqual(Set(expectedFontStyles.map { $0.name }).count, 17)
  }

  /// Only the three mono *label* styles uppercase. The mono *value* styles
  /// must not: an EIP-55 address carries its checksum in letter case, so
  /// uppercasing one corrupts it (§6, #629).
  func testOnlyMonoLabelStylesAreUppercase() {
    let uppercased = expectedFontStyles.filter { $0.style.isUppercase }.map { $0.name }
    XCTAssertEqual(Set(uppercased), ["labelMono11", "labelMono10", "labelMono9"])
  }

  func testOnlyTheSensingFigureStyleUsesMonospacedDigits() {
    let tabular = expectedFontStyles.filter { $0.style.usesMonospacedDigits }.map { $0.name }
    XCTAssertEqual(tabular, ["displayNumber40"])
  }

  func testFontRolesPointAtTheirLibraryStyles() throws {
    for row in expectedFontRoles {
      let expected = try expectedStyleRow(row.styleName)
      XCTAssertEqual(row.role, expected.style.font, "DS.Font.\(row.name)")
    }
    XCTAssertEqual(expectedFontRoles.count, 8)
    XCTAssertEqual(Set(expectedFontRoles.map { $0.name }).count, 8)
  }

  /// Each role resolves to its bundled face at its Library base size under
  /// the default content size. This is the check that the font files are
  /// actually registered: an unregistered `Font.custom` falls back to the
  /// system face and this fails.
  func testFontRolesResolveToBundledFacesAtDefaultContentSize() throws {
    guard #available(iOS 26.0, *) else {
      throw XCTSkip(
        """
        Font.resolve(in:) / Font.Resolved are @available(iOS 26.0) in the \
        installed SDK (iPhoneSimulator27.0, SwiftUICore.swiftinterface), so \
        a role's face cannot be inspected on this runtime. \
        testFontRolesPointAtTheirLibraryStyles still pins the role mapping.
        """
      )
    }
    let context = EnvironmentValues().fontResolutionContext
    for row in expectedFontRoles {
      let expected = try expectedStyleRow(row.styleName)
      let resolved = row.role.resolve(in: context)
      let name = CTFontCopyPostScriptName(resolved.ctFont) as String
      XCTAssertEqual(
        name,
        expected.postScriptName,
        "DS.Font.\(row.name) resolved to \(name)"
      )
      XCTAssertEqual(
        resolved.pointSize,
        expected.size,
        accuracy: 0.01,
        "DS.Font.\(row.name) point size"
      )
    }
  }

  /// `DS.Font.meta.weight(.semibold)` — the form four call sites use — must
  /// stay inside the bundled family instead of falling back to the system
  /// face when SwiftUI cannot find a semibold cut of DM Sans.
  func testWeightedMetaRoleStaysInTheBundledFamily() throws {
    guard #available(iOS 26.0, *) else {
      throw XCTSkip(
        """
        Font.resolve(in:) / Font.Resolved are @available(iOS 26.0) in the \
        installed SDK, so the resolved face of a weighted role cannot be \
        inspected on this runtime.
        """
      )
    }
    let resolved = DS.Font.meta.weight(.semibold).resolve(in: EnvironmentValues().fontResolutionContext)
    let name = CTFontCopyPostScriptName(resolved.ctFont) as String
    XCTAssertTrue(
      name.hasPrefix("DMSans-"),
      "DS.Font.meta.weight(.semibold) resolved to \(name)"
    )
  }

  /// The roles themselves grow at AX3 — not just Apple's curve. Each role's
  /// resolved point size is compared against `UIFontMetrics.scaledValue` on
  /// **the text style that role's own Library style chose**, computed here,
  /// so a wrong `relativeTo:` fails loudly instead of quietly scaling on
  /// someone else's curve: `screenTitle` is Display/46 on `.largeTitle` and
  /// lands near 68 pt at AX3, where the same base size on `.body`'s curve
  /// would reach about 100 pt. Both sides are Apple's, so this pins our
  /// choice of curve without pinning a number Apple owns. The tolerance
  /// absorbs SwiftUI resolving a rounded point size where `scaledValue`
  /// returns the 1/3-pt quantised one — Display/46 at AX3 resolves to 68.0
  /// against `scaledValue`'s 68.33 (measured on iOS 26.5).
  func testFontRolesGrowWithDynamicTypeAtAX3() throws {
    guard #available(iOS 26.0, *) else {
      throw XCTSkip(
        """
        Font.resolve(in:) / Font.Resolved are @available(iOS 26.0) in the \
        installed SDK, so a role's resolved point size cannot be read on \
        this runtime. testFontStylesScaleUpAtAX3 still pins that every \
        Library style grows at AX3 on the curve it chose.
        """
      )
    }
    var environment = EnvironmentValues()
    environment.dynamicTypeSize = .accessibility3
    let context = environment.fontResolutionContext
    let ax3 = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraLarge)

    for row in expectedFontRoles {
      let expected = try expectedStyleRow(row.styleName)
      let metrics = UIFontMetrics(forTextStyle: Self.uiTextStyle(expected.textStyle))
      let resolved = row.role.resolve(in: context).pointSize
      XCTAssertGreaterThan(resolved, expected.size, "DS.Font.\(row.name) at AX3")
      XCTAssertEqual(
        resolved,
        metrics.scaledValue(for: expected.size, compatibleWith: ax3),
        accuracy: 0.5,
        "DS.Font.\(row.name) (\(row.styleName) on \(expected.textStyle)) at AX3"
      )
    }
  }

  /// Every Library style grows at AX3 on the curve it chose.
  ///
  /// `UIContentSizeCategory.accessibilityExtraLarge` *is* AX3. The five
  /// accessibility constants, in order (`UIContentSizeCategory.h`), are
  /// AccessibilityMedium = AX1, AccessibilityLarge = AX2,
  /// AccessibilityExtraLarge = AX3, AccessibilityExtraExtraLarge = AX4,
  /// AccessibilityExtraExtraExtraLarge = AX5. Passing the last one — as
  /// this test did before — measures AX5, not AX3.
  func testFontStylesScaleUpAtAX3() {
    let ax3 = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraLarge)
    for row in expectedFontStyles {
      let metrics = UIFontMetrics(forTextStyle: Self.uiTextStyle(row.textStyle))
      let scaled = metrics.scaledValue(for: row.size, compatibleWith: ax3)
      XCTAssertGreaterThan(scaled, row.size, "\(row.name) at AX3")
    }
  }

  /// Why every Display style takes `.largeTitle` (§6, #629): it is the
  /// flattest accessibility curve available — the multiplier falls as the
  /// text style's own size rises, and `.largeTitle` is the largest.
  /// Stated as an inequality against *the same face at the same base size*
  /// on `.body`'s curve, built here in the test, so it asserts the reason
  /// rather than a measured number Apple is free to move — and it goes red
  /// the moment someone re-points a Display style at `.body`.
  func testDisplaySitsOnAFlatterCurveThanBodyAtAX3AndAX5() throws {
    guard #available(iOS 26.0, *) else {
      throw XCTSkip(
        """
        Font.resolve(in:) / Font.Resolved are @available(iOS 26.0) in the \
        installed SDK, so the two curves cannot be compared on this runtime.
        """
      )
    }
    let display = try expectedStyleRow("display60")
    let onBodyCurve = Font.custom(
      display.postScriptName, size: display.size, relativeTo: .body
    )
    for (label, size) in [("AX3", DynamicTypeSize.accessibility3), ("AX5", .accessibility5)] {
      var environment = EnvironmentValues()
      environment.dynamicTypeSize = size
      let context = environment.fontResolutionContext
      XCTAssertLessThan(
        display.style.font.resolve(in: context).pointSize,
        onBodyCurve.resolve(in: context).pointSize,
        "Display/60 on .largeTitle must stay under the same face on .body at \(label)"
      )
    }
  }

  func testStyleTrackingScalesWithPointSize() {
    XCTAssertEqual(
      DS.Font.Library.labelMono10.tracking(atPointSize: 10), 0.8, accuracy: 0.0001
    )
    XCTAssertEqual(
      DS.Font.Library.display60.tracking(atPointSize: 60), -1.2, accuracy: 0.0001
    )
    // +8% of a Dynamic Type-scaled 20 pt, not of the 10 pt base.
    XCTAssertEqual(
      DS.Font.Library.labelMono10.tracking(atPointSize: 20), 1.6, accuracy: 0.0001
    )
    XCTAssertEqual(DS.Font.Library.title17.tracking(atPointSize: 17), 0, accuracy: 0.0001)
  }

  /// `lineSpacing` is the gap added *between* lines, so it is the Library
  /// line height minus the face's own. DM Sans is 1.302 em (hhea 992/−310
  /// over 1000 upem), so Body/15 wants 21 − 19.53 ≈ 1.47 pt. The tolerance
  /// is wide because `UIFont.lineHeight` may round the face's ascent and
  /// descent; the exact relation is asserted separately below.
  func testStyleLineSpacingAddsToTheFaceLineHeight() throws {
    let face = try XCTUnwrap(UIFont(name: "DMSans-Regular", size: 15))
    XCTAssertEqual(
      DS.Font.Library.body15.lineSpacing(atPointSize: 15),
      1.4 * 15 - face.lineHeight,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      DS.Font.Library.body15.lineSpacing(atPointSize: 15), 1.47, accuracy: 0.6
    )
  }

  func testStyleLineSpacingIsZeroWhenTheLibraryGivesNoLineHeight() {
    XCTAssertEqual(DS.Font.Library.title17.lineSpacing(atPointSize: 17), 0)
    XCTAssertEqual(DS.Font.Library.labelMono13Value.lineSpacing(atPointSize: 13), 0)
  }

  /// The §6 gap: Display asks for 100% against a 1.2 em face, and
  /// `lineSpacing` is additive and nonnegative, so the request cannot be
  /// honoured. It must clamp, never emit a negative spacing.
  func testDisplayLineHeightBelowTheFaceClampsToZero() {
    XCTAssertEqual(DS.Font.Library.display60.lineSpacing(atPointSize: 60), 0)
    XCTAssertEqual(DS.Font.Library.display46.lineSpacing(atPointSize: 46), 0)
  }

  /// SwiftUI text style → its UIKit counterpart, written out so the AX3
  /// test reads Apple's curve without asking `Tokens.swift` for it.
  private static func uiTextStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
    switch style {
    case .largeTitle: return .largeTitle
    case .title: return .title1
    case .title2: return .title2
    case .title3: return .title3
    case .headline: return .headline
    case .subheadline: return .subheadline
    case .body: return .body
    case .callout: return .callout
    case .footnote: return .footnote
    case .caption: return .caption1
    case .caption2: return .caption2
    default: return .body
    }
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
