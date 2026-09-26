// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

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
  /// Only `joinable: true` retains these. `nearbyCandidateJoinEligibility`
  /// refuses with `INCOMPLETE_REGISTRY_EVIDENCE` unless the digest, the block
  /// hash and both validity bounds all survived the resolution, so a fixture
  /// that omits them cannot produce a `RegistryVerifiedJoinContext` at all.
  private let definitionHashHex = String(repeating: "b", count: 64)
  private let registryBlockHashHex = String(repeating: "c", count: 64)
  private let joinableValidFrom: Int64 = 900
  private let joinableValidUntil: Int64 = 1_100
  private let joinableNowEpochSeconds: Int64 = 1_000

  // MARK: - The gate

  func testRegistryVerifiedEnvelopeForTheJoinedEventRelays() {
    let result = verification(state: gateState(joinedEventIdHex: eventIdHex))

    guard case .registryVerified(_, let validFrom, let validThrough, let expires) = result else {
      return XCTFail("expected the envelope to be relayable, got \(result)")
    }
    XCTAssertEqual(validFrom, 995)
    XCTAssertEqual(validThrough, 1_100)
    // The verified SDK envelope supplies the signed deadline unchanged.
    XCTAssertEqual(expires, 1_080)
  }

  func testSignedExpiryIsUnchangedAtDifferentVerificationTimes() {
    for now: UInt32 in [996, 1_000, 1_050, 1_079] {
      let result = participantRelayVerification(
        state: gateState(joinedEventIdHex: eventIdHex),
        signedEnvelopeHex: envelopeHex,
        eventCodeHashHex: hashHex,
        eventId: hexBytes(eventIdHex),
        validFromEnin: 995,
        validThroughEnin: 1_100,
        currentEnin: now,
        relayExpiresAtEnin: 1_080,
        agreesWithDefinition: { _ in true }
      )
      guard case .registryVerified(_, _, _, let expires) = result else {
        return XCTFail("expected the envelope to be relayable at ENIN \(now), got \(result)")
      }
      XCTAssertEqual(expires, 1_080, "signed expiry must be preserved at \(now)")
    }
  }

  func testRelayWindowUsesTheSignedEnvelopeExpiry() {
    guard
      case .registryVerified(_, _, _, let expires) =
        verification(state: gateState(joinedEventIdHex: eventIdHex))
    else {
      return XCTFail("expected the envelope to be relayable")
    }

    XCTAssertEqual(expires, 1_080)
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
    coordinator.useDemoEventMode = false
    coordinator.startParticipantRelay()
    XCTAssertNotNil(control.verifier, "the relay must be armed before leaving can clear it")

    coordinator.leaveEvent()

    XCTAssertNil(control.verifier)
    XCTAssertGreaterThan(control.configureCalls, 0)
  }

  func testEndingTheSessionClearsTheRelay() {
    let control = RecordingParticipantRelayControl()
    let coordinator = makeIsolatedSensingCoordinator(for: self, participantRelayControl: control)
    coordinator.useDemoEventMode = false
    coordinator.startParticipantRelay()
    XCTAssertNotNil(control.verifier, "the relay must be armed before stopping can clear it")

    _ = coordinator.stopSensing()

    XCTAssertNil(control.verifier)
    XCTAssertGreaterThan(control.configureCalls, 0)
  }

  /// A reset leaves the engine scanning, and relay must stop anyway: it is a
  /// property of an active sensing session, not of the transport.
  ///
  /// The relay is armed first on purpose. An earlier version of this test
  /// asserted a verifier that had been nil since construction, so it passed
  /// whether or not `reset()` tore anything down: deleting the teardown left
  /// it green. Arming first is what makes the assertion about reset.
  func testResettingClearsTheRelay() {
    let control = RecordingParticipantRelayControl()
    let coordinator = makeIsolatedSensingCoordinator(for: self, participantRelayControl: control)
    coordinator.useDemoEventMode = false
    coordinator.startParticipantRelay()
    XCTAssertNotNil(control.verifier, "the relay must be armed before reset can clear it")
    let armedCalls = control.configureCalls

    _ = coordinator.reset()

    XCTAssertNil(control.verifier)
    XCTAssertGreaterThan(
      control.configureCalls,
      armedCalls,
      "reset must clear the relay rather than leave it configured"
    )
  }

  /// Selecting an event is not joining it, so it does not open the relay gate.
  ///
  /// The name and this comment were both corrected in beid#437, and what they
  /// used to claim is worth recording. This test called itself
  /// `testAJoinedEventWhoseDefinitionIsNotVerifiedKeepsTheGateClosed` and said
  /// that on iOS "joining still resolves a code to an event id and nothing
  /// more". Neither was true of what it runs: `SensingCoordinator.joinEvent`
  /// only *selects* — it records the code and the looked-up id and returns,
  /// never reaching the registry or the join gate — and the coordinator built
  /// here has no registry configured at all, so nothing could have joined even
  /// if it did. The gate is nil here because no join was attempted, not
  /// because an attempted join was refused.
  ///
  /// The refusal case it appeared to cover is covered elsewhere: the gate's
  /// own refusals live in `EventJoinGateTests`, and the admit case that opens
  /// the gate is `testAdmittingAVerifiedContextOpensTheRelayGateWithItsEventId`
  /// above. This is the relay-side half of
  /// `EventJoinGateTests.testSelectingAnEventDoesNotJoinBarnard`.
  func testSelectingAnEventDoesNotOpenTheRelayGate() {
    let coordinator = makeIsolatedSensingCoordinator(for: self)

    coordinator.joinEvent("community-night", canonicalEventIdHex: eventIdHex)

    XCTAssertNil(
      coordinator.relayGateJoinedEventIdHexForTesting,
      "selecting an event must not open the relay gate"
    )
    XCTAssertEqual(
      nearbyEventRelayEligibilityReason(
        joinedEventIdHex: coordinator.relayGateJoinedEventIdHexForTesting
      ),
      .NOT_JOINED
    )
  }

  // MARK: - The gate opens at join admit

  /// beid#437. The relay gate takes its event id from the verified join
  /// context the gate admitted, in the same shape as Android's
  /// `EventJoinCoordinator.beginVerifiedJoin`, rather than waiting for the
  /// separate identity-verification read to answer.
  ///
  /// The context here is built by `fromNearbyCandidate`, not by the
  /// `fromOperatorLookup` factory iOS actually wires in production. That is
  /// deliberate and it is a property of the test, not of the gate:
  /// `fromOperatorLookup` needs an `EventDefinitionResolution`, which Swift
  /// Export emits with only a `package` initializer, so no Swift test can
  /// build one — see the header of `EventJoinGateTests` for the full account.
  /// `applyJoinGateDecision` does not care which factory produced the
  /// capability, so the gate assertion holds either way; what this test does
  /// **not** cover is the operator-lookup path end to end.
  func testAdmittingAVerifiedContextOpensTheRelayGateWithItsEventId() throws {
    let relay = RecordingParticipantRelayControl()
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      participantRelayControl: relay,
      eventJoinControl: RecordingEventJoinControl()
    )
    coordinator.useDemoEventMode = false

    // Unwrapped separately from the assertion below: a nil here is a fixture
    // that failed to produce a capability, which must not read as a gate that
    // failed to open.
    let context = try XCTUnwrap(
      ExportedKotlinPackages.org.levarac.parallax.discovery
        .RegistryVerifiedJoinContext.Companion.shared.fromNearbyCandidate(
          candidates: candidates(promote: true, joinable: true),
          eventCodeHashHex: hashHex,
          nowEpochSeconds: joinableNowEpochSeconds
        ),
      "the fixture must produce a join context before the gate can be observed"
    )

    coordinator.applyJoinGateDecision(.admit(context))

    XCTAssertEqual(
      coordinator.relayGateJoinedEventIdHexForTesting,
      context.eventIdHex,
      "admitting a join must open the relay gate with the admitted context's event id"
    )
  }

  /// beid#437's other half: `stopParticipantRelay` is now the *only* closer,
  /// so it has to clear the stored id and not merely publish a nil alongside
  /// it. Every no-argument `republishRelayGateState` — a candidate snapshot
  /// arriving, a definition being cached, the relay being re-armed — rebuilds
  /// the gate from that property, so a stale id left behind would re-open a
  /// gate the user had already left. Before #437 this was covered by the
  /// identity-verification lifecycle clearing the property; that writer is
  /// gone, which is what makes this assertion load-bearing rather than
  /// incidental.
  func testStoppingTheRelayClearsTheStoredGateId() throws {
    let relay = RecordingParticipantRelayControl()
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      participantRelayControl: relay,
      eventJoinControl: RecordingEventJoinControl()
    )
    coordinator.useDemoEventMode = false
    let context = try XCTUnwrap(
      ExportedKotlinPackages.org.levarac.parallax.discovery
        .RegistryVerifiedJoinContext.Companion.shared.fromNearbyCandidate(
          candidates: candidates(promote: true, joinable: true),
          eventCodeHashHex: hashHex,
          nowEpochSeconds: joinableNowEpochSeconds
        ),
      "the fixture must produce a join context before the gate can be observed"
    )
    coordinator.applyJoinGateDecision(.admit(context))
    XCTAssertNotNil(
      coordinator.relayGateJoinedEventIdHexForTesting,
      "the gate must be open before stopping can be observed to close it"
    )

    coordinator.stopParticipantRelay()

    XCTAssertNil(
      coordinator.relayGateJoinedEventIdHexForTesting,
      "stopping the relay must clear the stored gate id, not just publish nil once"
    )
  }

  /// beid#437 addendum 2. A session boundary clears the gate even on the
  /// paths that reset **without** stopping the relay first.
  ///
  /// `resetSessionState` has three callers and only `endSensing` stops the
  /// relay before it; `startSensing` and `beginEventFoundSessionState` do not.
  /// Before #437 the gate was cleared on those two anyway, transitively:
  /// `resetSessionState` calls `invalidateEventIdentityVerification`, which
  /// used to write nil to the gate. #437 removes that write, so without a
  /// closer on `resetSessionState` itself a joined event's id would outlive
  /// the session it belonged to.
  ///
  /// Asserted by construction rather than by reachability: whether a
  /// no-argument republish can actually fire on those paths before the next
  /// admit is not the point, because a stale id must not cross a session
  /// boundary at all.
  func testStartingANewSessionClearsTheGateWithoutStoppingTheRelayFirst() throws {
    let relay = RecordingParticipantRelayControl()
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      participantRelayControl: relay,
      eventJoinControl: RecordingEventJoinControl()
    )
    coordinator.useDemoEventMode = false
    let context = try XCTUnwrap(
      ExportedKotlinPackages.org.levarac.parallax.discovery
        .RegistryVerifiedJoinContext.Companion.shared.fromNearbyCandidate(
          candidates: candidates(promote: true, joinable: true),
          eventCodeHashHex: hashHex,
          nowEpochSeconds: joinableNowEpochSeconds
        ),
      "the fixture must produce a join context before the gate can be observed"
    )
    coordinator.applyJoinGateDecision(.admit(context))
    XCTAssertNotNil(
      coordinator.relayGateJoinedEventIdHexForTesting,
      "the gate must be open before a reset can be observed to clear it"
    )

    // Resets at its third statement, before any permission work, and does not
    // stop the relay on the way.
    coordinator.startSensing()

    XCTAssertNil(
      coordinator.relayGateJoinedEventIdHexForTesting,
      "a session boundary must clear the stored gate id even when the relay was never stopped"
    )
  }

  /// beid#437 addendum 3. A phase transition inside the joined event does not
  /// close the relay gate.
  ///
  /// `handleDetection`'s `.sensing` case calls `beginEventFoundSessionState`,
  /// which calls `resetSessionState`. That is the sensing-to-eventFound
  /// transition **inside** the event this device is joined to — the first peer
  /// detection — not a session boundary. A closer attached to
  /// `resetSessionState` therefore shut the gate at the exact moment relay
  /// starts to matter, and nothing reopened it, because the only opener is the
  /// join admit that had already happened.
  ///
  /// **The acceptance criteria for #437 never asked for this**, which is why
  /// two full-suite mutation runs came back clean: mutation shows a guard has
  /// a witness, and cannot show a guard fires where it should not, because the
  /// objecting test does not exist so nothing goes red.
  ///
  /// Asserts the published value as well as the stored one. They have to move
  /// together, and a test reading only the stored side cannot tell a published
  /// closure from a forgotten one.
  func testAPhaseTransitionInsideTheJoinedEventLeavesTheGateOpen() throws {
    let relay = RecordingParticipantRelayControl()
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      participantRelayControl: relay,
      eventJoinControl: RecordingEventJoinControl()
    )
    coordinator.useDemoEventMode = false
    // Reaches `.sensing` so the detection below takes the transition branch.
    coordinator.startSensing(eventCode: "community-night")
    let context = try XCTUnwrap(
      ExportedKotlinPackages.org.levarac.parallax.discovery
        .RegistryVerifiedJoinContext.Companion.shared.fromNearbyCandidate(
          candidates: candidates(promote: true, joinable: true),
          eventCodeHashHex: hashHex,
          nowEpochSeconds: joinableNowEpochSeconds
        ),
      "the fixture must produce a join context before the gate can be observed"
    )
    coordinator.applyJoinGateDecision(.admit(context))
    XCTAssertEqual(
      coordinator.relayGateJoinedEventIdHexForTesting,
      context.eventIdHex,
      "the gate must be open before the transition can be observed to leave it alone"
    )

    coordinator.handleDetection(enin: 1, rpid: "peer-0", detectedDisplayId: nil)

    // Asserted first, and it is what stops this test being vacuous. Everything
    // below only means something if the detection actually took the `.sensing`
    // branch and reached `beginEventFoundSessionState`. Without this, a later
    // change that stopped the transition from firing would leave the gate
    // trivially open and the test would still pass — reporting that a
    // transition it never made does not close the gate.
    guard case .eventFound = coordinator.phase else {
      return XCTFail(
        "the detection must take the sensing-to-eventFound transition, or this test proves nothing"
      )
    }

    XCTAssertEqual(
      coordinator.relayGateJoinedEventIdHexForTesting,
      context.eventIdHex,
      "a phase transition inside the joined event must not close the relay gate"
    )
    let verifier = try XCTUnwrap(
      relay.verifier as? ParticipantRelayVerifier,
      "the relay must be armed with this app's verifier once the join is admitted"
    )
    XCTAssertEqual(
      verifier.publishedJoinedEventIdHexForTesting,
      context.eventIdHex,
      "the published gate id must survive the transition too, not only the stored one"
    )
  }

  // MARK: - Cadence

  /// The counterpart of Android's
  /// `theHostRunsTheRelayForwardOnTheDecisionBoundary`. Barnard self-ticks
  /// too, so this asserts that the host's own wake-up exists, not that it is
  /// the only thing ending a lease.
  func testTheHostRunsTheRelayForwardOnTheDecisionBoundary() async throws {
    let control = RecordingParticipantRelayControl()
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      participantRelayControl: control,
      relayCadenceNanoseconds: 10_000_000
    )

    // Demo mode never arms the relay, so the real path is what is under test.
    coordinator.useDemoEventMode = false
    coordinator.startParticipantRelay()
    XCTAssertNotNil(control.verifier)
    XCTAssertEqual(control.advanceCalls, 0)

    try await waitForRelayAdvance(on: control)
    XCTAssertGreaterThanOrEqual(control.advanceCalls, 1)
  }

  /// The counterpart of Android's `theCadenceStopsWhenTheEventIsLeft`.
  func testTheCadenceStopsWhenTheEventIsLeft() async throws {
    let control = RecordingParticipantRelayControl()
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      participantRelayControl: control,
      relayCadenceNanoseconds: 10_000_000
    )
    coordinator.useDemoEventMode = false
    coordinator.startParticipantRelay()

    coordinator.leaveEvent()
    let afterLeaving = control.advanceCalls
    try await Task.sleep(nanoseconds: 300_000_000)

    XCTAssertEqual(
      control.advanceCalls,
      afterLeaving,
      "a cancelled cadence must not keep running the relay forward"
    )
  }

  // MARK: - Visibility

  func testARelayDecisionIsSurfacedForVisibility() {
    let coordinator = makeIsolatedSensingCoordinator(for: self)

    coordinator.handleRelayDecision(
      decision: .broadcast,
      payloadDigestHex: "0a0b",
      hop: 1,
      reason: "elected"
    )

    XCTAssertEqual(
      coordinator.lastRelayDecision,
      ParticipantRelayDecision(
        decision: .broadcast,
        payloadDigestHex: "0a0b",
        hop: 1,
        reason: "elected"
      )
    )
  }

  // MARK: - Fixtures

  /// Polls rather than sleeping for the full boundary: the cadence is 30
  /// seconds in production, and a test that waited for it would spend that
  /// long doing nothing.
  private func waitForRelayAdvance(
    on control: RecordingParticipantRelayControl
  ) async throws {
    for _ in 0..<200 {
      if control.advanceCalls > 0 { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("the relay cadence never ran the relay forward")
  }

  private func nearbyEventRelayEligibilityReason(
    joinedEventIdHex: String?
  ) -> ExportedKotlinPackages.org.levarac.parallax.discovery.NearbyEventRelayEligibility {
    ExportedKotlinPackages.org.levarac.parallax.discovery.nearbyEventRelayEligibility(
      candidates: candidates(promote: true),
      signedEnvelopeHex: envelopeHex,
      eventCodeHashHex: hashHex,
      envelopeEventIdHex: eventIdHex,
      joinedEventIdHex: joinedEventIdHex
    )
  }

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
      relayExpiresAtEnin: 1_080,
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
    promote: Bool,
    joinable: Bool = false
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
        envelopeAgreesWithRegistry: true,
        verifiedDefinitionHashHex: joinable ? definitionHashHex : nil,
        registryBlockHashHex: joinable ? registryBlockHashHex : nil,
        verifiedDefinitionValidFromEpochSeconds: joinable ? joinableValidFrom : nil,
        verifiedDefinitionValidUntilEpochSeconds: joinable ? joinableValidUntil : nil
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
