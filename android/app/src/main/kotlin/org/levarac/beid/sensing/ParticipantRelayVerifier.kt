package org.levarac.beid.sensing

import android.util.Log
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
            reportRefusal = ::logRelayRefusal,
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
    /**
     * Where a refusal reason goes. Defaults to discarding it: the production
     * caller above passes [logRelayRefusal] explicitly, and defaulting to that
     * instead would make every plain JVM test throw, because `android.util.Log`
     * is not mocked in one.
     */
    reportRefusal: (String) -> Unit = {},
): BarnardRelayVerification {
    val eligibility = nearbyEventRelayEligibility(
        candidates = state.candidates,
        signedEnvelopeHex = signedEnvelopeHex,
        eventCodeHashHex = eventCodeHashHex,
        envelopeEventIdHex = eventId.toHexString(),
        joinedEventIdHex = state.joinedEventIdHex,
    )
    if (eligibility != NearbyEventRelayEligibility.ELIGIBLE) {
        // The reason, not just the refusal. The shared gate names six of them
        // precisely so a venue where nothing relays can be told apart from a
        // venue with nothing to relay, and dropping the answer here would make
        // that distinction unobservable. The name of a refusal carries no
        // identifier: no hash, no event id, no peer.
        reportRefusal(eligibility.name)
        return BarnardRelayVerification.Rejected
    }

    // The shared gate already required a hash this host promoted, which it
    // only does on agreement. Re-running barnard's own comparison against the
    // definition that promotion used costs one pure call and makes agreement a
    // property of these bytes, rather than something inherited through a
    // stored tier.
    val definition = state.verifiedDefinitionsByHash[eventCodeHashHex]
    if (definition == null) {
        reportRefusal("NO_CACHED_DEFINITION")
        return BarnardRelayVerification.Rejected
    }
    if (!agreesWithDefinition(definition)) {
        reportRefusal("DEFINITION_DISAGREES")
        return BarnardRelayVerification.Rejected
    }

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
        // authority signed. Tracked upstream as levarac/barnard#197: once the
        // verified envelope exposes `relayExpiresAtEnin`, this becomes a plain
        // echo of the signed field and the per-ENIN re-admission goes away.
        relayExpiresAtEnin = currentEnin + 1,
    )
}

private fun ByteArray.toHexString(): String =
    joinToString(separator = "") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }

/**
 * Relay diagnostics. Its own tag so relay decisions filter apart from the rest
 * of sensing, and nothing written under it identifies a person, a device, or
 * an event -- a refusal reason is a constant name from a fixed set.
 *
 * Passed in at the call site rather than called directly, because
 * `android.util.Log` throws in a plain JVM unit test and the refusal reasons
 * are worth asserting rather than merely worth printing.
 */
internal fun logRelayRefusal(reason: String) {
    // Diagnostics must never change a relay decision, so a logger that cannot
    // write is ignored rather than propagated. `android.util.Log` throws
    // outright in a plain JVM unit test, and a test exercising the real
    // verifier would otherwise fail inside a log call rather than on anything
    // it set out to assert. Narrow on purpose: the unmocked stub raises a
    // `RuntimeException`, while an `Error` -- an exhausted heap, say -- is not
    // this function's to swallow.
    try {
        Log.d(RELAY_LOG_TAG, "b005 relay refused: $reason")
    } catch (_: RuntimeException) {
        // The logger is unavailable. There is nothing to report it to.
    }
}

private const val RELAY_LOG_TAG = "BeidRelay"
