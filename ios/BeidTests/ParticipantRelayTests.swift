// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Barnard
import BarnardCore
import BeidSharedKit
import XCTest

@testable import Beid

/// Records what `SensingCoordinator` asks of Barnard's relay.
final class RecordingParticipantRelayControl: ParticipantRelayControlling, @unchecked Sendable {
  private(set) var verifier: (any BarnardRelayVerifier)?
  private(set) var configureCalls = 0
  private(set) var advanceCalls = 0

  func setParticipantRelayVerifier(_ verifier: (any BarnardRelayVerifier)?) {
    configureCalls += 1
    self.verifier = verifier
  }

  func advanceParticipantRelay() {
    advanceCalls += 1
  }
}

/// This app's answer to spec 134 step 3, and when relay is on at all (beid#367).
///
/// The accept case is one of many; everything else refuses. Relay puts an
/// authority-signed statement on the air from this device, so the gate is
/// built to fail closed and most of these tests are about the refusals.
@MainActor
final class ParticipantRelayTests: XCTestCase {
  private let eventIdHex =
    "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
  private let otherEventIdHex =
    "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100"
  private let hashHex = "6c86c6aac5fb24bc"
  private let envelopeHex = "11223344"

  // MARK: - The gate

  func testRegistryVerifiedEnvelopeForTheJoinedEventRelays() {
    let result = verification(state: gateState(joinedEventIdHex: eventIdHex))

    guard case .registryVerified(_, let validFrom, let validThrough, let expires) = result else {
      return XCTFail("expected the envelope to be relayable, got \(result)")
    }
    XCTAssertEqual(validFrom, 995)
    XCTAssertEqual(validThrough, 1_100)
    // The signed relay expiry is not readable from a verified envelope, so
    // the answer is the smallest value that cannot overstate it.
    XCTAssertEqual(expires, 1_001)
  }

  func testADeviceThatIsNotJoinedRelaysNothing() {
    XCTAssertEqual(verification(state: gateState(joinedEventIdHex: nil)), .rejected)
  }

  func testADeviceJoinedToAnotherEventRelaysNothing() {
    XCTAssertEqual(
      verification(state: gateState(joinedEventIdHex: otherEventIdHex)),
      .rejected
    )
  }

  func testRadioSelfVerificationAloneNeverRelays() {
    XCTAssertEqual(
      verification(state: gateState(joinedEventIdHex: eventIdHex, promote: false)),
      .rejected
    )
  }

  /// The tier alone is not the gate. Without the definition this app read,
  /// Barnard's own comparison cannot be re-run, and an answer that skipped it
  /// would trust a stored flag rather than the bytes in hand.
  func testAPromotedHashWithNoCachedDefinitionRelaysNothing() {
    XCTAssertEqual(
      verification(state: gateState(joinedEventIdHex: eventIdHex, cacheDefinition: false)),
      .rejected
    )
  }

  func testAnEnvelopeThatNoLongerAgreesWithTheDefinitionRelaysNothing() {
    XCTAssertEqual(
      verification(state: gateState(joinedEventIdHex: eventIdHex), agrees: false),
      .rejected
    )
  }

  /// The registry-verified tier is earned by specific bytes and does not
  /// carry over to a different envelope sharing the event-code hash.
  func testAnEnvelopeOtherThanTheRetainedOneIsRefused() {
    XCTAssertEqual(
      verification(state: gateState(joinedEventIdHex: eventIdHex), signedEnvelopeHex: "aabbccdd"),
      .rejected
    )
  }

  /// Bytes that are not a container never reach any of the above.
  func testUnparseableBytesAreRefusedByTheVerifierItself() {
    let verifier = ParticipantRelayVerifier(state: gateState(joinedEventIdHex: eventIdHex))

    XCTAssertEqual(
      verifier.verifyRelayEnvelope([UInt8](repeating: 0x7f, count: 8), currentEnin: 1_000),
      .rejected
    )
  }

  // MARK: - Lifecycle

  func testSensingWithoutPermissionLeavesTheRelayOff() {
    let control = RecordingParticipantRelayControl()
    _ = makeIsolatedSensingCoordinator(for: self, participantRelayControl: control)

    XCTAssertNil(control.verifier)
  }

  func testLeavingTheEventClearsTheRelay() {
    let control = RecordingParticipantRelayControl()
    let coordinator = makeIsolatedSensingCoordinator(for: self, participantRelayControl: control)

    coordinator.leaveEvent()

    XCTAssertNil(control.verifier)
    XCTAssertGreaterThan(control.configureCalls, 0)
  }

