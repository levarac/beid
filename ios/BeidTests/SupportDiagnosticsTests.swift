// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import Combine
import UIKit
import XCTest
@testable import Beid

@MainActor
final class SupportDiagnosticsTests: XCTestCase {
  func testActualShareItemExcludesSensitiveUIValuesAndUnknownFailureText() throws {
    let secret = "synthetic-private-key-DO-NOT-SHARE"
    let rpid = "a1b2c3d4e5f60718293a4b5c6d7e8f90ab"
    let phases = PassthroughSubject<ScanPhase, Never>()
    let reasons = PassthroughSubject<String?, Never>()
    let diagnostics = SupportDiagnostics(
      phases: phases.eraseToAnyPublisher(),
      refusalReasons: reasons.eraseToAnyPublisher(),
      clock: { 123 }
    )
    phases.send(.eventFound(EventSession(id: secret, name: rpid, venue: nil)))
    reasons.send(secret)
    reasons.send(rpid)
    reasons.send("network_required")

    let output = diagnostics.exportJson()
    let item = SupportShareItem(text: output)
    let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
    let actual = try XCTUnwrap(item.activityViewController(controller, itemForActivityType: nil) as? String)
    let bytes = try XCTUnwrap(actual.data(using: .utf8))
    XCTAssertEqual(actual, output)
    XCTAssertFalse(actual.contains(secret))
    XCTAssertFalse(actual.contains(rpid))
    for forbidden in [
      "synthetic-private", "a1b2c3d4", "7e8f90ab", "obLD1OX2BxgpOktcbX6PkKs=",
      "f4adc8d6d9e25499cf15290fffecb8eeff25a7027854cd1adbe5138eba494c22"
    ] {
      XCTAssertFalse(actual.contains(forbidden))
    }
    XCTAssertEqual(item.activityViewControllerPlaceholderItem(controller) as? String, actual)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(json["appVersion"] as? String, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    XCTAssertEqual(json["build"] as? String, Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    XCTAssertTrue(actual.contains("EVENT_FOUND"))
    XCTAssertTrue(actual.contains("NETWORK_REQUIRED"))
    XCTAssertEqual(
      ObjectIdentifier(type(of: diagnostics.recorder)),
      ObjectIdentifier(BeidSharedKit.support.SupportBundleRecorder.self)
    )
  }
}
