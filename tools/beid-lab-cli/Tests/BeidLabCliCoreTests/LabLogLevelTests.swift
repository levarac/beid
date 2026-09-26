// SPDX-License-Identifier: MIT

import XCTest

@testable import BeidLabCliCore

/// The level filter is the one control Ken asked for by name, so it is tested
/// as a total function over the level matrix rather than by spot checks: a
/// filter that is right for three of sixteen pairs looks right in a sample.
final class LabLogLevelTests: XCTestCase {
  func testSeverityOrderIsErrorInfoDebugTrace() {
    XCTAssertEqual(LabLogLevel.allCases, [.error, .info, .debug, .trace])
    XCTAssertTrue(LabLogLevel.error < LabLogLevel.info)
    XCTAssertTrue(LabLogLevel.info < LabLogLevel.debug)
    XCTAssertTrue(LabLogLevel.debug < LabLogLevel.trace)
  }

  func testEveryLevelPairDecidesEmissionByRank() {
    // configured -> exactly the line levels it admits.
    let expected: [LabLogLevel: Set<LabLogLevel>] = [
      .error: [.error],
      .info: [.error, .info],
      .debug: [.error, .info, .debug],
      .trace: [.error, .info, .debug, .trace],
    ]
    for configured in LabLogLevel.allCases {
      for lineLevel in LabLogLevel.allCases {
        XCTAssertEqual(
          configured.admits(lineLevel),
          expected[configured]!.contains(lineLevel),
          "configured=\(configured.rawValue) line=\(lineLevel.rawValue)"
        )
      }
    }
  }

  /// `error` is the floor, so a run's closing verdict is emitted at `error`
  /// and survives every setting. A `result` line that could be filtered away
  /// would make `--log-level error` produce a log with no verdict in it.
  func testErrorLevelStillAdmitsTheResultLine() {
    XCTAssertTrue(LabLogLevel.error.admits(LabLine.resultLineLevel))
  }

  func testParsesFromRawValueAndRejectsAnythingElse() {
    XCTAssertEqual(LabLogLevel(rawValue: "trace"), .trace)
    XCTAssertNil(LabLogLevel(rawValue: "verbose"))
    XCTAssertNil(LabLogLevel(rawValue: "TRACE"))
  }
}
