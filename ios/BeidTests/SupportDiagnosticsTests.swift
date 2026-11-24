// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import Combine
import CryptoKit
import UIKit
import XCTest
@testable import Beid

@MainActor
final class SupportDiagnosticsTests: XCTestCase {
  func testActualShareItemExcludesSensitiveUIValuesAndUnknownFailureText() throws {
    let secret = "synthetic-private-key-DO-NOT-SHARE"
    let rpidBytes = Data((0xA1...0xB1).map { UInt8($0) })
    let rpid = rpidBytes.map { String(format: "%02x", $0) }.joined()
    let rpidHash = SHA256.hash(data: rpidBytes).map { String(format: "%02x", $0) }.joined()
    let markers = [
      secret, "synthetic-private", "synthetic-seed-DO-NOT-SHARE", "synthetic-cookie-DO-NOT-SHARE",
      "https://example.invalid/rpc?key=synthetic-credential",
      "synthetic-signed-observation", "synthetic-signed-report", "synthetic-acceptance-receipt",
      rpid, rpid.uppercased(), String(rpid.prefix(8)), String(rpid.suffix(8)),
      rpidBytes.base64EncodedString(), rpidHash,
      "network_required\n\"injected\":\"synthetic-sensitive-error\""
    ]
    let phases = PassthroughSubject<ScanPhase, Never>()
    let reasons = PassthroughSubject<String?, Never>()
    let ownerKeyFailures = PassthroughSubject<OwnerKeyOperationFailure?, Never>()
    var timestamp: Int64 = 7_234_567
    let diagnostics = SupportDiagnostics(
      phases: phases.eraseToAnyPublisher(),
      refusalReasons: reasons.eraseToAnyPublisher(),
      ownerKeyFailures: ownerKeyFailures.eraseToAnyPublisher(),
      clock: { timestamp }
    )
    let event = EventSession(
      id: secret, name: rpid, venue: "synthetic-sensitive-venue", canonicalEventIdHex: rpidHash
    )
    phases.send(.idle)
    phases.send(.sensing)
    phases.send(.eventFound(event))
    phases.send(.recording(event: event, peersVerified: 5))
    phases.send(.signalLost(event: event, peersVerified: 7))
    timestamp = 10_800_123
    let knownReasons = ["network_required", "event_not_found", "code_mismatch", "event_not_active", "verification_failed"]
    for reason in knownReasons { reasons.send(reason) }
    reasons.send(nil)
    ownerKeyFailures.send(.unavailable)
    for marker in markers {
      phases.send(.sensing)
      reasons.send(marker)
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let metadata: [String: Any] = [
      "CFBundleIdentifier": "org.levarac.beid.tests.synthetic",
      "CFBundlePackageType": "BNDL", "CFBundleShortVersionString": "1.2.3",
      "CFBundleVersion": "42", "BeidGitHeight": "4242"
    ]
    try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
      .write(to: directory.appendingPathComponent("Info.plist"))
    let output = diagnostics.exportJson(bundle: try XCTUnwrap(Bundle(url: directory)))
    let item = SupportShareItem(text: output)
    let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
    // Later changes must not alter the snapshot already offered for sharing.
    phases.send(.idle)
    let actual = try XCTUnwrap(item.activityViewController(controller, itemForActivityType: nil) as? String)
    let bytes = try XCTUnwrap(actual.data(using: .utf8))
    XCTAssertEqual(actual, output)
    XCTAssertEqual(item.activityViewControllerPlaceholderItem(controller) as? String, actual)
    let json = try parse(actual)
    XCTAssertEqual(Set(json.keys), Set(["schemaVersion", "platform", "appVersion", "build", "gitHeight", "historyScope", "entries"]))
    XCTAssertEqual(json["schemaVersion"] as? Int, 1)
    XCTAssertEqual(json["platform"] as? String, "IOS")
    XCTAssertEqual(json["appVersion"] as? String, "1.2.3")
    XCTAssertEqual(json["build"] as? String, "42")
    XCTAssertEqual(json["gitHeight"] as? Int, 4242)
    XCTAssertFalse(json["gitHeight"] is String)
    XCTAssertEqual(json["historyScope"] as? String, "current_process")
    let entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
    let expectedStates = ["IDLE", "SENSING", "EVENT_FOUND", "RECORDING", "SIGNAL_LOST"]
      + Array(repeating: "JOIN_FAILED", count: 5) + ["OWNER_KEY_UNAVAILABLE"]
      + markers.flatMap { _ in ["SENSING", "JOIN_FAILED"] }
    let expectedFailures = ["NONE", "NONE", "NONE", "NONE", "SIGNAL_LOST", "NETWORK_REQUIRED",
                            "EVENT_NOT_FOUND", "CODE_MISMATCH", "EVENT_NOT_ACTIVE", "VERIFICATION_FAILED", "OWNER_KEY_UNAVAILABLE"]
      + markers.flatMap { _ in ["NONE", "UNKNOWN"] }
    XCTAssertEqual(entries.count, 11 + 2 * markers.count)
    XCTAssertEqual(entries.compactMap { $0["state"] as? String }, expectedStates)
    XCTAssertEqual(entries.compactMap { $0["failure"] as? String }, expectedFailures)
    for (index, entry) in entries.enumerated() {
      XCTAssertEqual(Set(entry.keys), Set(["hourStartEpochMs", "state", "failure"]))
      XCTAssertEqual(entry["hourStartEpochMs"] as? Int64, index < 5 ? 7_200_000 : 10_800_000)
    }
    for marker in markers + ["synthetic-sensitive-venue"] {
      let data = Data(marker.utf8)
      let encodings = [marker, data.base64EncodedString(), data.map { String(format: "%02x", $0) }.joined()]
      for encoding in encodings {
        XCTAssertNil(bytes.range(of: Data(encoding.utf8)), "Sensitive fixture value escaped into share bytes")
      }
    }
    XCTAssertEqual(
      ObjectIdentifier(type(of: diagnostics.recorder)),
      ObjectIdentifier(BeidSharedKit.support.SupportBundleRecorder.self)
    )
    let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
    attachment.name = "support-bundle-synthetic-json"
    attachment.lifetime = .keepAlways
    add(attachment)
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
