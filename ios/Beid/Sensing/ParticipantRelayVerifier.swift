// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Barnard
import BarnardCore
import BeidSharedKit
import Foundation
import os

/// Relay diagnostics. Its own category so relay decisions filter apart from
/// the sensing and ledger logs, and `.public` throughout because none of what
/// it prints identifies a person, a device, or an event.
private let relayLog = Logger(subsystem: "org.levarac.beid", category: "relay")

/// The Barnard relay operations `SensingCoordinator` drives, behind a
/// protocol so a test can watch them.
///
/// Deliberately only two calls wide. The relay lives in Barnard; this app
/// decides whether it is on and answers whether one envelope may be
/// re-broadcast, and a wider seam would invite re-deciding things spec 134
/// already settles.
protocol ParticipantRelayControlling: AnyObject {
  /// Enables the relay, or disables it when `verifier` is nil. Disabling is
  /// what makes Barnard drop the lease, the density handles, and the cached
  /// envelope.
  ///
  /// Named apart from Barnard's own `configureParticipantRelay(verifier:...)`
  /// on purpose: an extension method sharing that name and a prefix of its
  /// argument labels would call itself.
  func setParticipantRelayVerifier(_ verifier: (any BarnardRelayVerifier)?)

  /// Runs the relay's 30-second lease decisions.
  func advanceParticipantRelay()
}

extension BarnardEngine: ParticipantRelayControlling {
  func setParticipantRelayVerifier(_ verifier: (any BarnardRelayVerifier)?) {
    configureParticipantRelay(
      verifier: verifier,
      joinedEventProvider: nil,
      randomnessSeedMaterial: nil,
      clock: nil,
      eninSource: nil
    )
  }
}

/// Everything the relay gate reads, captured as one immutable value.
///
/// Barnard calls a relay verifier inline on the queue its GATT read arrived
/// on, while this app builds discovery state on the main actor. Handing the
/// verifier a value rather than the coordinator is what keeps that safe:
/// there is nothing to read half-updated.
struct ParticipantRelayGateState {
  var candidates: ExportedKotlinPackages.org.levarac.parallax.discovery.NearbyEventCandidates
  var verifiedDefinitionsByHash: [String: BarnardEventDefinitionV1]
  /// The canonical event id this device is joined to, as resolved by this
  /// app's own registry read. Nil while not joined, and nil fails closed.
  var joinedEventIdHex: String?
}

/// One spec 134 relay decision, in a form this app owns (beid#367).
///
/// Purely diagnostic: it says whether this device is currently re-broadcasting
/// an event's information and why that started or stopped. It is inert
/// everywhere else. A relayed candidate is an ordinary card, its hop count is
/// never shown, and neither the hop nor the number of relays nearby is
/// evidence about the event — spec 134 is explicit that relay volume says
/// nothing about an event's popularity, authenticity, or attendance.
struct ParticipantRelayDecision: Equatable {
  var decision: BarnardRelayDecision
  /// `SHA256(signedEnvelope)`, which is already derivable from the wire.
  var payloadDigestHex: String
  var hop: Int
  var reason: String
}

/// This app's answer to Barnard's spec 134 step 3 (beid#367).
///
/// Barnard pre-filters: only an envelope its own radio verification accepted
/// ever reaches here. What it cannot answer is whether the event is actually
/// registered, because the SDK has no registry access — so `RADIO_SELF_VERIFIED`
/// alone never relays, and this verifier says yes only for an envelope this
/// app's own authenticated registry read already confirmed.
///
/// It performs no lookup of its own. Both inputs come from the beid#376
/// discovery state a card is already drawn from, so an event that is not shown
/// as verified cannot be relayed either.
///
/// Nothing here touches recording, signing, or submission, and nothing may be
/// added that does: `ParticipantRelayIsolationTests` pins that.
final class ParticipantRelayVerifier: BarnardRelayVerifier {
  private let lock = NSLock()
  private var state: ParticipantRelayGateState

  init(state: ParticipantRelayGateState) {
    self.state = state
  }

  /// Republishes what the gate reads. Called from the main actor only; the
  /// lock exists for the verifier's side of the hand-off.
  func update(_ state: ParticipantRelayGateState) {
    lock.lock()
    defer { lock.unlock() }
    self.state = state
  }

  private var currentState: ParticipantRelayGateState {
    lock.lock()
    defer { lock.unlock() }
    return state
  }

