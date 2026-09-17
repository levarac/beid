// Use of this source code is governed by a BSD-style license.

import XCTest

@testable import BeidLabCliCore

/// Regression cover for the defect chk-beid-590 found on `8a64099`: the
/// promoted level was computed, gated on, and then thrown away at the `emit`
/// call, so GATT failures never appeared at the default level and a `-v`
/// capture stamped them `debug`.
///
/// The end-to-end cases below go through `LabEmitter` rather than asserting
/// the routing value alone, because the bug lived in the gap *between* the
/// decision and the emission. A test that only checked the decision would
/// have passed on the broken build.
final class LabEngineDebugRoutingTests: XCTestCase {
  private func routing(_ name: String, matches: Bool? = nil) -> LabEngineDebugRouting {
    LabEngineDebugRouting.routing(forDebugEventNamed: name, matches: matches)
  }

  // MARK: The decision

  func testGattFailuresArePromotedToInfo() {
    for name in ["gatt_exchange_timeout", "gatt_resolution_failed", "gatt_read_failed"] {
      XCTAssertEqual(routing(name).level, .info, name)
      XCTAssertEqual(routing(name).stage, .gattResolution, name)
    }
    XCTAssertEqual(routing("gatt_exchange_timeout").result, .timeout)
    XCTAssertEqual(routing("gatt_resolution_failed").result, .rejected)
  }

  func testTheB004GateIsPromotedAndCarriesItsVerdict() {
    XCTAssertEqual(
      routing("gatt_read_event_code_hash", matches: true),
      LabEngineDebugRouting(stage: .gattB004, level: .info, result: .match))
    XCTAssertEqual(
      routing("gatt_read_event_code_hash", matches: false),
      LabEngineDebugRouting(stage: .gattB004, level: .info, result: .mismatch))
    XCTAssertEqual(routing("gatt_b004_mismatch").result, .mismatch)
  }

  /// A backoff follows a failure that was already reported. Promoting it too
  /// would print every failure twice at `info`.
  func testBackoffStaysAtDebug() {
    XCTAssertEqual(routing("gatt_resolution_backoff").level, .debug)
    XCTAssertEqual(routing("gatt_resolution_backoff").stage, .gattResolution)
  }

  func testConnectLifecycleIsItsOwnStageAtDebug() {
    for name in ["connect_attempt", "connected", "connect_queue_full"] {
      XCTAssertEqual(routing(name).stage, .gattConnect, name)
      XCTAssertEqual(routing(name).level, .debug, name)
    }
  }

  func testAnUnknownEventIsOrdinaryDebugNoise() {
    XCTAssertEqual(
      routing("some_future_engine_event"),
      LabEngineDebugRouting(stage: .engineDebug, level: .debug, result: .ok))
  }

  /// Pins the promoted set as a whole. Without this, widening the promotion
  /// (and so raising the default level's volume) needs no test to change.
  func testExactlyTheDeclaredNamesArePromoted() {
    let candidates = [
      "gatt_read_event_code_hash", "gatt_respond_event_code_hash", "gatt_b004_mismatch",
      "gatt_exchange_timeout", "gatt_resolution_failed", "gatt_read_failed",
      "gatt_resolution_backoff", "connect_attempt", "connected", "connect_queue_full",
      "ble_discovery_result", "peripheral_state", "configure", "own_envelope_v2",
    ]
    let promoted = Set(candidates.filter { routing($0).level == .info })
    XCTAssertEqual(promoted, LabEngineDebugRouting.promotedEventNames)
  }

  // MARK: The emission — where the defect actually lived

  private final class RecordingSink: LabLineSink {
    var lines: [String] = []
    func write(line: String) { lines.append(line) }
    func close() {}
  }

  private func emit(_ name: String, at level: LabLogLevel) -> [String] {
    let sink = RecordingSink()
    let emitter = LabEmitter(
      level: level, mode: .participate, eventIdPrefix: nil, sinks: [sink],
      now: { Date(timeIntervalSince1970: 0) })
    let routing = LabEngineDebugRouting.routing(forDebugEventNamed: name, matches: nil)
    // The routing overload, which is exactly what `EngineLogging` calls. The
    // four-argument form is what the defect misused, and this path has no
    // level argument at all.
    emitter.emit(routing, data: ["event": .string(name)])
    return sink.lines
  }

  /// The exact failure: at the default level, nothing came out.
  func testAGattResolutionFailureAppearsAtTheDefaultLevel() {
    let lines = emit("gatt_resolution_failed", at: .info)
    XCTAssertEqual(lines.count, 1, "a GATT failure must be visible at --log-level info")
    XCTAssertTrue(lines[0].contains(#""stage":"gatt_resolution""#))
    XCTAssertTrue(lines[0].contains(#""result":"rejected""#))
  }

  /// The second half of the failure: the line existed at `-v` but was stamped
  /// `debug`, so one capture could not be filtered to `info` afterwards —
  /// which is the property the per-line level exists to give.
  func testThatLineCarriesLevelInfoEvenWhenCapturedAtTrace() {
    for captureLevel in [LabLogLevel.info, .debug, .trace] {
      let lines = emit("gatt_resolution_failed", at: captureLevel)
      XCTAssertEqual(lines.count, 1, "captured at \(captureLevel.rawValue)")
      XCTAssertTrue(
        lines[0].contains(#""level":"info""#),
        "captured at \(captureLevel.rawValue), got \(lines[0])")
    }
  }

  func testTheB004GateIsAlsoVisibleAtTheDefaultLevel() {
    let lines = emit("gatt_exchange_timeout", at: .info)
    XCTAssertEqual(lines.count, 1)
    XCTAssertTrue(lines[0].contains(#""result":"timeout""#))
    XCTAssertTrue(lines[0].contains(#""level":"info""#))
  }

  /// Unpromoted noise must still be absent at the default level, or the
  /// promotion would mean nothing.
  func testOrdinaryDebugNoiseIsStillAbsentAtInfo() {
    XCTAssertEqual(emit("ble_discovery_result", at: .info).count, 0)
    XCTAssertEqual(emit("ble_discovery_result", at: .debug).count, 1)
  }

  /// `--log-level error` is the floor an operator can ask for, and a GATT
  /// failure is not an error line; the closing `result` line carries the
  /// aggregate instead.
  func testNothingIsPromotedPastInfoIntoTheErrorFloor() {
    XCTAssertEqual(emit("gatt_resolution_failed", at: .error).count, 0)
  }
}
