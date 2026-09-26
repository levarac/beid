// SPDX-License-Identifier: MIT

import XCTest

@testable import BeidLabCliCore

/// The JSON-lines schema is a contract with whoever reads the log afterwards,
/// so these assert the exact bytes rather than "it decodes".
final class LabLineTests: XCTestCase {
  private let instant = Date(timeIntervalSince1970: 1_789_610_400.123)

  func testEveryLineCarriesTheSameSevenKeysInSortedOrder() throws {
    let line = LabLine(
      timestamp: instant,
      level: .info,
      mode: .observe,
      stage: .scanStart,
      eventId: nil,
      result: .ok,
      data: [:]
    )
    XCTAssertEqual(
      try line.encoded(),
      #"{"data":{},"event":null,"level":"info","mode":"observe","result":"ok","stage":"scan_start","ts":"2026-09-17T02:00:00.123Z"}"#
    )
  }

  /// `event` and `data` are present even when empty. A reader filtering a
  /// mixed log with `jq 'select(.event=="1a2b3c4d")'` must not have to know
  /// which stages happen to carry the field.
  func testEventAndDataArePresentWhenPopulated() throws {
    let line = LabLine(
      timestamp: instant,
      level: .debug,
      mode: .participate,
      stage: .gattB004,
      eventId: "1a2b3c4d",
      result: .mismatch,
      data: ["bytes": .int(8), "matches": .bool(false), "peer": .string("p1")]
    )
    XCTAssertEqual(
      try line.encoded(),
      #"{"data":{"bytes":8,"matches":false,"peer":"p1"},"event":"1a2b3c4d","level":"debug","mode":"participate","result":"mismatch","stage":"gatt_b004","ts":"2026-09-17T02:00:00.123Z"}"#
    )
  }

  func testStageNamesAreSnakeCaseAndStable() {
    // Spelled out rather than derived: the point of the assertion is that a
    // rename of the Swift case cannot silently rename the wire stage.
    XCTAssertEqual(LabStage.runStart.rawValue, "run_start")
    XCTAssertEqual(LabStage.permissions.rawValue, "permissions")
    XCTAssertEqual(LabStage.scanStart.rawValue, "scan_start")
    XCTAssertEqual(LabStage.advertiseRequested.rawValue, "advertise_requested")
    XCTAssertEqual(LabStage.advertiseStop.rawValue, "advertise_stop")
    XCTAssertEqual(LabStage.venueReady.rawValue, "venue_ready")
    XCTAssertEqual(LabStage.discovery.rawValue, "discovery")
    XCTAssertEqual(LabStage.peerFirstSeen.rawValue, "peer_first_seen")
    XCTAssertEqual(LabStage.peerLost.rawValue, "peer_lost")
    XCTAssertEqual(LabStage.gattB004.rawValue, "gatt_b004")
    XCTAssertEqual(LabStage.gattConnect.rawValue, "gatt_connect")
    XCTAssertEqual(LabStage.gattResolution.rawValue, "gatt_resolution")
    XCTAssertEqual(LabStage.detection.rawValue, "detection")
    XCTAssertEqual(LabStage.envelopeV2.rawValue, "envelope_v2")
    XCTAssertEqual(LabStage.state.rawValue, "state")
    XCTAssertEqual(LabStage.relay.rawValue, "relay")
    XCTAssertEqual(LabStage.engineEvent.rawValue, "engine_event")
    XCTAssertEqual(LabStage.engineDebug.rawValue, "engine_debug")
    XCTAssertEqual(LabStage.constraint.rawValue, "constraint")
    XCTAssertEqual(LabStage.failure.rawValue, "failure")
    XCTAssertEqual(LabStage.result.rawValue, "result")
  }

  func testTimestampIsUtcMillisecondsWithZSuffix() throws {
    let line = LabLine(
      timestamp: Date(timeIntervalSince1970: 0),
      level: .error,
      mode: .venue,
      stage: .result,
      eventId: nil,
      result: .ok,
      data: [:]
    )
    XCTAssertTrue(try line.encoded().contains(#""ts":"1970-01-01T00:00:00.000Z""#))
  }

  /// Slashes appear in nothing this tool emits except a `--log` path echoed
  /// back in `run_start`, and `\/` there would be read as a broken path by a
  /// human skimming the log.
  func testSlashesAreNotEscaped() throws {
    let line = LabLine(
      timestamp: instant, level: .info, mode: .observe, stage: .runStart,
      eventId: nil, result: .ok, data: ["log": .string("/tmp/run.jsonl")]
    )
    XCTAssertTrue(try line.encoded().contains("/tmp/run.jsonl"))
  }

  func testNullAndArrayValuesEncode() throws {
    let line = LabLine(
      timestamp: instant, level: .trace, mode: .observe, stage: .discovery,
      eventId: nil, result: .ok,
      data: ["name": .null, "services": .array([.string("b001"), .string("180a")]), "rssi": .int(-54)]
    )
    XCTAssertEqual(
      try line.encoded(),
      #"{"data":{"name":null,"rssi":-54,"services":["b001","180a"]},"event":null,"level":"trace","mode":"observe","result":"ok","stage":"discovery","ts":"2026-09-17T02:00:00.123Z"}"#
    )
  }

  func testResultTokensAreStable() {
    XCTAssertEqual(LabResult.ok.rawValue, "ok")
    XCTAssertEqual(LabResult.mismatch.rawValue, "mismatch")
    XCTAssertEqual(LabResult.match.rawValue, "match")
    XCTAssertEqual(LabResult.timeout.rawValue, "timeout")
    XCTAssertEqual(LabResult.rejected.rawValue, "rejected")
    XCTAssertEqual(LabResult.unavailable.rawValue, "unavailable")
    XCTAssertEqual(LabResult.interrupted.rawValue, "interrupted")
  }
}