  func testEndingTheSessionClearsTheRelay() {
    let control = RecordingParticipantRelayControl()
    let coordinator = makeIsolatedSensingCoordinator(for: self, participantRelayControl: control)

    _ = coordinator.stopSensing()

    XCTAssertNil(control.verifier)
    XCTAssertGreaterThan(control.configureCalls, 0)
  }

  /// A reset leaves the engine scanning, and relay must stop anyway: it is a
  /// property of an active sensing session, not of the transport.
  func testResettingClearsTheRelay() {
    let control = RecordingParticipantRelayControl()
    let coordinator = makeIsolatedSensingCoordinator(for: self, participantRelayControl: control)

    _ = coordinator.reset()

    XCTAssertNil(control.verifier)
  }

  // MARK: - Visibility

  func testARelayDecisionIsSurfacedForVisibility() {
    let coordinator = makeIsolatedSensingCoordinator(for: self)

    coordinator.handleRelayDecision(
      decision: "broadcast",
      payloadDigestHex: "0a0b",
      hop: 1,
      reason: "elected"
    )

    XCTAssertEqual(
      coordinator.lastRelayDecision,
      ParticipantRelayDecision(
        decision: "broadcast",
        payloadDigestHex: "0a0b",
        hop: 1,
        reason: "elected"
      )
    )
  }

  // MARK: - Fixtures

  private func verification(
    state: ParticipantRelayGateState,
    signedEnvelopeHex: String? = nil,
    agrees: Bool = true
  ) -> BarnardRelayVerification {
    participantRelayVerification(
      state: state,
      signedEnvelopeHex: signedEnvelopeHex ?? envelopeHex,
      eventCodeHashHex: hashHex,
      eventId: hexBytes(eventIdHex),
      validFromEnin: 995,
      validThroughEnin: 1_100,
      currentEnin: 1_000,
      agreesWithDefinition: { _ in agrees }
    )
  }

  private func gateState(
    joinedEventIdHex: String?,
    promote: Bool = true,
    cacheDefinition: Bool = true
  ) -> ParticipantRelayGateState {
    ParticipantRelayGateState(
      candidates: candidates(promote: promote),
      verifiedDefinitionsByHash: cacheDefinition ? [hashHex: definition] : [:],
      joinedEventIdHex: joinedEventIdHex
    )
  }

  private var definition: BarnardEventDefinitionV1 {
    BarnardEventDefinitionV1(
      eventId: hexBytes(eventIdHex),
      keySetDigest: [UInt8](repeating: 0, count: 32),
      joinMode: 0,
      eventCodeHash: hexBytes(hashHex),
      validFromUnixSeconds: 0,
      validUntilUnixSeconds: 1
    )
  }

  private func candidates(
    promote: Bool
  ) -> ExportedKotlinPackages.org.levarac.parallax.discovery.NearbyEventCandidates {
    let store = ExportedKotlinPackages.org.levarac.parallax.discovery
      .createNearbyEventDiscoveryStore()
    // A four-byte delivery header (0x03, hop 0, length 4) plus the envelope.
    _ = ExportedKotlinPackages.org.levarac.parallax.discovery
      .recordNearbyEventRadioSelfVerifiedEnvelopeFromHex(
        store: store,
        peripheralId: "peripheral-a",
        eventDisplayName: "Community night",
        eventCodeHashHex: hashHex,
        rawContainerHex: "03000004" + envelopeHex,
        agreesWithRegistry: false,
        additionalNamesOmitted: false,
        additionalEventsOmitted: false,
        observedAtEpochMillis: 1
      )
    guard promote else { return store.snapshot }
    guard
      let attempt = ExportedKotlinPackages.org.levarac.parallax.discovery
        .beginNearbyEventRegistryResolutionFromHex(
          store: store,
          eventCodeHashHex: hashHex
        )
    else {
      preconditionFailure("the hash has no registry resolution to complete")
    }
    return ExportedKotlinPackages.org.levarac.parallax.discovery
      .completeNearbyEventRegistryResolutionFromHex(
        store: store,
        attempt: attempt,
        result: .VERIFIED,
        resolvedEventIdHex: eventIdHex,
        verifiedDefinitionJoinMode: .OPEN,
        verifiedDefinitionEventIdHex: eventIdHex,
        verifiedDefinitionEventCodeHashHex: hashHex,
        envelopeAgreesWithRegistry: true
      ).snapshot
  }

  private func hexBytes(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map { offset in
      let start = hex.index(hex.startIndex, offsetBy: offset)
      let end = hex.index(start, offsetBy: 2)
      return UInt8(hex[start..<end], radix: 16) ?? 0
    }
  }
}
