package org.levarac.beid.sensing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.levarac.barnard.BarnardEventDefinitionV1
import org.levarac.barnard.BarnardRelayVerification
import org.levarac.parallax.discovery.NearbyEventCandidates
import org.levarac.parallax.discovery.NearbyEventRegistryResolutionResult
import org.levarac.parallax.discovery.beginNearbyEventRegistryResolutionFromHex
import org.levarac.parallax.discovery.completeNearbyEventRegistryResolutionFromHex
import org.levarac.parallax.discovery.createNearbyEventDiscoveryStore
import org.levarac.parallax.discovery.recordNearbyEventRadioSelfVerifiedEnvelope
import org.levarac.parallax.registry.EventJoinMode

/**
 * This host's answer to spec 134 step 3 (beid#367).
 *
 * The accept case is one of many; everything else refuses. Relay puts an
 * authority-signed statement on the air from this device, so the gate is built
 * to fail closed and these tests are mostly about the refusals.
 */
class ParticipantRelayVerifierTest {
    @Test
    fun `a registry-verified envelope for the joined event relays`() {
        val result = verification(gateState(joinedEventIdHex = EVENT_ID))

        assertTrue(result is BarnardRelayVerification.RegistryVerified)
        val verified = result as BarnardRelayVerification.RegistryVerified
        assertEquals(VALID_FROM, verified.validFromEnin)
        assertEquals(VALID_THROUGH, verified.validThroughEnin)
    }

    /**
     * The signed relay expiry is not readable from a verified envelope, so the
     * answer is the smallest value that cannot overstate it. It must always be
     * the very next ENIN, never anything further out.
     */
    @Test
    fun `the relay window never reaches past the next ENIN`() {
        val verified = verification(gateState(joinedEventIdHex = EVENT_ID))
            as BarnardRelayVerification.RegistryVerified

        assertEquals(NOW + 1, verified.relayExpiresAtEnin)
    }

    @Test
    fun `a device that is not joined relays nothing`() {
        assertEquals(
            BarnardRelayVerification.Rejected,
            verification(gateState(joinedEventIdHex = null)),
        )
    }

    @Test
    fun `a device joined to another event relays nothing`() {
        assertEquals(
            BarnardRelayVerification.Rejected,
            verification(gateState(joinedEventIdHex = OTHER_EVENT_ID)),
        )
    }

    @Test
    fun `radio self-verification alone never relays`() {
        assertEquals(
            BarnardRelayVerification.Rejected,
            verification(gateState(joinedEventIdHex = EVENT_ID, promote = false)),
        )
    }

    /**
     * The tier alone is not the gate. Without the definition this host read,
     * barnard's own comparison cannot be re-run, and an answer that skipped it
     * would be trusting a stored flag instead of the bytes in hand.
     */
    @Test
    fun `a promoted hash with no cached definition relays nothing`() {
        assertEquals(
            BarnardRelayVerification.Rejected,
            verification(gateState(joinedEventIdHex = EVENT_ID, cacheDefinition = false)),
        )
    }

    @Test
    fun `an envelope that no longer agrees with the definition relays nothing`() {
        assertEquals(
            BarnardRelayVerification.Rejected,
            verification(gateState(joinedEventIdHex = EVENT_ID), agrees = false),
        )
    }

    /** Bytes that are not a container never reach any of the above. */
    @Test
    fun `unparseable bytes are refused by the verifier itself`() {
        val verifier = ParticipantRelayVerifier { gateState(joinedEventIdHex = EVENT_ID) }

        assertEquals(
            BarnardRelayVerification.Rejected,
            verifier.verify(ByteArray(8) { 0x7f }, NOW),
        )
    }

    private fun verification(
        state: ParticipantRelayGateState,
        agrees: Boolean = true,
    ): BarnardRelayVerification = participantRelayVerification(
        state = state,
        signedEnvelopeHex = ENVELOPE_HEX,
        eventCodeHashHex = HASH,
        eventId = EVENT_ID.hexBytes(),
        validFromEnin = VALID_FROM,
        validThroughEnin = VALID_THROUGH,
        currentEnin = NOW,
        agreesWithDefinition = { agrees },
    )

    private fun gateState(
        joinedEventIdHex: String?,
        promote: Boolean = true,
        cacheDefinition: Boolean = true,
    ): ParticipantRelayGateState = ParticipantRelayGateState(
        candidates = candidates(promote),
        verifiedDefinitionsByHash = if (cacheDefinition) mapOf(HASH to DEFINITION) else emptyMap(),
        joinedEventIdHex = joinedEventIdHex,
    )

    private fun candidates(promote: Boolean): NearbyEventCandidates {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventRadioSelfVerifiedEnvelope(
            store = store,
            peripheralId = "p",
            eventDisplayName = "Event",
            eventCodeHash = HASH.hexBytes(),
            rawContainer = CONTAINER,
            agreesWithRegistry = false,
            additionalNamesOmitted = false,
            additionalEventsOmitted = false,
            observedAtEpochMillis = 1L,
        )
        if (!promote) return store.snapshot
        val attempt = requireNotNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
        return completeNearbyEventRegistryResolutionFromHex(
            store = store,
            attempt = attempt,
            result = NearbyEventRegistryResolutionResult.VERIFIED,
            resolvedEventIdHex = EVENT_ID,
            verifiedDefinitionJoinMode = EventJoinMode.OPEN,
            verifiedDefinitionEventIdHex = EVENT_ID,
            verifiedDefinitionEventCodeHashHex = HASH,
            envelopeAgreesWithRegistry = true,
        ).snapshot
    }

    private companion object {
        const val EVENT_ID = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        const val OTHER_EVENT_ID = "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100"
        const val HASH = "6c86c6aac5fb24bc"
        const val ENVELOPE_HEX = "11223344"
        const val NOW = 1_000L
        const val VALID_FROM = 995L
        const val VALID_THROUGH = 1_100L
        val CONTAINER = byteArrayOf(3, 0, 0, 4, 0x11, 0x22, 0x33, 0x44)
        val DEFINITION = BarnardEventDefinitionV1(
            eventId = EVENT_ID.hexBytes(),
            keySetDigest = ByteArray(32),
            joinMode = 0,
            eventCodeHash = HASH.hexBytes(),
            validFromUnixSeconds = 0L,
            validUntilUnixSeconds = 1L,
        )
    }
}

private fun String.hexBytes(): ByteArray =
    chunked(2).map { it.toInt(16).toByte() }.toByteArray()
