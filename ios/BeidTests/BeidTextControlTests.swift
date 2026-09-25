// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI
import UIKit
import XCTest
@testable import Beid

/// Flat 2b text controls (beid#631, DESIGN.md §12).
///
/// Every geometry assertion measures a **rendered** view through
/// `UIHostingController` and compares it with the literal 44 from §2 rule 5.
/// Reading `DS.Size.minHitTarget` back and comparing it with itself would pass
/// no matter what the control actually draws — the trap `DesignTokensTests`'
/// own header calls out — and would also keep passing if someone lowered the
/// token.
@MainActor
final class BeidTextControlTests: XCTestCase {
  /// §2 rule 5 / HIG minimum hit region, as a literal on purpose: see the
  /// class comment.
  private let minimumHitRegion: CGFloat = 44

  // MARK: - Acceptance criterion 2 — 44×44pt hit region

  /// Catches removal or narrowing of `.frame(minWidth:minHeight:)`: a
  /// one-character label is the worst case, because its glyph is ~10×13pt and
  /// a long label like "EVENTS" would satisfy the width check on its own.
  func testOneCharacterLabelRendersAtLeastFortyFourByFortyFour() {
    let size = measuredSize(BeidTextControlLabel("X"))

    XCTAssertGreaterThanOrEqual(size.width, minimumHitRegion, "width of a one-character label")
    XCTAssertGreaterThanOrEqual(size.height, minimumHitRegion, "height of a one-character label")
  }

  /// The glyph DESIGN.md §12 names is always paired with a spoken label
  /// through the typed glyph API, even in this geometry test.
  func testArrowGlyphLabelRendersAtLeastFortyFourByFortyFour() {
    let size = measuredSize(
      BeidTextControlLabel("X", glyph: .leading("←", announcing: "Back to X"))
    )

    XCTAssertGreaterThanOrEqual(size.width, minimumHitRegion, "width of an arrow-glyph label")
    XCTAssertGreaterThanOrEqual(size.height, minimumHitRegion, "height of an arrow-glyph label")
  }

  /// Catches a `BeidTextControl` that stops routing through
  /// `BeidTextControlLabel` — wrapping the text in a `Button` directly would
  /// lose the measured minimum frame. This geometry test does not exercise
  /// hit testing; the label's `contentShape` supplies that behavior.
  func testButtonFormKeepsTheHitRegionOfItsLabel() {
    let size = measuredSize(BeidTextControl("X") {})

    XCTAssertGreaterThanOrEqual(size.width, minimumHitRegion, "width of the button form")
    XCTAssertGreaterThanOrEqual(size.height, minimumHitRegion, "height of the button form")
  }

  /// Catches a regression to a fixed `height` (DESIGN.md §6 forbids
  /// fixed-height containers around text). A label narrow enough to wrap, at
  /// an accessibility content size, MUST make the control taller; a fixed
  /// 44pt height would clip it and this measurement would stay at 44.
  ///
  /// Deliberately not "is it taller at a11y size than at default size": with
  /// `minHeight: 44` a short label is 44pt at both, so that comparison would
  /// depend on the font's own scale curve rather than on the bug.
  func testLabelGrowsTallerThanItsMinimumWhenItsTextCannotFitOnOneLine() {
    let size = measuredSize(
      BeidTextControlLabel("Events and proofs collected on this device"),
      proposal: CGSize(width: 120, height: 640),
      dynamicTypeSize: .accessibility5
    )

    XCTAssertGreaterThan(
      size.height,
      minimumHitRegion,
      "a wrapping label at an accessibility content size must grow past the 44pt minimum, not clip"
    )
  }

  /// Catches a fixed-height regression from the other direction: the 44pt
  /// floor must still hold once Dynamic Type is turned all the way up.
  func testShortLabelStillMeetsTheHitRegionAtAccessibilityDynamicType() {
    let size = measuredSize(BeidTextControlLabel("X"), dynamicTypeSize: .accessibility5)

    XCTAssertGreaterThanOrEqual(size.width, minimumHitRegion, "width at accessibility5")
    XCTAssertGreaterThanOrEqual(size.height, minimumHitRegion, "height at accessibility5")
  }

  // MARK: - Acceptance criterion 3 — VoiceOver labels

  // Deliberately absent, and this block is the reason. Do not rebuild them here.
  //
  // Three tests lived here asserting that a control announces its supplied
  // VoiceOver label and never its `←`/`→` glyph. On 2026-09-23 they were run
  // against a real erased iOS 26.5 simulator and all three failed with:
  //
  //     failed: caught error: "No accessibility element was reachable from the
  //     hosted SwiftUI view"
  //
  // What was tried: the view was hosted in a `UIHostingController`, placed in a
  // `UIWindow` as its `rootViewController`, shown with `makeKeyAndVisible()`,
  // laid out with `setNeedsLayout()` + `layoutIfNeeded()`, then walked with
  // `isAccessibilityElement` / `accessibilityElementCount()` /
  // `accessibilityElement(at:)`. The traversal returns nothing at all.
  //
  // The five geometry tests above passed in that same run, so this is not a
  // broken harness: **SwiftUI does not expose a UIKit-reachable accessibility
  // tree in a unit-test process.** A test written here cannot pass — and, worse,
  // one that treats an empty traversal as "no violation found" passes vacuously
  // and reads as evidence.
  //
  // XCUITest can query real controls by their VoiceOver label, as this
  // repository already does elsewhere. Such assertions need to wait until
  // a product decision applies the helper to a real screen.
  //
  // The stronger guarantee is not a test at all: `BeidTextControlGlyph` carries
  // the spoken label, its memberwise initializer is `private`, and the glyph
  // initializer has no `accessibilityLabel` parameter — so a glyph without a
  // VoiceOver label does not compile.

  // MARK: - Measurement helpers

  private func measuredSize<V: View>(
    _ view: V,
    proposal: CGSize = CGSize(width: 320, height: 640),
    dynamicTypeSize: DynamicTypeSize = .large
  ) -> CGSize {
    let host = UIHostingController(rootView: view.environment(\.dynamicTypeSize, dynamicTypeSize))
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    return host.sizeThatFits(in: proposal)
  }
}
