package org.levarac.parallax.discovery

import org.levarac.parallax.registry.EventJoinMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * The three-tier B005 v2 receiver state (spec 122) as both hosts must observe
 * it. Registry status and receiver state are asserted together throughout:
 * they answer different questions and the whole point of the pair is that
 * neither implies the other.
 */
class NearbyEventReceiverStateTest {
    @Test
    fun candidateFromV1HintAloneStaysUnverified() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 1L)

        assertEquals(
            NearbyEventReceiverState.UNVERIFIED,
            assertNotNull(store.snapshot.candidateAt(0)).receiverState,
        )
    }

    @Test
    fun radioSelfVerifiedEnvelopeRaisesTheStateAndNothingElse() {
        val store = createNearbyEventDiscoveryStore()
        val update = recordEnvelope(store, observedAt = 1L)

        assertTrue(update.acceptedHint)
        assertTrue(update.changed)
        val candidate = assertNotNull(update.snapshot.candidateAt(0))
        assertEquals(NearbyEventReceiverState.RADIO_SELF_VERIFIED, candidate.receiverState)
        assertEquals(NearbyEventRegistryStatus.UNRESOLVED, candidate.registryStatus)
    }

    @Test
    fun registryAgreementPromotesWhenTheEnvelopeArrivedFirst() {
        val store = createNearbyEventDiscoveryStore()
        recordEnvelope(store, observedAt = 1L)
        val candidate = resolveRegistry(store, agrees = true)

        assertEquals(NearbyEventReceiverState.REGISTRY_VERIFIED, candidate.receiverState)
        assertEquals(NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP, candidate.registryStatus)
    }

    /**
     * A hash's registry resolution starts on its first v1 hint and completes
     * exactly once, so an envelope landing after that completion has no
     * resolution callback left to ride on and must be promoted through the
     * standalone agreement entry instead.
     */
    @Test
    fun registryAgreementPromotesWhenTheEnvelopeArrivedAfterResolution() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 1L)
        resolveRegistry(store, agrees = false)
        recordEnvelope(store, observedAt = 2L)

        val update = applyNearbyEventRegistryAgreementFromHex(store, HASH, agrees = true)

        assertTrue(update.changed)
        val candidate = assertNotNull(update.snapshot.candidateAt(0))
        assertEquals(NearbyEventReceiverState.REGISTRY_VERIFIED, candidate.receiverState)
    }

    @Test
    fun disagreementNeverPromotes() {
        val store = createNearbyEventDiscoveryStore()
        recordEnvelope(store, observedAt = 1L)
        val candidate = resolveRegistry(store, agrees = false)

        assertEquals(NearbyEventReceiverState.RADIO_SELF_VERIFIED, candidate.receiverState)
        assertEquals(NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP, candidate.registryStatus)
        assertFalse(applyNearbyEventRegistryAgreementFromHex(store, HASH, agrees = false).changed)
    }

    @Test
    fun agreementWithoutARadioSelfVerifiedEnvelopeNeverPromotes() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 1L)
        val candidate = resolveRegistry(store, agrees = true)

        assertEquals(NearbyEventReceiverState.UNVERIFIED, candidate.receiverState)
        assertEquals(NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP, candidate.registryStatus)
    }

    @Test
    fun agreementWithoutAVerifiedRegistryReadNeverPromotes() {
        val store = createNearbyEventDiscoveryStore()
        recordEnvelope(store, observedAt = 1L)
        val attempt = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
        val update = completeNearbyEventRegistryResolutionFromHex(
            store = store,
            attempt = attempt,
            result = NearbyEventRegistryResolutionResult.VERIFICATION_UNAVAILABLE,
            resolvedEventIdHex = EVENT_ID,
            verifiedDefinitionJoinMode = EventJoinMode.OPEN,
            verifiedDefinitionEventIdHex = EVENT_ID,
            verifiedDefinitionEventCodeHashHex = HASH,
            envelopeAgreesWithRegistry = true,
        )

        val candidate = assertNotNull(update.snapshot.candidateAt(0))
        assertEquals(NearbyEventReceiverState.RADIO_SELF_VERIFIED, candidate.receiverState)
        assertEquals(NearbyEventRegistryStatus.LOOKUP_UNAVAILABLE, candidate.registryStatus)
    }

    /**
     * The generation guard: a resolution belonging to a session that has since
     * expired cannot promote the hash a newer session re-observed.
     */
    @Test
    fun agreementFromASupersededResolutionNeverPromotes() {
        val store = createNearbyEventDiscoveryStore()
        recordEnvelope(store, observedAt = 0L)
        val stale = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))

        refreshNearbyEventDiscovery(store, 300_000L)
        recordEnvelope(store, observedAt = 300_001L)

        val update = completeNearbyEventRegistryResolutionFromHex(
            store = store,
            attempt = stale,
            result = NearbyEventRegistryResolutionResult.VERIFIED,
            resolvedEventIdHex = EVENT_ID,
            verifiedDefinitionJoinMode = EventJoinMode.OPEN,
            verifiedDefinitionEventIdHex = EVENT_ID,
            verifiedDefinitionEventCodeHashHex = HASH,
            envelopeAgreesWithRegistry = true,
        )

        assertFalse(update.changed)
        val candidate = assertNotNull(update.snapshot.candidateAt(0))
        assertEquals(NearbyEventReceiverState.RADIO_SELF_VERIFIED, candidate.receiverState)
        assertEquals(NearbyEventRegistryStatus.UNRESOLVED, candidate.registryStatus)
    }

    /**
     * `recordNearbyEventHint` replaces the whole registry record to retry a
     * lookup that came back unavailable. That retry must not take the receiver
     * state with it.
     */
    @Test
    fun retryingAFailedLookupKeepsTheReceiverState() {
        val store = createNearbyEventDiscoveryStore()
        recordEnvelope(store, observedAt = 1L)
        val attempt = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
        completeNearbyEventRegistryResolutionFromHex(
            store = store,
            attempt = attempt,
            result = NearbyEventRegistryResolutionResult.LOOKUP_UNAVAILABLE,
            resolvedEventIdHex = null,
            verifiedDefinitionJoinMode = null,
            verifiedDefinitionEventIdHex = null,
            verifiedDefinitionEventCodeHashHex = null,
            envelopeAgreesWithRegistry = false,
        )

        val update = recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 2L)

        val candidate = assertNotNull(update.snapshot.candidateAt(0))
        assertEquals(NearbyEventReceiverState.RADIO_SELF_VERIFIED, candidate.receiverState)
        assertEquals(NearbyEventRegistryStatus.UNRESOLVED, candidate.registryStatus)
    }

    @Test
    fun aLaterUnverifiedHintNeverLowersAnEstablishedState() {
        val store = createNearbyEventDiscoveryStore()
        recordEnvelope(store, observedAt = 1L)
        resolveRegistry(store, agrees = true)

        recordNearbyEventHint(store, "hostile", "Event", HASH.hexBytes(), null, false, false, 2L)

        assertEquals(
            NearbyEventReceiverState.REGISTRY_VERIFIED,
            assertNotNull(store.snapshot.candidateAt(0)).receiverState,
        )
    }

    @Test
    fun expiryAndResetClearTheReceiverState() {
        val store = createNearbyEventDiscoveryStore()
        recordEnvelope(store, observedAt = 0L)
        refreshNearbyEventDiscovery(store, 300_000L)
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 300_001L)
        assertEquals(
            NearbyEventReceiverState.UNVERIFIED,
            assertNotNull(store.snapshot.candidateAt(0)).receiverState,
        )

        recordEnvelope(store, observedAt = 300_002L)
        resetNearbyEventDiscovery(store)
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 300_003L)
        assertEquals(
            NearbyEventReceiverState.UNVERIFIED,
            assertNotNull(store.snapshot.candidateAt(0)).receiverState,
        )
    }

    @Test
    fun anEnvelopeNeverClearsACensusAV1HintRecorded() {
        val store = createNearbyEventDiscoveryStore()
        val census = byteArrayOf(1, 2, 3)
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), census, false, false, 1L)
        val update = recordEnvelope(store, observedAt = 2L)

        val source = assertNotNull(assertNotNull(update.snapshot.candidateAt(0)).sourceAt(0))
        assertTrue(census.contentEquals(assertNotNull(source.census)))
    }

    @Test
    fun anEnvelopeWithAMalformedHashIsRejected() {
        val store = createNearbyEventDiscoveryStore()
        val update = recordNearbyEventRadioSelfVerifiedEnvelopeFromHex(
            store = store,
            peripheralId = "p",
            eventDisplayName = "Event",
            eventCodeHashHex = "zz",
            additionalNamesOmitted = false,
            additionalEventsOmitted = false,
            observedAtEpochMillis = 1L,
        )

        assertFalse(update.acceptedHint)
        assertEquals(0, update.snapshot.candidateCount)
    }

    private fun recordEnvelope(
        store: NearbyEventDiscoveryStore,
        observedAt: Long,
    ): NearbyEventDiscoveryUpdate = recordNearbyEventRadioSelfVerifiedEnvelope(
        store = store,
        peripheralId = "p",
        eventDisplayName = "Event",
        eventCodeHash = HASH.hexBytes(),
        additionalNamesOmitted = false,
        additionalEventsOmitted = false,
        observedAtEpochMillis = observedAt,
    )

    private fun resolveRegistry(
        store: NearbyEventDiscoveryStore,
        agrees: Boolean,
    ): NearbyEventCandidate {
        val attempt = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
        return assertNotNull(
            completeNearbyEventRegistryResolutionFromHex(
                store = store,
                attempt = attempt,
                result = NearbyEventRegistryResolutionResult.VERIFIED,
                resolvedEventIdHex = EVENT_ID,
                verifiedDefinitionJoinMode = EventJoinMode.OPEN,
                verifiedDefinitionEventIdHex = EVENT_ID,
                verifiedDefinitionEventCodeHashHex = HASH,
                envelopeAgreesWithRegistry = agrees,
            ).snapshot.candidateAt(0),
        )
    }

    private companion object {
        const val EVENT_ID = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        const val HASH = "6c86c6aac5fb24bc"
    }
}

private fun String.hexBytes(): ByteArray =
    chunked(2).map { it.toInt(16).toByte() }.toByteArray()