  func verifyRelayEnvelope(_ bytes: [UInt8], currentEnin: UInt32) -> BarnardRelayVerification {
    // Barnard hands over the signed envelope, not the container it arrived
    // in. Re-wrapping at hop zero recovers a shape `verify` accepts; the hop
    // this device would actually serve is Barnard's to decide and is not an
    // input to any check below.
    guard
      let container = BarnardB005EnvelopeV2.encodeContainer(relayHopCount: 0, signedEnvelope: bytes),
      let verified = BarnardB005EnvelopeV2.verify(
        container: container,
        currentEnin: Int64(currentEnin),
        nameValidator: BarnardB005NativeDisplayNameNormalizer()
      )
    else { return .rejected }

    return participantRelayVerification(
      state: currentState,
      signedEnvelopeHex: bytes.relayHexString,
      eventCodeHashHex: verified.eventCodeHash.relayHexString,
      eventId: verified.eventId,
      validFromEnin: verified.validFromEnin,
      validThroughEnin: verified.validThroughEnin,
      currentEnin: currentEnin,
      agreesWithDefinition: { definition in
        BarnardB005EnvelopeV2.registryAgreement(verified, definition: definition) == .agrees
      }
    )
  }
}

/// Everything the gate decides once Barnard has verified the bytes.
///
/// Split out from `verifyRelayEnvelope` for the same reason
/// `handleEventInfoEnvelopeV2` takes plain arguments: a
/// `BarnardB005VerifiedEnvelope` can only be produced by Barnard from
/// genuinely signed bytes, so a test could otherwise reach none of this.
func participantRelayVerification(
  state: ParticipantRelayGateState,
  signedEnvelopeHex: String,
  eventCodeHashHex: String,
  eventId: [UInt8],
  validFromEnin: Int64,
  validThroughEnin: Int64,
  currentEnin: UInt32,
  agreesWithDefinition: (BarnardEventDefinitionV1) -> Bool
) -> BarnardRelayVerification {
  let eventIdHex = eventId.relayHexString
  let eligibility = ExportedKotlinPackages.org.levarac.parallax.discovery
    .nearbyEventRelayEligibility(
      candidates: state.candidates,
      signedEnvelopeHex: signedEnvelopeHex,
      eventCodeHashHex: eventCodeHashHex,
      envelopeEventIdHex: eventIdHex,
      joinedEventIdHex: state.joinedEventIdHex
    )
  guard eligibility == .ELIGIBLE else {
    // The reason, not just the refusal. The shared gate names six of them
    // precisely so a venue where nothing relays can be told apart from a
    // venue with nothing to relay, and dropping the answer here would make
    // that distinction unobservable. The name of a refusal carries no
    // identifier: no hash, no event id, no peer.
    relayLog.debug("b005 relay refused: \(String(describing: eligibility), privacy: .public)")
    return .rejected
  }

  // The shared gate already required a hash this app promoted, which it only
  // does on agreement. Re-running Barnard's own comparison against the
  // definition that promotion used costs one pure call and makes agreement a
  // property of these bytes, rather than something inherited through a stored
  // tier.
  guard let definition = state.verifiedDefinitionsByHash[eventCodeHashHex] else {
    relayLog.debug("b005 relay refused: no cached definition for a promoted hash")
    return .rejected
  }
  guard agreesWithDefinition(definition) else {
    relayLog.debug("b005 relay refused: envelope no longer agrees with the definition")
    return .rejected
  }

  guard
    let validFrom = UInt32(exactly: max(0, validFromEnin)),
    let validThrough = UInt32(exactly: min(Int64(UInt32.max), max(0, validThroughEnin))),
    currentEnin < UInt32.max
  else { return .rejected }

  return .registryVerified(
    eventId: eventId,
    validFromEnin: validFrom,
    validThroughEnin: validThrough,
    // The envelope's signed `relayExpiresAtEnin` is not exposed on
    // `BarnardB005VerifiedEnvelope`, although Barnard enforced it a moment
    // ago — so the honest answer is the smallest one that can never overstate
    // it. Verification succeeded, so the current ENIN is strictly inside the
    // signed relay window, which makes the next ENIN no later than the signed
    // expiry. The cost is that a candidate lapses after one ENIN and needs a
    // fresh observation, which re-verifies and so re-checks the true expiry.
    // Nothing here can outlive what the authority signed. Tracked upstream as
    // levarac/barnard#197: once the verified envelope exposes
    // `relayExpiresAtEnin`, this becomes a plain echo of the signed field and
    // the per-ENIN re-admission goes away.
    relayExpiresAtEnin: currentEnin + 1
  )
}

private extension Array where Element == UInt8 {
  /// Lowercase hex, the form every identifier crosses the shared boundary in.
  /// A local copy rather than a shared one: `SensingCoordinator`'s equivalent
  /// is deliberately `fileprivate`, and widening it for relay would widen it
  /// for everything else too.
  var relayHexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
