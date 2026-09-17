// Use of this source code is governed by a BSD-style license.

import XCTest

@testable import BeidLabCliCore

/// Issue #588 says no raw RPID at any level. Ken's 2026-09-17 addition
/// relaxes that to trace only, with a prefix below. Both halves are load
/// bearing, so both are asserted here: a redactor that never redacts and a
/// redactor that always redacts each pass half of the rule.
final class LabRedactionTests: XCTestCase {
  private let rpid = "9f3c71aab20d4e58"

  func testRpidIsFullOnlyAtTrace() {
    XCTAssertEqual(LabRedaction.rpid(rpid, at: .trace), rpid)
  }

  func testRpidIsPrefixedAtDebugAndBelow() {
    for level in [LabLogLevel.error, .info, .debug] {
      XCTAssertEqual(LabRedaction.rpid(rpid, at: level), "9f3c...", "level=\(level.rawValue)")
    }
  }

  func testRpidShorterThanThePrefixIsStillMarkedRedacted() {
    // Never return the whole value just because it is short: a short value is
    // still the whole value.
    XCTAssertEqual(LabRedaction.rpid("9f", at: .info), "9f...")
    XCTAssertEqual(LabRedaction.rpid("", at: .info), "...")
    XCTAssertEqual(LabRedaction.rpid("", at: .trace), "")
  }

  func testEventIdPrefixTakesTheFirstEightHexCharacters() {
    XCTAssertEqual(LabRedaction.eventIdPrefix("1A2B3C4D5E6F7788"), "1a2b3c4d")
    XCTAssertEqual(LabRedaction.eventIdPrefix("0x1a2b3c4d5e6f7788"), "1a2b3c4d")
    XCTAssertEqual(LabRedaction.eventIdPrefix("1a2b3c4d"), "1a2b3c4d")
  }

  func testEventIdPrefixRejectsShortOddAndNonHexInput() {
    XCTAssertNil(LabRedaction.eventIdPrefix("1a2b3c4"))
    XCTAssertNil(LabRedaction.eventIdPrefix("1a2b3c4g5e6f7788"))
    XCTAssertNil(LabRedaction.eventIdPrefix(""))
    XCTAssertNil(LabRedaction.eventIdPrefix("0x"))
  }

  func testHexIsLowercaseAndTwoCharactersPerByte() {
    XCTAssertEqual(LabRedaction.hex([0x00, 0x0f, 0xa0, 0xff]), "000fa0ff")
    XCTAssertEqual(LabRedaction.hex([]), "")
  }

  /// Trace adds raw bytes for non-secret fields only, and the gate is this
  /// function rather than each call site remembering.
  func testRawBytesAreOnlyOfferedAtTrace() {
    XCTAssertEqual(LabRedaction.rawBytes([0xde, 0xad], at: .trace), .string("dead"))
    for level in [LabLogLevel.error, .info, .debug] {
      XCTAssertEqual(LabRedaction.rawBytes([0xde, 0xad], at: level), .null)
    }
  }
}
