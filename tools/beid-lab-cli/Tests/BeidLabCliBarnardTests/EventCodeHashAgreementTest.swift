// SPDX-License-Identifier: MIT

import BarnardCore
import XCTest

@testable import BeidLabCliCore

/// Proves that the string `participate` builds produces the B004 the phones
/// expect.
///
/// ## Why this is an agreement test and not a fixture
///
/// A fixture would be a value somebody copied out of a log. It pins what the
/// tool does, which is worth something, but it cannot notice that the
/// *definition* side moved -- and a fixture whose expected value was produced
/// by the same reasoning as the code is a test that cannot fail for the
/// reason it exists.
///
/// Barnard already contains two independent paths to the same eight bytes:
///
/// - `BarnardCoreCrypto.computeEventCodeHash(_:)` hashes a join string, which
///   is what `BarnardEngine` does with whatever it is handed;
/// - `BarnardB005EnvelopeV2.openEventCodeHash(eventId:)` hex-renders a raw
///   32-byte Event ID and hashes that, which is what the signed definition
///   carries.
///
/// beid's wire contract is that those two agree, because `shared/`'s
/// `RegistryVerifiedJoinContext` sets the join string to the canonical Event
/// ID hex. So asserting the agreement -- through `LabEventCode.joinString`,
/// the function this tool actually uses -- fails if either side of the SDK
/// moves, if the normalisation drifts, or if this tool stops producing what
/// the app produces. A fixture would catch only the last of those.
///
/// It is also the check that would have caught the 2026-09-17 session: the
/// run joined with `parallax-sepolia-20260917-05`, and no amount of correct
/// hashing can make that agree with an Event ID.
final class EventCodeHashAgreementTest: XCTestCase {
  /// Spread over the byte range on purpose: 0x00 and 0xff both render as two
  /// characters that a naive hex formatter gets wrong in opposite ways.
  private let eventIds: [[UInt8]] = [
    (0..<32).map { UInt8($0) },
    (0..<32).map { UInt8(255 - $0) },
    [UInt8](repeating: 0x00, count: 32),
    [UInt8](repeating: 0xff, count: 32),
    Array("levarac-beid-lab-cli-agreement-32".utf8.prefix(32)),
  ]

  func testTheJoinStringHashesToTheDefinitionsEventCodeHash() throws {
    for eventId in eventIds {
      let hex = LabRedaction.hex(eventId)
      let joinString = try XCTUnwrap(
        LabEventCode.joinString(forEventIdHex: hex), "not normalisable: \(hex)")
      let fromDefinition = try XCTUnwrap(
        BarnardB005EnvelopeV2.openEventCodeHash(eventId: eventId))
      let fromJoinString = BarnardCoreCrypto.computeEventCodeHash(joinString)
      XCTAssertEqual(
        fromJoinString, fromDefinition,
        "B004 disagreement for event id \(hex): the engine would derive "
          + "\(LabRedaction.hex(fromJoinString)) and the definition carries "
          + "\(LabRedaction.hex(fromDefinition))")
    }
  }

  /// B004 is eight bytes. If this ever changes, the `bytes: 8` fields in the
  /// engine's own trace lines stop meaning what this tool's README says.
  func testB004IsEightBytes() {
    let hash = BarnardCoreCrypto.computeEventCodeHash(LabRedaction.hex(eventIds[0]))
    XCTAssertEqual(8, hash.count)
  }

  /// The failure the field session actually hit, asserted rather than
  /// described: the operator's lookup code does not hash to the event's B004.
  func testTheOperatorLookupCodeDoesNotAgreeWithTheEventId() throws {
    let eventId = eventIds[0]
    let fromDefinition = try XCTUnwrap(
      BarnardB005EnvelopeV2.openEventCodeHash(eventId: eventId))
    let fromOperatorCode = BarnardCoreCrypto.computeEventCodeHash("parallax-sepolia-20260917-05")
    XCTAssertNotEqual(fromOperatorCode, fromDefinition)
  }

  /// Case is part of the join string, so an uppercase Event ID is a different
  /// string and a different B004. This is why `joinString` lowercases rather
  /// than merely validating.
  func testUppercaseHexWouldDeriveADifferentHash() throws {
    let eventId = eventIds[1]
    let hex = LabRedaction.hex(eventId)
    let fromDefinition = try XCTUnwrap(
      BarnardB005EnvelopeV2.openEventCodeHash(eventId: eventId))
    XCTAssertNotEqual(BarnardCoreCrypto.computeEventCodeHash(hex.uppercased()), fromDefinition)
    XCTAssertEqual(BarnardCoreCrypto.computeEventCodeHash(hex), fromDefinition)
  }
}
