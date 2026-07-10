// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI
import XCTest
@testable import Beid

@MainActor
final class LocalizationContractTests: XCTestCase {
  func testDesignSystemCopyUsesLocalizedStringKeys() {
    let hero = BeidHeroHeader(systemImage: "star", title: "Title", subtitle: "Subtitle")
    let primaryButton = BeidPrimaryButton("Primary") {}
    let secondaryButton = BeidSecondaryButton(title: "Secondary") {}
    let bullet = BeidBulletRow(systemImage: "star", title: "Bullet")
    let status = BeidStatusLayout(systemImage: "star", title: "Status", message: "Message")
    let metric = BeidMetricRow(label: "Label", value: "Value")
    let dynamicMetric = BeidMetricRow(label: "Label", verbatimValue: "runtime-value")

    XCTAssertEqual(typeName(of: hero.title), "SwiftUI.LocalizedStringKey")
    XCTAssertEqual(typeName(of: hero.subtitle), "Swift.Optional<SwiftUI.LocalizedStringKey>")
    XCTAssertEqual(typeName(of: primaryButton.title), "SwiftUI.LocalizedStringKey")
    XCTAssertEqual(typeName(of: secondaryButton.title), "SwiftUI.LocalizedStringKey")
    XCTAssertEqual(typeName(of: bullet.title), "SwiftUI.LocalizedStringKey")
    XCTAssertEqual(typeName(of: status.title), "SwiftUI.LocalizedStringKey")
    XCTAssertEqual(typeName(of: status.message), "SwiftUI.LocalizedStringKey")
    XCTAssertEqual(typeName(of: metric.label), "SwiftUI.LocalizedStringKey")
    XCTAssertEqual(typeName(of: metric.value), "SwiftUI.Text")
    XCTAssertEqual(typeName(of: dynamicMetric.value), "SwiftUI.Text")
  }

  private func typeName<T>(of value: T) -> String {
    String(reflecting: T.self)
  }
}
