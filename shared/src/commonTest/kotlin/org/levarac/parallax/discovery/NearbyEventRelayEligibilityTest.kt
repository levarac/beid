package org.levarac.parallax.discovery

import org.levarac.parallax.registry.EventJoinMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * The spec 134 relay gate, as both hosts must answer it (beid#367).
 *
 * Every case here is a refusal except one. That asymmetry is the point: relay
 * re-broadcasts an authority-signed statement from this device, so the gate
 * fails closed on anything it cannot positively confirm.
 */
class NearbyEventRelayEligibilityTest {
    @Test
    fun registryVerifiedEnvelopeForTheJoinedEventIsEligible() {
        val snapshot = registryVerifiedSnapshot()

        assertEquals(
            NearbyEventRelayEligibility.ELIGIBLE,
            eligibility(snapshot, joinedEventIdHex = EVENT_ID),
        )
        assertTrue(
            isNearbyEventRelayEligible(
                candidates = snapshot,
                signedEnvelopeHex = ENVELOPE_HEX,
                eventCodeHashHex = HASH,
                envelopeEventIdHex = EVENT_ID,
                joinedEventIdHex = EVENT_ID,
            ),
        )
    }

    @Test
    fun radioSelfVerifiedAloneNeverRelays() {
        val store = createNearbyEventDiscoveryStore()
        val snapshot = recordEnvelope(store).snapshot
        assertEquals(
            NearbyEventReceiverState.RADIO_SELF_VERIFIED,
            assertNotNull(snapshot.candidateAt(0)).receiverState,
        )

        assertEquals(
            NearbyEventRelayEligibility.NOT_REGISTRY_VERIFIED,
            eligibility(snapshot, joinedEventIdHex = EVENT_ID),
        )
    }

    @Test
    fun anUnjoinedDeviceRelaysNothing() {
        assertEquals(
            NearbyEventRelayEligibility.NOT_JOINED,
            eligibility(registryVerifiedSnapshot(), joinedEventIdHex = null),
        )
    }

    @Test
    fun aDeviceJoinedToAnotherEventRelaysNothing() {
        assertEquals(
            NearbyEventRelayEligibility.OTHER_EVENT,
            eligibility(registryVerifiedSnapshot(), joinedEventIdHex = OTHER_EVENT_ID),
        )
    }

    /**
     * The tier is earned by specific bytes. An envelope that merely shares the
     * event-code hash does not inherit it, because the registry agreement was
     * computed over the retained container's contents and not over these.
     */
    @Test
    fun anEnvelopeOtherThanTheRetainedOneIsRefused() {
        val snapshot = registryVerifiedSnapshot()

        assertEquals(
            NearbyEventRelayEligibility.CONTAINER_MISMATCH,
            eligibility(snapshot, joinedEventIdHex = EVENT_ID, signedEnvelopeHex = "aabbccdd"),
        )
    }

    /** A candidate built only from v1 hints retains no container at all. */
    @Test
    fun aHintOnlyCandidateIsRefused() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 1L)

        assertEquals(
            NearbyEventRelayEligibility.NOT_REGISTRY_VERIFIED,
            eligibility(store.snapshot, joinedEventIdHex = EVENT_ID),
        )
    }

    @Test
    fun anUnknownEventCodeHashIsRefused() {
        assertEquals(
            NearbyEventRelayEligibility.NOT_REGISTRY_VERIFIED,
            eligibility(
                registryVerifiedSnapshot(),
                joinedEventIdHex = EVENT_ID,
                eventCodeHashHex = "0011223344556677",
            ),
        )
    }

    /**
     * The hop count lives in the four-byte delivery header and changes at
     * every hop, so it must not take part in the comparison. Only the envelope
     * the signature covers does.
     */
    @Test
    fun theHopCountInTheRetainedHeaderDoesNotAffectTheMatch() {
        val store = createNearbyEventDiscoveryStore()
        val relayedContainer = CONTAINER.copyOf().also { it[1] = 1 }
        recordEnvelope(store, rawContainer = relayedContainer)
        val snapshot = resolveRegistry(store, agrees = true)

        assertEquals(
            NearbyEventRelayEligibility.ELIGIBLE,
            eligibility(snapshot, joinedEventIdHex = EVENT_ID),
        )
    }

    /** Case and an `0x` prefix are presentation, not identity. */
    @Test
    fun hexComparisonIgnoresCaseAndAnOxPrefix() {
        assertEquals(
            NearbyEventRelayEligibility.ELIGIBLE,
            eligibility(
                registryVerifiedSnapshot(),
                joinedEventIdHex = "0x" + EVENT_ID.uppercase(),
                signedEnvelopeHex = ENVELOPE_HEX.uppercase(),
            ),
        )
    }

    /**
     * Both sides of the hash comparison are normalized, so a caller that
     * spells the hash with different case or an `0x` prefix still finds its
     * candidate. Without this the gate would refuse silently, and a spelling
     * rather than a policy would have cost the relay.
     */
    @Test
    fun aHashSpelledDifferentlyStillFindsItsCandidate() {
        val snapshot = registryVerifiedSnapshot()

        assertEquals(
            NearbyEventRelayEligibility.ELIGIBLE,
            eligibility(snapshot, joinedEventIdHex = EVENT_ID, eventCodeHashHex = HASH.uppercase()),
        )
        assertEquals(
            NearbyEventRelayEligibility.ELIGIBLE,
            eligibility(snapshot, joinedEventIdHex = EVENT_ID, eventCodeHashHex = "0x" + HASH),
        )
    }

    @Test
    fun aMalformedJoinedEventIdFailsClosed() {
        assertEquals(
            NearbyEventRelayEligibility.NOT_JOINED,
            eligibility(registryVerifiedSnapshot(), joinedEventIdHex = "not-hex"),
        )
        assertFalse(
            isNearbyEventRelayEligible(
                candidates = registryVerifiedSnapshot(),
                signedEnvelopeHex = ENVELOPE_HEX,
                eventCodeHashHex = HASH,
                envelopeEventIdHex = EVENT_ID,
                joinedEventIdHex = "",
            ),
        )
    }

    private fun eligibility(
        candidates: NearbyEventCandidates,
        joinedEventIdHex: String?,
        signedEnvelopeHex: String = ENVELOPE_HEX,
        eventCodeHashHex: String = HASH,
        envelopeEventIdHex: String = EVENT_ID,
    ): NearbyEventRelayEligibility = nearbyEventRelayEligibility(
        candidates = candidates,
        signedEnvelopeHex = signedEnvelopeHex,
        eventCodeHashHex = eventCodeHashHex,
        envelopeEventIdHex = envelopeEventIdHex,
        joinedEventIdHex = joinedEventIdHex,
    )

    private fun registryVerifiedSnapshot(): NearbyEventCandidates {
        val store = createNearbyEventDiscoveryStore()
        recordEnvelope(store)
        return resolveRegistry(store, agrees = true)
    }

    private fun recordEnvelope(
        store: NearbyEventDiscoveryStore,
        rawContainer: ByteArray = CONTAINER,
    ): NearbyEventDiscoveryUpdate = recordNearbyEventRadioSelfVerifiedEnvelope(
        store = store,
        peripheralId = "p",
        eventDisplayName = "Event",
        eventCodeHash = HASH.hexBytes(),
        rawContainer = rawContainer,
        agreesWithRegistry = false,
        additionalNamesOmitted = false,
        additionalEventsOmitted = false,
        observedAtEpochMillis = 1L,
    )

    private fun resolveRegistry(
        store: NearbyEventDiscoveryStore,
        agrees: Boolean,
    ): NearbyEventCandidates {
        val attempt = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
        return completeNearbyEventRegistryResolutionFromHex(
            store = store,
            attempt = attempt,
            result = NearbyEventRegistryResolutionResult.VERIFIED,
            resolvedEventIdHex = EVENT_ID,
            verifiedDefinitionJoinMode = EventJoinMode.OPEN,
            verifiedDefinitionEventIdHex = EVENT_ID,
            verifiedDefinitionEventCodeHashHex = HASH,
            envelopeAgreesWithRegistry = agrees,
        ).snapshot
    }

    private companion object {
        const val EVENT_ID = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        const val OTHER_EVENT_ID = "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100"
        const val HASH = "6c86c6aac5fb24bc"

        /** A four-byte delivery header (`0x03`, hop 0, length 4) plus four envelope bytes. */
        val CONTAINER = byteArrayOf(3, 0, 0, 4, 0x11, 0x22, 0x33, 0x44)
        const val ENVELOPE_HEX = "11223344"
    }
}

private fun String.hexBytes(): ByteArray =
    chunked(2).map { it.toInt(16).toByte() }.toByteArray()
