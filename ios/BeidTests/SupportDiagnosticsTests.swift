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
    let hexHash = "ef93b80721fc4e29d8a37594303a251f6eaebe88b41bb29d17da1e905b5224af"
    let phases = PassthroughSubject<ScanPhase, Never>()
    let reasons = PassthroughSubject<String?, Never>()
    let diagnostics = SupportDiagnostics(
      phases: phases.eraseToAnyPublisher(),
      refusalReasons: reasons.eraseToAnyPublisher(),
      ownerKeyFailures: Empty().eraseToAnyPublisher(),
      clock: { 123 }
    )
    let event = EventSession(id: secret, name: rpid, venue: "synthetic-sensitive-venue", canonicalEventIdHex: hexHash)
    phases.send(.eventFound(event))
    phases.send(.recording(event: event, peersVerified: 5))
    phases.send(.signalLost(event: event, peersVerified: 7))
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
      "f4adc8d6d9e25499cf15290fffecb8eeff25a7027854cd1adbe5138eba494c22",
      "synthetic-sensitive-venue", hexHash
    ] {
      XCTAssertFalse(actual.contains(forbidden))
    }
    XCTAssertEqual(item.activityViewControllerPlaceholderItem(controller) as? String, actual)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(json["appVersion"] as? String, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    XCTAssertEqual(json["build"] as? String, Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    XCTAssertTrue(actual.contains("EVENT_FOUND"))
    XCTAssertTrue(actual.contains("SIGNAL_LOST"))
    XCTAssertTrue(actual.contains("NETWORK_REQUIRED"))
    XCTAssertEqual(
      ObjectIdentifier(type(of: diagnostics.recorder)),
      ObjectIdentifier(BeidSharedKit.support.SupportBundleRecorder.self)
    )
  }

  func testOwnerKeyFailuresAreRecordedIncludingFailureLatchedBeforeSubscription() throws {
    let failures = CurrentValueSubject<OwnerKeyOperationFailure?, Never>(.unavailable)
    let diagnostics = SupportDiagnostics(
      phases: Empty().eraseToAnyPublisher(),
      refusalReasons: Empty().eraseToAnyPublisher(),
      ownerKeyFailures: failures.eraseToAnyPublisher(),
      clock: { 3_600_123 }
    )
    failures.send(nil)
    failures.send(.unavailable)
    let json = try parse(diagnostics.exportJson())
    let entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?["state"] as? String, "OWNER_KEY_UNAVAILABLE")
    XCTAssertEqual(entries.first?["failure"] as? String, "OWNER_KEY_UNAVAILABLE")
    XCTAssertEqual(entries.first?["hourStartEpochMs"] as? Int64, 3_600_000)
  }

  func testGitHeightComesFromTheBundleAndRejectsNonNumericMetadata() throws {
    let diagnostics = SupportDiagnostics(
      phases: Empty().eraseToAnyPublisher(),
      refusalReasons: Empty().eraseToAnyPublisher(),
      ownerKeyFailures: Empty().eraseToAnyPublisher()
    )
    for height in [nil, "4242", "local", "synthetic-sensitive-height", "1.2"] as [String?] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      var metadata: [String: Any] = [
        "CFBundleIdentifier": "org.levarac.beid.tests.\(UUID().uuidString)",
        "CFBundlePackageType": "BNDL",
        "CFBundleShortVersionString": "1.2.3",
        "CFBundleVersion": "42"
      ]
      metadata["BeidGitHeight"] = height
      let plist = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
      try plist.write(to: directory.appendingPathComponent("Info.plist"))
      let bundle = try XCTUnwrap(Bundle(url: directory))
      let output = diagnostics.exportJson(bundle: bundle)
      let json = try parse(output)
      XCTAssertEqual(json["appVersion"] as? String, "1.2.3")
      XCTAssertEqual(json["build"] as? String, "42")
      if height == "4242" {
        XCTAssertEqual(json["gitHeight"] as? Int64, 4242)
      } else {
        XCTAssertTrue(json["gitHeight"] is NSNull)
        XCTAssertFalse(output.contains("synthetic-sensitive-height"))
      }
    }
  }

  private func parse(_ output: String) throws -> [String: Any] {
    let bytes = try XCTUnwrap(output.data(using: .utf8))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
  }
}
