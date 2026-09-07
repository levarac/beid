package org.levarac.parallax.discovery

import org.levarac.parallax.registry.EventJoinMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
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

    /**
     * The record call acts on the verdict itself, so a host cannot record an
     * agreeing envelope and forget the promotion. This is the late-arrival
     * order: the hash resolved before the envelope was ever seen.
     */
    @Test
    fun recordingAnAgreeingEnvelopePromotesWithoutASecondCall() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 1L)
        resolveRegistry(store, agrees = false)

        val update = recordEnvelope(store, observedAt = 2L, agreesWithRegistry = true)

        assertTrue(update.changed)
        assertEquals(
            NearbyEventReceiverState.REGISTRY_VERIFIED,
            assertNotNull(update.snapshot.candidateAt(0)).receiverState,
        )
    }

    /**
     * The fold does not weaken the guard: an agreeing envelope for a hash the
     * registry never vouched for still promotes nothing.
     */
    @Test
    fun recordingAnAgreeingEnvelopeWithoutARegistryReadPromotesNothing() {
        val store = createNearbyEventDiscoveryStore()

        val update = recordEnvelope(store, observedAt = 1L, agreesWithRegistry = true)

        assertEquals(
            NearbyEventReceiverState.RADIO_SELF_VERIFIED,
            assertNotNull(update.snapshot.candidateAt(0)).receiverState,
        )
    }

    /** The empty-container rejection lives in the byte entry, so a host
     * calling it directly inherits it. */
    @Test
    fun anEmptyContainerIsRejectedByTheByteEntryToo() {
        val store = createNearbyEventDiscoveryStore()

        val update = recordEnvelope(store, observedAt = 1L, rawContainer = ByteArray(0))

        assertFalse(update.acceptedHint)
        assertEquals(0, update.snapshot.candidateCount)
        assertEquals(1, update.snapshot.unverifiedEnvelopeCount)
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
            rawContainerHex = "03000102",
            agreesWithRegistry = false,
            additionalNamesOmitted = false,
            additionalEventsOmitted = false,
            observedAtEpochMillis = 1L,
        )

        assertFalse(update.acceptedHint)
        assertEquals(0, update.snapshot.candidateCount)
        assertEquals(1, update.snapshot.unverifiedEnvelopeCount)
    }

    /**
     * A dropped container moves no candidate, source, omission fact or expiry
     * time, so it must not report a change: a peer transmitting garbage would
     * otherwise drive an unbounded card rebuild and expiry re-arm on every
     * receiving device.
     */
    @Test
    fun aDroppedContainerReportsNoChangeAndDisturbsNoExpirySchedule() {
        val store = createNearbyEventDiscoveryStore()
        recordEnvelope(store, observedAt = 1L)
        val before = store.snapshot

        val update = recordNearbyEventUnverifiedEnvelope(store)

        assertFalse(update.changed)
        assertEquals(before.candidateCount, update.snapshot.candidateCount)
        assertEquals(before.nextExpiryAtEpochMillis, update.snapshot.nextExpiryAtEpochMillis)
        assertEquals(1, update.snapshot.unverifiedEnvelopeCount)
    }

    /**
     * Zero bytes are not what came off the wire. A relay re-sending an empty
     * container would be worse than relaying nothing, so a container that does
     * not survive the hex boundary is rejected and counted rather than stored.
     */
    @Test
    fun aContainerThatFailsTheHexBoundaryIsRejectedRatherThanStoredEmpty() {
        listOf("zz", "", "0").forEach { badContainer ->
            val store = createNearbyEventDiscoveryStore()
            val update = recordNearbyEventRadioSelfVerifiedEnvelopeFromHex(
                store = store,
                peripheralId = "p",
                eventDisplayName = "Event",
                eventCodeHashHex = HASH,
                rawContainerHex = badContainer,
                agreesWithRegistry = false,
                additionalNamesOmitted = false,
                additionalEventsOmitted = false,
                observedAtEpochMillis = 1L,
            )

            assertFalse(update.acceptedHint, "accepted container hex '$badContainer'")
            assertEquals(0, update.snapshot.candidateCount)
            assertEquals(1, update.snapshot.unverifiedEnvelopeCount)
        }
    }

    @Test
    fun theRawContainerIsRetainedForRelayAndDroppedWithTheSession() {
        val store = createNearbyEventDiscoveryStore()
        recordEnvelope(store, observedAt = 1L)

        val candidate = assertNotNull(store.snapshot.candidateAt(0))
        assertTrue(CONTAINER.contentEquals(assertNotNull(candidate.rawEnvelopeContainer)))
        assertEquals("03000102", candidate.rawEnvelopeContainerHex)

        // A defensive copy, so a caller cannot mutate the bytes a signature
        // was computed over.
        assertNotNull(candidate.rawEnvelopeContainer)[0] = 0x7f
        assertTrue(CONTAINER.contentEquals(assertNotNull(candidate.rawEnvelopeContainer)))

        resetNearbyEventDiscovery(store)
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 2L)
        assertNull(assertNotNull(store.snapshot.candidateAt(0)).rawEnvelopeContainer)
    }

    /**
     * Barnard's radio self-check passes for any internally consistent
     * envelope, including one carrying a different key set for the same
     * event-code hash. Such an envelope cannot lower an established tier and
     * its disagreement is dropped by the promotion tier guard, so a
     * newest-wins container rule would leave a REGISTRY_VERIFIED candidate
     * holding bytes no registry read vouched for -- and those are exactly the
     * bytes a spec 134 relay re-sends.
     */
    @Test
    fun aVerifiedCandidateKeepsTheAgreedContainerAgainstADisagreeingEnvelope() {
        val store = createNearbyEventDiscoveryStore()
        recordEnvelope(store, observedAt = 1L)
        resolveRegistry(store, agrees = true)
        assertEquals(
            NearbyEventReceiverState.REGISTRY_VERIFIED,
            assertNotNull(store.snapshot.candidateAt(0)).receiverState,
        )

        val impostor = byteArrayOf(3, 0, 9, 9)
        val update = recordEnvelope(
            store,
            observedAt = 2L,
            rawContainer = impostor,
            agreesWithRegistry = false,
        )

        val candidate = assertNotNull(update.snapshot.candidateAt(0))
        assertEquals(NearbyEventReceiverState.REGISTRY_VERIFIED, candidate.receiverState)
        assertTrue(CONTAINER.contentEquals(assertNotNull(candidate.rawEnvelopeContainer)))
    }

    /**
     * The other half: a relayed copy of the same envelope differs only in its
     * hop count, which `registryAgreement` does not compare, so it agrees and
     * is allowed to replace what is held.
     */
    @Test
    fun aVerifiedCandidateSwapsInAnAgreeingEnvelope() {
        val store = createNearbyEventDiscoveryStore()
        recordEnvelope(store, observedAt = 1L)
        resolveRegistry(store, agrees = true)

        val relayed = byteArrayOf(3, 1, 1, 2)
        val update = recordEnvelope(
            store,
            observedAt = 2L,
            rawContainer = relayed,
            agreesWithRegistry = true,
        )

        val candidate = assertNotNull(update.snapshot.candidateAt(0))
        assertEquals(NearbyEventReceiverState.REGISTRY_VERIFIED, candidate.receiverState)
        assertTrue(relayed.contentEquals(assertNotNull(candidate.rawEnvelopeContainer)))
    }

    /** Below REGISTRY_VERIFIED the newest container still simply wins. */
    @Test
    fun anUnpromotedCandidateTakesTheNewestContainer() {
        val store = createNearbyEventDiscoveryStore()
        recordEnvelope(store, observedAt = 1L)

        val newer = byteArrayOf(3, 0, 4, 5)
        val update = recordEnvelope(
            store,
            observedAt = 2L,
            rawContainer = newer,
            agreesWithRegistry = false,
        )

        val candidate = assertNotNull(update.snapshot.candidateAt(0))
        assertEquals(NearbyEventReceiverState.RADIO_SELF_VERIFIED, candidate.receiverState)
        assertTrue(newer.contentEquals(assertNotNull(candidate.rawEnvelopeContainer)))
    }

    @Test
    fun aHintOnlyCandidateHasNoRawContainer() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 1L)

        assertNull(assertNotNull(store.snapshot.candidateAt(0)).rawEnvelopeContainer)
    }

    @Test
    fun anUnverifiableContainerIsCountedRatherThanVanishing() {
        val store = createNearbyEventDiscoveryStore()

        val update = recordNearbyEventUnverifiedEnvelope(store)

        assertFalse(update.acceptedHint)
        assertEquals(0, update.snapshot.candidateCount)
        assertEquals(1, update.snapshot.unverifiedEnvelopeCount)
        assertEquals(2, recordNearbyEventUnverifiedEnvelope(store).snapshot.unverifiedEnvelopeCount)
        assertEquals(0, resetNearbyEventDiscovery(store).snapshot.unverifiedEnvelopeCount)
    }

    private fun recordEnvelope(
        store: NearbyEventDiscoveryStore,
        observedAt: Long,
        rawContainer: ByteArray = CONTAINER,
        agreesWithRegistry: Boolean = false,
    ): NearbyEventDiscoveryUpdate = recordNearbyEventRadioSelfVerifiedEnvelope(
        store = store,
        peripheralId = "p",
        eventDisplayName = "Event",
        eventCodeHash = HASH.hexBytes(),
        rawContainer = rawContainer,
        agreesWithRegistry = agreesWithRegistry,
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
        val CONTAINER = byteArrayOf(3, 0, 1, 2)
    }
}

private fun String.hexBytes(): ByteArray =
    chunked(2).map { it.toInt(16).toByte() }.toByteArray()
