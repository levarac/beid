package org.levarac.parallax.discovery

import org.levarac.parallax.registry.EventJoinMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * Synthetic-clock characterization for beid#587.
 *
 * ENIN is deliberately absent from the discovery reducer's inputs. These
 * cases put observations on either side of a 300-second boundary to separate
 * a healthy envelope handoff, a registry transport failure, and actual loss
 * of the broadcast without assigning any of them to the boundary itself.
 */
class NearbyEventBoundaryCharacterizationTest {
    @Test
    fun aHealthyEnvelopeHandoffAcrossAnEninBoundaryKeepsRegistryVerification() {
        val store = verifiedStore(observedAt = 299_999L)

        val update = recordNearbyEventRadioSelfVerifiedEnvelope(
            store = store,
            peripheralId = "venue",
            eventDisplayName = "Event",
            eventCodeHash = HASH.hexBytes(),
            rawContainer = byteArrayOf(0x02),
            agreesWithRegistry = true,
            additionalNamesOmitted = false,
            additionalEventsOmitted = false,
            observedAtEpochMillis = 300_001L,
        )

        val candidate = assertNotNull(update.snapshot.candidateAt(0))
        assertEquals(NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP, candidate.registryStatus)
        assertEquals(NearbyEventReceiverState.REGISTRY_VERIFIED, candidate.receiverState)
        assertNull(update.snapshot.nextRegistryRetryAtEpochMillis)
    }

    @Test
    fun aTransientLookupFailureRetriesFromItsOwnDeadlineAcrossTheBoundary() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "venue", "Event", HASH.hexBytes(), null, false, false, 299_999L)
        val first = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
        completeNearbyEventRegistryResolutionFromHex(
            store, first, NearbyEventRegistryResolutionResult.LOOKUP_UNAVAILABLE,
            null, null, null, null, false,
        )
        val armed = refreshNearbyEventDiscovery(store, 300_001L)

        assertEquals(305_001L, armed.snapshot.nextRegistryRetryAtEpochMillis)
        refreshNearbyEventDiscovery(store, 305_000L)
        assertNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
        refreshNearbyEventDiscovery(store, 305_001L)
        assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
    }

    @Test
    fun lossOfTheBroadcastEvictsTheCandidateAtItsTtlNotAtAnEninBoundary() {
        val store = verifiedStore(observedAt = 299_999L)

        assertNotNull(refreshNearbyEventDiscovery(store, 599_998L).snapshot.candidateAt(0))
        val expired = refreshNearbyEventDiscovery(store, 599_999L).snapshot

        assertEquals(0, expired.candidateCount)
        assertNull(expired.nextRegistryRetryAtEpochMillis)
    }

    private fun verifiedStore(observedAt: Long): NearbyEventDiscoveryStore {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventRadioSelfVerifiedEnvelope(
            store, "venue", "Event", HASH.hexBytes(), byteArrayOf(0x01), false,
            false, false, observedAt,
        )
        val attempt = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
        completeNearbyEventRegistryResolutionFromHex(
            store = store,
            attempt = attempt,
            result = NearbyEventRegistryResolutionResult.VERIFIED,
            resolvedEventIdHex = EVENT_ID,
            verifiedDefinitionJoinMode = EventJoinMode.OPEN,
            verifiedDefinitionEventIdHex = EVENT_ID,
            verifiedDefinitionEventCodeHashHex = HASH,
            envelopeAgreesWithRegistry = true,
        )
        return store
    }

    private fun String.hexBytes(): ByteArray =
        ByteArray(length / 2) { index ->
            ((this[index * 2].digitToInt(16) shl 4) or this[index * 2 + 1].digitToInt(16)).toByte()
        }

    private companion object {
        const val EVENT_ID = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        const val HASH = "6c86c6aac5fb24bc"
    }
}
