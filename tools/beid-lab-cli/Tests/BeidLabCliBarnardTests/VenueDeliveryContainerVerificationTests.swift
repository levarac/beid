// SPDX-License-Identifier: MIT

import Barnard
import BarnardCore
import XCTest

@testable import BeidLabCliCore

/// What `venue_ready` reports about a genuine delivery container, checked on
/// a real signed one.
///
/// The fixture is Barnard's `test-vectors/venue-envelope-producer-fixture.txt`
/// container, the same bytes `ios/BeidTests/ProductionVenueBundleVerifierTests`
/// uses: signed with a real key, registrar/anchor/nonce 0xa1/0xa2/0xa3
/// repeated, one authority key, joinMode 0, eninSeconds 300, validFromEnin
/// 6,000,000, validThroughEnin 6,000,010, relayExpiresAtEnin 6,000,004,
/// display name "Venue Test Event".
final class VenueDeliveryContainerVerificationTests: XCTestCase {
  private static let containerHex =
    "030000d601a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2" +
    "a2a2a2a2a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3010279be667e" +
    "f9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179800012c005b8d80005b8d8a005b8" +
    "d8402236c422fa9e53e281056656e75652054657374204576656e74000f02ac07c182b379723813bf05" +
    "46ce0991cc0d05022c49dd1c7068a2f22a0ffb29ad1ee643185f0f260459c2808aae5a1c871784bd93ff" +
    "4d8bc8b87f634596fe00"

  private var container: [UInt8] {
    let hex = Array(Self.containerHex.utf8)
    return stride(from: 0, to: hex.count, by: 2).map { UInt8(String(decoding: hex[$0..<$0 + 2], as: UTF8.self), radix: 16)! }
  }

  private func verify(_ bytes: [UInt8], at enin: Int64?) -> BarnardB005VerifiedEnvelope? {
    BarnardB005EnvelopeV2.verify(
      container: bytes, currentEnin: enin, nameValidator: BarnardB005NativeDisplayNameNormalizer())
  }

  func testSchedulingFieldsGiveTheWindowVenueReadyPrints() throws {
    let scheduling = try XCTUnwrap(BarnardB005EnvelopeV2.schedulingFields(container: container))
    XCTAssertEqual(scheduling.validFromEnin, 6_000_000)
    XCTAssertEqual(scheduling.relayExpiresAtEnin, 6_000_004)
    XCTAssertEqual(scheduling.validThroughEnin, 6_000_010)
    XCTAssertEqual(
      LabVenueWindow.acceptedThroughUnix(
        relayExpiresAtEnin: Int64(scheduling.relayExpiresAtEnin), eninSeconds: Int64(scheduling.eninSeconds)),
      1_800_001_199)
  }

  func testNoEninReportsEvenAGenuineDeliveryContainerAsUnverified() {
    // The behaviour venue_ready had before it passed the envelope's own start.
    XCTAssertNil(verify(container, at: nil))
  }

  func testVerifyingAtTheEnvelopesOwnStartReportsItGenuine() throws {
    let scheduling = try XCTUnwrap(BarnardB005EnvelopeV2.schedulingFields(container: container))
    let verified = try XCTUnwrap(verify(container, at: Int64(scheduling.validFromEnin)))
    XCTAssertEqual(verified.receiverState, .RADIO_SELF_VERIFIED)
    XCTAssertEqual(verified.eventDisplayName, "Venue Test Event")
    XCTAssertEqual(verified.relayHopCount, 0)
  }

  func testAChangedSignatureByteIsNotGenuine() {
    var tampered = container
    tampered[tampered.count - 2] ^= 0x01
    XCTAssertNil(verify(tampered, at: 6_000_000))
  }

  func testPhonesRefuseItFromRelayExpiryOn() {
    XCTAssertNotNil(verify(container, at: 6_000_003))
    XCTAssertNil(verify(container, at: 6_000_004))
  }
}
