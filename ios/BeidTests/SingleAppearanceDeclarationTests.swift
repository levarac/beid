// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Beid

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
  @MainActor
  func testAppWindowHasAnExplicitCanvasBackground() throws {
    let window = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows).first { $0.isKeyWindow },
      "Inspect the running app's window, not a detached test window"
    )
    let color = try XCTUnwrap(window.backgroundColor, "The app must own its transition backdrop")
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    XCTAssertTrue(color.resolvedColor(with: window.traitCollection)
      .getRed(&red, green: &green, blue: &blue, alpha: &alpha))
    XCTAssertEqual(red, 1, accuracy: 0.001)
    XCTAssertEqual(green, 1, accuracy: 0.001)
    XCTAssertEqual(blue, 1, accuracy: 0.001)
    XCTAssertEqual(alpha, 1, accuracy: 0.001)
    XCTAssertEqual(window.traitCollection.userInterfaceStyle, .light)
  }

  @MainActor
  func testBackingFollowsPushPopTabsAndSheetDismissalWithoutChangingAppearance() async throws {
    let original = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows).first { $0.isKeyWindow })
    let scene = try XCTUnwrap(original.windowScene)
    let window = UIWindow(windowScene: scene)
    window.frame = scene.coordinateSpace.bounds
    window.overrideUserInterfaceStyle = .light
    defer { window.isHidden = true; original.makeKeyAndVisible() }

    func host(_ color: Color) -> UIViewController {
      UIHostingController(rootView: Text("Background test")
        .frame(maxWidth: .infinity, maxHeight: .infinity).beidScreenBackground(color))
    }
    let ink = host(DS.Color.textPrimary)
    let navigation = UINavigationController(rootViewController: ink)
    let records = host(DS.Color.surfaceCanvas)
    let tabs = UITabBarController()
    tabs.viewControllers = [navigation, records]
    window.rootViewController = tabs
    window.makeKeyAndVisible()
    await assertBacking(window, controllers: [tabs, navigation, ink], ink: true)

    let detail = host(DS.Color.surfaceCanvas)
    navigation.pushViewController(detail, animated: false)
    await assertBacking(window, controllers: [tabs, navigation, detail], ink: false)
    navigation.popViewController(animated: false)
    await assertBacking(window, controllers: [tabs, navigation, ink], ink: true)

    tabs.selectedIndex = 1
    await assertBacking(window, controllers: [tabs, records], ink: false)
    let account = host(DS.Color.textPrimary)
    account.modalPresentationStyle = .pageSheet
    records.present(account, animated: false)
    await assertBacking(window, controllers: [account], ink: true)
    account.dismiss(animated: false)
    await assertBacking(window, controllers: [tabs, records], ink: false)
    XCTAssertEqual(window.traitCollection.userInterfaceStyle, .light)
  }

  @MainActor
  private func assertBacking(_ window: UIWindow, controllers: [UIViewController], ink: Bool,
                             file: StaticString = #filePath, line: UInt = #line) async {
    let expected: [Double] = ink ? [11.0 / 255, 11.0 / 255, 15.0 / 255, 1] : [1, 1, 1, 1]
    func matches(_ color: UIColor?) -> Bool {
      guard let color else { return false }
      var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
      guard color.resolvedColor(with: window.traitCollection)
        .getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
      return zip([red, green, blue, alpha], expected).allSatisfy { pair in
        abs(Double(pair.0) - pair.1) < 0.001
      }
    }
    for _ in 0..<100 {
      if matches(window.backgroundColor) && controllers.allSatisfy({ matches($0.viewIfLoaded?.backgroundColor) }) { break }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertTrue(matches(window.backgroundColor), "Window backing must follow the visible surface", file: file, line: line)
    for controller in controllers {
      XCTAssertTrue(matches(controller.viewIfLoaded?.backgroundColor),
                    "Container backing must follow the visible surface: \(type(of: controller))", file: file, line: line)
    }
  }

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
