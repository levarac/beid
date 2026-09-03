package org.levarac.parallax.discovery

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NearbyEventRegistryResolutionTest {
    @Test
    fun matchingVerifiedDefinitionHashPublishesRegisteredEventId() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", ByteArray(8) { it.toByte() }, null, false, false, 1L)
        val hash = "0001020304050607"
        assertTrue(beginNearbyEventRegistryResolutionFromHex(store, hash))
        assertFalse(beginNearbyEventRegistryResolutionFromHex(store, hash))
        val update = completeNearbyEventRegistryResolutionFromHex(
            store = store,
            eventCodeHashHex = hash,
            result = NearbyEventRegistryResolutionResult.VERIFIED,
            resolvedEventIdHex = "0x" + "ab".repeat(32),
            verifiedDefinitionEventCodeHashHex = hash,
        )
        val candidate = update.snapshot.candidateAt(0)!!
        assertEquals(NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP, candidate.registryStatus)
        assertEquals("0x" + "ab".repeat(32), candidate.resolvedEventIdHex)
    }

    @Test
    fun missingVerifiedDefinitionHashNeverPublishesRegisteredStatus() {
        val candidate = completeVerifiedDefinition(eventCodeHash = "0001020304050607", definitionHash = null)

        assertEquals(NearbyEventRegistryStatus.LOOKUP_UNAVAILABLE, candidate.registryStatus)
        assertNull(candidate.resolvedEventIdHex)
    }

    @Test
    fun mismatchedVerifiedDefinitionHashNeverPublishesRegisteredStatus() {
        val candidate = completeVerifiedDefinition(
            eventCodeHash = "0001020304050607",
            definitionHash = "08090a0b0c0d0e0f",
        )

        assertEquals(NearbyEventRegistryStatus.LOOKUP_UNAVAILABLE, candidate.registryStatus)
        assertNull(candidate.resolvedEventIdHex)
    }

    @Test
    fun expiryDropsVerdictAndReappearanceStartsUnresolved() {
        val store = createNearbyEventDiscoveryStore()
        val bytes = ByteArray(8)
        recordNearbyEventHint(store, "p", "Event", bytes, null, false, false, 0L)
        assertTrue(beginNearbyEventRegistryResolutionFromHex(store, "0000000000000000"))
        completeNearbyEventRegistryResolutionFromHex(
            store,
            "0000000000000000",
            NearbyEventRegistryResolutionResult.NOT_REGISTERED,
            null,
            null,
        )
        refreshNearbyEventDiscovery(store, 300_000L)
        recordNearbyEventHint(store, "p2", "Event", bytes, null, false, false, 300_001L)
        val candidate = store.snapshot.candidateAt(0)!!
        assertEquals(NearbyEventRegistryStatus.UNRESOLVED, candidate.registryStatus)
        assertNull(candidate.resolvedEventIdHex)
    }

    private fun completeVerifiedDefinition(
        eventCodeHash: String,
        definitionHash: String?,
    ): NearbyEventCandidate {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(
            store,
            "p",
            "Event",
            eventCodeHash.chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
            null,
            false,
            false,
            1L,
        )
        assertTrue(beginNearbyEventRegistryResolutionFromHex(store, eventCodeHash))
        return completeNearbyEventRegistryResolutionFromHex(
            store = store,
            eventCodeHashHex = eventCodeHash,
            result = NearbyEventRegistryResolutionResult.VERIFIED,
            resolvedEventIdHex = "0x" + "ab".repeat(32),
            verifiedDefinitionEventCodeHashHex = definitionHash,
        ).snapshot.candidateAt(0)!!
    }
}
