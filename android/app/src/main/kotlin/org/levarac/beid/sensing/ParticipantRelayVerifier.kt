package org.levarac.beid.sensing

import org.levarac.barnard.BarnardB005EnvelopeV2
import org.levarac.barnard.BarnardEventDefinitionV1
import org.levarac.barnard.BarnardRegistryAgreement
import org.levarac.barnard.BarnardRelayVerification
import org.levarac.barnard.BarnardRelayVerifier
import org.levarac.parallax.discovery.NearbyEventCandidates
import org.levarac.parallax.discovery.NearbyEventRelayEligibility
import org.levarac.parallax.discovery.nearbyEventRelayEligibility

/**
 * Everything the relay gate reads, captured as one immutable value.
 *
 * barnard calls a relay verifier inline on the thread its GATT read arrived
 * on, while this host builds discovery state on the main thread. Handing the
 * verifier a value rather than a live session is what keeps that safe: there
 * is nothing to read half-updated, and nothing to lock.
 */
internal data class ParticipantRelayGateState(
    val candidates: NearbyEventCandidates,
    val verifiedDefinitionsByHash: Map<String, BarnardEventDefinitionV1>,
    val joinedEventIdHex: String?,
)

/**
 * This host's answer to barnard's spec 134 step 3 (beid#367).
 *
 * barnard pre-filters: only an envelope its own radio verification accepted
 * ever reaches here. What it cannot answer is whether the event is actually
 * registered, because the SDK has no registry access — so `RADIO_SELF_VERIFIED`
 * alone never relays, and this verifier says yes only for an envelope this
 * host's own authenticated registry read already confirmed.
 *
 * It performs no lookup of its own. Both inputs are the beid#376 discovery
 * state a card is already drawn from, so a card that is not shown as verified
 * cannot be relayed either.
 *
 * Nothing here touches recording, signing, or submission, and nothing may be
 * added that does: `ParticipantRelayIsolationTest` pins that.
 */
internal class ParticipantRelayVerifier(
    private val gateState: () -> ParticipantRelayGateState,
) : BarnardRelayVerifier {
    override fun verify(envelope: ByteArray, currentEnin: Long): BarnardRelayVerification {
        // barnard hands over the signed envelope, not the container it arrived
        // in. Re-wrapping at hop zero recovers a shape `verify` accepts; the
        // hop this device would actually serve is barnard's to decide and is
        // not an input to any check below.
        val container = BarnardB005EnvelopeV2.encodeContainer(0, envelope)
            ?: return BarnardRelayVerification.Rejected
        val verified = BarnardB005EnvelopeV2.verify(container, currentEnin)
            ?: return BarnardRelayVerification.Rejected

        return participantRelayVerification(
            state = gateState(),
            signedEnvelopeHex = envelope.toHexString(),
            eventCodeHashHex = verified.eventCodeHash.toHexString(),
            eventId = verified.eventId,
            validFromEnin = verified.validFromEnin,
            validThroughEnin = verified.validThroughEnin,
            currentEnin = currentEnin,
            agreesWithDefinition = { definition ->
                BarnardB005EnvelopeV2.registryAgreement(verified, definition) is BarnardRegistryAgreement.Agrees
            },
        )
    }
}

/**
 * Everything the gate decides once barnard has verified the bytes.
 *
 * Split out from [ParticipantRelayVerifier.verify] for the same reason
 * `handleEventInfoEnvelopeV2` takes plain arguments on both hosts: a
 * `BarnardB005VerifiedEnvelope` can only be produced by barnard's own
 * verification of a genuinely signed envelope, so a test could otherwise not
 * reach any of this at all.
 */
internal fun participantRelayVerification(
    state: ParticipantRelayGateState,
    signedEnvelopeHex: String,
    eventCodeHashHex: String,
    eventId: ByteArray,
    validFromEnin: Long,
    validThroughEnin: Long,
    currentEnin: Long,
    agreesWithDefinition: (BarnardEventDefinitionV1) -> Boolean,
): BarnardRelayVerification {
    val eligibility = nearbyEventRelayEligibility(
        candidates = state.candidates,
        signedEnvelopeHex = signedEnvelopeHex,
        eventCodeHashHex = eventCodeHashHex,
        envelopeEventIdHex = eventId.toHexString(),
        joinedEventIdHex = state.joinedEventIdHex,
    )
    if (eligibility != NearbyEventRelayEligibility.ELIGIBLE) {
        return BarnardRelayVerification.Rejected
    }

    // The shared gate already required a hash this host promoted, which it
    // only does on agreement. Re-running barnard's own comparison against the
    // definition that promotion used costs one pure call and makes agreement a
    // property of these bytes, rather than something inherited through a
    // stored tier.
    val definition = state.verifiedDefinitionsByHash[eventCodeHashHex]
        ?: return BarnardRelayVerification.Rejected
    if (!agreesWithDefinition(definition)) return BarnardRelayVerification.Rejected

    return BarnardRelayVerification.RegistryVerified(
        eventId = eventId,
        validFromEnin = validFromEnin,
        validThroughEnin = validThroughEnin,
        // The envelope's signed `relayExpiresAtEnin` is not exposed on
        // `BarnardB005VerifiedEnvelope`, although barnard enforced it a moment
        // ago -- so the honest answer is the smallest one that can never
        // overstate it. Verification succeeded, so the current ENIN is
        // strictly inside the signed relay window, which makes the next ENIN
        // no later than the signed expiry. The cost is that a candidate lapses
        // after one ENIN and needs a fresh observation, which re-verifies and
        // so re-checks the true expiry. Nothing here can outlive what the
        // authority signed. Tracked upstream: expose `relayExpiresAtEnin` and
        // this becomes a plain echo.
        relayExpiresAtEnin = currentEnin + 1,
    )
}

private fun ByteArray.toHexString(): String =
    joinToString(separator = "") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }
