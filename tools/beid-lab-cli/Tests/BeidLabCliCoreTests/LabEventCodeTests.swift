// SPDX-License-Identifier: MIT

import XCTest

@testable import BeidLabCliCore

/// The 2026-09-17 lab session joined with the operator lookup code instead of
/// the Event ID, derived a B004 nothing matched, and reported a clean run
/// that measured nothing. These cover the shape check that now catches it.
final class LabEventCodeTests: XCTestCase {
  /// A real-shaped 32-byte Event ID.
  private let eventId = "9f3c71aab20d4e58a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718"
  /// The string from the session that failed.
  private let operatorCode = "parallax-sepolia-20260917-05"

  func testAnEventIdNormalisesToTheStringBeidHandsTheEngine() {
    XCTAssertEqual(LabEventCode.joinString(forEventIdHex: eventId), eventId)
    XCTAssertEqual(LabEventCode.joinString(forEventIdHex: "0x" + eventId), eventId)
    XCTAssertEqual(LabEventCode.joinString(forEventIdHex: eventId.uppercased()), eventId)
    XCTAssertEqual(LabEventCode.joinString(forEventIdHex: "0X" + eventId.uppercased()), eventId)
  }

  /// A join string that is nearly an Event ID is not a near miss on the wire:
  /// it hashes to something unrelated. So a wrong length is refused outright
  /// rather than padded, trimmed or accepted.
  func testAnythingThatIsNotThirtyTwoHexBytesIsRefused() {
    XCTAssertNil(LabEventCode.joinString(forEventIdHex: String(eventId.dropLast())))
    XCTAssertNil(LabEventCode.joinString(forEventIdHex: eventId + "00"))
    XCTAssertNil(LabEventCode.joinString(forEventIdHex: operatorCode))
    XCTAssertNil(LabEventCode.joinString(forEventIdHex: ""))
    XCTAssertNil(LabEventCode.joinString(forEventIdHex: "0x"))
    XCTAssertNil(
      LabEventCode.joinString(forEventIdHex: String(eventId.dropLast()) + "g"))
  }

  func testTheCodeFromTheFailedSessionIsRecognisedAsNonCanonical() {
    XCTAssertFalse(LabEventCode.looksCanonical(operatorCode))
  }

  func testAnEventIdHexIsRecognisedAsCanonical() {
    XCTAssertTrue(LabEventCode.looksCanonical(eventId))
  }

  /// Uppercase hex of the right length is still wrong: the bytes hashed are
  /// the *characters*, so `9F` and `9f` are different join strings and
  /// produce different B004 values.
  func testUppercaseHexOfTheRightLengthIsNotCanonical() {
    XCTAssertFalse(LabEventCode.looksCanonical(eventId.uppercased()))
  }

  func testTheWarningSaysWhatToDoInstead() {
    // Asserted because this string is the entire mitigation: an operator who
    // reads it must learn the flag to use, not only that something is wrong.
    XCTAssertTrue(LabEventCode.nonCanonicalWarning.contains("--event-id"))
    XCTAssertTrue(LabEventCode.nonCanonicalWarning.contains("--container"))
  }
}
