package org.levarac.parallax.discovery

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NearbyEventRegistryResolutionTest {
    @Test
    fun resolutionIsDeduplicatedAndVerifiedIdIsPublished() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", ByteArray(8) { it.toByte() }, null, false, false, 1L)
        val hash = "0001020304050607"
        assertTrue(beginNearbyEventRegistryResolutionFromHex(store, hash))
        assertFalse(beginNearbyEventRegistryResolutionFromHex(store, hash))
        val update = completeNearbyEventRegistryResolutionFromHex(
            store, hash, NearbyEventRegistryResolutionResult.VERIFIED, "0x" + "ab".repeat(32),
        )
        val candidate = update.snapshot.candidateAt(0)!!
        assertEquals(NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP, candidate.registryStatus)
        assertEquals("0x" + "ab".repeat(32), candidate.resolvedEventIdHex)
    }

    @Test
    fun expiryDropsVerdictAndReappearanceStartsUnresolved() {
        val store = createNearbyEventDiscoveryStore()
        val bytes = ByteArray(8)
        recordNearbyEventHint(store, "p", "Event", bytes, null, false, false, 0L)
        assertTrue(beginNearbyEventRegistryResolutionFromHex(store, "0000000000000000"))
        completeNearbyEventRegistryResolutionFromHex(store, "0000000000000000", NearbyEventRegistryResolutionResult.NOT_REGISTERED, null)
        refreshNearbyEventDiscovery(store, 300_000L)
        recordNearbyEventHint(store, "p2", "Event", bytes, null, false, false, 300_001L)
        val candidate = store.snapshot.candidateAt(0)!!
        assertEquals(NearbyEventRegistryStatus.UNRESOLVED, candidate.registryStatus)
        assertNull(candidate.resolvedEventIdHex)
    }
}
