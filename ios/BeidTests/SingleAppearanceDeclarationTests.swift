// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation
import XCTest

/// Regression coverage for thegreeting/beid#632 (DESIGN.md §14): the app
/// declares a single appearance, and the declaration itself — not only the
/// drawing it produces — has to survive.
///
/// `SingleAppearanceUITests` proves the app's own drawing does not follow the
/// OS appearance. It cannot prove this key is present, because #632 also
/// removed every dark colour and illustration: with no dark variant left to
/// switch to, the app draws identically whether or not the appearance is
/// locked. Deleting `UIUserInterfaceStyle` from `ios/project.yml` accordingly
/// left that suite green (measured 2026-09-23: 682 tests, no failure).
///
/// The key is not decoration. It governs the UI the app does *not* draw — the
/// keyboard, alerts, action sheets, context menus, text-selection handles and
/// share sheets — all of which follow the OS appearance unless the app forces
/// one. This is the direct assertion on the declaration.
final class SingleAppearanceDeclarationTests: XCTestCase {
  func testAppBundleDeclaresLightUserInterfaceStyle() {
    // A unit-test bundle with a test host runs inside the app process, so
    // `Bundle.main` is the built Beid app rather than the test runner.
    // Asserting that first keeps a failure honest: without it, a bundle that
    // was not the app would read a missing key and fail for the wrong reason.
    let bundle = Bundle.main
    XCTAssertEqual(
      bundle.bundleIdentifier,
      "org.levarac.beid",
      "Bundle.main is not the Beid app, so the key below would be read from the wrong Info.plist"
    )

    // Read the built bundle, not `ios/project.yml`: this is what ships, so it
    // also catches a regeneration that dropped the key rather than only an
    // edit that removed it.
    let style = bundle.object(forInfoDictionaryKey: "UIUserInterfaceStyle") as? String
    XCTAssertEqual(
      style,
      "Light",
      """
      The built app must declare UIUserInterfaceStyle = Light (DESIGN.md §14, #632). \
      Declare it in the Beid target's info.properties in ios/project.yml and regenerate. \
      Without it the keyboard, alerts, action sheets, context menus and share sheets \
      follow the device's dark mode, even though the app's own drawing does not.
      """
    )
  }
}
